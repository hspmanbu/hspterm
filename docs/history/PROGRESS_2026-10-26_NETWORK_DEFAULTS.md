# HSPTerm 当前开发进度

唯一产品基线：[V1.4](HSPTerm_最终需求规格_v1.4.md)及用户后续终端标签修订/全功能连续开发指令。175项逐条状态见[覆盖清单](REQUIREMENTS_COVERAGE.md)，不表示175项已完成。原200KB历史见[早期记录](docs/history/PROGRESS_2026-10-25.md)，网络节点原文见[网络开发记录](docs/history/PROGRESS_2026-10-25_NETWORK.md)，跳板过程见[跳板开发记录](docs/history/PROGRESS_2026-10-26_JUMP.md)；历史“在途”不优先于本文。

## 执行策略更新（2026-10-26 用户指令）

改为成批静态编码→跨层契约/生命周期/安全审查→集中构建/调试/统一修正；减少逐项反复编译。保留既有测试能力，不把静态审核当运行通过。当前正在运行的Rust完整回归允许结束，后续Flutter/NDK步骤已暂停调度；旧Rust回归已正常结束（进程退出码0，285项通过，仅适用于新草稿/临时链接编码前的恢复节点）；后续shell已安全终止，未启动旧Flutter/NDK命令。下一批同时补齐转发草稿/临时链接与相关终端链接交互，统一生成FRB/编译/回归。

## 当前阶段

持续Phase3B真实业务与全部剩余V1.4开发；Phase1/Phase2 Ubuntu A类基础验收、Phase3A交互原型已在。阶段/模块完成后不等待用户验收，不把MVP或Mock当最终交付。Windows/Android完整软件仍未完成，并非只剩实机验证；只排除当前不具备的Windows/Android实机验收，不因此停止平台编码/适用构建。

一标签一独立SSH Transport/PTY/SFTP，TabGroup/SplitTree只改布局，不复制/重连；单主窗口空白启动，无托盘/本地Shell/广播/自动重连。Android单终端、终端/SFTP全屏切换，不能复制桌面分屏。仅隔离回环服务器/合成数据；Codex真实二进制用隔离合成provider，不读登录凭据、不做付费/生产操作。

## 最近稳定节点

- 217787c：未知移动离线本机审阅/明确结束；不推断成功、不放宽任何网络身份。
- 967fd70/a9f701b/eec7baf/60bc94f：被动OSC7严格解析/同主机路径；正式终端选区→原会话SFTP定位；隐藏零帧的元数据合并；可选OSC7跟随及加密主机偏好/单次高级保存。
- 50237a2/4b7bbe3：被动OSC133最新阶段/可选退出值；冻结历史半开范围的流式纯文本读取。尚无可靠命令锚点/按命令复制/导航，不能凭phase、旧行号或文本相似性猜范围。
- 3aa85b8/991bda2：HTTP CONNECT/SOCKS5单代理核心、共享Budget/取消、原目标TOFU、无直连/认证降级；独立加密代理凭据/草稿/复制删除与正式网络表单。
- 3437a28：主机级总超时/心跳间隔与关闭/失败阈值，草稿/副本/重开保持；窄窗字段竖排及底部操作栏换行。
- 2bb0812：ManagedSession无认证/无PTY握手探测，调用方abort只取消本次，保留旧画面/历史。
- 3562b5d：FRB/短生命周期隐藏Controller/真实主机页“测试连接”，只读正式配置、原目标复核、TOFU、可取消/退出等待，不建立可见标签或最近记录；未保存编辑需先保存。结果明确不证明目标登录成功。过期Dialog的Future不能取消后来测试；长目标弹窗可滚动。详见SSH_NETWORK.md。

- 93a770c/7a2d561：一级跳板Rust核心及加密保存主机引用，正反图验证禁止两级/双代理，删除保留失效引用，不直连回退。
- ef0bb9c正式跳板业务提交：统一路由工厂/继承唯一代理、独立目标TOFU命名空间、至多2槽的原尝试确认与取消、正式跳板选择器；真实双端指纹/跳板认证/目标PTY/SFTP/手动重连与删除行为已验。确认回调异常明确拒绝，Entry销毁永久阻止新准备，不能在取消后重新激活。

