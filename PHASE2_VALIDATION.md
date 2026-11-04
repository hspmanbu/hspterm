# Phase 2 Ubuntu 验收记录（2026-10-22）

状态：**Ubuntu环境验收完成，Windows/Android实机验收待完成**。本标签针对用户本轮列出的 A 类基础终端收尾验收。V1.4 是唯一产品需求基线；本轮只按用户最新 A/B 分类验收终端核心，不进入 Phase 3，不代表完整 V1.4 产品功能已完成。

## 实际实现与修复

- 以原 alacritty 网格维护主/备用屏及 Reflow，热历史行留 RAM，冷行压缩并用运行期 AES-GCM 密钥存临时分段。行数上限、分段引用回收、权限/多进程运行锁、异常残留清理均有测试；临时历史不跨重启恢复。磁盘 I/O/认证失败向上传播，不伪造空白帧。
- 保留原 Reflow 算法，完成行增量分页，避免缩放时所有冷历史同时展开。中文/宽字/组合字符/Emoji 与纯内存参考网格逐单元格比较；500 行原文经多次宽度变化后逐字节导出和搜索一致。
- 当前终端普通/正则/大小写搜索、总数、上下导航、可见高亮、滚动条标记；冻结文档上的后台可取消搜索，内容变化/重排后拒绝旧索引并重建。不跨会话搜索。查询上限4096字节、语料上限256MiB，超限明确返回错误；稀疏命中索引避免每个命中长期存完整坐标。UTF-8 导出流式读历史，完成后无覆盖发布。
- FRB 同时只有一帧未确认通知，输出和确认唤醒共享最多60/s上限；空闲没有定时拉帧，隐藏不绘制但继续解析网络。字形4096项、ASCII段128项和可见行 Picture 有界缓存；同背景合并、空白跳绘、等宽验证的 ASCII 段绘制，斜体/宽字/组合字符保持单元格裁剪与像素对照。
- Kitty/CSI u/传统按键及 modifyOtherKeys 1/2，鼠标报告、Shift 覆盖捕获、复制/粘贴与 bracketed paste、可编辑多行确认、IME composing/提交、PTY锁定/恢复；关闭 OSC52 后撤销队列及未完成读取回调。软换行复制保留真实空格，宽字光标覆盖两格。
- 修复 VTE 部分 UTF-8 + ASCII + 后续多字节字符时多消费字节而漏空格的问题；两种 advance API 所有两段切分回归通过。修复上游 Kitty 栈满时误删 title_stack 的崩溃风险，保留所有许可证和最小补丁说明。
- 修复 SSH 超时预算把计时元数据 watch 关闭误报为 Disconnected 的竞态，保留具体主机密钥拒绝及原取消/超时语义。停止/销毁等待网络、FRB端口及文档任务释放；并发 shutdown 共用同一 Future。Linux 正常窗口关闭等待清理，不弹退出确认。
- 真实 Codex 测试的 managed daemon/pid-update-loop 采用隔离环境停止及限定可执行目录的退出确认，避免测试辅助进程泄漏；不检查真实账户环境或凭据。

## 已执行检查

以下命令在项目根目录运行，Flutter命令切到 `ui_flutter`。本机所列测试没有跳过项；Linux专用夹具在其他平台显式跳过，不能视作目标平台通过。

| 检查 | 结果 |
| --- | --- |
| `cargo fmt --all -- --check` | 通过 |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | 通过 |
| `cargo test --workspace --locked -- --test-threads=1` | 42通过，0失败/忽略 |
| `cargo test -p vte --locked` | 56通过 |
| `cargo test --manifest-path vendor/alacritty_terminal/Cargo.toml --lib --locked` | 132通过 |
| `cargo build -p hspterm-frb-bridge --locked` | 原生debug库通过；GUI CMake另构建打包release库 |
| `cargo audit` | 1349条公告/295个依赖，退出0，无已知漏洞报告（非完整安全审计） |
| `flutter analyze` | 无问题 |
| `flutter test --reporter expanded` | 12通过，包括10项widget、native真实SSH、真实Codex TUI |
| `xvfb-run -a dbus-run-session -- flutter test integration_test/ssh_terminal_test.dart -d linux --reporter expanded` | 1通过：真实画布/OpenSSH/Vim/tmux/htop/隐藏输出/重连等 |
| `xvfb-run -a dbus-run-session -- flutter test integration_test/codex_terminal_test.dart -d linux --reporter expanded` | 1通过：真实Codex普通/备用屏、Flutter物理按键 |
| `flutter build linux --profile -t benchmark/performance.dart ...` + 独立Xvfb运行 | 扩展性能工作负载完整通过，status=complete |
| `cargo check --workspace --target aarch64-linux-android --locked`（NDK25/API26） | 通过；不是APK/运行验证 |
| 默认 `main.dart` 的 `flutter build linux --debug/--release` 及真实GTK窗口关闭 | 两种构建均通过；两种真实窗口关闭均退出0且无历史run目录残留 |

