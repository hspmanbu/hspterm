# HSPTerm 项目交接文档

> 面向第三方接手者。读完本文档（配合其指向的资料）应能直接接手开发、验证与发布。
> 编写日期：2026-11-09。对应最新提交：`0165e9d`（分支 `fix/round7-windows-feedback`）。

---

## 1. 项目是什么

HSPTerm 是一个 **Windows / Android SSH + SFTP 终端客户端**：

- **Rust 共享核心 + Flutter UI**，通过 flutter\_rust\_bridge (FRB) 2.13.0 桥接。
- 功能范围：多标签 SSH 终端（自由分屏）、加密主机/密钥管理、SFTP 文件面板（列配置/排序/权限与所有者列）、文件夹传输任务（断点续传/限速/冲突处理）、内置与外部文件编辑（写回远端）、端口转发（-L/-R/-D/跳板/代理）、可选 Shell 集成（OSC7/133）、配置同步/备份（WebDAV/Google Drive）、tmux 附着、命令面板等。
- **唯一产品需求基线**是 [`HSPTerm_最终需求规格_v1.4.md`](HSPTerm_最终需求规格_v1.4.md)（含逐轮用户修订 appended 在文末）。功能完成度以 [`REQUIREMENTS_COVERAGE.md`](REQUIREMENTS_COVERAGE.md) 为准（由 `tools/requirements_coverage.py` 生成，不得用 PROGRESS 替代）。
- 当前状态：**Windows 功能开发完成并经分支 CI 构建**；Windows 11 实机人工验收部分待用户执行；Android 按用户指示**暂停**（共享核心保持可移植，未从需求删除）。

---

## 2. 仓库布局

```
/opt/hspterm/
├── crates/                    # Rust 核心（4 个 crate）
│   ├── term-core/             # 终端仿真：VTE 解析、网格、Kitty 键盘协议、
│   │                          #   OSC7/8/133、历史分页、命令范围、排版偏好
│   ├── ssh-core/              # SSH/SFTP/PTY/传输：russh 封装、目录分页读取、
│   │                          #   TreeTransfer/FIFO、跳板、代理、端口转发、
│   │                          #   Agent、tmux、直传、远端复制/移动
│   ├── storage-sync/          # 加密 SQLite 配置库：主机/密钥/书签/转发规则/
│   │                          #   终端偏好/命令历史/云同步账本/任务检查点
│   └── frb-bridge/            # FRB API 层（~250 个公开函数）+ 错误边界
├── ui_flutter/                # Flutter UI
│   ├── lib/
│   │   ├── main.dart              # 最小 SSH 验收入口
│   │   ├── workbench_main.dart    # ★ 正式工作台入口
│   │   ├── prototype_main.dart    # 独立 Mock 原型（布局回归用）
│   │   ├── prototype/             # 共享工作台组件（files.dart=SFTP面板等）
│   │   ├── terminal/              # TerminalView/Controller/Painter、IME、输入
│   │   ├── workbench/             # 真实业务：model、队列、编辑、诊断、设置
│   │   └── src/rust/              # ★ FRB 生成代码——绝不手改
│   ├── test/                  # ~165 个文件、~590 项组件/单元测试
│   ├── integration_test/      # GUI 集成测试（含真实 OpenSSH/TUI 场景）
│   └── windows/               # Windows runner（含 Explorer 拖放、窗口过程）
├── vendor/                    # 固定补丁的依赖（russh 0.64.1 消费驱动流控、
│                              #   alacritty_terminal、vte、russh-sftp），各带
│                              #   HSPTERM-PATCH.md 说明与许可
├── tools/                     # 构建辅助（见 §5）
├── validation/                # 每轮验证证据归档（README+results.json+截图）
├── .github/workflows/windows-build.yml   # Windows x64 CI
├── AGENTS.md                  # ★ 强约束开发约定（必读，见 §8）
├── PROGRESS.md                # ★ 开发进度时间线（新条目在顶部）
├── *_VALIDATION.md / *_*.md   # 40+ 份模块专题文档（见 §7）
└── flutter_rust_bridge.yaml  # FRB 代码生成配置（版本/路径固定）
```

规模：Rust ~66,500 行；Dart（不含生成代码）~43,500 行；历史 45 个提交（main 之后 17 个为第八~十一轮反馈修复）。

---

## 3. 架构与关键数据流

### 3.1 四层结构

```
Flutter UI (workbench_main.dart)
   │  FRB 2.13.0（async，String/DTO 边界）
frb-bridge::api  —— ~250 个 pub async fn，全部经 public_errors 边界
   │
ssh-core / term-core / storage-sync
   │
vendor/（russh 0.64.1 + 消费驱动流控补丁、russh-sftp）
```

