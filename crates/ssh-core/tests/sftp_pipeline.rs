//! Explicit wire-level pipeline gates: no real credentials or server required.
use bytes::Bytes;
use hspterm_ssh_core::{
    SftpSession,
    transfer::{FileDisposition, download_file, upload_file},
};
use russh_sftp::protocol::{Attrs, Data, FileAttributes, Handle, Packet, StatusCode, Version};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, DuplexStream},
    sync::Notify,
    time::{Duration, timeout},
};
use tokio_util::sync::CancellationToken;

async fn packet(stream: &mut DuplexStream) -> Packet {
    let length = stream.read_u32().await.unwrap() as usize;
    assert!(length <= 131072);
    let mut frame = vec![0; length];
    stream.read_exact(&mut frame).await.unwrap();
    Packet::try_from(&mut Bytes::from(frame)).unwrap()
}
async fn send(stream: &mut DuplexStream, packet: Packet) {
    stream
        .write_all(&Bytes::try_from(packet).unwrap())
        .await
        .unwrap();
}

#[tokio::test]
async fn bounded_offset_pipeline_waits_for_contiguous_ack_and_drains_before_close() {
    for (uploading, fail) in [(true, false), (false, false), (true, true), (false, true)] {
        let data: Arc<Vec<u8>> =
            Arc::new((0..2 * 1024 * 1024 + 37).map(|i| (i % 251) as u8).collect());
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let confirmed = Arc::new(AtomicU64::new(0));
        let (client, mut server) = tokio::io::duplex(2 * 1024 * 1024);
        let (ready, gate, content) = (entered.clone(), release.clone(), data.clone());
        let peer = tokio::spawn(async move {
            assert!(matches!(packet(&mut server).await, Packet::Init(_)));
            let mut version = Version::new();
            version
                .extensions
                .insert("fsync@openssh.com".into(), "1".into());
            send(&mut server, Packet::Version(version)).await;
            let mut first_window = Vec::new();
            let mut gated = false;
            let mut written = vec![0; content.len()];
            let mut packets = 0;
            let mut fsyncs = 0;
            loop {
                let response = match packet(&mut server).await {
                    Packet::Lstat(p) if uploading => Packet::error(p.id, StatusCode::NoSuchFile),
                    Packet::Lstat(p) => Packet::Attrs(Attrs {
                        id: p.id,
                        attrs: FileAttributes {
                            size: Some(content.len() as u64),
                            permissions: Some(0o100600),
                            ..Default::default()
                        },
                    }),
                    Packet::Fstat(p) => Packet::Attrs(Attrs {
                        id: p.id,
                        attrs: FileAttributes {
                            size: Some(content.len() as u64),
                            permissions: Some(0o100600),
                            ..Default::default()
                        },
                    }),
                    Packet::Open(p) => Packet::Handle(Handle {
                        id: p.id,
                        handle: "pipeline".into(),
                    }),
                    Packet::Write(p) => {
                        assert!(p.data.len() <= 65536);
                        let start = p.offset as usize;
                        written[start..start + p.data.len()].copy_from_slice(&p.data);
                        packets += 1;
                        Packet::status(p.id, StatusCode::Ok, "", "")
                    }
                    Packet::Read(p) => {
                        assert!(p.len <= 65536);
                        let start = p.offset as usize;
                        packets += 1;
                        Packet::Data(Data {
                            id: p.id,
                            data: content[start..(start + p.len as usize).min(content.len())]
                                .to_vec(),
                        })
                    }
                    Packet::Extended(p) => {
                        assert_eq!(p.request, "fsync@openssh.com");
                        fsyncs += 1;
                        Packet::status(p.id, StatusCode::Ok, "", "")
                    }
                    Packet::Close(p) => {
                        assert!(gated);
                        send(&mut server, Packet::status(p.id, StatusCode::Ok, "", "")).await;
                        assert_eq!(fsyncs, usize::from(uploading && !fail));
                        if uploading && !fail {
                            assert_eq!(written, *content);
                        }
                        return packets;
                    }
                    other => panic!("unexpected request {other:?}"),
                };
                if packets > 0 && matches!(response, Packet::Data(_) | Packet::Status(_)) && !gated
                {
                    first_window.push(response);
                    if first_window.len() < 16 {
                        continue;
                    }
                    // Confirm the later fifteen requests first. The first
                    // missing ACK must prevent ANY published checkpoint.
                    while first_window.len() > 1 {
                        let first = first_window.pop().unwrap();
                        let first = if fail {
                            let id = match first {
                                Packet::Status(p) => p.id,
                                Packet::Data(p) => p.id,
                                _ => unreachable!(),
                            };
                            Packet::error(id, StatusCode::Failure)
                        } else {
                            first
                        };
                        send(&mut server, first).await;
                    }
                    ready.notify_one();
                    gate.notified().await;
                    let first = first_window.pop().unwrap();
                    let first = if fail {
                        let id = match first {
                            Packet::Status(p) => p.id,
                            Packet::Data(p) => p.id,
                            _ => unreachable!(),
                        };
                        Packet::error(id, StatusCode::Failure)
                    } else {
                        first
                    };
                    send(&mut server, first).await;
                    gated = true;
                } else {
                    send(&mut server, response).await;
                }
            }
        });
        let session = Arc::new(SftpSession::new(client).await.unwrap());
        let remote = session.clone();
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("contents");
        if uploading {
            std::fs::write(&path, &*data).unwrap();
        }
        let local = path.clone();
        let progress = confirmed.clone();
        let transfer = tokio::spawn(async move {
            let changed = |p: hspterm_ssh_core::transfer::FileProgress| {
                progress.store(p.acknowledged, Ordering::SeqCst);
            };
            if uploading {
                upload_file(
                    &remote,
                    &local,
                    "/fixture",
                    FileDisposition::CreateNew,
                    &CancellationToken::new(),
                    changed,
                )
                .await
            } else {
                download_file(
                    &remote,
                    "/fixture",
                    &local,
                    FileDisposition::CreateNew,
                    &CancellationToken::new(),
                    changed,
                )
                .await
            }
        });
        timeout(Duration::from_secs(5), entered.notified())
            .await
            .unwrap();
        tokio::task::yield_now().await;
        assert_eq!(confirmed.load(Ordering::SeqCst), 0);
        assert!(!transfer.is_finished());
        release.notify_one();
        let done = timeout(Duration::from_secs(5), transfer)
            .await
            .unwrap()
            .unwrap();
        if fail {
            assert!(done.is_err());
            assert_eq!(confirmed.load(Ordering::SeqCst), 0);
        } else {
            assert_eq!(done.unwrap().acknowledged, data.len() as u64);
            if !uploading {
                assert_eq!(std::fs::read(path).unwrap(), *data);
            }
        }
        assert!(peer.await.unwrap() >= 16);
        session.close().await.unwrap();
    }
}
