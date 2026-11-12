# HSPTerm

**专注 SSH 与 SFTP，让远程终端与文件操作自然衔接。**

HSPTerm 将 SSH 终端、SFTP 文件管理和传输队列放进同一个紧凑工作台。连接服务器、查看日志、修改配置、上传文件，尽量在一个窗口内完成，减少在终端、文件管理器和编辑器之间来回切换。

当前以 **Windows 11 x64** 为主要开发与使用测试平台，采用 **Flutter + Rust** 架构。

[下载测试构建](https://github.com/hspmanbu/hspterm/actions/workflows/windows-build.yml) · [反馈问题](https://github.com/hspmanbu/hspterm/issues) · [从源码构建](#从源码构建)

> 项目正在持续开发和修复中。Actions 提供开发测试构建，暂不视为稳定发行版；Android 版本尚未提供。

## 让常用操作更顺手

### 终端与文件管理，始终关联同一个会话

- **文件就在终端旁边**：SFTP 侧栏跟随当前焦点终端，切换服务器时同步切换文件上下文。
- **少复制一次路径**：将文件或目录拖入终端，或从菜单发送名称、路径；路径会进行 Shell 安全引用，插入路径不会自动执行。
- **目录双向联动**：从终端定位远端文件，在可靠获取工作目录时跟随终端路径，也可以从 SFTP 跳转到终端所在目录。
- **顺手导航**：面包屑地址栏、路径编辑与缓存补全、主机书签和全局书签，方便反复访问常用目录。

部分目录联动、路径输入和命令联想需要远端 Shell 提供可靠状态，可逐主机主动启用可选 Shell 集成。输入环境无法确认时，路径操作会退回复制，不向全屏程序盲目发送按键。

### 一个标签，一个独立终端

- 多个 SSH 会话以标签管理，支持切换、排序、重命名和固定。
- 将已有标签拖到边缘形成左右或上下分屏，也可以在分屏区域之间移动标签。
- 拖动边界调整比例，临时最大化一个区域，随后恢复原布局。
- 移动标签和调整布局只改变显示方式，不重新建立 SSH 连接。
- 断线后保留已有画面与历史，由用户手动重新连接。

### 用熟悉的编辑器修改远端文件

- 双击远端文件，在本地关联编辑器中打开，保存后回传修改。
- 编辑进度集中显示在传输队列中，同一会话内重复打开同一文件不会堆积编辑会话。
- 遇到远端变化或回传失败时提示处理，并保留未同步草稿。
- 支持文件预览、内置文本编辑，以及打开本地文件和定位所在文件夹。

### 文件传输，有进度，也有后续处理

- 文件与文件夹级上传、下载任务，集中查看进度、速度和状态。
- 支持并发控制、带宽限制、暂停、继续、取消和失败重试。
- 文件夹任务可展开查看内部统计、当前文件与失败项目。
- 支持文件冲突处理、可继续任务的断点恢复，以及跨服务器文件操作。
- 面向 Windows Explorer 的拖放传输，以及剪贴板图片上传，让文件进入远端的路径更短。

## 终端能力

HSPTerm 以远端终端行为的正确性为基础，持续完善 Vim、tmux、htop 等交互程序的使用体验。

- **显示**：ANSI 颜色、256 色、TrueColor、Unicode、中文、宽字符、组合字符和可配置光标。
- **输入**：传统按键序列、Kitty Keyboard Protocol、CSI u、鼠标报告和中文输入法处理。
- **粘贴**：统一文字与图片粘贴入口、Bracketed Paste、多行预览确认；图片上传后只填入远端路径，不自动回车。
- **查找**：当前会话历史的普通文本或正则搜索、匹配定位，以及 UTF-8 文本导出。
- **阅读**：字体与配色设置、Ctrl + 滚轮缩放、自定义文本高亮、语义着色、彩虹括号和选中同词高亮。
- **效率**：历史单行命令联想和命令面板。显示增强只作用于绘制层，不改写 SSH 原始输出。

滚动历史结合内存与运行期临时磁盘保存，应用退出后不跨重启恢复。tmux 的历史拖动以远端实际保留的缓冲区为准；部分功能依赖远端能力，应用自己管理的历史仍由该应用控制。

## 主机管理与数据保护

- 主机分组、收藏、搜索、复制及 OpenSSH 配置导入。
- 密码或私钥认证、密钥管理，以及首次主机指纹确认和密钥变更保护。
- 跳板机、HTTP CONNECT / SOCKS5 代理，以及本地、远端和动态端口转发。
- 主密码保护本地配置与凭据，使用 Argon2id 与 AES-256-GCM 等机制保护敏感数据。
- 加密备份与恢复，可选 WebDAV / Google Drive 加密配置同步。
- 可导出本次启动以来的运行日志，便于反馈问题；提交反馈前请检查并脱敏。

## 专注工具本身，不加入 AI 功能

**HSPTerm 不内置大模型，不接入 AI 服务，不提供 AI 聊天助手或 AI 生成、执行命令。**

历史命令联想只匹配用户此前记录的单行命令，不调用模型。项目持续投入的方向是连接稳定性、终端兼容性、文件操作、安全性与资源效率。

用户可以通过 SSH 运行自己的远端程序；HSPTerm 本身保持终端和文件传输工具的职责。

## 下载与使用

1. 打开 [Windows x64 构建页面](https://github.com/hspmanbu/hspterm/actions/workflows/windows-build.yml)，选择成功的构建。
2. 在 **Artifacts** 中下载 `HSPTerm-windows-x64`。
3. 将整个压缩包解压到本地目录，运行 `hspterm.exe`。
4. 按提示创建或解锁主密码，保存主机配置，确认服务器指纹后连接。

请保留程序同目录的 DLL 和 `data` 目录，不要只复制 EXE。Actions 构建产物有保存期限，过期后可使用源码构建。

Windows 原生拖放、多显示器与高 DPI、输入法、复杂 TUI 及真实同步服务仍在持续验证和完善。Android 是后续平台目标，目前暂停开发；Linux 桌面运行入口用于开发验证。

## 从源码构建

### Windows 环境

- Git、Python 3。
- Rust，版本由 [rust-toolchain.toml](rust-toolchain.toml) 指定，目标为 `x86_64-pc-windows-msvc`。
- Flutter，版本与 [Windows CI](.github/workflows/windows-build.yml) 保持一致。
- Visual Studio 2022，安装“使用 C++ 的桌面开发”、Windows SDK、C++ CMake 工具与所需 ATL 组件。
- `flutter_rust_bridge_codegen` **2.13.0**。

当前开发代码位于 `fix/round7-windows-feedback` 分支。在 PowerShell 中执行：

```powershell
git clone --branch fix/round7-windows-feedback https://github.com/hspmanbu/hspterm.git
cd hspterm

rustup target add x86_64-pc-windows-msvc
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter config --enable-windows-desktop

.\tools\build_windows.ps1 -CreateArchive
```

[构建脚本](tools/build_windows.ps1) 会准备受维护的原生扩展、解析 Flutter 依赖、生成 FRB 绑定、编译 Rust 核心与正式 Flutter 工作台，并打包所需运行库。

- 程序目录：`ui_flutter/build/windows/x64/runner/Release/`
- 压缩包：`ui_flutter/build/windows/HSPTerm-windows-x64.zip`
- 正式入口：`ui_flutter/lib/workbench_main.dart`

### 源码结构

| 目录 | 职责 |
| --- | --- |
| `crates/term-core` | 终端协议、状态、历史、搜索与输入编码 |
| `crates/ssh-core` | SSH、PTY、SFTP、网络连接与传输核心 |
| `crates/storage-sync` | 加密存储、凭据、备份与配置同步 |
| `crates/frb-bridge` | Rust 与 Flutter 的接口和事件桥接 |
| `ui_flutter` | 桌面工作台、终端绘制与平台交互 |
| `tools` | 构建、静态检查与验证工具 |
| `vendor` | 保留许可证的第三方源码及维护补丁 |

终端基于 `alacritty_terminal` / `vte`，SSH 与 SFTP 主要基于 `russh` / `russh-sftp`；Flutter 使用 `CustomPainter` 绘制终端，不使用 WebView、Electron 或 Tauri。

## 反馈问题

欢迎通过 [Issues](https://github.com/hspmanbu/hspterm/issues) 反馈问题。请尽量提供应用构建版本、Windows 版本、显示缩放比例、复现步骤，以及脱敏后的本次运行日志。涉及 tmux 或远端 TUI 时，也请附上对应版本。

请勿提交密码、私钥、Token 或包含敏感信息的服务器配置。

第三方代码与字体资源的许可保留在对应目录中，使用与分发时请遵守各自许可。
