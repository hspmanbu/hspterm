//! One ephemeral image operation per terminal, sharing transfer admission and
//! bandwidth limits. Child channels remain owned until actual cleanup succeeds.
use anyhow::{Result, bail};
use hspterm_ssh_core::{ManagedSession, SessionPhase};
use parking_lot::Mutex;
use rand::RngCore;
use std::{
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
};
use tokio_util::sync::CancellationToken;

#[derive(Default)]
pub(crate) struct Uploads {
    gate: tokio::sync::Mutex<()>,
    active: Mutex<Option<CancellationToken>>,
    channels: crate::transfer_channels::Channels,
}
impl Uploads {
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
                    Ok(hspterm_ssh_core::clipboard_image::upload(
                        &remote, local, &nonce, &stop, &budget,
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