Rust测试覆盖：临时段回收/多进程锁/损坏报告、历史锚定/主备用屏/重连/Reflow/精确Unicode导出、搜索清理/正则/取消、宽字/颜色/光标、传统/Kitty/modifyOtherKeys/鼠标/粘贴/OSC52。真实OpenSSH覆盖认证、指纹变化、取消/网络关闭、PTY/SFTP、无渲染大输出、同步输出截止刷新和查询洪泛。

并发OpenSSH回归连续5轮、共60项通过；最终完整串行12项通过。压力运行曾另出现一次加密私钥/PTY连接的泛化 Protocol 错误，尚未复现/定位；已增加仅记录错误类别和受控sshd有界诊断，不能称其原因已经修复。该项继续登记观察。

## Codex 与输入兼容性

已安装 Codex CLI 0.163.0，经独立回环 OpenSSH 运行真实 TUI。每个模式使用临时 HOME、CODEX_HOME、XDG 和空工作目录，清空继承环境，仅连接本机合成 Responses 服务。没有读取/复制真实登录凭据、没有真实模型调用/费用或模型工具执行。

正常 `--no-alt-screen` 和默认备用屏均覆盖启动/退出、上下/左右、Enter/Tab/Esc、Ctrl/Alt/Shift+Enter、中文和长文本、多行确认粘贴、流式响应及窗口缩放；native测试和Flutter物理事件GUI测试均通过。通用协议测试另外覆盖 Kitty 协商/事件、CSI u、modifyOtherKeys和传统模式。不是每一种协议强制组合下的 Codex 实机矩阵，也不代表真实账号/长时间模型任务完成验收。

widget层验证 composing不提前发送、提交只一次；Ubuntu GUI与native测试不能替代Windows真实IME或Android输入法。Claude Code无可用账号，未执行真实测试；按用户指令不要求本轮完成。

## 性能、内存和资源

聚合原始数据在 [validation/phase2-ubuntu](validation/phase2-ubuntu/)。环境为4 vCPU Ubuntu24.04.5，Flutter3.47.7 profile，Xvfb/D-Bus，Impeller OpenGLES软件渲染，DRI3不可用。RSS包含Flutter/Dart/图形映射及Rust；不是Rust单独占用。CPU以一个核心100%计，多核负载可超过100%。单次顺序样本存在调度/分配器波动，不将一次RSS判断为泄漏。

正式入口 `ui_flutter/benchmark/performance.dart` 使用普通 WidgetsFlutterBinding。此前测试绑定主动持续调帧的样本已排除。每阶段包含600ms结算，空闲额外预热2秒；扩展空闲观察5.6秒。重绘、桥接帧、CPU、RSS/PSS、build/raster p95、缓存、冷行读写和输入延迟均记录；每阶段断言桥接通知不超过60/s容差。

| 共同工作负载RSS（MiB） | 修改前8d39b62 | 最终eed6889核心 |
| --- | ---: | ---: |
| 空Flutter引擎 | 261.9 | 261.8 |
| 创建终端后空闲 | 387.4 | 283.2 |
| SSH连接后空闲 | 419.9 | 288.3 |
| Vim / tmux / htop | 422.1 / 426.2 / 433.7 | 290.4 / 292.1 / 308.6 |
| 五万Unicode行 | 631.4 | 325.1 |
| 100次快速滚动 | 657.3 | 328.0 |
| 缩窄60列 / 恢复140列 | 758.0 / 662.5 | 333.1 / 332.4 |
| 五次手动重连后 | 669.7 | 338.7 |

