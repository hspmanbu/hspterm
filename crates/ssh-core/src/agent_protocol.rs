//! Bounded RFC 9987 agent wire protocol. Transport permission, key selection,
//! signing and lifetime are supplied by the original session's consent lease.
//! No key-management, external-agent or filesystem operations are supported.
use std::future::Future;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

const MAX_FRAME: usize = 256 * 1024;
const MAX_KEY: usize = 16 * 1024;
const MAX_DATA: usize = 128 * 1024;
const MAX_KEYS: usize = 16;
const FAILURE: u8 = 5;

pub(crate) struct Identity {
    pub blob: Vec<u8>,
}
pub(crate) trait Signer: Send + Sync {
    fn identities(&self) -> impl Future<Output = Result<Vec<Identity>, ()>> + Send;
    /// Return an SSH signature blob (algorithm string + signature string),
    /// never a private key. Unknown keys/flags and revoked leases must fail.
    fn sign(
        &self,
        key: &[u8],
        data: &[u8],
        flags: u32,
    ) -> impl Future<Output = Result<Vec<u8>, ()>> + Send;
}
enum Request<'a> {
    Identities,
    Sign {
        key: &'a [u8],
        data: &'a [u8],
        flags: u32,
    },
    Denied,
}
fn string<'a>(input: &mut &'a [u8], limit: usize) -> Option<&'a [u8]> {
    let length = u32::from_be_bytes(input.get(..4)?.try_into().ok()?) as usize;
    if length > limit {
        return None;
    }
    let value = input.get(4..4usize.checked_add(length)?)?;
    *input = input.get(4 + length..)?;
    Some(value)
}
fn request(frame: &[u8]) -> Request<'_> {
    let Some((&kind, mut body)) = frame.split_first() else {
        return Request::Denied;
    };
    if kind == 11 && body.is_empty() {
        return Request::Identities;
    }
    if kind != 13 {
        return Request::Denied;
    }
    let Some(key) = string(&mut body, MAX_KEY) else {
        return Request::Denied;
    };
    let Some(data) = string(&mut body, MAX_DATA) else {
        return Request::Denied;
    };
    let Ok(flags) = <[u8; 4]>::try_from(body) else {
        return Request::Denied;
    };
    let flags = u32::from_be_bytes(flags);
    // SSH_AGENT_RSA_SHA2_256 / SHA2_512, or no flags for non-RSA keys.
    // The signer validates the algorithm-specific combination and SHA-1 policy.
    if flags & !6 != 0 {
        return Request::Denied;
    }
    Request::Sign { key, data, flags }
}
fn put_string(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    out.extend_from_slice(bytes);
}
async fn response<S: Signer>(signer: &S, frame: &[u8]) -> Zeroizing<Vec<u8>> {
    let failed = || Zeroizing::new(vec![FAILURE]);
    match request(frame) {
        Request::Denied => failed(),
        Request::Identities => {
            let Ok(keys) = signer.identities().await else {
                return failed();
            };
            if keys.len() > MAX_KEYS
                || keys
                    .iter()
                    .any(|k| k.blob.len() > MAX_KEY || k.blob.is_empty())
            {
                return failed();
            }
            let total = keys
                .iter()
                .try_fold(5usize, |size, key| size.checked_add(8 + key.blob.len()));
            if total.is_none_or(|size| size > MAX_FRAME) {
                return failed();
            }
            let mut out = vec![12];
            out.extend_from_slice(&(keys.len() as u32).to_be_bytes());
            for key in keys {
                put_string(&mut out, &key.blob);
                put_string(&mut out, b"");
            }
            Zeroizing::new(out)
        }
        Request::Sign { key, data, flags } => {
            let Ok(signature) = signer.sign(key, data, flags).await else {
                return failed();
            };
            if signature.is_empty() || signature.len() > MAX_KEY {
                return failed();
            }
            let mut out = vec![14];
            put_string(&mut out, &signature);
            Zeroizing::new(out)
        }
    }
}
pub(crate) async fn serve<T, S>(
    mut stream: T,
    signer: &S,
    permission: CancellationToken,
) -> std::io::Result<()>
where
    T: AsyncRead + AsyncWrite + Unpin,
    S: Signer,
{
    serve_first(&mut stream, signer, permission, None).await
}
pub(crate) async fn serve_first<T, S>(
    mut stream: T,
    signer: &S,
    permission: CancellationToken,
    mut initial: Option<Zeroizing<Vec<u8>>>,
) -> std::io::Result<()>
where
    T: AsyncRead + AsyncWrite + Unpin,
    S: Signer,
{
    loop {
        let frame = if let Some(frame) = initial.take() {
            frame
        } else {
            let mut header = [0; 4];
            tokio::select! {
                biased;
                _ = permission.cancelled() => return Ok(()),
                result = stream.read(&mut header[..1]) => {
                    if result? == 0 { return Ok(()); }
                },
            }
            tokio::select! {
                biased;
                _ = permission.cancelled() => return Ok(()),
                result = stream.read_exact(&mut header[1..]) => { result?; },
            }
            let length = u32::from_be_bytes(header) as usize;
            if length == 0 || length > MAX_FRAME {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "SSH agent frame exceeds bounds",
                ));
            }
            let mut frame = Zeroizing::new(vec![0; length]);
            tokio::select! {
                biased;
                _ = permission.cancelled() => return Ok(()),
                result = stream.read_exact(&mut frame) => { result?; },
            }
            frame
        };
        let reply = tokio::select! {
            biased;
            _ = permission.cancelled() => return Ok(()),
            reply = response(signer, &frame) => reply,
        };
        tokio::select! {
            biased;
            _ = permission.cancelled() => return Ok(()),
            result = async {
                stream.write_all(&(reply.len() as u32).to_be_bytes()).await?;
                stream.write_all(&reply).await?; stream.flush().await
            } => { result?; },
        }
        tokio::task::yield_now().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_exact_identity_and_sign_requests_are_decoded() {
        assert!(matches!(request(&[11]), Request::Identities));
        for denied in [
            vec![],
            vec![11, 0],
            vec![17],
            vec![18],
            vec![19],
            vec![22],
            vec![23],
            vec![27],
        ] {
            assert!(matches!(request(&denied), Request::Denied));
        }
        let mut frame = vec![13];
        put_string(&mut frame, b"public-key");
        put_string(&mut frame, b"challenge");
        frame.extend_from_slice(&2u32.to_be_bytes());
        assert!(matches!(
            request(&frame),
            Request::Sign {
                key: b"public-key",
                data: b"challenge",
                flags: 2
            }
        ));
        for length in 0..frame.len() {
            assert!(matches!(request(&frame[..length]), Request::Denied));
        }
        frame.push(0);
        assert!(matches!(request(&frame), Request::Denied));
        frame.pop();
        *frame.last_mut().unwrap() = 1;
        assert!(matches!(request(&frame), Request::Denied));
        assert!(string(&mut &[255, 255, 255, 255][..], MAX_DATA).is_none());
    }
}

