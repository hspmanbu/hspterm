# 2026-11-05 Windows 四项反馈修复

Windows [run41933717144](https://github.com/hspmanbu/hspterm/actions/runs/41933717144) 已成功：正规 FRB/MSVC Release、Analyze0、52组件、原生启动/正常关闭、关闭重开的位置/大小恢复。源码cf13882。[下载完整 Windows 包](https://github.com/hspmanbu/hspterm/actions/runs/41933717144/artifacts/13374471855)，需整包解压；不要混用旧 DLL。服务器CI不是Windows11用户设备测试。

实现与边界见 RUNTIME_DIAGNOSTICS.md、WINDOWS_WINDOW.md、SHELL_INTEGRATION.md，统计见 results.json。Ubuntu 的窗口/内存数据不能作为 Windows 测量。GTK 九分类×两个窗口尺寸通过，截图仅用于本轮视觉检查，不纳入 Git。

实际命令：

```sh
python3 tools/prepare_native_extensions.py
cd ui_flutter && flutter pub get
# 根目录，固定 FRB 2.13.0，低磁盘构建环境
flutter_rust_bridge_codegen generate
cargo test -p hspterm-frb-bridge --lib -- --test-threads=1
cargo test -p hspterm-term-core
cargo test -p hspterm-ssh-core --test openssh openssh_integration -- --test-threads=2
cargo test -p hspterm-ssh-core --lib integration::tests
cargo clippy -p hspterm-frb-bridge -p hspterm-term-core -p hspterm-ssh-core --lib -- -D warnings
# ui_flutter
flutter analyze --no-pub
flutter test --no-pub test/run_log_test.dart test/diagnostics_test.dart test/terminal_paths_send_test.dart test/typography_settings_test.dart test/settings_leave_guard_test.dart test/display_settings_test.dart test/transfer_settings_test.dart test/configuration_sync_settings_test.dart test/file_open_settings_test.dart test/history_controls_test.dart test/palette_settings_test.dart test/terminal_notifications_test.dart
xvfb-run -a flutter test --no-pub -d linux integration_test/settings_feedback_test.dart
flutter build linux --debug --no-pub -t lib/workbench_main.dart
xvfb-run -a dbus-run-session -- python3 benchmark/workbench_smoke.py build/linux/x64/debug/bundle/hspterm
```

实际统一使用 CARGO_INCREMENTAL=0、CARGO_BUILD_JOBS=2、CARGO_PROFILE_DEV_DEBUG=0、CARGO_PROFILE_TEST_DEBUG=0、CMAKE_BUILD_PARALLEL_LEVEL=2，GTK 使用 LIBGL_ALWAYS_SOFTWARE=1/GDK_BACKEND=x11。最终代码另通过日志/错误边界10项、路径5项复测，非重复增加总数。日志最终Native单测2项再次通过。根目录与 ui_flutter 命令需分别运行。

Windows 构建流程新增日志组件测试及 tools/validate_windows_geometry.ps1。用户复测：完整解压新包，启用集成并手动重连到普通 Bash 提示符；缩放后发送路径不执行；诊断可导出当前启动 `.log`；解锁工作台后拖动八方向边框，移动后正常关闭/重开。检查多显示器/DPI、最大化及 Snap。
