//! SSH -D style SOCKS5 CONNECT subset. Exact reads preserve pipelined payload.
use crate::{SshError, Stage, TcpChannel, TcpConnector, proxy};
use std::{
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    time::{Instant, timeout},
};
use tokio_util::sync::CancellationToken;

#[derive(Debug, thiserror::Error)]
pub enum Socks5Error {
    #[error("SOCKS5 版本或保留字段无效")]
    Version,
    #[error("动态转发仅接受无需认证的 SOCKS5 客户端")]
    Method,
    #[error("动态转发仅支持 SOCKS5 CONNECT，不支持 BIND 或 UDP")]
    Command,
    #[error("SOCKS5 目标地址或端口无效")]
    Address,
}
struct Destination {
    address: String,
    port: u16,
}
async fn reply(stream: &mut (impl AsyncWrite + Unpin), code: u8) -> Result<(), SshError> {
    // SSH direct-tcpip does not expose the server's outbound socket address.
    // An unspecified binding is returned; never invent a local/remote binding.
    stream.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    Ok(())
}
async fn reject(
    stream: &mut (impl AsyncWrite + Unpin),
    code: u8,
    error: Socks5Error,
) -> Result<Destination, SshError> {
    reply(stream, code).await?;
    Err(error.into())
}
async fn negotiate(
    stream: &mut (impl AsyncRead + AsyncWrite + Unpin),
) -> Result<Destination, SshError> {
    let mut greeting = [0; 2];
    stream.read_exact(&mut greeting).await?;
    if greeting[0] != 5 {
        return Err(Socks5Error::Version.into());
    }
    let mut methods = vec![0; greeting[1] as usize];
    stream.read_exact(&mut methods).await?;
    if !methods.contains(&0) {
        stream.write_all(&[5, 255]).await?;
        return Err(Socks5Error::Method.into());
    }
    stream.write_all(&[5, 0]).await?;
    let mut header = [0; 4];
    stream.read_exact(&mut header).await?;
    if header[0] != 5 || header[2] != 0 {
        return reject(stream, 1, Socks5Error::Version).await;
    }
    if header[1] != 1 {
        return reject(stream, 7, Socks5Error::Command).await;
    }
    let address = match header[3] {
        1 => {
            let mut ip = [0; 4];
            stream.read_exact(&mut ip).await?;
            Ipv4Addr::from(ip).to_string()
        }
        4 => {
            let mut ip = [0; 16];
            stream.read_exact(&mut ip).await?;
            Ipv6Addr::from(ip).to_string()
        }
        3 => {
            let length = stream.read_u8().await? as usize;
            let mut bytes = vec![0; length];
            stream.read_exact(&mut bytes).await?;
            match String::from_utf8(bytes) {
                Ok(value) if proxy::host(&value).is_some() => value,
                _ => return reject(stream, 8, Socks5Error::Address).await,
            }
        }
        _ => return reject(stream, 8, Socks5Error::Address).await,
    };
    let port = stream.read_u16().await?;
    if port == 0 {
        return reject(stream, 8, Socks5Error::Address).await;
    }
    Ok(Destination { address, port })
}

pub(super) async fn connect(
    socket: &mut TcpStream,
    connector: &TcpConnector,
    origin: SocketAddr,
    deadline: Duration,
    cancel: CancellationToken,
) -> Result<TcpChannel, SshError> {
    let started = Instant::now();
    let target = timeout(deadline, negotiate(socket))
        .await
        .map_err(|_| SshError::Timeout(Stage::Forward))??;
    let remaining = deadline.saturating_sub(started.elapsed());
    let result = if remaining.is_zero() {
        Err(SshError::Timeout(Stage::Forward))
    } else {
        connector
            .open(&target.address, target.port, origin, remaining, cancel)
            .await
    };
    let code = match &result {
        Ok(_) => 0,
        Err(SshError::Protocol(russh::Error::ChannelOpenFailure(
            russh::ChannelOpenFailure::AdministrativelyProhibited,
        ))) => 2,
        Err(_) => 1,
    };
    // A final small reply has its own bounded write, never an unbounded wait on
    // a client that stopped reading. Only confirmed SSH opens receive success.
    timeout(deadline.min(Duration::from_secs(1)), reply(socket, code))
        .await
        .map_err(|_| SshError::Timeout(Stage::Forward))??;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn ipv4_ipv6_and_domain_requests_preserve_trailing_application_bytes() {
        for (kind, data, expected) in [
            (1, vec![127, 0, 0, 1], "127.0.0.1"),
            (4, Ipv6Addr::LOCALHOST.octets().to_vec(), "::1"),
            (3, b"\x12target-via.invalid".to_vec(), "target-via.invalid"),
        ] {
            let (mut client, mut server) = tokio::io::duplex(2048);
            let mut bytes = vec![5, 2, 2, 0, 5, 1, 0, kind];
            bytes.extend(data);
            bytes.extend_from_slice(&2222_u16.to_be_bytes());
            bytes.extend_from_slice(b"application-payload");
            client.write_all(&bytes).await.unwrap();
            let result = negotiate(&mut server).await.unwrap();
            assert_eq!(result.address, expected);
            assert_eq!(result.port, 2222);
            let mut payload = [0; 19];
            server.read_exact(&mut payload).await.unwrap();
            assert_eq!(&payload, b"application-payload");
            let mut method = [0; 2];
            client.read_exact(&mut method).await.unwrap();
            assert_eq!(method, [5, 0]);
        }
    }
    #[tokio::test]
    async fn unsupported_or_malformed_requests_have_bounded_static_errors_and_explicit_replies() {
        for (packet, expected) in [
            (vec![4, 1, 0], vec![]),
            (vec![5, 1, 2], vec![5, 255]),
            (vec![5, 0], vec![5, 255]),
            (vec![5, 1, 0, 5, 2, 0, 1], vec![5, 0, 5, 7]),
            (vec![5, 1, 0, 5, 3, 0, 1], vec![5, 0, 5, 7]),
            (vec![5, 1, 0, 5, 1, 1, 1], vec![5, 0, 5, 1]),
            (vec![5, 1, 0, 4, 1, 0, 1], vec![5, 0, 5, 1]),
            (vec![5, 1, 0, 5, 1, 0, 9], vec![5, 0, 5, 8]),
            (vec![5, 1, 0, 5, 1, 0, 3, 0], vec![5, 0, 5, 8]),
            (vec![5, 1, 0, 5, 1, 0, 3, 1, 255], vec![5, 0, 5, 8]),
            (vec![5, 1, 0, 5, 1, 0, 4, 0, 0], vec![5, 0]),
            (
                b"\x05\x01\0\x05\x01\0\x03\x0bsecret\0host".to_vec(),
                vec![5, 0, 5, 8],
            ),
            (
                vec![5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, 0, 0],
                vec![5, 0, 5, 8],
            ),
        ] {
            let (mut client, mut server) = tokio::io::duplex(2048);
            client.write_all(&packet).await.unwrap();
            client.shutdown().await.unwrap();
            let error = negotiate(&mut server)
                .await
                .err()
                .expect("invalid request accepted");
            assert!(!format!("{error:?}").contains("secret"));
            drop(server);
            let mut received = Vec::new();
            client.read_to_end(&mut received).await.unwrap();
            assert!(received.starts_with(&expected));
            assert!(received.len() <= 12);
        }
    }
}
