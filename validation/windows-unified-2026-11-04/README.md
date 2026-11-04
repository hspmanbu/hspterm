# Windows代码集中收尾：Ubuntu验证记录

2026-11-04，Windows功能代码已接入正式工作台，当前Ubuntu可执行验证收齐。Android按用户要求暂缓。本记录不代表Windows客户端已在目标平台编译/验收，也不代表Google/WebDAV真实账号测试通过。

| 检查 | 实际结果 |
| --- | --- |
| Rust Workspace完整运行 | 647通过；安全补丁前的完整基线 |
| 安全补丁后受影响范围 | Bridge75、SSH255通过；其余自身依赖图未变化 |
| 本地上游补丁 | VTE56；alacritty132单元+45参考记录+1文档通过 |
| Flutter正式/组件/Native测试 | 143文件、507个去重用例全部有通过证据；原53轮中断后续20文件52项通过，3项重复不另计；不是伪称一条完整命令507通过 |
| 真实GTK集成 | 29个Ubuntu适用文件通过；新锁Kitty/Codex/SSH3项再次通过；Windows DPAPI文件明确延期 |
| 静态检查 | Linux/Windows GNU全目标严格Clippy0警告；Flutter Analyze0项；305个Dart文件格式0变更；Rust格式通过 |
| 工具回归 | Python22项通过；237API/74DTO/282Dart文件源码调用审查0发现；233公开Result有错误边界（词法审查不等于编译） |
| 构建与正常退出 | 正式debug/release构建、真实GTK启动、Native加载、未擅自建库/历史、预览run清理和退出0；两种包内Rust库散列与对应构建一致 |
| 依赖安全 | crypto-bigint0.7.5→0.7.10、ctutils0.4.3→0.4.8；当前Cargo audit数据库0条漏洞/0条警告 |

原始聚合数据：[results.json](results.json)、[补丁前性能](performance-before-security-patch.json)、[补丁后性能](performance-after-security-patch.json)、[debug启动](smoke-debug.json)、[release启动](smoke-release.json)。[实际命令面板截图](command-palette.png)来自合成SSH/Kitty测试，不是静态设计图。完整历史含失败与修正记录见[集中验证](../../UNIFIED_VALIDATION.md)。

## 本轮修正

- 正式工作台保存命令面板键位后立即更新原路由，保留Navigator和按键所有权。
- Ctrl/Shift按下已发SSH时，释放回到原控制器/nativeID/代次；F8与本地面板Enter/释放留本机，不串入另一标签或重连后的会话。
- 异步取消状态与FRB Future回执保持同一中文错误，不暴露FFI包装。
- SSH本地关闭后的peer CLOSE确认、SFTP/检查/直传准入回执与实际worker退休保持一致；同步停用立即取消并拒绝迟到HTTP准备。
- Readline候选夹具等待真实新提示符，不把S提交回执当R就绪；生产输入证明不放宽。修复滚动布局、确认文案及测试资源排空问题。
- 只更新两项兼容密码学补丁，不屏蔽公告或保留撤回版本。来源：[RUSTSEC-2026-0387](https://rustsec.org/advisories/RUSTSEC-2026-0387.html)、[RUSTSEC-2026-0385](https://rustsec.org/advisories/RUSTSEC-2026-0385.html)。

## 性能与边界

新锁release19个场景实际运行49.2秒，包括真实Vim/tmux/htop、5万Unicode行、100次历史滚动、Reflow、5次手动重连、长历史正则/标记、负载输入及原生窗口/PTY变化。5.603秒终端空闲样本0桥接帧/0渲染帧、CPU0.178%；5万行场景1.716秒；负载20次输入回执中位30ms/P95 46ms/最大53ms，普通命令回显中位53ms/P95 78ms。新锁真实GTK20次Native生命周期RSS差值−1,314,816字节。

图形环境是Ubuntu Xvfb/Impeller/OpenGL软件栈。终端基准的Engine空闲RSS约286MiB、连接后约341MiB、5万行约369MiB；高输出raster P95约90ms、负载约47ms。锁库页密码焦点的最终release短样本RSS约330MiB/CPU16.0%，失焦约334MiB/5.6%；debug约528MiB/50.2%，失焦约524MiB/7.6%。这些值包含Flutter Engine、字体/图形缓存及分配器保留，不单凭RSS判泄漏，也不宣称60fps或长期无泄漏。两次基准系统负载不同，不作安全补丁带来性能改善的因果结论；目标Windows GPU和长时表现待验。

## 运行与复现

Ubuntu正式程序：`/opt/hspterm/ui_flutter/build/linux/x64/release/bundle/hspterm`。锁库首屏由用户创建/打开配置库、正式保存主机并明确连接；Mock独立入口仍为`prototype_main.dart`，原最小SSH入口`main.dart`保留。

```sh
# 根目录；依赖解析/clean后先准备固定维护fork
python3 tools/prepare_native_extensions.py
# ui_flutter目录
flutter analyze --no-pub
flutter test --no-pub --concurrency=1 --reporter expanded
python3 benchmark/external_editor_gtk.py flutter test --no-pub -d linux integration_test/live_workbench_test.dart --reporter expanded
# GUI测试后恢复正式入口
flutter build linux --debug --no-pub -t lib/workbench_main.dart
flutter build linux --release --no-pub -t lib/workbench_main.dart
```

Rust完整测试、Windows GNU及低空间profile参数见[UNIFIED_VALIDATION](../../UNIFIED_VALIDATION.md)、[PLATFORM_VALIDATION](../../PLATFORM_VALIDATION.md)。本次中断恢复清单已汇总在results.json，不依赖聊天上下文或/tmp才能知道完成状态。

## 后续所需条件

- Windows11：MSVC/Flutter/原生C++实际编译，窗口/DPI/Snap、真实键盘/中文IME、OLE/Explorer、DPAPI、系统通知与GPU表现；使用`tools/build_windows.ps1 -CreateArchive`，前提和验收步骤见[平台记录](../../PLATFORM_VALIDATION.md)。Ubuntu不提供已验证的Windows exe/zip。
- 真实Google Drive OAuth客户端/账号及WebDAV服务端条件写入、授权撤销、网络恢复端到端；当前测试为隔离HTTP/协议夹具，未读真实账号或付费。
- Android应用专项按指令暂缓；真实Claude Code账号当前不要求测试。实际Codex CLI使用隔离HOME/CODEX_HOME和合成回环provider，无真实凭据或付费请求。
