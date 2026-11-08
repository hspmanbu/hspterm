//! FRB 2.13's anyhow codec formats Debug, including the entire source chain.
//! Publish a NEW, source-less error rather than only adding a safe context to
//! an error whose inner SSH/HTTP/JSON/OS payload is still reachable.
use futures_util::FutureExt;
use std::fmt;
use std::{future::Future, panic::AssertUnwindSafe, sync::Once};
const _: () = assert!(matches!(log::STATIC_MAX_LEVEL, log::LevelFilter::Off));
static PANIC_HOOK: Once = Once::new();

pub(crate) fn prepare() {
    PANIC_HOOK.call_once(|| {
        crate::diagnostics::prepare_panic_recording();
        crate::run_log::prepare();
        // This private native library is the application owner, not a public
        // embedding SDK. Default hooks can print key/output-bearing panic data.
        std::panic::set_hook(Box::new(|_info| {
            crate::diagnostics::panic_record();
            crate::run_log::panic_location(_info.location());
            // Unit-test failures must be locatable without ever formatting a
            // potentially secret-bearing panic payload. Production stays silent.
            #[cfg(test)]
            if let Some(location) = _info.location() {
                eprintln!(
                    "HSPTerm test panic location: {}:{}:{}",
                    location.file(),
                    location.line(),
                    location.column()
                );
            }
        }));
    });
}
pub(crate) async fn guard<T>(future: impl Future<Output = anyhow::Result<T>>) -> anyhow::Result<T> {
    prepare();
    match AssertUnwindSafe(future).catch_unwind().await {
        Ok(result) => result,
        Err(_) => Err(panicked()),
    }
}
/// Records a non-fatal loss (best-effort cleanup that failed after the
/// primary operation already succeeded). These never fail the call; they
/// surface in diagnostics only, with the fixed message the caller passes.
pub(crate) fn log_loss(message: String) {
    crate::diagnostics::record(
        crate::diagnostics::DiagnosticCode::LocalEditReplaceLoss,
        None,
        None,
    );
    log::debug!("{message}");
}

pub(crate) fn guard_sync<T>(action: impl FnOnce() -> anyhow::Result<T>) -> anyhow::Result<T> {
    prepare();
    match std::panic::catch_unwind(AssertUnwindSafe(action)) {
        Ok(result) => result,
        Err(_) => Err(panicked()),
    }
}
fn panicked() -> anyhow::Error {
    anyhow::Error::new(PublicFailure(
        "核心工作异常退出，操作结果未确认；请保留当前状态并重启应用".into(),
    ))
}

#[path = "public_error_literals.rs"]
mod literals;

struct PublicFailure(String);
impl fmt::Display for PublicFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl fmt::Debug for PublicFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}
impl std::error::Error for PublicFailure {}