### 3.2 终端数据流（务必理解，出过多次 bug）

- Rust `term-core::Terminal` 持有真实网格；SSH 输出 feed 进解析器，revision/content\_revision 递增。
- Flutter `TerminalController` 通过事件流拉取**快照帧**；`TerminalView` 只负责平台输入；`TerminalPainter` 只消费真实快照、不改缓冲。
- **规则**（违反会死锁/丢帧）：颜色/尺寸查询必须由网络 actor 内部回复；同时只允许一个未确认帧通知；不可见时不取帧但继续消费平台事件；Dart 侧必须等 FRB stream `onDone` 后再取消订阅/销毁端口。
- 输入路径：可打印键先挂起为 `_pendingTextKey` 等平台文本链路回填（第十一轮后有 150ms 超时直发回退+迟到去重，详见 `terminal/view.dart` 注释）；Windows IME 候选框定位靠 `setComposingRect`（不是 `setCaretRect`）。

### 3.3 SFTP / 传输

- 目录读取走 open/page/close 分页（`directory_reader.dart` + ssh-core `directory.rs`），`DirectoryCache` 每会话 16 目录/64MiB 有界，重连清空。
- 文件/文件夹任务：`ssh-core::transfer/tree_transfer/task_scheduler` 持流与 FIFO；`frb-bridge::transfers` 是运行期 registry；`workbench/queue.dart` 仅展示、不拥有 SSH。
- 传输检查点按 256 节点分块入 `storage-sync::local_tasks`（设备本机、排除云同步）。
- 路径安全：清单 relative 是 POSIX 路径，Windows 映射必须按原始分量处理（`TRANSFER_PATH_SAFETY.md`）。

### 3.4 本地编辑写回（近期重点，见 `local_edit_launch.dart`）

- 双击远端文件 → 每任务独立临时目录+保留原文件名 → 系统编辑器打开 → 监测稳定修改 → 上传到远端临时文件 → **两阶段替换**：
  1. `sftp_edit_replace`：优先 POSIX-rename 原子替换（OpenSSH 零弹窗），保留权限位；
  2. 无 POSIX 扩展时弹三选框（取消/仅本次/本次连接均覆盖），确认后 `sftp_edit_replace_confirmed`：原文件→备份→顶替→失败回滚→恢复权限→删备份。
- "本次连接均覆盖"记忆按 (native id, generation) 存于运行时 `LocalEditRegistry`（重连失效、跨标签隔离、不落盘）。
- 下载/上传均**流式**（逐块 IOSink / RandomAccessFile），修改检测用增量双 FNV-1a 摘要；dispose 只删已确认同步的文件，未同步草稿保留。
- 全流程绑定 SSH generation，防跨连接误传。

### 3.5 错误边界（改 API 前必读 `ERROR_BOUNDARIES.md`）

frb-bridge 的 ~250 个 `Result` 由 `public_errors::guard/finish` 包装：任何 anyhow 错误只输出**白名单固定摘要**（`PUBLIC_LITERALS`），绝不透出原文。新增/修改 Rust API 后必须：

```sh
python3 tools/bridge_error_boundaries.py --write   # 先写再审查
python3 tools/bridge_error_boundaries.py --check   # 静态清单检查
```

FRB 枚举变化（如 DiagnosticCode 新增）会连累 `workbench/diagnostics.dart` 的穷举 switch——历史上曾因此 CI 失败，改枚举务必同步。

---

## 4. 环境搭建（Ubuntu 开发机）

已验证环境（本项目实际使用的机器）：

| 组件 | 版本/位置 |
|---|---|
| Rust | 1.99.1（`rust-toolchain.toml` 固定，含 rustfmt/clippy），`/root/.cargo/bin` |
| Flutter | `/opt/flutter/bin/flutter`（3.47 系列） |
| FRB codegen | `flutter_rust_bridge_codegen` 2.13.0（cargo 安装） |
| OpenSSH | 本机 sshd 9.6 + ssh-keygen（真实集成测试用；测试自建回环 sshd，不动系统服务） |
| Python | 3.x（工具脚本；Linux `python3`，Windows `python`） |

首次/清理后构建顺序（**顺序不可乱**）：

```sh
cd /opt/hspterm
python3 tools/prepare_native_extensions.py   # 固定 super_native_extensions 0.9.1 补丁；
                                            #   flutter clean 后也要重跑
cd ui_flutter
flutter pub get
mkdir -p build/native_assets/linux          # 干净构建需预创建
flutter build linux --debug                 # 或 --release
./build/linux/x64/debug/bundle/hspterm      # 冒烟：timeout 25 dbus-run-session -- ./...
```

