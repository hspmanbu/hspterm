# 正式工作台（持续开发）

**最新源码恢复说明**：后续用户已取消逐阶段/视觉确认暂停；目前Windows优先、Android暂缓，先连续源码编制与静态审核，最后统一生成FRB/编译测试。下方旧阶段说明只保留历史背景，当前状态以根目录PROGRESS.md为准。Flutter依赖解析/运行前（包括`flutter clean`之后）须先在项目根目录运行`python3 tools/prepare_native_extensions.py`，Windows用`python`，再执行`flutter pub get`；固定本地原生补丁副本及未验证边界见WINDOWS_EXPLORER_DROP.md。准备器尚未在当前批次执行，不要用旧锁或旧绑定声称新源码已构建。

真实业务入口与原终端验收入口、Mock 原型分别保留：

```sh
# 在 ui_flutter 目录执行；不自动联网，先解锁/创建加密库并正式保存主机
flutter run -d linux -t lib/workbench_main.dart
flutter build linux --debug -t lib/workbench_main.dart
flutter build linux --release -t lib/workbench_main.dart
# 原最小 SSH 终端验收程序
flutter run -d linux -t lib/main.dart
# 独立 Mock UI：不连接 SSH，不加载 Rust
flutter run -d linux -t lib/prototype_main.dart
# 真实三会话/SFTP/GTK 交互；仅临时回环服务和生成密钥
xvfb-run -a dbus-run-session -- flutter test integration_test/live_workbench_test.dart -d linux --reporter expanded
```

正式工作台保存主机/凭据/未保存草稿到 Rust 加密库；复制先产生独立草稿，须显式保存。每个标签持有独立 SSH Transport/PTY，分屏和标签移动复用同一控制器；关闭标签有序释放，断开保留画面，只有用户请求才重连。SFTP 列表读取、目录导航、重命名、新建目录、删除及同会话移动访问实际服务器。

尚未接入的上传下载/文件复制粘贴/编辑预览/同步等入口会明确说明未完成，不执行模拟业务。完整需求与剩余项见根目录 REQUIREMENTS_COVERAGE.md；Linux 用于开发测试，不代表 Windows/Android 实机验收。

---

# HSPTerm Flutter：真实终端与 UI 原型

项目基线和恢复记录见根目录 [README](../README.md) 和 [PROGRESS](../PROGRESS.md)。当前界面提供加密保存主机、显式连接/主机指纹确认、单个SSH终端、状态/错误、手动重连；不是Phase3正式工作台。


Phase3A原型入口与真实终端独立：

```sh
# 工作台原型：无服务器要求，所有会话/文件/传输是Mock
flutter run -d linux -t lib/prototype_main.dart
# Phase2真实SSH入口：保留原有核心与测试能力
flutter run -d linux -t lib/main.dart
```

原型交互、20张PNG、构建/测试和平台边界见 [Phase3A视觉验收](../PHASE3A_REVIEW.md)。用户确认UI前不进入Phase3B；以下真实终端说明继续适用。构建目录共用，运行/重建时始终指定所需入口，避免把GUI测试的临时bundle当作交付程序。

- Flutter 3.47.7 / Dart 3.13.5；FRB runtime和codegen固定2.13.0。
- Windows：安装Visual Studio C++桌面工具链、Rust MSVC和Flutter后执行 `flutter build windows` / `flutter run -d windows`。CMake自动构建Rust release DLL并放入可执行文件目录。尚未在Windows实际构建或运行。
- Linux：GTK3/CMake/Ninja/Clang用于开发验收，`flutter run -d linux`；CMake构建并打包Rust。Linux不列为正式产品平台。
- Android：保留Flutter runner及共享UI入口，JNI构建/打包、SAF和输入/生命周期适配尚待Phase4，不应把模板APK当作可用Android客户端。

首次启动选择“解锁配置”创建主密码；主机必须“保存并连接”。配置库位于path_provider的application support目录，主机资料、凭据和指纹均由Rust Vault加密保存。不能恢复丢失的主密码。不自动连接或重连。

终端点击获得焦点；Ctrl+C原样发送（有文本选择时复制）；Ctrl+Shift+C/V复制/粘贴；Shift+Insert粘贴；Shift+PageUp/PageDown或滚轮浏览历史。远端捕获鼠标时按住Shift可本地选择。右键本地菜单可复制/粘贴，远端捕获时右键按协议上报。多行/控制字符/长粘贴先预览并明确确认，取消不发送。字体±触发实际PTY resize。工具栏支持当前会话搜索（普通/正则/大小写、上一/下一、数量和滚动条标记）、UTF-8 导出、PTY 尺寸锁定和 OSC52 双向开关。上翻后输出不强制回到底部，新增行提示可点击返回底部。