#[track_caller]
pub(crate) fn finish<T>(result: anyhow::Result<T>) -> anyhow::Result<T> {
    let caller = std::panic::Location::caller();
    result.map_err(|error| {
        let message = summary(&error);
        crate::run_log::failure(&error, &message, caller);
        // Do not retain the original error in source(), context(), backtrace
        // text or any diagnostic store. A new anyhow backtrace may refer to
        // code locations when explicitly enabled, never the original payload.
        anyhow::Error::new(PublicFailure(message))
    })
}
pub(crate) fn summary(error: &anyhow::Error) -> String {
    if let Some(known) = error.downcast_ref::<PublicFailure>() {
        return known.0.clone();
    }
    // The SshError mapping runs BEFORE the plain-literal allowlist: variants
    // like Terminal must surface their audited variant summaries instead of
    // the blanket enum display (which once masked real causes as
    // "终端尺寸无效").
    if let Some(known) = error.downcast_ref::<hspterm_ssh_core::SshError>() {
        return ssh_summary(known);
    }
    let head = error.to_string();
    if literals::PUBLIC_LITERALS.contains(&head.as_str()) {
        return head;
    }
    if let Some(hspterm_term_core::decorations::DecorationError::Rule(index)) =
        error.downcast_ref::<hspterm_term_core::decorations::DecorationError>()
    {
        return format!("第{index}条规则无效或超过正则容量限制；未修改原配置");
    }
    if let Some(hspterm_storage_sync::openssh_import::ImportError::Syntax(line)) =
        error.downcast_ref::<hspterm_storage_sync::openssh_import::ImportError>()
    {
        return format!("第{line}行SSH配置语法无效；未导入任何主机");
    }
    if error.is::<serde_json::Error>() {
        return "数据格式无效或版本不支持；请重新读取当前状态".into();
    }
    if error.is::<tokio::task::JoinError>() {
        return "后台工作未正常结束；结果未获完整确认，请检查当前状态".into();
    }
    if let Some(known) = error.downcast_ref::<std::io::Error>() {
        return match known.kind() {
            std::io::ErrorKind::AlreadyExists => "目标已存在；请检查当前状态并重新选择目标",
            std::io::ErrorKind::NotFound => "所需文件或目录已不存在；请重新选择并读取",
            std::io::ErrorKind::PermissionDenied => "文件或目录访问被拒绝；请检查权限和当前状态",
            _ => "文件读写或持久化未获完整确认；请检查当前状态后再操作",
        }
        .into();
    }
    if error.is::<russh_sftp::client::error::Error>() {
        return "远端文件操作未成功；请检查连接、路径和权限".into();
    }
    if matches!(
        error.downcast_ref::<hspterm_term_core::TerminalError>(),
        Some(hspterm_term_core::TerminalError::History(_))
    ) {
        return "终端临时历史不可用；请保留当前会话并检查本机存储".into();
    }
    if error.is::<hspterm_storage_sync::backup::BackupError>() {
        return "备份或恢复未获完整确认；请保留文件并重新核对预览和当前配置".into();
    }
    "操作未获得完整确认；请检查当前状态后再操作，错误详情已脱敏".into()
}
fn ssh_summary(error: &hspterm_ssh_core::SshError) -> String {
    use hspterm_ssh_core::{ProxyError, SshError};
    match error {
        SshError::Timeout(_)
        | SshError::RequestDenied(_)
        | SshError::Proxy(ProxyError::HttpStatus(_) | ProxyError::SocksStatus(_)) => {
            error.to_string()
        }
        SshError::Jump(source) => format!("跳板机连接失败：{}", ssh_summary(source)),
        // Bounded enum metadata only: the raw io message never crosses FFI.
        SshError::Terminal(hspterm_term_core::TerminalError::InvalidSize) => {
            "终端行列必须在 2..=4096，且可见单元格不得超过 1048576".into()
        }
        SshError::Terminal(hspterm_term_core::TerminalError::History(io)) => format!(
            "终端临时历史不可用（{:?}）；终端未创建，原数据未修改",
            io.kind()
        ),
        _ => {
            let display = error.to_string();
            if literals::PUBLIC_LITERALS.contains(&display.as_str()) {
                display
            } else {
                "SSH操作未获完整确认；请检查连接和当前状态".into()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ssh_source_payload_cannot_escape_via_frbs_debug_error_codec() {
        let original = anyhow::Error::new(hspterm_ssh_core::SshError::Io(std::io::Error::other(
            "synthetic-private-source-token",
        )))
        .context("连接失败");
        assert!(format!("{original:?}").contains("synthetic-private-source-token"));
        let public = finish::<()>(Err(original)).unwrap_err();
        assert!(!format!("{public:?}").contains("synthetic-private-source-token"));
        assert_eq!(public.chain().count(), 1);
        assert!(public.to_string().contains("连接失败"));
    }
    #[test]
    fn json_values_unknown_strings_and_foreign_io_details_are_not_public_errors() {
        let json = serde_json::from_str::<bool>(r#""synthetic-json-password""#).unwrap_err();
        let samples = [
            anyhow::Error::from(json),
            anyhow::anyhow!("用户秘密synthetic-value 不应通过中文前缀绕过"),
            anyhow::Error::from(std::io::Error::other("synthetic-local-file-token")),
        ];
        for sample in samples {
            let public = finish::<()>(Err(sample)).unwrap_err();
            assert!(!format!("{public:?}").contains("synthetic-"));
            assert_eq!(public.chain().count(), 1);
        }
    }
    #[test]
    fn known_literal_and_bounded_domain_metadata_stay_actionable_and_idempotent() {
        let literal = finish::<()>(Err(anyhow::anyhow!("连接已取消"))).unwrap_err();
        assert_eq!(literal.to_string(), "连接已取消");
        let again = finish::<()>(Err(
            literal.context("synthetic-late-context-must-not-survive")
        ))
        .unwrap_err();
        assert_eq!(again.to_string(), "连接已取消");
        assert!(!format!("{again:?}").contains("synthetic-late"));
        let timed = finish::<()>(Err(hspterm_ssh_core::SshError::Timeout(
            hspterm_ssh_core::Stage::Authentication,
        )
        .into()))
        .unwrap_err();
        assert!(timed.to_string().contains("Authentication"));
    }
    #[tokio::test]
    async fn actual_public_api_rejects_invalid_geometry_with_a_source_less_error() {
        let result = crate::api::create_terminal(1, 4, 100).await.unwrap_err();
        assert!(result.downcast_ref::<PublicFailure>().is_some());
        assert_eq!(result.chain().count(), 1);
    }
    #[tokio::test]
    async fn panic_payload_is_not_a_bridge_result_and_owned_future_is_actually_dropped() {
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        };
        struct Lease(Arc<AtomicBool>);
        impl Drop for Lease {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }
        let released = Arc::new(AtomicBool::new(false));
        let lease = Lease(released.clone());
        let result: anyhow::Result<()> = guard(async move {
            let _lease = lease;
            panic!("synthetic-private-panic-payload");
        })
        .await;
        let error = finish(result).unwrap_err();
        assert!(!format!("{error:?}").contains("synthetic-private-panic-payload"));
        assert_eq!(error.chain().count(), 1);
        assert!(released.load(Ordering::Acquire));
        assert!(error.to_string().contains("操作结果未确认"));
    }
    #[test]
    fn sync_panic_has_the_same_fixed_non_success_result() {
        let result: anyhow::Result<()> = guard_sync(|| panic!("synthetic-private-sync-panic"));
        let error = finish(result).unwrap_err();
        assert!(!format!("{error:?}").contains("synthetic-private-sync-panic"));
        assert!(error.to_string().contains("重启应用"));
    }
}