注意：

- `prepare_native_extensions.py` 核对固定上游散列，不改全局 pub 缓存；已有本地修改会拒绝覆盖。
- 磁盘紧张时（本机 97G 盘）：`rm -rf ui_flutter/build target/debug` 可回收 ~8-9G；源码+vendor+字体+验证证据必须保留。当前可用约 12G。
- 仓库根有**用户保留的未跟踪文件不得提交/删除**：`HSPTerm-*.log`、`ssh-screen/`、`tools/AGENTS.md`、`ui_flutter/benchmark/screenshot.py`。

---

## 5. 构建与 CI

### 5.1 Windows CI（当前发布通道）

- 工作流 `.github/workflows/windows-build.yml`：`push` 到 **main**（路径过滤）或 **workflow\_dispatch** 触发。
- **产品开发在分支上时**（近年常态，如 `fix/round7-windows-feedback`）：push 后需手动 dispatch：

```sh
TOKEN=$(grep -oP 'https://[^:]+:\K[^@]+(?=@github.com)' ~/.git-credentials | head -1)
curl -s -X POST -H "Authorization: token $TOKEN" \
  https://api.github.com/repos/hspmanbu/hspterm/actions/workflows/windows-build.yml/dispatches \
  -d '{"ref":"<分支名>"}'
```

- CI 内容：runner windows-2022、RUSTUP\_TOOLCHAIN 1.99.1-msvc；正规 FRB 重生成 → `tools/build_windows.ps1 -CreateArchive`（MSVC Release、Analyze 0、固定组件测试、原生启动/退出、窗口几何恢复）→ 产物 `HSPTerm-windows-x64`（~40MB zip）+ `windows-startup-memory`。
- 监控查询（不要重复 dispatch，先查）：

```sh
curl -s -H "Authorization: token $TOKEN" \
 "https://api.github.com/repos/hspmanbu/hspterm/actions/runs?branch=<分支>&per_page=1"
```

- 历史构建时长 ~20-25 分钟。**CI 成功 ≠ Windows 实机验证通过**——每轮都有明确的"待 Win11 实机"清单记录在 PROGRESS.md 对应条目。

### 5.2 Ubuntu 本地验证（每次提交前）

```sh
# Rust
cd /opt/hspterm
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked -- --test-threads=1

# Flutter
cd ui_flutter
flutter analyze                    # 必须 0 issue
flutter test                       # 全套件
dart format lib test --set-exit-if-changed
```

改了 Rust DTO/API 后：`flutter_rust_bridge_codegen generate`（在仓库根），并把生成物一并提交。**绝不手改 `ui_flutter/lib/src/rust/` 与 `crates/frb-bridge/src/frb_generated.rs`。**

### 5.3 已知测试基线（重要，勿误判）

全套件当前为 **586 通过 / 11 失败**，11 项失败经逐项 git-stash 对照确认为**分支预存**（非本轮引入）：

- `workbench_lifecycle_test.dart` 5 项（需已构建 native lib 的生命周期测试）
- 桥接类（`terminal_path_bridge` / `sftp_properties_bridge` / `transfer_queue` / `explorer_files_panel` / `live_workbench` / `file_context_menu`）各 1 项

另注意：`flutter test` 需要 `build/native_assets/linux` 下有**当前源码对应的**native 库——若刚清理过 build/ 或重新生成过 FRB，先重跑 `flutter build linux --debug`，否则会出现 ~60 项 RustLib 初始化失败（是环境问题不是代码回归）。

### 5.4 真实 OpenSSH 集成测试

`crates/ssh-core/tests/openssh.rs` 及 `openssh_*/` 子模块在 Linux 上自建回环 sshd（需 `/usr/sbin/sshd`、`/run/sshd`、ssh-keygen、当前用户可登录、python3/vim/tmux/htop）。跑法：`cargo test -p hspterm-ssh-core --test openssh <名称过滤>`。这些测试使用真实 SFTP/PTY，是"Mock Gateway 测试通过"之外的关键验收层。

---

## 6. 开发工作流（反馈-修复轮次模式）

项目以**用户实机反馈轮次**推进（目前已完成十一轮）。每轮流程固定：

