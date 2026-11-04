# OSC8批次及此前恢复记录（最新状态见根PROGRESS）

# HSPTerm 开发恢复进度

## 当前状态与执行约定

- 工作目录 `/opt/hspterm`；V1.4 及明确后续修订为唯一产品基线。一个终端标签一个独立 SSH/PTY/SFTP；SplitTree 只组织 TabGroup 显示布局。
- 持续完成 Windows/Android 全功能，不在阶段或模块边界等待验收。按依赖批量静态编码、接口与安全交叉审查，再集中构建/修复/回归。无实机仅阻塞相应平台验证，不停止其他编码。
- 恢复先读 AGENTS、完整 V1.4、本文、REQUIREMENTS_COVERAGE，检查 Git/未提交 diff/近期提交和实际日志。未知修改不清理；一次性脚本不盲重跑。
- Phase 1/2 Ubuntu 基础验收与 Phase 3A 修订原型已完成；当前正式 Windows 业务整合持续中，Agent/RSA/原连接身份保护已接。仍有大量需求未实现，不能称完整可交付应用。

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
2. 原Transport身份回执/原代次/连接准备Vault作用域和跨库指纹保护已实现验证，见CONNECTION_IDENTITY及下节；不要重做。接着执行第3项真实背压复现。
3. PTY未读输出阻塞独立SFTP已真实复现并修复，产品PTY/SFTP显式消费窗口、原库默认接口不变；完整185核心/Native7通过，见SESSION_FLOW。继续第4项临时覆盖/tmux，不重复做已验证的背压修复。
4. 网络其余：可选 tmux 附着/单控制端/尺寸锁、完整按配置继续未完成任务（单次临时覆盖本批已验）。已完成跳板/代理/转发/心跳/导入/Agent不重做。
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

## 本批稳定节点：原连接回执与跨库指纹保护

- ConnectionReceipt通过原actor成功响应同时返回原代次/握手已验证HostKey/用户；原connect/test_connection API保留。拒绝不缓存，接受的原身份rekey复用、改变拒绝；新连接不会改变旧回执。Bridge用实际回执关联SFTP/传输/Agent，不再从当前Vault重读fingerprint，也不从显示设置推断凭据来源；关联前复查原代次/状态/关闭标记/原目标。迟到失效回执报错。
- Verification Scope绑定原Vault.instance_id；跳板/目标准备和确认都核对，同路径重开也是新实例。成功换库在原Vault门控内清旧slots/待确认oneshot，已建立或已经受信任的SSH保留，错主密码不修改原状态。终端resize/历史失败也await关闭新Root再发布失败；不持terminal/Vault/parking锁跨关闭await。
- 旧5179749 Native SO运行新跨库测试12秒失败（旧确认未失效），新库重建后同测试通过；不把静态风险当网络攻破。Rust身份缓存1、真实回执/探测3、Vault作用域3项先通过；新Native8项49秒通过，覆盖跨/同库重开/错密码/连接保留、Agent、跳板、探测、RSA与原Phase2 TUI。20次Native生命周期RSS差557056B仅短样本。
- **完整workspace341项通过**（groups26/48/101/4/1/2/8/9/7/2/2/80/20/2/8/7/6/8，含184项SSH核心）；最新Native8项通过。前一RSA节点全Flutter207项5:02通过，本批未宣称全Flutter208重跑。Clippy all-targets拒绝警告、Analyze、NDK25/API26共享核心check通过。日志`.local/connection-receipt-*`。
- 正式debug/release重建，SO与同模式target匹配：debug `038069ccdf999a446deeb6ec4a0e53dd1328f8014c6e3b325f5a277103042209`；release `b9862a95a9a363bf2d5619e0975a18a30d2a9400dd856a5f706db6f1baa178d4`。两个独立窗口启动/resize/退出0，无历史/工作副本/preview残留。session7849已0结束；旧84369的测试括号lint已修，勿重等。
- 5秒短样本`validation/phase3b/connection-receipt-startup-*.json`：release RSS341090304/聚焦CPU13.00%，失焦334843904/5.40%；debug511348736/44.40%，失焦513077248/5.60%。各批原始数据保留，不从短样本推断泄漏/优化；失焦开销仍待定位。
- 详细恢复边界见CONNECTION_IDENTITY。本批稳定提交号以git log核对。`.local/connection-receipt-static`为过时审查副本，**已在5179749干净状态后接入正式源码并继续修改**，不能再覆盖正式文件；integrate_connection_receipt.py只产旧副本。历史在途文字归档RSA_RECEIPT并由本文替代。