第一轮分页优化后的Reflow仍曾约575MiB，完成行增量分页后降至约334MiB；中间样本亦保留。引擎空白约262MiB是此Linux图形栈的基础，不能据此推定Windows/Android资源目标。最终样本在共同工作负载后增加搜索/持续输出/输入测量/两次真实窗口resize，最终关闭RSS393MiB，不与旧版未做这些额外操作的关闭值直接比较。allocator/引擎保留分配后RSS不归零，资源释放由循环/运行目录/句柄生命周期另验。

- 默认真实主界面（非基准入口）独立启动：debug RSS403.3MiB、release266.3MiB，预热2秒后观察5.6秒CPU均0.0%；两种窗口关闭均退出0、无历史run目录。该主界面尚未解锁/连接，不与SSH工作负载混用。
- 五万行：build p95 40.691→8.126ms，raster p95 205.067→70.117ms；快速滚动build29.133→8.485ms、raster100.787→48.945ms。软件图形栈仍超过16.7ms帧预算，不能声称稳定60FPS或目标GPU表现。
- 扩展空闲5.6秒：0桥接帧、0绘制、0渲染帧，CPU约0.2%。600ms短样本CPU约1.7%为单tick量化，长期样本更有意义。
- 20次普通回显延迟p50/p95/max=39/73/75ms；持续原始TUI输出期间20次输入ACK为38/44/55ms。延迟包括20ms探测轮询与桥接/SSH处理；不是硬件键盘到显示光子的延迟。负载和滚动会使用多个CPU核心，未静默丢弃原始输出。
- 实际X11窗口720×480和1280×720触发Flutter布局→Rust→PTY，远端 `stty size` 分别核对78×22和140×34。
- 20次native创建/关闭：最终单测RSS增量491,520字节，GUI样本-1,511,424字节；五次真实手动重连通过。无可复现的持续增长泄漏证据，不等于数小时soak证明。
- 核心独立百万行/10万行保留：输出10.809秒，100k/300k/600k/1M点RSS均22,593,536字节（21.5MiB），最终磁盘18,822,554字节。10万行正则100033命中759ms；8502805单字符命中及可见坐标1302ms；四次Reflow1934/1584/1026/856ms，导出330ms。整个进程峰值RSS61,828KiB，总耗时0:18.63，退出0；包含搜索/四次Reflow/导出，不含Flutter/SSH。热行、保留行和段大小有断言，原始聚合数据单独保存。

当前性能复现：见 [ui_flutter/README.md](ui_flutter/README.md) 的profile/窗口关闭命令，核心执行 `cargo run -p hspterm-term-core --example history_benchmark --release --locked`，Linux可用 `/usr/bin/time -v target/release/examples/history_benchmark` 测峰值。运行时勿同时编译/压测其他任务。修改前普通绑定的匹配可执行文件和SO保留在本机忽略目录 `.local/perf/baseline-benchmark-bundle`；旧仪器源码已被当前入口替换，干净克隆可以复现当前工作负载，无法直接重建完全相同的旧仪器程序。不可将新FRB绑定加载旧SO。所有入库数据只含合成聚合指标，不含输出、截图、密钥、真实地址或VM服务日志。

## 未完成与后续平台事项

- Windows11没有构建/运行环境；MSVC、真实IME/AltGr、DPI、字体、剪贴板、窗口关闭等待资源释放尚待实现/实测。Android只完成共享Rust交叉check；JNI/ABI/APK、应用私有cache路径、设备IME/触控/扩展键盘/后台传输均在Phase4验证。本机SDK部分许可证尚未接受，未擅自接受协议或搭建模拟器。详见 [PLATFORM_VALIDATION.md](PLATFORM_VALIDATION.md)。
- OSC7/133及完整语义边界/命令段跳转和复制、重连标记稳定映射、跨屏选择、本地可靠输入跟踪、显示装饰与候选等V1.4范围仍未实现，明确保留原计划，不因本轮A类基础验收而取消。当前选择覆盖可见网格，内容更新时取消旧选择；完整产品Phase2范围尚未全部交付。
- 无数小时真实网络/模型任务soak，偶发一次Protocol错误继续观察；Xvfb负载raster超帧预算。未执行真实Claude Code或Windows/Android运行验证，不作通过声明。
- 完整Windows工作台/SFTP任务/转发代理/同步与Android产品功能保持Phase3/4待办；本轮停止增加功能，后续需用户明确指令。
