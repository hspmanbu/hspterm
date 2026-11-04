//! Passive terminal notices. No input, network, history index or file tasks.
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use std::{
    collections::{VecDeque, hash_map::DefaultHasher},
    hash::{Hash, Hasher},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
static POLICIES: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    pub text: String,
    pub regex: bool,
    pub case_sensitive: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub enabled: bool,
    pub bell: bool,
    pub osc: bool,
    pub foreground: bool,
    pub background: bool,
    pub desktop: bool,
    /// Remote output is omitted from every UI/OS notice unless explicitly enabled.
    pub preview: bool,
    /// Zero disables silence detection. A new output batch arms a single deadline.
    pub quiet_seconds: u32,
    pub rules: Vec<Rule>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            enabled: true,
            bell: true,
            osc: true,
            foreground: false,
            background: true,
            desktop: false,
            preview: false,
            quiet_seconds: 0,
            rules: vec![],
        }
    }
}
#[derive(Clone)]
pub struct Prepared {
    pub settings: Settings,
    patterns: Arc<Vec<Regex>>,
    id: u64,
}
impl Settings {
    pub fn prepare(&self) -> Result<Prepared, crate::preferences::PreferencesError> {
        if (self.quiet_seconds != 0 && !(5..=86400).contains(&self.quiet_seconds))
            || self.rules.len() > 16
        {
            return Err(crate::preferences::PreferencesError);
        }
        let patterns = self
            .rules
            .iter()
            .map(|r| {
                if r.text.is_empty() || r.text.len() > 256 || r.text.chars().any(|c| c.is_control())
                {
                    return Err(crate::preferences::PreferencesError);
                }
                RegexBuilder::new(&if r.regex {
                    r.text.clone()
                } else {
                    regex::escape(&r.text)
                })
                .case_insensitive(!r.case_sensitive)
                .size_limit(256 * 1024)
                .dfa_size_limit(64 * 1024)
                .nest_limit(32)
                .build()
                .map_err(|_| crate::preferences::PreferencesError)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let id = POLICIES
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |v| v.checked_add(1))
            .map_err(|_| crate::preferences::PreferencesError)?;
        Ok(Prepared {
            settings: self.clone(),
            patterns: Arc::new(patterns),
            id,
        })
    }
}
#[derive(Clone, Serialize)]
pub struct Notice {
    pub policy: String,
    pub kind: &'static str,
    pub title: String,
    pub body: String,
    pub foreground: bool,
    pub background: bool,
    pub desktop: bool,
}
// Never derive Debug on notices or retained output fragments.
pub(crate) struct Engine {
    config: Prepared,
    pending: Vec<Notice>,
    recent: VecDeque<(u64, Instant)>,
    last: Option<Instant>,
    quiet: Option<Instant>,
}
impl Default for Engine {
    fn default() -> Self {
        Self {
            config: Settings::default()
                .prepare()
                .expect("fixed notification defaults"),
            pending: vec![],
            recent: VecDeque::new(),
            last: None,
            quiet: None,
        }
    }
}
pub fn clean(value: &str, limit: usize) -> String {
    value
        .chars()
        .filter(|c| {
            !c.is_control() && !matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
        .take(limit)
        .collect()
}
impl Engine {
    pub fn policy(&self) -> u64 {
        self.config.id
    }
    pub fn rules_enabled(&self) -> bool {
        self.config.settings.enabled && !self.config.patterns.is_empty()
    }
    pub fn configure(&mut self, prepared: Prepared) {
        self.config = prepared;
        self.pending.clear();
        self.quiet = None;
    }
    pub fn reset(&mut self) {
        self.pending.clear();
        self.recent.clear();
        self.last = None;
        self.quiet = None;
    }
    pub fn disconnect(&mut self) {
        self.quiet = None;
    }
    pub fn activity(&mut self, now: Instant) {
        let s = &self.config.settings;
        if s.enabled && s.quiet_seconds > 0 {
            self.quiet = now.checked_add(Duration::from_secs(s.quiet_seconds.into()));
        }
    }
    pub fn deadline(&self) -> Option<Instant> {
        self.quiet
    }
    pub fn flush(&mut self, now: Instant) {
        if self.quiet.is_some_and(|at| now >= at) {
            self.quiet = None;
            self.emit("quiet", "", "", now);
        }
    }
    pub fn bell(&mut self, now: Instant) {
        if self.config.settings.bell {
            self.emit("bell", "", "", now);
        }
    }
    pub fn osc(&mut self, title: &str, body: &str, now: Instant) {
        if self.config.settings.osc {
            self.emit("osc", title, body, now);
        }
    }
    pub fn line(&mut self, line: &str, now: Instant) {
        if !self.config.settings.enabled || line.len() > 4096 || self.cooldown(now) {
            return;
        }
        if self.config.patterns.iter().any(|r| r.is_match(line)) {
            self.emit("rule", "", line, now);
        }
    }
    fn cooldown(&self, now: Instant) -> bool {
        self.last
            .is_some_and(|last| now.saturating_duration_since(last) < Duration::from_millis(250))
    }
    fn emit(&mut self, kind: &'static str, title: &str, body: &str, now: Instant) {
        let s = &self.config.settings;
        if !s.enabled
            || (!s.foreground && !s.background)
            || self.cooldown(now)
            || self.pending.len() >= 16
        {
            return;
        }
        let title = clean(title, 128);
        let body = clean(body, 512);
        let mut hasher = DefaultHasher::new();
        (kind, &title, &body).hash(&mut hasher);
        let key = hasher.finish();
        self.recent
            .retain(|(_, at)| now.saturating_duration_since(*at) < Duration::from_secs(5));
        if self.recent.iter().any(|(k, _)| *k == key) {
            return;
        }
        if self.recent.len() == 16 {
            self.recent.pop_front();
        }
        self.recent.push_back((key, now));
        self.last = Some(now);
        self.pending.push(Notice {
            policy: self.config.id.to_string(),
            kind,
            title: if s.preview { title } else { String::new() },
            body: if s.preview { body } else { String::new() },
            foreground: s.foreground,
            background: s.background,
            desktop: s.desktop,
        });
    }
    pub fn take(&mut self) -> Vec<Notice> {
        std::mem::take(&mut self.pending)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dedup_budget_and_preview_are_independent_of_terminal_bytes() {
        let mut e = Engine::default();
        let now = Instant::now();
        for _ in 0..100000 {
            e.osc("remote title", "synthetic-private-output", now);
        }
        let notices = e.take();
        assert_eq!(notices.len(), 1);
        assert!(notices[0].body.is_empty());
        e.osc(
            "remote title",
            "synthetic-private-output",
            now + Duration::from_secs(1),
        );
        assert!(e.take().is_empty());
        e.osc(
            "remote title",
            "synthetic-private-output",
            now + Duration::from_secs(6),
        );
        assert_eq!(e.take().len(), 1);
        assert!(clean("x\u{1b}\u{202e}\ny", 10) == "xy");
    }
    #[test]
    fn quiet_deadline_is_one_shot_rearmed_by_output_and_cancelled_on_disconnect() {
        let mut e = Engine::default();
        let now = Instant::now();
        e.configure(
            Settings {
                quiet_seconds: 5,
                ..Settings::default()
            }
            .prepare()
            .unwrap(),
        );
        assert!(e.deadline().is_none());
        e.activity(now);
        e.activity(now + Duration::from_secs(4));
        e.flush(now + Duration::from_secs(5));
        assert!(e.take().is_empty());
        e.flush(now + Duration::from_secs(9));
        assert_eq!(e.take()[0].kind, "quiet");
        e.flush(now + Duration::from_secs(100));
        assert!(e.take().is_empty());
        e.activity(now);
        e.disconnect();
        assert!(e.deadline().is_none());
    }
    #[test]
    fn bounded_explicit_rules_respect_case_and_literal_vs_regex() {
        let mut e = Engine::default();
        let now = Instant::now();
        e.configure(
            Settings {
                preview: true,
                rules: vec![Rule {
                    text: "ERROR.[0-9]+".into(),
                    regex: true,
                    case_sensitive: true,
                }],
                ..Settings::default()
            }
            .prepare()
            .unwrap(),
        );
        e.line("error 123", now);
        assert!(e.take().is_empty());
        e.line("ERROR 123", now);
        assert_eq!(e.take()[0].body, "ERROR 123");
        assert!(
            Settings {
                rules: vec![Rule {
                    text: "[".into(),
                    regex: true,
                    case_sensitive: false
                }],
                ..Settings::default()
            }
            .prepare()
            .is_err()
        );
        assert!(
            Settings {
                quiet_seconds: 1,
                ..Settings::default()
            }
            .prepare()
            .is_err()
        );
        e.configure(
            Settings {
                enabled: false,
                ..Settings::default()
            }
            .prepare()
            .unwrap(),
        );
        e.bell(now);
        e.osc("", "", now);
        assert!(e.take().is_empty());
    }
}