## 已实现的实际基础

- Rust终端协议/输入/Unicode/宽字符/颜色/光标、Kitty/CSI u、鼠标/Shift覆盖、OSC52、安全粘贴/IME、同步输出、RAM+临时磁盘历史/Reflow/当前终端搜索/流式导出；FRB2增量绘制与隐藏不拉帧，断线保留画面/明确重连。Phase2证据见PHASE2_VALIDATION.md。
- 加密主机/独立凭据/本机草稿/基础分组收藏、密钥生成导入导出与TOFU；正式多会话标签/自由分屏/焦点关联SFTP保持，原最小SSH/独立Mock入口保留。代理/时限/握手测试已接真实业务；其余高级网络/UI仍部分Mock。
- 真实SFTP分页/双限额缓存/缓存补全/基本CRUD/书签/递归文件名搜索；选区定位与可选OSC7跟随；受控系统预览/确认阈值、严格编码内置文本编辑/加密草稿恢复、外部文本与大原始字节分块编辑/监听回传/租约/保留及明确清理。
- 本地↔远端文件/目录队列：共享可配置FIFO/方向限速、暂停续传、冲突策略/失败重扫、分块加密恢复；远端↔远端明确内存中转复制/私有暂存发布屏障与失败目录重扫、复制到/移动到、部分入队重试。
- 同账户无覆盖移动Intent/ACK与编辑互斥；丢ACK不盲重发，不从缺失/大小推断成功。在线只读核对与离线本机结束分离，UserEnded不等于Confirmed，保留加密审计；删除主机/关SSH后仍能本机结束。各领域边界详见AGENTS.md及领域记录，不将部分实现计作整条完成。

## 最近稳定转发节点

- 55445be/7387c60/23b27a3：原Transport TCP能力/L监听/D SOCKS5 CONNECT，取消安全stop与真实慢消费堵PTY修复（vendor消费窗口）。
- 1087ae7：未经授权的七类服务器入站明确拒绝；8af4c18：原目标独立R路由、迟到启动/取消ACK、未知/拒绝重试、32规则/64流与入站消费窗口。
- 83bb2af：完整回归复现失败结果与阶段分开发布的竞态；全部启动失败改原子watch更新，13项R专项与错误分配连续20轮通过。
- cda1af7：每主机加密规则/字段及冲突验证/读取前128KiB、32条；复制新规则ID与草稿/凭据/catalog同事务，正式保存前排除正式读取，丢弃/删除与失败回滚。
- 2d43f69/fb9d1e1：配置FRB正规生成/Native/双模式正式包与启动收尾；51db278：每Entry独立运行期FRB，原终端/代次/规则快照，start/list/stop与断开销毁，跨标签token隔离。
- 本次UI节点（确切提交见git log）：正式主机进阶页及当前终端菜单的实际规则/运行管理；Mock明确不联网，脏主机须先正式保存。规则编辑/删除与实例停止独立，配置不可读取/主机删除后仍能停止原实例；选中源绑定不可变ID/代次，失效禁用，布局/标签移动不换连接。6项Widget与真实GTK通过，三图见下。

## 最新真实验证（2026-10-26）

