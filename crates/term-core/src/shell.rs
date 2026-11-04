//! Only what the remote stream reported. These phases are not proof of a safe
//! POSIX shell, echo mode, cursor position or locally tracked command input.
use alacritty_terminal::vte::ansi::ShellMarker;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ShellPhase {
    #[default]
    Unknown,
    Prompt,
    Input,
    Output,
    Finished,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ShellContext {
    pub phase: ShellPhase,
    /// Runtime prompt counter only, not a persistent command ID.
    pub sequence: u64,
    pub revision: u64,
    pub exit_status: Option<u8>,
}

#[derive(Default)]
pub(crate) struct ShellState {
    pub context: ShellContext,
}
impl ShellState {
    pub fn apply(&mut self, marker: ShellMarker) {
        let before = self.context;
        match marker {
            ShellMarker::Prompt => {
                self.context.sequence = self.context.sequence.wrapping_add(1);
                self.context.phase = ShellPhase::Prompt;
                self.context.exit_status = None;
            }
            ShellMarker::Input if self.context.phase == ShellPhase::Prompt => {
                self.context.phase = ShellPhase::Input;
            }
            ShellMarker::Output if self.context.phase == ShellPhase::Input => {
                self.context.phase = ShellPhase::Output;
            }
            ShellMarker::Finished(status) if self.context.phase == ShellPhase::Output => {
                self.context.phase = ShellPhase::Finished;
                self.context.exit_status = status;
            }
            ShellMarker::Finished(_) if self.context.phase != ShellPhase::Input => return,
            _ => {
                self.context.phase = ShellPhase::Unknown;
                self.context.exit_status = None;
            }
        }
        if self.context != before {
            self.context.revision = before.revision.wrapping_add(1);
        }
    }
    pub fn invalidate(&mut self) {
        self.apply(ShellMarker::Invalid);
    }
}
