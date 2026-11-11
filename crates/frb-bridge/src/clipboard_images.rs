//! One ephemeral image operation per terminal, sharing transfer admission and
//! bandwidth limits. Child channels remain owned until actual cleanup succeeds.
use anyhow::{Result, bail};
use hspterm_ssh_core::{ManagedSession, SessionPhase};
use parking_lot::Mutex;
use rand::RngCore;
use std::{
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
};
use tokio_util::sync::CancellationToken;

struct Progress {
    generation: u64,
    local: PathBuf,
    path: String,
    done: u64,
    total: u64,
}

#[derive(Default)]
pub(crate) struct Uploads {
    gate: tokio::sync::Mutex<()>,
    active: Mutex<Option<CancellationToken>>,
    channels: crate::transfer_channels::Channels,
    progress: Mutex<Option<Progress>>,
}
impl Uploads {
    pub(crate) fn progress(&self, generation: u64, local: &Path) -> String {
        match &*self.progress.lock() {
            Some(value) if value.generation == generation && value.local == local => {
                serde_json::json!({"path": value.path, "done": value.done, "total": value.total})
                    .to_string()
            }
            _ => "{}".to_owned(),
        }
    }

    pub(crate) async fn upload(
        &self,
        session: &ManagedSession,
        generation: u64,
        closing: &AtomicBool,
        local: &Path,
    ) -> Result<String> {
        let _gate = self.gate.lock().await;
        let stop = CancellationToken::new();
        {
            let mut active = self.active.lock();
            let state = session.status();
            if closing.load(Ordering::Acquire)
                || state.phase != SessionPhase::Connected
                || state.generation != generation
            {
                bail!("原图片粘贴会话已断开或改变，未上传");
            }
            *active = Some(stop.clone());
            self.progress.lock().take();
        }
        let mut states = session.subscribe();
        let changed = async {
            loop {
                let state = states.borrow_and_update().clone();
                if state.phase != SessionPhase::Connected || state.generation != generation {
                    break;
                }
                if states.changed().await.is_err() {
                    break;
                }
            }
        };
        let mut permit = None;
        let outcome = self
            .channels
            .supervise(async {
                let work = async {
                    let (admission, budget) = crate::transfers::content_admission(true)?;
                    permit = Some(admission.enter(&stop).await?);
                    let remote = self.channels.open(session, generation, &stop).await?;
                    let mut nonce = [0; 16];
                    rand::rngs::OsRng.try_fill_bytes(&mut nonce)?;
                    let nonce = nonce.iter().map(|b| format!("{b:02x}")).collect::<String>();
                    Ok(hspterm_ssh_core::clipboard_image::upload_observed(
                        &remote,
                        local,
                        &nonce,
                        &stop,
                        &budget,
                        |path, value| {
                            *self.progress.lock() = Some(Progress {
                                generation,
                                local: local.to_owned(),
                                path: path.to_owned(),
                                done: value.acknowledged,
                                total: value.total,
                            });
                        },
                    )
                    .await?)
                };
                tokio::pin!(work);
                tokio::select! {
                    result = &mut work => result,
                    _ = changed => {
                        stop.cancel();
                        // Do not drop an operation with outstanding WRITE requests.
                        work.await
                    }
                }
            })
            .await;
        self.active.lock().take();
        outcome
    }
    pub(crate) async fn stop(&self) -> Result<()> {
        if let Some(stop) = self.active.lock().as_ref() {
            stop.cancel();
        }
        let _gate = self.gate.lock().await;
        self.channels.retire().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshots_are_bound_to_generation_and_the_exact_local_upload() {
        let uploads = Uploads::default();
        *uploads.progress.lock() = Some(Progress {
            generation: 7,
            local: PathBuf::from("first.png"),
            path: "/tmp/private/clipboard.png".into(),
            done: 512,
            total: 1024,
        });
        assert_eq!(uploads.progress(8, Path::new("first.png")), "{}");
        assert_eq!(uploads.progress(7, Path::new("next.png")), "{}");
        let value: serde_json::Value =
            serde_json::from_str(&uploads.progress(7, Path::new("first.png"))).unwrap();
        assert_eq!(value["done"], 512);
        assert_eq!(value["path"], "/tmp/private/clipboard.png");
    }
}