1. **确认基线**：`git log` 看 HEAD，通读 `AGENTS.md` 顶部"最新交付"节 + `PROGRESS.md` 顶部条目。
2. **Ubuntu 源码修改**：定位根因（要求实际源码分析，不是猜）、修改、补测试。
3. **本地验证**：§5.2 全套 + 针对性真实 OpenSSH/GTK 验证（GUI 截图用 `test/rename_menu_visual_test.dart` 的 RepaintBoundary→PNG 模式，或 dbus-run-session 冒烟）。
4. **提交推送**分支（提交信息带 `[UNVERIFIED native/platform]` 标注未实机部分）。
5. **dispatch Windows CI**（§5.1），**轮询等待实际成功**，失败则修复重跑。
6. **更新 PROGRESS.md**（新条目置顶；区分 Ubuntu 验证 / Windows CI / 待实机验收三层）并以 `[skip ci]` 提交。
7. **清理构建中间产物**，报告：commit SHA、Run/产物链接、根因、测试结果、待实机清单。

近期各轮要点（详见 PROGRESS.md 对应节）：

| 轮 | 主题 |
|---|---|
| 8 | SFTP 编辑代次错误、CapsLock 首字符恢复、无响应诊断桩、菜单图标行 |
| 9 | 重命名框单元格内编辑、菜单主题化+外部关闭、权限/所有者列+按主机持久化、编辑队列任务、文件类型、调色板提亮 |
| 10 | 菜单条件项样式、编辑保存 posix 覆盖、编辑框居中 |
| 11 | 真单行编辑器+长名滚动、两阶段覆盖确认+连接级记忆+回滚、P0 流式传输+摘要 |

---

## 7. 模块专题文档索引（按需精读）

仓库根 40+ 份 `*.MD` 是各模块的权威设计/边界文档，**修改对应模块前必读其文档**：

- 终端：TERMINAL\_LAYOUT / TERMINAL\_TYPOGRAPHY / TERMINAL\_PATHS / SHELL\_INTEGRATION / OSC8\_LINKS / TMUX / TERMINAL\_DECORATIONS / TERMINAL\_NOTIFICATIONS / TERMINAL\_PREFERENCES / SESSION\_FLOW / CONNECTION\_IDENTITY
- SFTP/文件：DIRECTORY\_PAGING / SFTP\_BOOKMARKS / SFTP\_RECOVERY / FILE\_PREVIEWS / FILE\_SEARCH / REMOTE\_EDITING / LARGE\_EDITING / REMOTE\_FILE\_OPERATIONS / CACHED\_PATH\_COMPLETION
- 传输：TRANSFER\_ENGINE / TRANSFER\_PERFORMANCE / TRANSFER\_PATH\_SAFETY / TRANSFER\_RECONNECT / STAGING\_CLEANUP / SOURCE\_RETIREMENT / WINDOWS\_EXPLORER\_DROP / DIRECT\_TRANSFERS
- 网络/安全：SSH\_NETWORK / SSH\_AGENT / SSH\_RSA / PORT\_FORWARDING / KEY\_MANAGEMENT / TEMPORARY\_CONNECTIONS / OPENSSH\_IMPORT
- 配置/同步：BACKUP\_RESTORE / CLOUD\_SYNC\*（4 份）/ GOOGLE\_DRIVE / COMMAND\_HISTORY / HOST\_ORDERING / WINDOWS\_UNLOCK
- 平台/质量：WINDOWS\_WINDOW / ERROR\_BOUNDARIES / RUNTIME\_DIAGNOSTICS / STATIC\_REVIEW / REQUIREMENTS\_COVERAGE
- 历史阶段：PHASE2\_VALIDATION / PHASE3A\_REVIEW / UNIFIED\_VALIDATION / WORKBENCH\_VALIDATION / PLATFORM\_VALIDATION

---

## 8. 红线约束（AGENTS.md 的强约定，违反即返工）

1. **不提交**真实凭据/私钥/Token/真实服务器配置/测试生成的秘密或输出。
2. **未编译/未运行/未验证的功能不得标为完成**；平台缺失必须列明。
3. **不自动重连 SSH**（用户 opt-in 设置除外）、**不增加本地 Shell**、**不修改原始终端内容**（显示增强只派生样式）。
4. 字体/排版：元数据仅设备本机，禁止云同步字体正文；读取失败不得当默认覆盖。
5. 每次 Rust API/DTO 变更后**必须**正规 FRB 重生成并检查生成枚举的 Dart switch 一致性。
6. `bridge_error_boundaries.py --check` 必须通过；错误输出只走白名单摘要。
7. Windows 专有行为（IME/Explorer/窗口/DPI）不能由 Ubuntu 验收替代；`tools/build_windows.ps1` 仅 Windows x64。
8. `prepare_native_extensions.py` 必须在 pub get 之前跑（flutter clean 后同样）。
9. 用户未跟踪文件（§4 末）不提交不清理。
10. 历史决策以 V1.4 末尾用户修订为最高优先；PROGRESS.md 顶部是当前状态唯一入口，**不按早期空库状态重复生成工程、不回退已通过的功能**。

