//! Display configuration and immutable per-terminal render policy. No SSH writes.
use anyhow::{Context, Result, ensure};
use hspterm_storage_sync::display_settings::DisplaySettings;
use hspterm_term_core::decorations::{Config, Decorator, Rule, Style};
use std::sync::Arc;

#[derive(Clone)]
pub struct DisplayRule {
    pub id: String,
    pub name: String,
    pub pattern: String,
    pub regex: bool,
    pub case_sensitive: bool,
    pub enabled: bool,
    pub force_color: bool,
    pub foreground: Option<u32>,
    pub background: Option<u32>,
    pub underline: bool,
}
#[derive(Clone)]
pub struct DisplayConfig {
    pub enabled: bool,
    pub semantic: bool,
    pub rainbow: bool,
    pub same_word: bool,
    pub same_word_case_sensitive: bool,
    pub allow_in_alternate_screen: bool,
    pub rules: Vec<DisplayRule>,
}
impl From<Config> for DisplayConfig {
    fn from(c: Config) -> Self {
        Self {
            enabled: c.enabled,
            semantic: c.semantic,
            rainbow: c.rainbow,
            same_word: c.same_word,
            same_word_case_sensitive: c.same_word_case_sensitive,
            allow_in_alternate_screen: c.allow_in_alternate_screen,
            rules: c
                .rules
                .into_iter()
                .map(|r| DisplayRule {
                    id: r.id,
                    name: r.name,
                    pattern: r.pattern,
                    regex: r.regex,
                    case_sensitive: r.case_sensitive,
                    enabled: r.enabled,
                    force_color: r.force_color,
                    foreground: r.style.foreground,
                    background: r.style.background,
                    underline: r.style.underline,
                })
                .collect(),
        }
    }
}
impl DisplayConfig {
    pub(crate) fn core(self) -> Config {
        Config {
            version: 1,
            enabled: self.enabled,
            semantic: self.semantic,
            rainbow: self.rainbow,
            same_word: self.same_word,
            same_word_case_sensitive: self.same_word_case_sensitive,
            allow_in_alternate_screen: self.allow_in_alternate_screen,
            rules: self
                .rules
                .into_iter()
                .map(|r| Rule {
                    id: r.id,
                    name: r.name,
                    pattern: r.pattern,
                    regex: r.regex,
                    case_sensitive: r.case_sensitive,
                    enabled: r.enabled,
                    force_color: r.force_color,
                    style: Style {
                        foreground: r.foreground,
                        background: r.background,
                        underline: r.underline,
                    },
                })
                .collect(),
        }
    }
}
#[derive(Clone)]
pub struct DisplaySettingsView {
    pub vault_scope: String,
    pub revision: u64,
    pub override_config: Option<DisplayConfig>,
    pub effective: DisplayConfig,
}
#[derive(Clone)]
pub struct DisplayRuleMatch {
    pub id: String,
    pub count: u32,
}
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct Source {
    pub vault_scope: String,
    pub host: Option<String>,
}
pub(crate) struct DisplayRuntime {
    pub source: Source,
    pub decorator: Arc<Decorator>,
}
fn formal_host(v: &mut hspterm_storage_sync::Vault, host: Option<&str>) -> Result<()> {
    if let Some(id) = host {
        ensure!(
            hspterm_storage_sync::Repository::new(v).host(id)?.is_some(),
            "请先正式保存主机配置"
        );
    }
    Ok(())
}
fn view(v: &mut hspterm_storage_sync::Vault, host: Option<&str>) -> Result<DisplaySettingsView> {
    formal_host(v, host)?;
    let doc = DisplaySettings::load(v, host)?;
    Ok(DisplaySettingsView {
        vault_scope: v.instance_id().to_owned(),
        revision: doc.revision,
        override_config: doc.config.map(Into::into),
        effective: DisplaySettings::effective(v, host)?.into(),
    })
}
pub(crate) fn capture(
    v: &hspterm_storage_sync::Vault,
    host: Option<&str>,
) -> Result<DisplayRuntime> {
    Ok(DisplayRuntime {
        source: Source {
            vault_scope: v.instance_id().to_owned(),
            host: host.map(str::to_owned),
        },
        decorator: Arc::new(Decorator::new(DisplaySettings::effective(v, host)?)?),
    })
}
pub(crate) async fn load(host: Option<String>) -> Result<DisplaySettingsView> {
    tokio::task::spawn_blocking(move || crate::api::with_vault(|v| view(v, host.as_deref())))
        .await?
}
pub(crate) async fn save(
    host: Option<String>,
    scope: String,
    expected_revision: u64,
    config: Option<DisplayConfig>,
) -> Result<DisplaySettingsView> {
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            ensure!(
                v.instance_id() == scope,
                "配置库已重新打开，请重新载入显示设置"
            );
            formal_host(v, host.as_deref())?;
            let config = config.map(DisplayConfig::core);
            // Finish all fallible compilation before the atomic write. A failed
            // refresh must never be reported as an unsuccessful configuration save.
            let effective = match &config {
                Some(c) => c.clone(),
                None if host.is_some() => DisplaySettings::effective(v, None)?,
                None => Config::default(),
            };
            let mut compiled = std::collections::BTreeMap::new();
            let mut updates = Vec::new();
            for (id, source) in crate::api::display_sources() {
                if source.vault_scope != scope
                    || host
                        .as_ref()
                        .is_some_and(|h| source.host.as_ref() != Some(h))
                {
                    continue;
                }
                let decorator = if let Some(d) = compiled.get(&source.host) {
                    Arc::clone(d)
                } else {
                    let selected = if host.is_none() && source.host.is_some() {
                        DisplaySettings::load(v, source.host.as_deref())?
                            .config
                            .unwrap_or_else(|| effective.clone())
                    } else {
                        effective.clone()
                    };
                    let d = Arc::new(Decorator::new(selected)?);
                    compiled.insert(source.host.clone(), Arc::clone(&d));
                    d
                };
                updates.push((id, source, decorator));
            }
            let doc = DisplaySettings::save(v, host.as_deref(), expected_revision, config)?;
            for (id, source, decorator) in updates {
                crate::api::replace_display(id, &source, decorator);
            }
            Ok(DisplaySettingsView {
                vault_scope: scope,
                revision: doc.revision,
                override_config: doc.config.map(Into::into),
                effective: effective.into(),
            })
        })
    })
    .await?
}
pub(crate) async fn test(config: DisplayConfig, sample: String) -> Result<Vec<DisplayRuleMatch>> {
    tokio::task::spawn_blocking(move || {
        let decorator = Decorator::new(config.core())?;
        Ok(decorator
            .test(&sample)?
            .into_iter()
            .map(|(id, count)| DisplayRuleMatch {
                id,
                count: count as u32,
            })
            .collect())
    })
    .await
    .context("规则测试任务失败")?
}
/// Strict bounded JSON import of rules only. Existing display toggles stay local.
/// Parsing never persists; the user reviews and explicitly saves the result.
pub(crate) async fn import_rules(source: String) -> Result<Vec<DisplayRule>> {
    tokio::task::spawn_blocking(move || {
        ensure!(source.len() <= 32768, "规则文件超过32KiB限制");
        let rules: Vec<Rule> =
            serde_json::from_str(&source).map_err(|_| anyhow::anyhow!("规则JSON格式无效"))?;
        let config = Config {
            rules,
            ..Config::default()
        };
        Decorator::new(config.clone())?;
        Ok(DisplayConfig::from(config).rules)
    })
    .await?
}
