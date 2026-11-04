use tokio::sync::mpsc::Sender;

use super::WindowSizeRef;
use crate::ChannelMsg;

/// A handle to the [`super::Channel`]'s to be able to transmit messages
/// to it and update it's `window_size`.
#[derive(Debug)]
pub struct ChannelRef {
    pub(super) sender: Sender<ChannelMsg>,
    pub(super) window_size: WindowSizeRef,
    pub(crate) flow: Option<super::flow_control::FlowSender>,
}

impl ChannelRef {
    pub fn new(sender: Sender<ChannelMsg>) -> Self {
        Self {
            sender,
            window_size: WindowSizeRef::new(0),
            flow: None,
        }
    }

    pub(crate) fn window_size(&self) -> &WindowSizeRef {
        &self.window_size
    }
    pub async fn send(
        &self,
        message: ChannelMsg,
    ) -> Result<(), tokio::sync::mpsc::error::SendError<ChannelMsg>> {
        // Opening replies still go to wait_channel_confirmation's raw receiver.
        if let Some(flow) = &self.flow
            && !matches!(
                message,
                ChannelMsg::Open { .. } | ChannelMsg::OpenFailure(_)
            )
        {
            return flow
                .send(message)
                .map_err(tokio::sync::mpsc::error::SendError);
        }
        self.sender.send(message).await
    }
    pub fn try_send(
        &self,
        message: ChannelMsg,
    ) -> Result<(), tokio::sync::mpsc::error::TrySendError<ChannelMsg>> {
        if let Some(flow) = &self.flow {
            return flow
                .send(message)
                .map_err(tokio::sync::mpsc::error::TrySendError::Closed);
        }
        self.sender.try_send(message)
    }
}

impl std::ops::Deref for ChannelRef {
    type Target = Sender<ChannelMsg>;

    fn deref(&self) -> &Self::Target {
        &self.sender
    }
}