---

## 9. 当前待办与验收缺口

### 9.1 待 Windows 11 用户实机验收（第十一轮产物）

- 长名文件重命名单行/居中/光标滚动观感（含 125%/150% DPI、紧凑模式、Ctrl+滚轮缩放）
- 双击编辑保存到 OpenSSH：应**零弹窗直接成功**（POSIX 原子替换）
- 非 POSIX 服务器：三选弹窗（取消/仅本次/本次连接均覆盖）行为
- "本次连接均覆盖"后同连接免问、**断开重连后恢复询问**、不同标签互不影响
- 确认期间远端被外部修改 → 必须拒绝覆盖转冲突提示
- 编辑保存后远端权限位保持；失败回滚完整性
- 多文件并行编辑的内存观感（P0 流式化收益）

### 9.2 已知未完成/暂缓项

- **Windows 系统关联图标**：SFTP 文件列表当前全为内置类别图标，shell 图标缓存方案未实现（明确列为后续增强，禁止为视觉效果引入逐行 Shell API 调用）。
- **Agent CLI 闪烁**（P2）：帧诊断（frameJank build/raster/pull）已部署，完整修复待实机日志定位；不得用降刷新率换取。
- **Android**：整体暂停（用户指示），核心保持可移植。
- 交互场景性能基准（三标签/高频输出/大目录/多编辑）无法无头驱动，依靠已部署的 `uiStall/frameJank/resourceCount` 诊断事件，由实机导出 `.log` 采集（`HSPTERM_INPUT_TRACE=1` 可开输入元数据追踪）。
- Cloud Sync / Google Drive / 备份等大模块的"待整体接入"状态以 PROGRESS.md 各专题条目为准。

### 9.3 分支合并注意

产品分支 `fix/round7-windows-feedback` 领先 main 17 个提交（第八~十一轮全部工作）。合并回 main 时注意：历史上用户明确要求**不**用旧 main 覆盖分支成果、**不**盲目合并旧草稿 PR #1（其内容已在第七轮选择性吸收）。

---

## 10. 快速参考卡

```sh
# 日常开发循环
python3 tools/prepare_native_extensions.py && cd ui_flutter && flutter pub get
flutter analyze && flutter test <针对性文件>
cd .. && cargo clippy --workspace --all-targets --locked -- -D warnings

# FRB 重生成（Rust API/DTO 变更后）
flutter_rust_bridge_codegen generate

# 冒烟
cd ui_flutter && timeout 25 dbus-run-session -- ./build/linux/x64/debug/bundle/hspterm

# 真实 OpenSSH 集成测试
mkdir -p /run/sshd && cargo test -p hspterm-ssh-core --test openssh <filter>

# CI dispatch + 查询（分支）
# 见 §5.1

# 静态合同检查
PYTHONDONTWRITEBYTECODE=1 python3 tools/bridge_contracts.py
python3 tools/bridge_error_boundaries.py --check

# 需求覆盖再生成
python3 tools/requirements_coverage.py
```

诊断事件速查（导出的运行 .log 中）：`uiStall`（心跳漂移>250ms）、`frameJank`（帧>100ms 或拉取>200ms，含 buildMs/rasterMs）、`resourceCount`（30s 资源计数）、`inputTrace`（HSPTERM\_INPUT\_TRACE=1 时的输入管线元数据，无字符内容）。

---

## 11. 交接确认清单

接手后建议按顺序做一遍以建立手感：

1. 通读本文档 → AGENTS.md → PROGRESS.md 顶部两条 → V1.4 规格目录。
2. 按 §4 从零构建一次 Linux debug（体验 prepare→pub get→build 顺序）。
3. 跑 §5.2 全套验证，对照 §5.3 的 586/11 基线。
4. 跑 2-3 个真实 OpenSSH 测试（如 `cargo test -p hspterm-ssh-core --test openssh posix_rename`）。
5. 读 `local_edit_launch.dart` 全文（近期改动最集中的模块，注释即设计）。
6. 用 `test/rename_menu_visual_test.dart` 跑一次视觉捕获，看 `/tmp/hspterm-r9-shots/` 输出。
7. dispatch 一次分支 CI 并等待成功（确认你对发布流程的理解）。
8. 从 §9.1 清单中挑一项等待用户实机反馈回流。

—— 以上流程全部走通后，即可独立承接下一轮反馈修复。