自动化测试从本目录运行：

```sh
cargo build --manifest-path ../Cargo.toml -p hspterm-frb-bridge --locked
flutter analyze
flutter test --reporter expanded
xvfb-run -a dbus-run-session -- flutter test integration_test/ssh_terminal_test.dart -d linux --reporter expanded
xvfb-run -a dbus-run-session -- flutter test integration_test/codex_terminal_test.dart -d linux --reporter expanded
flutter build linux --debug
flutter build linux --release
```

原生测试需要Linux OpenSSH、ssh-keygen、Python3、Vim、tmux、htop和当前可登录账户；测试自动使用独立127.0.0.1临时端口/临时密钥/临时Vault，最终清理，不修改宿主sshd。GUI集成测试另需Xvfb和D-Bus，截图写到系统临时目录 `hspterm-phase2-terminal.png`（只有合成测试内容）。已执行真实已安装 Codex CLI 0.163.0 的终端和 GUI 测试：临时 HOME/CODEX_HOME、仅回环合成 Responses 服务，不读取真实登录资料、不使用付费模型或执行模型工具。普通/备用屏、按键、中文长输入、多行粘贴、流式响应、缩放与退出均有断言；不是账号推理测试。Claude Code 当前无账号，未测。

FRB绑定已提交。修改Rust API后在项目根目录运行：

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter_rust_bridge_codegen generate
cargo fmt --all
```

测试程序不是发布版：Windows 实机、Android 原生打包/设备和完整 V1.4 增强功能继续按 PROGRESS 推进。界面选择只覆盖可见网格，内容变化后取消旧选择；跨屏选择与命令语义等未完项见根目录验收记录。Linux Xvfb 软件图形栈性能数据不能代表目标设备，尚无数小时/真实网络长期 soak 结论。

性能入口使用普通 WidgetsFlutterBinding，避免 integration_test 绑定主动调帧污染空闲指标。从本目录执行（独占运行，先结束其他构建/压力任务）：

```sh
flutter build linux --profile -t benchmark/performance.dart \
  --dart-define=HSPTERM_BENCH_OUT=/tmp/hspterm-performance.json \
  --dart-define=HSPTERM_BENCH_EXTENDED=true
xvfb-run -a dbus-run-session -- build/linux/x64/profile/bundle/hspterm
# 恢复真实主程序入口，检查正常窗口关闭与临时历史清理：
flutter build linux --debug
xvfb-run -a dbus-run-session -- python3 benchmark/normal_exit.py build/linux/x64/debug/bundle/hspterm
flutter build linux --release
xvfb-run -a dbus-run-session -- python3 benchmark/normal_exit.py build/linux/x64/release/bundle/hspterm
```

聚合输出含分阶段 RSS/PSS、CPU、帧耗时、缓存/桥接/冷行统计、回显及持续输出时的输入确认延迟。测试仅创建独立临时 SSH 服务器和合成数据；不在报告中写终端原文或凭据。说明及结果见 [PHASE2_VALIDATION.md](../PHASE2_VALIDATION.md)。

终端标签/分屏已按用户反馈修订为Session→Tab→TabGroup，SplitTree仅布局；详见[结构说明](../TERMINAL_LAYOUT.md)。当前已获完整连续开发授权，真实生命周期接入见上方工作台入口；不再因视觉确认暂停。

正式工作台主机认证页已接Rust Ed25519生成、私钥文件导入、公钥查看/复制/导出、每次主密码验证的私钥直接文件导出。生成/导入先保存加密草稿，仍需显式保存主机。详见根目录KEY_MANAGEMENT.md；原生选择器Ubuntu已测，Windows/Android验证边界见PLATFORM_VALIDATION.md。

真实工作台SFTP“上传”可选多文件或整目录，“下载”选择本地目录；同名目标不会自动覆盖，在队列详情决定。原会话关闭/重启后，手动连接原主机，在“全部任务”中继续；实际目标/用户/指纹不同会拒绝恢复。完成/取消任务只留本次运行，未完成检查点本机加密且不入云配置。队列已显示确认字节速率/估计剩余时间，设置页已接加密保存的全局上/下行限速和并发，队列可对本任务当前同名冲突批次明确覆盖或跳过，更名仍逐项处理；批次更名/默认策略等待做，完整边界见TRANSFER_ENGINE.md。
