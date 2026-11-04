# HSPTerm 开发恢复进度

## 当前状态与执行约定

- 工作目录 `/opt/hspterm`；V1.4 及明确后续修订为唯一产品基线。一个终端标签一个独立 SSH/PTY/SFTP；SplitTree 只组织 TabGroup 显示布局。
- 持续完成 Windows/Android 全功能，不在阶段或模块边界等待验收。按依赖批量静态编码、接口与安全交叉审查，再集中构建/修复/回归。无实机仅阻塞相应平台验证，不停止其他编码。
- 恢复先读 AGENTS、完整 V1.4、本文、REQUIREMENTS_COVERAGE，检查 Git/未提交 diff/近期提交和实际日志。未知修改不清理；一次性脚本不盲重跑。
- Phase 1/2 Ubuntu 基础验收与 Phase 3A 修订原型已完成；当前正式 Windows 业务整合持续中。仍有大量需求未实现，不能称完整可交付应用。

## 最近稳定节点

- `909b002`：明确重连后可选转发恢复/局部失败、加密规则草稿 CAS、确认后临时回环链接转发。
- `093ab2a`：加密全局 SSH 默认、主机继承/覆盖、独立真实 ACK 心跳响应超时；不自动重连。
- `c21a9fb`：显式 OpenSSH Config 受控预览与原子元数据导入，不执行命令、不读 IdentityFile 秘密。
- `c04531b`：有界只读显示增强、加密全局/主机规则、同词高亮、样式刷新保留真实选择。
- `3d2e024`：ring-only RSA SHA2 私钥签名、限时应用内 Agent 核心、消费驱动通道发送 ACK 额度竞态修复。真实慢消费者修复后五次通过。细节见 SSH_AGENT。
- `66eca8b`：本批正式 Agent 接入已验证：主机开关、桥接票据、真实目标/密钥指纹风险确认、运行状态推送及撤销。

## 本批已实现和验证：正式应用内 Agent

- HostRecord/HostConfig 默认关闭；已保存主机开关只对下一次明确连接申请 socket 生效，不自动授权。默认请求被拒仍保留普通 Shell；撤销不能把未申请端点提升为可授权。
- 原 Entry/nativeID/代次/实际 Target/Vault.instance_id 绑定；120 秒一次性内存预览，最多16个不同应用内密钥，授权1–3600秒。预览不保留解析私钥；确认重读凭据、复核内容标签/公钥指纹，明确风险勾选后安装。
- 改/删密钥来源、重开/切换 Vault、断线/重连使旧授权与票据失效；不关闭无关 SSH。新 Root 不继承。关闭对话框保留现有授权；明确撤销等待原 worker。
- Entry 单名额先于全局 Agent 读锁取得并跟随实际 blocking 私钥工作；关闭等待，取消调用者不提前释放。切库独占门控与 Vault 临界区同步 invalidate epoch。无 Vault/parking 锁跨网络/crypto await。
- 独立 agentChanges 事件按首变更起100ms合并，不触发隐藏帧，不随绘制通知查询密钥。列表读取失败仍可撤销。crypto panic 明确 Failed/收尾错误，不冒充自然到期。
- RSA后续批次已扩展PKCS1/PKCS8/PBES2与遗留AES PEM导入及SHA2主机验签，见下节；签名2048–4096位，验证2048–8192位，不承诺任意格式。不得开启有未修复 RUSTSEC-2023-0071 的 RustCrypto rsa 功能。

## 实际执行结果（2026-10-27）

