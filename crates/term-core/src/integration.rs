//! Opt-in Readline protocol state. This is independent of passive OSC133.
//! The owner must bind one fresh nonce to one authenticated PTY generation and
//! feed only complete private packets from the terminal parser. It must retire
//! this state on disconnect, reset, TUI/IME entry, or unsupported input.
//!
//! No screen scraping, persistence, terminal-buffer mutation, or guessed erase
//! sequence. Plans require a remote compare-and-apply ACK before new proof can
//! be used. This protocol assumes the explicitly selected remote helper is
//! trusted; it is not a security boundary against a malicious SSH server.
use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

pub const MAX_LINE: usize = 4096;
const MAX_PACKET: usize = 2 * MAX_LINE + 160;
const ACK_TIMEOUT: Duration = Duration::from_secs(2);

/// Opaque to diagnostics, Debug and serialization. No client-supplied arbitrary
/// shell script is carried by this state.
pub struct Nonce(Zeroizing<String>);
impl Nonce {
    pub fn parse(value: String) -> Option<Self> {
        let value = Zeroizing::new(value);
        (value.len() == 64
            && value
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
        .then_some(Self(value))
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Proof {
    pub prompt: u64,
    pub revision: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Unavailable,
    Changed,
    Unsupported,
    Capacity,
}
/// An eligible *candidate for filtering* only, never persistence authorization.
/// The bridge must still validate original host/Vault/PTY, temporary overrides,
/// record preference and the history repository's sensitive-text filter.
pub struct Submission {
    pub prompt: u64,
    pub text: Zeroizing<String>,
}
#[derive(Clone, Copy)]
pub enum Edit<'a> {
    Replace(&'a str),
    Insert(&'a str),
    /// Explicit user-run history selection; not an arbitrary automatic action.
    Execute(&'a str),
}
pub struct Plan {
    pub request: u64,
    pub prompt: u64,
    pub execute: bool,
    /// Private Readline binding plus a hex-only framed request. Never log.
    pub bytes: Zeroizing<Vec<u8>>,
}
struct PendingEdit {
    id: u64,
    prompt: u64,
    text: Zeroizing<String>,
    execute: bool,
    until: Instant,
}
struct PendingEnter {
    request: Option<u64>,
    prompt: u64,
    text: Zeroizing<String>,
    until: Instant,
}
pub struct State {
    nonce: Nonce,
    prompt: u64,
    revision: u64,
    next_request: u64,
    ready: bool,
    text: Zeroizing<String>,
    /// Mirror of Readline's POINT in characters. Exact while every tracked
    /// edit appended at the caret: pure caret keys move it without touching
    /// the proof, and any edit with the caret before the end fail-closes in
    /// typed/backspace instead of guessing the insertion point.
    caret: usize,
    edit: Option<PendingEdit>,
    enter: Option<PendingEnter>,
    receipts: VecDeque<(u64, bool)>,
}

/// Caret-only movement; the mirrored line text is untouched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaretMove {
    Left,
    Right,
    Home,
    End,
}
fn single_line(text: &str) -> bool {
    text.len() <= MAX_LINE && !text.chars().any(char::is_control)
}
fn hex(text: &str) -> Zeroizing<String> {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut result = Zeroizing::new(String::with_capacity(text.len() * 2));
    for byte in text.bytes() {
        result.push(DIGITS[(byte >> 4) as usize] as char);
        result.push(DIGITS[(byte & 15) as usize] as char);
    }
    result
}
fn unhex(raw: &str) -> Option<Zeroizing<String>> {
    if raw.len() > 2 * MAX_LINE || !raw.len().is_multiple_of(2) {
        return None;
    }
    let mut bytes = Zeroizing::new(Vec::with_capacity(raw.len() / 2));
    fn digit(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            _ => None,
        }
    }
    for pair in raw.as_bytes().as_chunks::<2>().0 {
        bytes.push((digit(pair[0])? << 4) | digit(pair[1])?);
    }
    let text = std::str::from_utf8(&bytes).ok()?;
    single_line(text).then(|| Zeroizing::new(text.to_owned()))
}
fn number(text: &str) -> Option<u64> {
    if text.is_empty() || text.len() > 20 || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let result = text.parse::<u64>().ok()?;
    (result.to_string() == text).then_some(result)
}
impl State {
    pub fn new(nonce: Nonce) -> Self {
        Self {
            nonce,
            prompt: 0,
            revision: 0,
            next_request: 0,
            ready: false,
            text: Zeroizing::new(String::new()),
            caret: 0,
            edit: None,
            enter: None,
            receipts: VecDeque::new(),
        }
    }
    fn receipt(&mut self, request: u64, accepted: bool) {
        self.receipts.push_back((request, accepted));
        while self.receipts.len() > 8 {
            self.receipts.pop_front();
        }
        self.revision = self.revision.saturating_add(1);
    }
    pub fn outcome(&self, request: u64) -> Option<bool> {
        self.receipts
            .iter()
            .rev()
            .find(|(id, _)| *id == request)
            .map(|(_, ok)| *ok)
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn has_prompt(&self) -> bool {
        self.prompt != 0
    }
    pub fn deadline(&self) -> Option<Instant> {
        self.edit
            .as_ref()
            .map(|p| p.until)
            .into_iter()
            .chain(self.enter.as_ref().map(|p| p.until))
            .min()
    }
    pub fn input(&self) -> Option<(Proof, Zeroizing<String>)> {
        self.proof().map(|proof| (proof, self.text.clone()))
    }
    pub fn invalidate(&mut self) {
        if let Some(edit) = self.edit.take() {
            self.receipt(edit.id, false);
        }
        if let Some(enter) = self.enter.take()
            && let Some(id) = enter.request
        {
            self.receipt(id, false);
        }
        self.ready = false;
        self.text = Zeroizing::new(String::new());
        self.caret = 0;
        self.edit = None;
        self.enter = None;
        self.revision = self.revision.saturating_add(1);
    }
    pub fn proof(&self) -> Option<Proof> {
        (self.ready && self.revision != u64::MAX).then_some(Proof {
            prompt: self.prompt,
            revision: self.revision,
        })
    }
    /// Borrow only for bounded local matching; never copy to diagnostics.
    pub fn prefix(&self) -> Option<&str> {
        self.proof().map(|_| self.text.as_str())
    }
    pub fn expire(&mut self, now: Instant) {
        if self.edit.as_ref().is_some_and(|p| now >= p.until)
            || self.enter.as_ref().is_some_and(|p| now >= p.until)
        {
            self.invalidate();
        }
    }
    /// Caret-only movement (plain arrows/Home/End). The line text — and so
    /// the suggestion prefix and proof — is unchanged; only the mirrored
    /// POINT moves. No revision bump: a click that dismissed the box must
    /// not resurrect it until the input actually changes.
    pub fn caret(&mut self, movement: CaretMove) {
        if !self.ready || self.edit.is_some() {
            return;
        }
        let chars = self.text.chars().count();
        self.caret = match movement {
            CaretMove::Left => self.caret.saturating_sub(1),
            CaretMove::Right => (self.caret + 1).min(chars),
            CaretMove::Home => 0,
            CaretMove::End => chars,
        };
    }
    /// Invoke in the PTY owner's input order. Any unsupported key/paste/IME or
    /// cursor/history edit must call invalidate rather than infer an edit.
    pub fn typed(&mut self, text: &str) -> Result<(), Failure> {
        if !self.ready || self.edit.is_some() {
            self.invalidate();
            return Err(Failure::Unavailable);
        }
        if self.caret != self.text.chars().count() {
            // The caret sits before the end, so the remote inserted mid-line
            // while the mirror can only append; guessing would desync it.
            self.invalidate();
            return Err(Failure::Unavailable);
        }
        if !single_line(text) || self.text.len().saturating_add(text.len()) > MAX_LINE {
            self.invalidate();
            return Err(Failure::Unsupported);
        }
        self.caret += text.chars().count();
        self.text.push_str(text);
        self.revision = self.revision.checked_add(1).ok_or_else(|| {
            self.invalidate();
            Failure::Capacity
        })?;
        Ok(())
    }
    /// Backspace after non-ASCII input is deliberately uncertain until a fresh
    /// prompt; different Readline locales/grapheme policies must not be guessed.
    pub fn backspace(&mut self) -> Result<(), Failure> {
        if !self.ready || !self.text.is_ascii() || self.caret != self.text.chars().count() {
            self.invalidate();
            return Err(Failure::Unsupported);
        }
        self.caret = self.caret.saturating_sub(1);
        self.text.pop();
        self.revision = self.revision.checked_add(1).ok_or_else(|| {
            self.invalidate();
            Failure::Capacity
        })?;
        Ok(())
    }
    /// Called for one ordinary Enter, immediately BEFORE its bytes are sent.
    /// No collection until a matching helper submission confirms actual input.
    pub fn submitted_enter(&mut self, now: Instant) {
        let pending = if self.ready && !self.text.is_empty() {
            Some(PendingEnter {
                request: None,
                prompt: self.prompt,
                text: self.text.clone(),
                until: now + ACK_TIMEOUT,
            })
        } else {
            None
        };
        self.invalidate();
        self.enter = pending;
    }
    pub fn plan(&mut self, proof: Proof, edit: Edit<'_>, now: Instant) -> Result<Plan, Failure> {
        self.expire(now);
        if self.proof() != Some(proof) {
            return Err(Failure::Changed);
        }
        let added = match &edit {
            Edit::Replace(text) | Edit::Insert(text) | Edit::Execute(text) => *text,
        };
        if !single_line(added)
            || (matches!(edit, Edit::Insert(_))
                && self.text.len().saturating_add(added.len()) > MAX_LINE)
        {
            return Err(Failure::Unsupported);
        }
        let (next, execute) = match edit {
            Edit::Replace(text) => (Zeroizing::new(text.to_owned()), false),
            Edit::Execute(text) => (Zeroizing::new(text.to_owned()), true),
            Edit::Insert(text) => {
                let mut next = self.text.clone();
                next.push_str(text);
                (next, false)
            }
        };
        if !single_line(&next) {
            return Err(Failure::Unsupported);
        }
        let id = self.next_request.checked_add(1).ok_or(Failure::Capacity)?;
        let mut bytes = Zeroizing::new(Vec::new());
        // Binding dispatch is exact; the helper must never evaluate this body.
        bytes.extend_from_slice(b"\x1b[9876~");
        let packet = Zeroizing::new(format!(
            "HSP1;{};{};{};{};{};{}",
            self.nonce.0.as_str(),
            self.prompt,
            id,
            u8::from(execute),
            hex(&self.text).as_str(),
            hex(&next).as_str()
        ));
        bytes.extend_from_slice(format!("{:05}", packet.len()).as_bytes());
        bytes.extend_from_slice(packet.as_bytes());
        if execute {
            // The helper enables this commit macro only after exact validation;
            // it is a no-op on rejection. No raw Enter is ever in a plan.
            bytes.extend_from_slice(b"\x1b[9878~");
        }
        self.next_request = id;
        self.ready = false;
        self.text = Zeroizing::new(String::new());
        self.caret = 0;
        self.edit = Some(PendingEdit {
            id,
            prompt: self.prompt,
            text: next,
            execute,
            until: now + ACK_TIMEOUT,
        });
        Ok(Plan {
            request: id,
            prompt: self.prompt,
            execute,
            bytes,
        })
    }
    /// Complete payload excluding OSC selector. Strict seven fields:
    /// HSP1;nonce;prompt;R/B/S/A/X;request;byte-point;UTF8-hex.
    /// R is a fresh empty primary Readline prompt, S actual accepted input,
    /// A exact applied line, X rejected request, B execution/unsafe transition.
    /// The parser caller must invalidate on truncated/aborted/oversize OSC too.
    pub fn report(&mut self, packet: &str, now: Instant) -> Option<Submission> {
        self.expire(now);
        if packet.len() > MAX_PACKET {
            self.invalidate();
            return None;
        }
        let mut fields = packet.split(';');
        let Some([version, nonce, prompt, kind, request, point, raw]) = (|| {
            Some([
                fields.next()?,
                fields.next()?,
                fields.next()?,
                fields.next()?,
                fields.next()?,
                fields.next()?,
                fields.next()?,
            ])
        })() else {
            self.invalidate();
            return None;
        };
        let parsed = number(prompt).zip(number(request)).zip(number(point));
        if fields.next().is_some()
            || version != "HSP1"
            || nonce != self.nonce.0.as_str()
            || parsed.is_none()
        {
            self.invalidate();
            return None;
        }
        let ((prompt, request), point) = parsed?;
        let Some(text) = unhex(raw) else {
            self.invalidate();
            return None;
        };
        if point != text.len() as u64 || prompt == 0 {
            self.invalidate();
            return None;
        }
        match kind {
            "R" if request == 0 && text.is_empty() && prompt > self.prompt => {
                self.invalidate();
                self.prompt = prompt;
                self.ready = true;
            }
            // Readline redraws its already-expanded PS1 after bind -x. Such a
            // replay is not a fresh prompt and must neither restore readiness
            // nor erase the pending exact submission/application receipt.
            "R" if request == 0 && text.is_empty() && prompt == self.prompt => {}
            "B" if prompt == self.prompt && request == 0 && text.is_empty() => self.invalidate(),
            "S" if prompt == self.prompt && request == 0 => {
                let pending = self.enter.take();
                self.invalidate();
                if let Some(ref pending) = pending
                    && pending.prompt == prompt
                    && pending.text.as_str() == text.as_str()
                {
                    if let Some(id) = pending.request {
                        self.receipt(id, true);
                    }
                    return Some(Submission { prompt, text });
                } else if let Some(pending) = pending
                    && let Some(id) = pending.request
                {
                    self.receipt(id, false);
                }
            }
            "A" if prompt == self.prompt => {
                let pending = self.edit.take();
                self.invalidate();
                if let Some(ref pending) = pending
                    && (pending.id != request
                        || pending.prompt != prompt
                        || pending.text.as_str() != text.as_str())
                {
                    self.receipt(pending.id, false);
                }
                if let Some(pending) = pending
                    && pending.id == request
                    && pending.prompt == prompt
                    && pending.text.as_str() == text.as_str()
                {
                    if pending.execute {
                        // Only a later S emitted at actual acceptance can
                        // qualify this one explicitly run history selection.
                        self.enter = Some(PendingEnter {
                            request: Some(pending.id),
                            prompt,
                            text,
                            until: now + ACK_TIMEOUT,
                        });
                    } else {
                        self.receipt(pending.id, true);
                        self.caret = text.chars().count();
                        self.text = text;
                        self.ready = true;
                    }
                }
            }
            _ => self.invalidate(),
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn state() -> State {
        State::new(Nonce::parse("a".repeat(64)).unwrap())
    }
    fn packet(prompt: u64, kind: &str, request: u64, text: &str) -> String {
        format!(
            "HSP1;{};{prompt};{kind};{request};{};{}",
            "a".repeat(64),
            text.len(),
            hex(text).as_str()
        )
    }
    fn ready(state: &mut State, prompt: u64, now: Instant) {
        assert!(state.report(&packet(prompt, "R", 0, ""), now).is_none());
        assert!(state.proof().is_some());
    }
    #[test]
    fn disabled_until_private_fresh_prompt_and_no_replay() {
        let now = Instant::now();
        let mut s = state();
        assert!(s.proof().is_none());
        ready(&mut s, 1, now);
        s.typed("git status").unwrap();
        let proof = s.proof();
        s.report(&packet(1, "R", 0, ""), now);
        assert_eq!(s.proof(), proof);
        s.invalidate();
        s.report(&packet(1, "R", 0, ""), now);
        assert!(s.proof().is_none());
        ready(&mut s, 2, now);
        let wrong = packet(3, "R", 0, "").replacen(&"a".repeat(64), &"b".repeat(64), 1);
        s.report(&wrong, now);
        assert!(s.proof().is_none());
    }
    #[test]
    fn submitted_text_requires_actual_line_ack_and_is_consumed_once() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        s.typed("printf 中文").unwrap();
        s.submitted_enter(now);
        assert!(s.proof().is_none());
        s.report(&packet(1, "R", 0, ""), now);
        assert!(s.proof().is_none());
        let good = packet(1, "S", 0, "printf 中文");
        let submission = s.report(&good, now).unwrap();
        assert_eq!(submission.text.as_str(), "printf 中文");
        assert!(s.report(&good, now).is_none());
        ready(&mut s, 2, now);
        s.typed("echo known").unwrap();
        s.submitted_enter(now);
        assert!(
            s.report(&packet(2, "S", 0, "echo external-edit"), now)
                .is_none()
        );
    }
    #[test]
    fn local_edits_are_bounded_and_unknown_unicode_backspace_invalidates() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        s.typed("ab").unwrap();
        s.backspace().unwrap();
        assert_eq!(s.prefix(), Some("a"));
        s.typed("中文e\u{301}").unwrap();
        assert!(s.backspace().is_err());
        assert!(s.prefix().is_none());
        ready(&mut s, 2, now);
        assert!(s.typed("paste\nnext").is_err());
        ready(&mut s, 3, now);
        assert!(s.typed(&"x".repeat(MAX_LINE + 1)).is_err());
    }
    #[test]
    fn replacement_does_not_restore_proof_without_exact_apply_receipt() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        s.typed("git st").unwrap();
        let before = s.proof().unwrap();
        let plan = s.plan(before, Edit::Replace("git status"), now).unwrap();
        assert!(!plan.execute);
        assert!(s.prefix().is_none());
        assert!(plan.bytes.starts_with(b"\x1b[9876~"));
        assert!(!plan.bytes.contains(&b'\n') && !plan.bytes.contains(&b'\r'));
        assert!(
            s.report(&packet(1, "A", plan.request, "git status"), now)
                .is_none()
        );
        assert_eq!(s.prefix(), Some("git status"));
        assert_eq!(s.outcome(plan.request), Some(true));
        assert_eq!(
            s.plan(before, Edit::Replace("git log"), now).err(),
            Some(Failure::Changed)
        );
        // Tab filled only; Enter remains a separate actual Shell submission.
        s.submitted_enter(now);
        assert!(s.report(&packet(1, "S", 0, "git status"), now).is_some());
    }
    #[test]
    fn explicit_run_is_not_replayed_and_uncertain_input_cannot_revive_proof() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        let plan = s
            .plan(s.proof().unwrap(), Edit::Execute("git status"), now)
            .unwrap();
        assert!(plan.execute);
        assert_eq!(s.outcome(plan.request), None);
        s.report(&packet(1, "A", plan.request, "git status"), now);
        assert!(s.proof().is_none());
        assert_eq!(s.outcome(plan.request), None);
        assert!(s.report(&packet(1, "S", 0, "git status"), now).is_some());
        assert_eq!(s.outcome(plan.request), Some(true));
        assert!(
            s.report(&packet(1, "A", plan.request, "git status"), now)
                .is_none()
        );
        assert!(s.report(&packet(1, "S", 0, "git status"), now).is_none());
        ready(&mut s, 2, now);
        let plan = s
            .plan(s.proof().unwrap(), Edit::Replace("pwd"), now)
            .unwrap();
        assert!(s.typed("later-key").is_err());
        s.report(&packet(2, "A", plan.request, "pwd"), now);
        assert!(s.proof().is_none());
    }
    #[test]
    fn paste_tui_disconnect_and_timeout_never_keep_stale_input() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        s.typed("pwd").unwrap();
        s.submitted_enter(now);
        s.expire(now + ACK_TIMEOUT);
        assert!(
            s.report(&packet(1, "S", 0, "pwd"), now + ACK_TIMEOUT)
                .is_none()
        );
        ready(&mut s, 2, now);
        s.typed("pwd").unwrap();
        let plan = s
            .plan(s.proof().unwrap(), Edit::Replace("ls"), now)
            .unwrap();
        s.invalidate();
        assert_eq!(s.outcome(plan.request), Some(false));
        s.report(&packet(2, "A", plan.request, "ls"), now);
        assert!(s.proof().is_none());
        ready(&mut s, 3, now);
        s.typed("read secret").unwrap();
        s.report(&packet(3, "B", 0, ""), now);
        s.submitted_enter(now);
        assert!(s.report(&packet(3, "S", 0, "read secret"), now).is_none());
    }
    #[test]
    fn malformed_control_and_wrong_cursor_packets_fail_closed() {
        let now = Instant::now();
        let mut s = state();
        for bad in [
            "HSP1".into(),
            packet(1, "R", 0, "") + ";extra",
            format!("HSP1;{};01;R;0;0;", "a".repeat(64)),
            format!("HSP1;{};1;A;1;1;e4b8ad", "a".repeat(64)),
            packet(1, "S", 0, "x\npassword"),
            "x".repeat(MAX_PACKET + 1),
        ] {
            assert!(s.report(&bad, now).is_none());
            assert!(s.proof().is_none());
        }
        assert!(Nonce::parse("x".repeat(64)).is_none());
    }
    #[test]
    fn insert_preserves_prefix_and_never_allows_oversize_plan() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        s.typed("cat ").unwrap();
        let plan = s
            .plan(s.proof().unwrap(), Edit::Insert("'/tmp/a b'"), now)
            .unwrap();
        s.report(&packet(1, "A", plan.request, "cat '/tmp/a b'"), now);
        assert_eq!(s.prefix(), Some("cat '/tmp/a b'"));
        let proof = s.proof().unwrap();
        assert!(
            s.plan(proof, Edit::Insert(&"x".repeat(MAX_LINE)), now)
                .is_err()
        );
        assert_eq!(s.proof(), Some(proof));
    }
    #[test]
    fn execution_receipts_require_submission_and_failed_or_expired_requests_are_final() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        let plan = s
            .plan(s.proof().unwrap(), Edit::Execute("pwd"), now)
            .unwrap();
        s.report(&packet(1, "A", plan.request, "pwd"), now);
        assert_eq!(s.outcome(plan.request), None);
        assert!(s.report(&packet(1, "S", 0, "different"), now).is_none());
        assert_eq!(s.outcome(plan.request), Some(false));
        ready(&mut s, 2, now);
        let plan = s
            .plan(s.proof().unwrap(), Edit::Execute("pwd"), now)
            .unwrap();
        s.report(&packet(2, "A", plan.request, "pwd"), now);
        s.expire(now + ACK_TIMEOUT);
        assert_eq!(s.outcome(plan.request), Some(false));
        assert!(
            s.report(&packet(2, "S", 0, "pwd"), now + ACK_TIMEOUT)
                .is_none()
        );
        assert_eq!(s.outcome(plan.request), Some(false));
    }
    #[test]
    fn receipts_are_bounded_and_rejection_never_restores_the_line() {
        let now = Instant::now();
        let mut s = state();
        for prompt in 1..=12 {
            ready(&mut s, prompt, now);
            let plan = s
                .plan(s.proof().unwrap(), Edit::Insert("'/tmp/a'"), now)
                .unwrap();
            s.report(&packet(prompt, "X", plan.request, ""), now);
            assert_eq!(s.outcome(plan.request), Some(false));
            assert!(s.proof().is_none());
            assert!(s.receipts.len() <= 8);
        }
        assert_eq!(s.outcome(1), None);
    }
    #[test]
    fn caret_moves_keep_the_exact_prefix_and_proof() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        s.typed("git status").unwrap();
        let proof = s.proof().unwrap();
        // Click-to-cursor replays and arrow browsing only move POINT.
        for _ in 0..3 {
            s.caret(CaretMove::Left);
        }
        assert_eq!(s.proof(), Some(proof), "caret keys never bump the revision");
        assert_eq!(s.prefix(), Some("git status"));
        for _ in 0..2 {
            s.caret(CaretMove::Right);
        }
        s.caret(CaretMove::End);
        assert_eq!(s.prefix(), Some("git status"));
        // Back at the end the mirror is exact again, so appending works.
        s.typed(" --short").unwrap();
        assert_eq!(s.prefix(), Some("git status --short"));
        s.backspace().unwrap();
        assert_eq!(s.prefix(), Some("git status --shor"));
    }
    #[test]
    fn edits_with_the_caret_mid_line_fail_closed() {
        let now = Instant::now();
        let mut s = state();
        ready(&mut s, 1, now);
        s.typed("中文").unwrap();
        s.caret(CaretMove::Home);
        // Insertion before the end has an unknowable position in an
        // append-only mirror; backspace likewise deletes elsewhere.
        assert!(s.typed("X").is_err());
        assert!(s.prefix().is_none());
        ready(&mut s, 2, now);
        s.typed("abc").unwrap();
        s.caret(CaretMove::Left);
        assert!(s.backspace().is_err());
        assert!(s.prefix().is_none());
        // A dead state ignores caret keys; only a fresh prompt re-arms.
        s.caret(CaretMove::End);
        assert!(s.prefix().is_none());
        ready(&mut s, 3, now);
        assert_eq!(s.prefix(), Some(""));
        // Clamp at both edges keeps the mirror honest.
        s.caret(CaretMove::Left);
        s.typed("ok").unwrap();
        assert_eq!(s.prefix(), Some("ok"));
        for _ in 0..5 {
            s.caret(CaretMove::Right);
        }
        s.typed("!").unwrap();
        assert_eq!(s.prefix(), Some("ok!"));
    }
}