- 完整Rust **283项通过**（.local/ssh-forwarding-runtime-workspace-fixed.log）；ssh-core154项，openssh目录82项中73项实际OpenSSH与9项受控真实russh peer。19项Bridge单测含新增2项关闭RAII；storage65项含5项规则/事务/复制草稿/密文/容量测试。workspace/all-targets Clippy拒绝警告、格式通过（runtime-status-clippy.log）。
- 完整Flutter **176项4:06通过**（ssh-forwarding-ui-flutter-complete.log），Analyze无问题；6项新组件测试覆盖失败读取不可覆盖、源选择/配置删除后停止、主机不可读取后停止、生命周期失效/100次普通通知0额外RPC与空闲无poll、字段验证、480×360/1.6倍文字无溢出。
- 匹配Native最终4项27秒（runtime-status-native-tests.log）：配置、L/R/D真实65KiB+17/PTY并行/跨标签与关闭/重连旧token/删除主机仍可停止/退出清R、原Phase2真实SSH+TUI+20次生命周期，以及真实Codex二进制+隔离合成provider。不是Claude/真实账号/付费任务；20次生命周期该窗口RSS差188416字节，不据此推断泄漏。
- 真实GTK当前UI **1项21秒通过**（ssh-forwarding-gtk-complete.log）：从当前标签菜单进入、实际表单保存L/R/D、实际TCP回显、停止、切主机进阶页再打开，原NativeID/代次/会话数不变。三张已查看PNG：validation/phase3b/hspterm-forwarding-{config,running,host-settings}.png。首次GTK发现长列表关闭按钮被滚走，已固定关闭/刷新并重验；测试错误/原竞态日志保留，不放宽标准行为。
- NDK/API26 aarch64 workspace check通过（ssh-forwarding-ui-android.log），不是APK/设备验收。Windows/Android真实软件仍未完成，不只是待实机测试。
- 正式workbench_main debug/release构建通过（ssh-forwarding-ui-build-*.log），SO与target同模式SHA256一致；独立GTK启动/resize/正常退出app/wrapper均0，无Vault/终端历史/编辑工作副本，预览run残留0（ui-smoke-*.log）。本轮portal随隔离X/D-Bus关闭的错误不是app退出失败。
- 启动锁库密码框聚焦5秒：debug RSS448802816字节/CPU4.80%；release RSS276574208字节/CPU4.40%。见validation/phase3b/ssh-forwarding-ui-startup-*.json。旧flow/API/jump/proxy/timing样本保留，不据此称优化、长期泄漏或Windows/Android通过。

## 最新状态推送节点（2026-10-26）

- 转发状态改任务驱动推送：Weak观察器不拥有SSH/registry生命周期，100ms固定窗口合并；隐藏终端只通知独立forwardingChanges，不拉帧/全局重绘。面板合并在途读取、已移除过渡轮询，保留手动刷新。
- 完整Rust **285项通过**（ssh-forwarding-events-workspace.log），Clippy拒绝警告、格式及NDK/API26 aarch64 check通过；完整Flutter **178项4:15通过**（events-flutter-all.log），Analyze无问题。4项Rust观察器/关闭单测、19项Flutter专项通过，真实GTK **1项21秒通过**：面板外停止R后自动显示已停止，原NativeID/代次保持。
- 正式workbench_main debug/release重建通过，SO与target同模式SHA256一致（events-bundle-hashes.log）。独立GTK启动/resize/退出均0，无Vault/历史/编辑副本，预览run残留0；Mock独立启动同样0、Rust未加载、历史未创建（ssh-forwarding-mock-startup.json）。
- 新锁库密码框聚焦5秒样本：debug RSS510226432字节/CPU35.40%，release RSS345792512/CPU7.20%；无其他本项目构建的复测debug506761216/33.40%、release341942272/8.60%，JSON保存为ssh-forwarding-events-startup-{debug,release}{,-isolated}.json。较上一节点上升，当前未定位原因，不宣称性能优化或长期无泄漏；此启动页无SSH/转发实例，需后续区分密码框光标/Flutter图形成本与业务增长。保留原样本。

## 转发恢复早期过程（已由下方整批结果取代）

已在3b1beee之上接入原成功目标身份核对、连接尝试内捕获加密规则、仅enabled+restore_on_reconnect的单次恢复；首次连接不启动。局部bind失败记录独立失败元数据，不伪造监听或SSH断线；R继续原异步状态/迟到ACK生命周期。UI恢复开关与非回环持久授权确认已编码。Rust check/Clippy/匹配Native和21桥接单测通过；10项新增/既有组件与真实Native通过15秒，实际GTK重新连接按钮→L/R/D恢复与新代次回显通过28秒，两个PNG已归档查看。debug构建完成后外层命令、并行完整Rust/Flutter均遭SIGTERM（143），无正常结束，不能算完整通过；release已单独重建且SO匹配。现串行运行两包独立启动→完整Rust→完整Flutter→NDK/格式/Analyze，日志为.local/ssh-forwarding-restore-*-sequential.log，先查在途进程/结果。尚未完成最终回归/提交，不能标已交付。

## 最新已验证整批：恢复、草稿与终端链接