#[cfg(test)]
mod wire_tests {
    use super::*;
    use crate::agent_signer::AgentAuthority;
    use russh::keys::{Algorithm, PrivateKey, signature::Verifier, ssh_key::Signature};
    use std::time::Duration;
    async fn exchange(stream: &mut tokio::io::DuplexStream, message: &[u8]) -> Vec<u8> {
        stream
            .write_all(&(message.len() as u32).to_be_bytes())
            .await
            .unwrap();
        stream.write_all(message).await.unwrap();
        let length = stream.read_u32().await.unwrap() as usize;
        assert!(length <= MAX_FRAME);
        let mut output = vec![0; length];
        stream.read_exact(&mut output).await.unwrap();
        output
    }
    #[tokio::test]
    async fn framed_service_signs_only_authorized_keys_and_denies_key_management() {
        let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        let public = key.public_key().clone();
        let blob = public.to_bytes().unwrap();
        let root = CancellationToken::new();
        let mut authority =
            AgentAuthority::authorised(vec![key], Duration::from_secs(60), &root).unwrap();
        let signer = authority.signer();
        let (mut client, server) = tokio::io::duplex(1024);
        let permission = signer.stop_token();
        let serving = tokio::spawn(async move { serve(server, &signer, permission).await });
        let identities = exchange(&mut client, &[11]).await;
        assert_eq!(&identities[..5], &[12, 0, 0, 0, 1]);
        let mut tail = &identities[5..];
        assert_eq!(string(&mut tail, MAX_KEY), Some(blob.as_slice()));
        assert_eq!(string(&mut tail, MAX_KEY), Some(&b""[..]));
        assert!(tail.is_empty());
        for kind in [17, 18, 19, 20, 22, 23, 25, 26, 27] {
            assert_eq!(exchange(&mut client, &[kind]).await, [FAILURE]);
        }
        let mut request = vec![13];
        put_string(&mut request, &blob);
        put_string(&mut request, b"wire challenge");
        request.extend_from_slice(&0u32.to_be_bytes());
        let result = exchange(&mut client, &request).await;
        assert_eq!(result[0], 14);
        let mut tail = &result[1..];
        let signature = Signature::try_from(string(&mut tail, MAX_KEY).unwrap()).unwrap();
        Verifier::verify(&public, b"wire challenge", &signature).unwrap();
        assert!(tail.is_empty());
        authority.shutdown().await.unwrap();
        serving.await.unwrap().unwrap();
        assert!(!root.is_cancelled());
    }
    #[tokio::test]
    async fn malformed_frames_close_only_the_stream_and_cancellation_interrupts_partial_frames() {
        for input in [
            vec![0, 0, 0, 0],
            vec![0xff, 0xff, 0xff, 0xff],
            vec![0, 0],
            vec![0, 0, 0, 5, 11],
        ] {
            let root = CancellationToken::new();
            let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
            let mut authority =
                AgentAuthority::authorised(vec![key], Duration::from_secs(60), &root).unwrap();
            let signer = authority.signer();
            let (mut client, server) = tokio::io::duplex(64);
            client.write_all(&input).await.unwrap();
            client.shutdown().await.unwrap();
            assert!(serve(server, &signer, signer.stop_token()).await.is_err());
            assert!(signer.active());
            authority.shutdown().await.unwrap();
        }
        let root = CancellationToken::new();
        let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        let mut authority =
            AgentAuthority::authorised(vec![key], Duration::from_secs(60), &root).unwrap();
        let signer = authority.signer();
        let (mut client, server) = tokio::io::duplex(64);
        client.write_all(&[0, 0]).await.unwrap();
        let serving =
            tokio::spawn(async move { serve(server, &signer, signer.stop_token()).await });
        authority.shutdown().await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), serving)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }
}
