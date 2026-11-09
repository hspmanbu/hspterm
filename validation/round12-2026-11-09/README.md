# 第十二轮验证证据（2026-11-09）

源码 a849625（PROGRESS beba68b），分支 fix/round7-windows-feedback。详细数字见 results.json。

## Ubuntu 侧（本机完成）
- flutter analyze 0 issue；dart format 全绿。
- flutter test 全套件：594 通过 / 10 失败 = 上轮预存集减一（terminal_path_bridge_test 由定位修复转通过；其余 10 项逐一核对预存清单，workbench_test 新失败已定位为本轮引入并修复——quiet 通知状态栏溢出，Flexible 化后通过）。
- 新增测试 9 项全过（见 results.json new_tests）。
- cargo fmt --check / clippy -D warnings / cargo test --workspace --locked -- --test-threads=1 全部 0 失败。
- 真实 OpenSSH：posix_rename 2 项通过。
- GTK 冒烟：debug 构建 + dbus-run-session under xvfb-run 25 秒零异常。

## Windows CI
- run 42569313140（workflow_dispatch，源码 a849625）——结果与产物链接在完成后记入 PROGRESS.md 顶部条目。
- CI 成功不等于 Win11 实机验证；实机清单见 PROGRESS.md 第十二轮条目末尾。

## 验证边界（如实声明）
- Explorer 打开所在文件夹（SHOpenFolderAndSelectItems）、弹窗窗口拉回（ensureDialogVisible）、reveal 原生通道：Windows 原生行为，Ubuntu 无法验证，仅静态实现+CI 编译。
- 内存优化前后对比：确定性修复（metadata 锚定/digest isolate/IOSink flush）有代码级依据，但用户场景的 RSS 前后对比需要 Win11 实机同环境测量；本轮已部署归因诊断字段（frameAgg queueShare、dirCache 计数、maxRss、10s 启动加密采样）供下一次实机日志分解。
- 配色观感（MOTD/ANSI）与新预设、通知分级观感、候选框默认无高亮交互：需实机确认。