已编写storage-sync::forwarding_drafts（未完成字段/64KiB/修订墓碑/CAS/原规则冲突保护/正式提交同事务/删除主机回收）、FRB DTO与三个草稿接口、规则编辑器加密去抖/恢复/离开及退出等待。临时回环L API不联网探测、不保存、不重连；终端可见网格链接解析（宽/组合字符、软换行、有界扫描）、被动悬停、Ctrl+Click/菜单、原会话确认/浏览器交付及失败清理已编码，保持远端鼠标优先/Shift覆盖。

静态交叉核对已修正配置快照CAS读取顺序、草稿ABA复活、失败草稿退出保护、URI异常/端口/凭据/非回环拒绝及旧代次操作。新Rust仓库/临时目标测试、Flutter草稿恢复/失败、链接协议/鼠标/Unicode、真实Native与GTK确认/失败/断线保护测试代码已补；首轮已发现并修正底层忙碌动画在模态编辑期间持续重绘、测试夹具认证类型和FakeAsync视图销毁后的等待；修正后Flutter23项10秒通过，旧失败日志保留。官方FRB2.13.0已统一生成（未手改）；整批Rust all-targets Clippy拒绝警告、Flutter Analyze第一轮无问题，匹配Native构建通过。Rust仓库3项17.61秒/Bridge22项34.57秒，修正后Flutter23项10秒，真实GTK管理及重连恢复1项29秒、链接确认/取消/浏览器失败清理/迟到确认不执行1项14秒均通过。唯一最终串行管道已完成完整Rust289/Flutter186（4:21）及NDK/API26 aarch64检查；生成器Rust导入排序与workspace格式冲突已由cargo fmt正规修正（仅排序），格式/Clippy重新核对；正式debug/release、匹配SO和独立启动均通过（.local/ssh-forwarding-batch-*），详情见下方最终检查。Analyze最终源无问题。

### 整批最终检查

完整Rust **289项通过**（ssh-forwarding-batch-workspace.log），完整Flutter **186项4:21通过**（batch-flutter-all.log）；Clippy/all-targets拒绝警告、最终Analyze无问题、NDK/API26 aarch64检查与格式通过。生成器导入排序由cargo fmt正规修正，仅格式，不手改FRB接口。两项真实GTK29秒/14秒、配置草稿/原会话Native与原Phase2/Codex回归均已包含或独立通过；不是Claude或真实云端账号测试。

正式workbench_main debug/release已重建，包SO与target同模式SHA256一致（batch-bundle-hashes.log），独立GTK启动/resize/正常退出均0、无Vault/历史/编辑副本、预览run残留0（batch-smoke-*.log）。保存SSH转发配置不等于真实系统浏览器测试，GTK浏览器为隔离记录适配器。

新增startup样本：debug RSS511549440字节/聚焦CPU38.60%，失焦513216512/6.00%；release341950464/10.80%，失焦345645056/4.60%，各采样5秒（ssh-forwarding-batch-startup-*.json）。聚焦动画贡献部分成本，失焦剩余开销未定位；不据短采样声称长期无泄漏/性能优化。旧样本全部保留。下一批网络文件仍未注册/未验证，与本次结果分开。

## 当前未完成与直接下一步

1. **转发整批收尾**：明确重连恢复、加密规则草稿、终端链接确认临时转发均已编码，正规FRB已生成；仓库3/Bridge22/修正后组件及Native23项通过，GTK/最终全量289 Rust/186 Flutter及双模式正式包均通过。Android正式界面、OSC8及完整链接/配置工作流仍待做，不计所有客户端功能完成。下一批网络全局默认等继续按下条推进。
2. 网络其余：全局默认/主机覆盖、独立心跳响应超时、应用内部显式限时Agent授权、可选tmux附着/控制与尺寸策略。已有单代理/一级跳板/独立目标TOFU/握手测试不重做，不用外部Agent、不自动SSH重连。
3. 可靠OSC133 C/D历史锚点及裁剪/Reflow映射、命令导航/输出复制；安全POSIX Shell本地输入追踪→十项路径联动/合格单行命令加密历史/联想。OSC7/133自报不能证明安全输入，不盲清行/向TUI注入；已有被动phase/CWD/选区定位/冻结范围读取不重做。
4. 按175条覆盖清单继续全部剩余：显示装饰/字体/链接通知/命令面板、完整主机排序/批改、文件内并行/安全直传/跨服务器剪切/暂存审计清理/CRUD编辑保护、配置同步/备份/OpenSSH导入/DPAPI/Keystore、Windows原生适配及完整Android/SAF/触控IME/扩展键盘/前台服务。未列细项仍以V1.4为准，不作为取消需求。