## 本批稳定节点：PTY/SFTP背压修复

- 当前上一稳定提交bf00066（实际身份回执/旧Vault确认保护），此后的背压修复提交号以git log核对。
- 默认session策略真实复现未读PTY堵塞SFTP，4.22秒失败于3秒截止。产品PTY/SFTP显式session消费窗口，原库默认API/跳板策略不变；read/请求确认显式处理ReceiveWindowError。不移除全局pending门控或扩大无界缓冲。新8MiB逐字校验首轮1.47秒通过、五次1.36–1.38秒重复通过。
- 完整SSH核心185项、Native7项67秒通过（真实Codex隔离合成provider/原TUI/传输/Agent/跨库/RSA），Clippy拒绝警告、NDK/API26共享核心check通过。前节点完整workspace341/全Flutter207保留，本批未宣称预计342/208全量。日志.local/session-flow-*，管道63406已0结束，不重复等候。
- 正式debug/release重建、SO同模式匹配：debug`df03ee9608725085cb24adfd6e49694347ac638fcd1624511f6661f0db5f97c7`；release`aeb1b2b5ba90330f1d780c80abc34e2e82e46ff92fbe1066be9bc0b02c991300`。release独立窗口启动/resize/退出0，无历史/工作副本/preview残留；本批未重复debug启动。短样本RSS344326144B/聚焦CPU7.80%，失焦344662016/4.80%，原始JSON保留。不证明长期泄漏/优化，Windows/Android设备未验。
- SESSION_FLOW说明协议边界。prepare_session_flow.py只产旧副本，相关文件已接入并正规格式化，不能用副本覆盖当前lib.rs；原旧策略失败日志保留，不调大截止掩盖问题。

## 本批稳定节点：已保存主机单次临时覆盖

- 正式主机“临时覆盖”已接：本次地址/端口/用户、明确保存认证/本次密码/本次私钥三选一；不写配置/凭据/草稿，不回退认证。Source绑定原Vault实例和主机/跳板元数据，文件读取前及最终准备复核；新目标继续原TOFU。临时Root标记排除未来命令历史采集（历史模块仍未实现）。
- 确认后才新标签；断线按钮/Enter重新打开表单，仅预填非秘密元数据，新的临时秘密须重输；取消保留旧画面/代次、不连接原保存地址。关闭/移动/切库/重复Enter与迟到返回均有原身份检查；四名额文件worker跟随实际阻塞任务，秘密零化，Dart用后释放引用而不声称物理擦除字符串。见TEMPORARY_CONNECTIONS。
- FRB2.13正规生成；Rust桥接完整30项56.82秒通过，删除主机专项最终补验1项7.13秒通过；**全Flutter213项6:06通过**，含真实双端OpenSSH临时密钥/实际端口/原记录不变/错误口令无回退、原真实Codex隔离合成provider及SFTP/编辑/队列回归。组件3项及GTK真实表单/SSH/断线取消14秒通过，三张PNG已检查且仅fixture背景，位于validation/phase3b/temporary-{connection,session,reconnect}.png。
- Clippy all-targets拒绝警告、Analyze、NDK25/API26共享核心check通过；不是完整Rust workspace本批重跑或APK。日志.local/temporary-*；34551最终退出1仅因末尾读取当时尚未生成的release JSON，前面的删除专项和Clippy均成功。
- 正式debug/release已构建，SO同模式匹配：debug`113ce91f81ff1c6c299fd44e86f66f997e226982a600d1de33c87366a8e4f6fe`，release`ee8f3f388788c4fe228ba3bfca81e5810cb75a22a8fffb2b69d025eb20c43f3a`。debug实际窗口启动/resize/退出0；release首轮未创建GTK窗口，原因未确定，独立图形会话重测启动/resize/退出0，无历史/工作副本/preview残留，不能隐去首次失败或声称根因已修。
- 5秒短样本原始JSON保留：release RSS343863296B/聚焦CPU15.60%，失焦350920704/5.40%；debug498278400/46.80%，失焦503312384/6.20%。短样本不证明长期无泄漏或性能优化；未定位失焦开销。Windows/Android实机未验。
- 旧在途/一次性脚本记录归档docs/history/PROGRESS_2026-10-27_TEMPORARY.md，不可重跑integrate_temporary_native.py或integrate_temporary_ui.py覆盖源码。继续未完成网络tmux及协议语义/链接、存储同步和平台业务；不等待验收。下一独立静态批次先补原终端已解析但桥接丢失的OSC8链接，再集中验证。