- 完整 `cargo test --workspace --locked -- --test-threads=1`：330项通过；完整 Flutter：206项、5:02通过。日志 `.local/agent-ui-full-{rust,flutter}.log`。
- all-target Clippy 拒绝警告、Analyze、NDK25/API26 aarch64 共享核心 check 通过，见 `.local/agent-ui-final-{clippy,analyze,ndk}.log`。不是 APK/实机验证。
- 4项组件/2项真实 Native/OpenSSH：原代次、票据取消/复用、库重开、源更改删除、重复密钥/过量选择拒绝、隐藏推送、100次绘制零密钥查询；2项Rust门控测试；真实两台隔离OpenSSH签名/到期/撤销/新Root、RSA flags 独立openssl验签、标准受控peer及慢消费者回归保留。
- 实际 GTK 主机开关保存、目标/指纹/风险确认、远端 ssh-add 真实签名验证、关闭对话框仍授权、撤销后 SSH 正常：最终19秒通过（`.local/agent-ui-gtk-clean-captures.log`）。清理夹具背景采用远端标准2J→3J→home；截图断言无真实登录背景，三张PNG已查看并保存在 `validation/phase3b/agent-{host-option,consent,active}.png`，无图像涂改。
- full Flutter 回归含真实 Codex CLI、隔离临时 HOME/CODEX_HOME 和本机合成 provider；未用真实账号/凭据/付费请求。Claude Code无账号未测，Windows/Android实机未测。
- 正式 debug/release 均成功构建并匹配 target SO：debug `70d60b48360dbd0b80d756e628a1a1bcf56e861aae5c5114f4c7576ca6e5684c`；release `e37477a4ec548316f168af43650de3e9143b5aa9c208e1c49fb6c3b839d59463`。GTK后再次重建正式 debug，当前不是测试 runner。
- 独立启动/resize/退出均0，无终端历史/工作副本/preview残留。5秒短样本 release RSS341331968B/聚焦CPU14.80%，失焦341671936/6.00%；最终 debug RSS514379776/38.40%，失焦519405568/5.40%。原始多轮 JSON `validation/phase3b/agent-*startup*.json` 全保留，不据短采样判长期泄漏或优化；失焦约5–6%仍待定位。
- 本批所有构建/测试管道均已0结束；旧session35357/24810/35467无需再等待。早期失败日志保留，已修复生命周期监听误随每帧查询、测试夹具时序/背景清理及测试模块排序，未跳过检查。

## 下一步直接开发入口（不等待验收）

1. RSA SHA2验签、六种私钥格式导入与真实主机/认证/rekey已完成验证并提交5179749；不重复实现，后续以SSH_RSA边界为准。优先接入下面第2项原Transport身份回执。
2. 静态风险待验证：Bridge成功连接后从当前Vault读取主机指纹而非实际Transport证明，切库/迟到连接可能身份归属错误。应让核心提供不可变实际验证指纹/原代次回执，不凭重开库记录给运行能力贴身份。尚未复现，不宣称漏洞已证实。
3. 静态候选：发送窗口增量grant当前仅显式消费驱动 TCP/Agent；默认 PTY/SFTP 沿原绝对更新。测试慢SFTP消费者与PTY/取消是否同样堵塞，复现后按边界修复，不删除全局有界门控或扩大无界缓存。
4. 网络其余：可选 tmux 附着/单控制端/尺寸锁、已保存主机单次临时覆盖、完整按配置继续未完成任务。已完成跳板/代理/转发/心跳/导入/Agent不重做。
5. 可靠 OSC133 C/D 历史锚点及裁剪/Reflow、命令导航/输出复制；可靠普通Shell输入跟踪→十项路径联动/合格单行历史加密与联想。OSC7/133不能单独证明安全编辑；禁止盲Ctrl+U/Backspace/TUI注入。已有选区定位/CWD跟随不重做。
6. 继续175项覆盖清单：字体/OSC8/通知/命令面板、主机批改排序、文件内并行/直传/跨服务器剪切/暂存清理/编辑保护、配置加密备份/同步/DPAPI/Keystore、Windows原生与Android专用UI/SAF/IME/触控/扩展键盘/前台服务。平台缺失不能替代业务编码。

## 安全与可复现构建

- 同步/备份仅正式catalog的主机/独立凭据/允许设置/书签/合格历史；排除草稿（包括转发/显示副本）、布局、设备任务、滚动历史、预览/编辑正文、临时凭据/运行端口以及 Agent 授权/票据。未来凭据恢复也须在原Vault临界区使关联Agent失效。
- PATH `/opt/flutter/bin:/root/.cargo/bin:$PATH`；导出 `CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=2`。同一时间一个重构建管道。FRB2.13正规生成后cargo fmt，不手改绑定。
- 正式入口 `ui_flutter/lib/workbench_main.dart`，真实Phase2 `lib/main.dart`，独立Mock `lib/prototype_main.dart`。GTK后重建正式入口，不交付测试runner；正式运行 `cd ui_flutter && flutter run -d linux --release -t lib/workbench_main.dart`。
- `.local/integrate_agent_transport.py`、`integrate_agent_api.py`、`integrate_agent_ui.py` 已各执行一次，不可重跑。其他一次性显示脚本亦已执行。旧细节归档 `docs/history/PROGRESS_2026-10-27_AGENT.md`，其在途/未注册旧描述由本文替代。


## 本批稳定节点：RSA 主机验签与 PEM 导入