## 重要生命周期边界

- 一标签独立SSH/PTY/SFTP，分屏与标签移动只改布局；配置保存/删除不改变运行实例。R未知取消不是Stopped，迟到ACK仍在原Transport清理，旧token不指向新代次；原Root结束后才退休旧资源。
- 复制规则与副本草稿/凭据原子，复制草稿的独立规则记录也属于本机草稿；未来同步/备份必须按正式catalog.hosts归属筛，不只扫key前缀。运行状态/分配端口/历史/任务/编辑工作副本不能入配置云同步。
- 转发TCP慢消费者不阻塞共享PTY的显式vendor窗口补丁只用于对应TCP API；默认PTY/SFTP/跳板策略保持。来源/许可证/公开上游测试向量说明见vendor/russh/HSPTERM_PATCH.md，不提交真实凭据或测试生成的秘密。
- 其他任务/编辑/未知移动/TOFU锁顺序与断线恢复见AGENTS.md及领域文档；不能借新增UI清理未知记录、重传未知移动、换Root或绕过安全粘贴/输入协议。

## 恢复与构建

- 先读AGENTS/V1.4/本文/覆盖清单，检查git status/log/diff及在途日志；保留未提交修改/未知数据。当前完整转发过程归档docs/history/PROGRESS_2026-10-26_FORWARDING{,_BUSINESS}.md，档内“在途”被本文结果取代。
- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；Cargo/FRB/Flutter原生构建export CARGO_INCREMENTAL=0。FRB2.13.0只正规生成，不能手改绑定；新接口先匹配Native再Flutter。
- cargo test --workspace --locked -- --test-threads=1；cargo clippy --workspace --all-targets --locked -- -D warnings；cargo fmt --all -- --check。ui_flutter下flutter analyze/test；GTK用benchmark/external_editor_gtk.py隔离Xvfb/D-Bus。
- lib/main.dart保留Phase2真实SSH，prototype_main.dart独立Mock，workbench_main.dart正式。集成测试覆盖debug包，完成后顺序重建正式debug/release、核对SO及独立启动；不得交付测试入口。
- 仅无活跃构建/测试时可cargo clean本项目四crate可再生缓存，先核对包SO独立inode，不删源码/记录/未知数据。已安全清355个dev缓存文件2.3GiB再重建；当前空间约5.8GiB。Windows/Android实机与Claude真实账号待条件具备，其他可编码工作持续，不等待阶段验收。

## 下一批静态准备（不属于当前验证快照）

`crates/storage-sync/src/network_defaults.rs`及未注册的`crates/frb-bridge/src/network_settings.rs`已编写全局SSH总时限/心跳间隔及阈值的加密版本记录与测试，暂未注册mod或接主机继承/FRB/UI，因此尚不计可用功能，也不纳入当前289项预计快照。当前回归结束并保存稳定提交后，继续按旧主机保留明确参数、用户显式选择继承的兼容策略接入；独立心跳响应超时仍需后续核心实现，不能把间隔/阈值当响应超时。

下一批心跳实现注意：vendor/russh::Handle::send_ping当前忽略oneshot接收错误，不能把其Ok当作真实ACK；旧内置keepalive用任意接收数据重置失败数，不能当独立响应超时。应在原Transport上明确使用ACK可验证、有界在途的探测，保持全局请求FIFO，区分心跳失败与用户取消，保留跳板/目标生命周期和默认兼容行为；勿直接用inactivity_timeout冒充响应超时。

## 当前下一批：全局网络参数与独立心跳（静态编码阶段）

