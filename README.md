# HSPTerm

专注于SSH和SFTP的终端

Windows / Android SSH 与 SFTP 客户端。Rust 共享核心 + Flutter UI，需求以 [V1.4](HSPTerm_最终需求规格_v1.4.md) 为准。

Windows功能源码已接入正式工作台，并收齐当前Ubuntu可执行的统一验证；Android专项按用户指示暂缓。正式入口为`ui_flutter/lib/workbench_main.dart`，包含独立SSH终端标签/自由分屏、加密主机和密钥管理、SFTP/文件夹任务/恢复与限速、内置及外部编辑、转发/跳板/代理、终端增强与可选Shell集成、配置同步/备份及Windows原生适配源码。完整状态见[需求覆盖](REQUIREMENTS_COVERAGE.md)和[最终验证记录](validation/windows-unified-2026-11-04/README.md)。

本机只有Ubuntu：Windows Flutter/MSVC/原生C++构建及系统行为、真实云账号尚未验收，当前没有已验证的Windows安装包；构建方案见`tools/build_windows.ps1`和[平台记录](PLATFORM_VALIDATION.md)。Linux bundle用于开发验收，不新增正式产品平台。

原型入口 `prototype_main.dart` 保留独立 Mock 模式供布局回归，截图见 [PHASE3A_REVIEW.md](PHASE3A_REVIEW.md)。一标签一会话/标签组分屏结构见 [TERMINAL_LAYOUT.md](TERMINAL_LAYOUT.md)。已取消阶段和视觉确认暂停。

Phase 2 的 Ubuntu 核心验收结果见 [PHASE2_VALIDATION.md](PHASE2_VALIDATION.md)，开发恢复入口为 [PROGRESS.md](PROGRESS.md)。Windows平台与真实服务商验收仍待环境，Android开发暂停；当前不是已验证可发布的Windows/Android客户端。

## 当前构建与测试

2026-11-04已收齐：Rust完整workspace647项；安全补丁后受影响Bridge75/SSH255项；Flutter143文件507个去重用例；29个Ubuntu适用GTK文件；VTE56/alacritty178项；Python22项。Flutter原53轮中断后按文件续齐，完整过程含失败/修正及去重证据见[集中验证](UNIFIED_VALIDATION.md)，不把续跑伪称单条命令整轮通过。最终Analyze0项、Rust/Dart格式、Linux及Windows GNU全目标严格Clippy通过；正式Ubuntu debug/release构建、真实启动清理退出及包内Native散列一致。

依赖解析/clean后，先在根目录执行`python3 tools/prepare_native_extensions.py`（Windows为`python`）。脚本核对固定上游散列并应用维护的Windows虚拟目录描述符补丁，保留MIT许可，不改全局pub缓存，已有本地修改会拒绝覆盖。详[Explorer拖放](WINDOWS_EXPLORER_DROP.md)。以下为复现入口，低空间测试profile参数见UNIFIED_VALIDATION。

安装 `rust-toolchain.toml` 指定的 Rust（含 rustfmt/clippy）。当前机器使用 `/root/.cargo/bin/cargo`，或先 `source /root/.cargo/env`。

```sh
cargo fmt --all -- --check
cargo check --workspace --all-targets --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked -- --test-threads=1
cargo test -p vte --locked
```

Linux OpenSSH 集成测试需要 `ssh-keygen`、`/usr/sbin/sshd`、`/run/sshd`、可登录的当前用户，以及 `python3`、`vim`、`tmux`、`htop`。测试自动创建独立回环 sshd、临时密钥及目录，不使用或更改现有 SSH 服务。其他平台不会编译 Linux 专属 OpenSSH 测试；不代表对应平台验收通过。

已有实际可运行的Flutter SSH测试程序、FRB2.13.0生成绑定与CustomPainter终端。构建、使用及GUI测试见 [Flutter README](ui_flutter/README.md)。Linux开发runner已经真实OpenSSH/TUI集成验证；Windows/Android平台验证尚未完成。

终端输入编码依据 [Kitty Keyboard Protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) 和 [xterm 控制序列](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)；尚待完成的兼容项见进度记录。VTE 使用保留许可证的 OSC 内存上限及分块 UTF-8 消费计数修复，说明见 [HSPTERM-PATCH.md](vendor/vte/HSPTERM-PATCH.md)。

核心合成解析基准（不包含网络或 Flutter）：

```sh
cargo run -p hspterm-term-core --example throughput --release --locked
/usr/bin/time -v target/release/examples/throughput  # Linux 单独测量进程峰值 RSS
cargo audit
```

当前历史由热 RAM 行和运行期加密临时磁盘段组成，不跨重启恢复；搜索/UTF-8 导出不改变原始网格。上游补丁范围见 [alacritty 补丁说明](vendor/alacritty_terminal/HSPTERM-PATCH.md)。

资源/搜索/Reflow 基准（合成内容，不访问真实 SSH 或账户）：

```sh
cargo run -p hspterm-term-core --example history_benchmark --release --locked
```

GUI 性能测量及优化前后聚合数据见 [Ubuntu 验收记录](PHASE2_VALIDATION.md)；目标平台构建与人工验收见 [PLATFORM_VALIDATION.md](PLATFORM_VALIDATION.md)。

### 已接入的端口转发入口

正式工作台中，已保存主机的「进阶→端口转发配置」管理加密规则；终端标签组菜单的「当前终端端口转发」固定到原会话。首次连接需明确启动L/R/D，可选在每次手动重连成功后恢复；配置编辑/删除、运行停止、关闭面板互相独立。未保存的字段可保留本机加密草稿，正式修改仍需点击「保存规则」。主机删除后，原有实例仍可在对应终端停止。

终端链接悬停只显示文本，Ctrl+Click或右键菜单进入确认。回环URL/host:port可在确认后临时转发，经原SSH访问远端回环目标，不保存配置或自动重连；浏览器启动失败只清理本次监听。普通http/https链接交给系统浏览器，HTTPS证书仍正常验证。临时实例也在原会话转发面板停止。OSC8与Windows路径菜单已接入并经Ubuntu回归；Android交互暂缓，目标平台验证范围见PORT_FORWARDING.md和PROGRESS.md。

正式主机管理已支持显式OpenSSH Config预览/筛选/加密元数据导入（不读IdentityFile秘密、不执行命令、不自动连接），使用范围与实际验证见[OPENSSH_IMPORT.md](OPENSSH_IMPORT.md)。导入后仍须明确配置认证凭据。

终端显示增强已接正式加密设置：自定义高亮、语义着色、彩虹括号与同词标记只改变绘制，不改变SSH/历史/复制；工作量上限、实际测试与截图见[TERMINAL_DECORATIONS.md](TERMINAL_DECORATIONS.md)。
