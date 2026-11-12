# HSPTerm

一个 SSH / SFTP 客户端，使用 Flutter 和 Rust 开发。目前主要开发 Windows 11 x64 版本。

支持多标签、分屏、SFTP 文件管理、本地编辑远端文件和传输队列。终端与 SFTP 使用同一个 SSH 会话，切换终端时，文件侧栏也会跟着切换。

项目只做 SSH 和 SFTP，不计划加入 AI 功能，不接入大模型服务。命令联想只匹配用户已经记录的历史命令。

[下载测试版](https://github.com/hspmanbu/hspterm/actions/workflows/windows-build.yml) · [问题反馈](https://github.com/hspmanbu/hspterm/issues) · [编译说明](#编译)

目前还在开发和修复问题，下载到的是测试构建。Android 暂未提供可用版本。

## 功能

### 终端

- 多标签管理 SSH 会话，支持拖动排序、重命名和固定。
- 左右、上下分屏；可以把已有标签拖到另一个区域，调整分屏比例或临时最大化。
- 中文输入、Unicode 宽字符、256 色和 TrueColor，可设置字体、配色和光标。
- 普通文本与正则搜索、滚动历史、文本导出。
- 多行粘贴预览、历史命令联想、自定义高亮和命令面板。
- `Ctrl + 鼠标滚轮` 调整终端字号。
- 断线后保留画面和历史，手动重新连接。

### SFTP

- 面包屑导航、路径补全、目录书签、多选、重命名和文件属性。
- 将远端文件拖进终端，或通过菜单插入名称、路径；只插入，不自动回车。
- 从终端定位文件，在 SFTP 中跳转到终端目录，也可以跟随终端路径。
- 双击远端文件，用本地编辑器打开，保存后回传。发生冲突或回传失败时保留未同步修改。
- 文件及文件夹上传、下载，支持 Windows Explorer 拖放和跨服务器文件操作。
- 传输队列支持暂停、继续、取消、限速、断点恢复和失败重试；文件夹任务可展开查看详情。
- 粘贴剪贴板图片时上传到远端，再把文件路径填入终端。

目录跟随、命令联想等功能需要远端 Shell 提供相应信息，可在主机配置中启用可选 Shell 集成。无法确认输入状态时，发送路径会退回复制，避免误操作远端程序。

tmux 中的历史滚动条对应 tmux 实际保存的缓冲区，需要远端 Python 3。没有进入 tmux 缓冲区的应用内历史，仍使用应用自己的滚动方式。

### 连接与配置

- 主机分组、收藏、搜索、密钥管理和 OpenSSH 配置导入。
- 密码或私钥认证，首次连接确认主机指纹，密钥变更时阻止直接连接。
- 跳板机、HTTP CONNECT / SOCKS5 代理，本地、远端及动态端口转发。
- 主密码保护本地配置与凭据，加密备份与恢复。
- 可选 WebDAV / Google Drive 加密配置同步。
- 导出本次启动以来的运行日志。

## 下载

在 [GitHub Actions](https://github.com/hspmanbu/hspterm/actions/workflows/windows-build.yml) 中选择成功的构建，下载 **Artifacts → HSPTerm-windows-x64**，完整解压后运行 `hspterm.exe`。

请保留同目录的 DLL 和 `data` 文件夹。构建产物有保存期限，过期后需要重新构建。

Windows 拖放、高 DPI、输入法及远端 TUI 的兼容性仍在修复和测试中。配置同步也需要在实际服务环境下验证。

## 编译

Windows 环境需要：

- Git、Python 3。
- Rust，版本见 [rust-toolchain.toml](rust-toolchain.toml)。
- Flutter，版本与 [Windows CI](.github/workflows/windows-build.yml) 一致。
- Visual Studio 2022，安装“使用 C++ 的桌面开发”、Windows SDK、C++ CMake 工具和 ATL 组件。

当前开发分支为 `fix/round7-windows-feedback`。在 PowerShell 中执行：

```powershell
git clone --branch fix/round7-windows-feedback https://github.com/hspmanbu/hspterm.git
cd hspterm

rustup target add x86_64-pc-windows-msvc
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter config --enable-windows-desktop

.\tools\build_windows.ps1 -CreateArchive
```

[构建脚本](tools/build_windows.ps1) 会准备依赖、生成桥接代码，编译并打包 Rust 和 Flutter 程序。

输出目录：`ui_flutter/build/windows/x64/runner/Release/`

压缩包：`ui_flutter/build/windows/HSPTerm-windows-x64.zip`

终端基于 `alacritty_terminal` / `vte`，SSH / SFTP 基于 `russh` / `russh-sftp`，通过 `flutter_rust_bridge` 连接 Flutter。终端使用 `CustomPainter` 绘制。

## 反馈

遇到问题请提交 [Issue](https://github.com/hspmanbu/hspterm/issues)，附上构建版本、Windows 版本、复现步骤和运行日志。显示问题请补充缩放比例；tmux 或远端程序的问题请补充对应版本。

日志请先检查并脱敏，不要上传密码、私钥或 Token。

第三方代码和字体的许可证保留在各自目录中。