稳定提交909b002已完成上一批289 Rust/186 Flutter/NDK/双模式包及GTK，不等待验收。当前网络文件已注册：全局加密默认/版本与条件写入、HostRecord兼容继承标志与可选响应超时、原连接路由捕获、FRB DTO/API、实际设置面板/主机选项和模型传播已编码；尚未正规生成新绑定/编译。旧主机默认保持明确参数/旧策略，新主机UI默认继承。

ssh-core新增ACK心跳任务及虚拟时钟策略测试：独立间隔/响应等待/连续阈值，原Root关闭与资源释放，None保留旧行为，区分超时与用户取消；vendor只增显式send_ping_checked，保留默认旧API，迟到ACK仍由全局FIFO消费。尚待静态交叉核对所有配置构造/关闭错误分支、补齐真实ACK/停流、字段与继承/草稿副本、设置面板测试，然后统一生成/构建/测试。当前新源码未验证，不能用上一批测试或包宣称此批通过。

网络批次静态补充：已补Core虚拟时钟阈值/取消、全局记录版本及加密、Route默认快照/旧主机不读损坏默认、实际设置表单保护、Native OpenSSH真实ACK/停流/默认修改不影响当前Root/手动重连读取0关闭及主机草稿副本测试代码。尚未运行。已将监视器退出原因区分timeout/transport/panic，并保持弱Handle/原Root停止，避免任务异常后无心跳静默存活。下一操作是一次统一的正规FRB生成、格式/Clippy/Analyze与集中测试；不能回用909b002的包/测试充作此批已通过。

网络批次集中检查已启动：.local/ssh-network-batch-{codegen,analyze,clippy,native}.*。旧主机/DTO缺字段默认false/None，新建主机UI继承true；主机覆盖值仍可编辑并明确仅关闭继承时生效。全局间隔0同时禁用新监视与旧内置心跳；修改全局设置不会热改已有Transport。官方绑定/匹配Native完成前不得调用新API测试，仍未宣称此批通过。

网络批次专项结果：官方FRB2.13.0/匹配Native/Clippy全targets/Analyze已通过；Core心跳2虚拟时钟、加密默认2、Route快照2均通过。真实Native默认继承/ACK/2000行PTY/停流断线/设置改动不热改Root/关闭心跳重连/草稿副本通过；既有Native TUI/20生命周期/真实Codex合成provider和L/R/D恢复通过，14项通过1项旧测试未滚动失败已修复，最终8表单组件6秒通过。实际GTK全局设置/主机继承与独立响应保存14秒通过，截图已归档（尚待查看）。

现在唯一最终串行管道运行中：.local/ssh-network-batch-{workspace,flutter-all,android,format-check,build-debug,build-release,bundle-hashes,smoke-*}。未完成不能标通过。先查进程和日志，不重复启动重构/构建。SFTP opener集中生成时发现误借self破坏static能力，已恢复原独立Handle契约，不弱化生命周期约束。

下一批静态准备：`crates/ssh-core/src/agent_protocol.rs`已写有界Agent二进制协议/流式帧和取消处理，仅允许列表/签名，拒绝增删锁定等请求，不访问外部Agent/文件系统；尚未注册mod、未编译，Signer仍是明确的能力接口，没有假签名实现。必须继续实现实际密钥签名器/限时同意/原Client路由与入站消费窗口/PTY启动前请求/桥接UI及真实测试后才计Agent功能完成。不能直接复用上游AgentServer：其私有KeyStore初始化/密钥管理权限及RSA签名flags处理不满足此范围，也不能在已运行Shell盲目注入SSH_AUTH_SOCK。

Agent协议已核对2026-05发布的RFC9987及OpenSSH PROTOCOL.agent（https://datatracker.ietf.org/doc/html/rfc9987，https://raw.githubusercontent.com/openssh/openssh-portable/master/PROTOCOL.agent）：RSA flags是位集合，允许2/4合并；新标准还定义agent-forward/agent-req/agent名称协商，不能只实现旧OpenSSH别名便称全兼容。未注册codec已按位集合修正并区分干净EOF/截断帧，仍未编译。当前已用ssh-key0.7.0-rc.11、signature3.0.0均以现有Cargo.lock/源码为准，不应按旧版本API猜测或随意升级依赖。