- ring RSA SHA2验证接KEX/hostkeys-proof/受控服务端userauth；短签名仅按模数左补零，KEX签名标识须匹配协商。HSPTerm不提出SHA1。每次rekey调用信任检查；Client缓存原已接受HostKey，相同不重问、改变拒绝，目标与跳板独立。SshConnection提供实际握手已验证HostKey，Bridge回执整合是下一模块。
- PKCS1/PKCS8、PBES2 PBKDF2/scrypt、传统AES128/256-CBC PEM只读导入已接。DER16KiB/PEM256KiB、PBKDF2≤100万/scrypt≤64MiB及工作预算派生前检查。ring本地签名检查原CRT，不将损坏dP/dQ悄悄重算；借用DER整数避免丢弃的秘密Mpint副本，解码/明文/派生密钥清零。无新增依赖/Cargo.lock变化。详细边界见SSH_RSA。
- 核心完整182项通过（`.local/rsa-full-core-2.log`）；之后借用整数小修最终12项RSA专项17秒通过（`rsa-final-focused.log`）。Clippy all-targets拒绝警告、Analyze、NDK/API26共享核心check通过。完整Flutter207项5:02通过（`rsa-full-flutter.log`），含新真实Native加密PKCS8/RSA-only host/持续输出重协商/手动重连及原Codex合成provider。不是新全量workspace338项运行，旧330仍是前一节点。
- 新专项含六种格式实际OpenSSH认证、错误口令/弱密钥/4096组件/无效CRT/合法DER恶意KDF即时拒绝、真实RSA-only SHA256/512主机首次确认/错误指纹/hostkeys证明/rekey、SHA1-only拒绝、省略前导零验签、受控服务器RSA用户签名。早期失败保留：原库rekey不回调信任策略已修；受控fixture误把注释当公钥身份已修，未放宽验签。Agent截图夹具补括号lint后最新Analyze无问题。
- 正式debug/release重建、SO同模式匹配：debug `0ca87aa7c0988102f18f49a3c99dcb365eab6ff6412fb6415595fc230cecdbe4`，release `28963b30d12ea0146d2c83dd46501d073dc2045c6a4fee92d123c8ae46f8d4fa`。独立窗口启动/resize/退出0，无历史/编辑工作副本/preview残留。session11816已0结束，不重复等待。
- 5秒原始短样本 `validation/phase3b/rsa-startup-*.json`：release RSS341696512B/聚焦CPU7.40%，失焦345391104/5.00%；debug517758976/38.60%，失焦519430144/5.20%。保留前批数据，不从短采样宣称长期无泄漏或性能优化。

## 下一模块静态审查副本（尚未接入/编译）

`.local/connection-receipt-static` 为隔离审查副本，生成器 `.local/integrate_connection_receipt.py` 仅产副本，可再生成；正式源码尚未修改。内容为core原代次/实际HostKey/用户回执、Bridge不再重读当前Vault指纹，以及原Vault指纹确认作用域与成功换库失效未确认请求，不关闭已受信任SSH。新Native跨库/同库重开/错主密码测试也只在副本目录。RSA稳定提交后核对差异/基线再接入，不把副本称已实现；继续后续模块而非等待阶段验收。

连接回执批次正式接入中：已在5179749干净状态后将隔离副本的5个Rust文件及1个Native测试复制到正式源码；不要再次从旧副本覆盖。生成器仍只产副本，不能用它替代最新正式源码。下一步补原代次/缓存身份/跨Vault与同路径重开的Rust测试，静态审查后集中编译，不算已验证。

连接回执集中验证：原native SO（5179749的debug哈希0ca87…）运行新跨库测试，12秒失败于换库后旧确认未结束，复现日志connection-receipt-before-native。新源码Rust身份缓存1项、真实回执/探测3项、Vault作用域3项通过；新Native重建后8项真实桥接49秒通过（跨/重开库、错密码不破坏原确认、已建立SSH保持、Agent/跳板/探测/RSA/Vim等）。Analyze无问题。完整workspace/Clippy/NDK/正式双模式及启动正在session7849顺序执行，日志.local/connection-receipt-*，不要同时再开重管道。旧session84369停于新测试括号lint，已用dart fix修正；未跳过检查。

下一独立模块静态准备 `.local/session-flow-static`，生成器prepare_session_flow.py仅产审查副本，不改源码：原session显式消费窗口API，产品PTY/SFTP选择，ReceiveWindowError明确失败；真实OpenSSH 8MiB未读PTY与SFTP独立协商测试尚未注册/运行。当前仍只能称默认PTY/SFTP阻塞候选，需在回执稳定节点后先用旧逻辑复现再接修，不得把静态副本算完成或覆盖本批lib.rs新身份单测。