## 在途静态批次：OSC8链接

- 已在Snapshot保留原Alacritty共享Hyperlink，桥接改为每变化行半开物理列span（不是逐单元复制URI）；每补丁256KiB/2048段、单URI4096B，超限以明确空URI屏蔽该段/该行自动识别。原文/导出/历史格式不改。
- Controller独立保存每行链接元数据，增量更新/全帧重置；View复用原hover/明确Ctrl+Click与菜单/确认打开/回环临时转发。OSC8显式目标优先，隐藏单元/非法方案/控制字符/双向控制拒绝，不从恶意标签回退另一URL。尚未生成桥接、编译或验证；下一步先补核心冷历史/Reflow/覆盖与增量/组件/真实Native测试源码，再集中验证。

OSC8静态批次已补：核心3项（分块/Unicode/冷历史Reflow/覆盖清屏/主备屏与新PTY）、Bridge span增量与字节/数量预算2项、Flutter3项（伪装标签/方案与隐藏拒绝/增量清理/远端鼠标与Shift覆盖）、真实双SSH Native1及GTK1测试源码。尚未运行。安全策略只激活HTTP(S)，file://等不交本机系统打开，远端文件URI定位另列后续需求；不把方案拒绝当完整路径定位完成。接下来正规生成、集中编译及修正。

OSC8集中验证首轮：Analyze修复两处新条件的括号lint后通过；workspace中Bridge32/SSH185/存储80等均通过，运行到新增冷历史测试时复现既有Grid.scroll_display的display_offset+i32::MAX溢出（整条命令exit101，不能标全量成功）。已改饱和offset运算，不缩小测试delta。资源审查另补网格保留前URI4096/id1024上限及第4项测试、64K单元桥接工作量上限；最终需完整term-core/bridge frame专项、新SO、Flutter/GTK/Clippy/NDK/正式包验证。旧首轮日志保留。

OSC8后续：完整Flutter217项5:37通过（含真实Codex隔离provider），GTK点击8秒通过；同命令启动第二个GTK runner失败于debug连接建立，未执行其断言，后续必须逐文件独立私有桌面运行。新增40分号URI在旧VTE专项真实失败（目标仅保留前14段），日志osc8-semicolon-baseline；已静态修正URI尾分号保留、OSC8完整ST/取消专用discard、UTF8及分配前长度检查，追加3项核心测试并让Native目标也含20分号。新补丁尚待最终VTE/term/Native/独立GTK验证；不能将前217项当新解析补丁的全量结果。

最终解析补丁：term-core58项、VTE56项、frame3项、Native/真实Codex与输入8项27秒通过，Native20次生命周期RSS差425984B（短样本）。GTK OSC8 9秒通过；独立转发GTK实际超时于新增元数据读取，已定位夹具没有挂TerminalView、LiveSession按设计visible=false；只在夹具显式设可见取帧，捕获链接后再隐藏，不改变产品隐藏零帧规则。补真实GTK hover断言及统一普通/OSC8 URL的C1/双向控制拒绝后，下一管道集中做最终组件/双GTK/Clippy/NDK/正式双包和独立启动。
