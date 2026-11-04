# HSPTerm 当前开发进度

唯一产品基线：[V1.4](HSPTerm_最终需求规格_v1.4.md)及用户后续终端标签修订/全功能连续开发指令。175项逐条状态见[覆盖清单](REQUIREMENTS_COVERAGE.md)，不表示175项已完成。原200KB历史见[早期记录](docs/history/PROGRESS_2026-10-25.md)，网络节点原文见[网络开发记录](docs/history/PROGRESS_2026-10-25_NETWORK.md)，跳板过程见[跳板开发记录](docs/history/PROGRESS_2026-10-26_JUMP.md)；历史“在途”不优先于本文。

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

## 最新真实验证（2026-10-26，源码23b27a3）

- Rust完整workspace **262项通过**；ssh-core140项，openssh目录68项（67项实际OpenSSH、1项受控真实russh peer）。4项生产接收队列源码/真实消息边界测试已包含。workspace/all-targets Clippy拒绝警告、格式通过。
- 匹配Native库编译通过；完整Flutter **168项通过（3:54）**，Analyze无问题。包含真实Native终端、隔离合成provider的Codex二进制、代理/超时/探测/跳板与传输回归，不访问真实登录或付费任务。
- NDK/API26 aarch64 workspace check通过，不是APK或设备验收。Ubuntu正式workbench_main debug/release构建通过，各包SO与target对应模式SHA256相同。
- 独立GTK/X11启动/resize/正常关闭均app与wrapper退出0，Native加载，无终端历史/编辑工作副本，预览run残留0。锁库密码框聚焦5秒样本：debug RSS450609152字节、CPU6.40%；release RSS282832896字节、CPU6.00%。见validation/phase3b/ssh-flow-startup-*.json；旧样本保留，不据此称优化、长期泄漏或平台验收。
- 证据日志.local/ssh-flow-{workspace,clippy,native-build,flutter-all,flutter-analyze,android,build-debug,build-release,bundle-hashes,smoke-debug,smoke-release}.log。GTK退出后portal的bus/X连接结束信息来自隔离wrapper关闭，app正常退出。

## 已提交转发核心（正式可视化仍未接）

- 55445be：原Transport TcpConnector、共享64在途/活动通道名额、代次绑定、超时/取消/abort后迟到确认有界收尾。ManagedSession仅返回能力，不阻塞PTY actor。
- 7387c60：本地-L真实监听、流式半关闭、watch统计及显式stop/根SSH取消，无新SSH/直连回退。
- 23b27a3：动态-D无认证SOCKS5 CONNECT（IPv4/IPv6/域名），严格有界解析、不丢合并包负载；cancel-safe stop保留原JoinHandle，调用方abort后再次stop仍等待清理。
- 同提交修复真实慢TCP消费者堵塞共享PTY：固定vendor/russh0.64.1显式消费驱动窗口，TCP专用有界FIFO/合并credit；默认PTY/SFTP/跳板策略保持。原红测3.53秒失败→修复1.53秒整个测试通过（不是精确输入延迟）；8MiB+17逐字节完整、多窗口补充测试通过。17项转发专项18.91秒通过。
- 来源、原crate校验、许可证、默认/opt-in边界及公开上游测试向量说明见vendor/russh/HSPTERM_PATCH.md，详细API/生命周期见PORT_FORWARDING.md。没有真实凭据提交。

## 当前任务与直接开发入口

1. **远端-R核心**：先拒绝未经授权的服务器入站通道，再原目标Client独立有界路由、入站消费流控、tcpip_forward迟到ACK清理、停止确认/未知状态。跳板不能共享路由；不得drop全局请求Future后误判监听已关闭。
2. L/R/D核心后接加密规则/FRB运行期生命周期、正式可视化管理及明确手动重连恢复；当前没有FRB转发命令或GUI业务，不能将Mock当完成。全局网络默认/主机覆盖及独立心跳响应超时仍待做。
3. 可靠OSC133 C/D历史锚点、裁剪/Reflow映射、命令导航/复制。已有被动phase与冻结范围读取不重做，不能凭文本/旧行号猜范围。
4. 安全Shell输入追踪→十项路径联动/合格单行命令加密历史与联想；OSC7/133自报不证明POSIX Shell/回显/光标安全，不向TUI盲清行/注入。
5. 其余175项覆盖清单：显示装饰/字体/链接通知/命令面板、完整主机排序/批改、文件并行/安全直传/跨服务器剪切/暂存审计清理/CRUD编辑保护、配置同步/备份/OpenSSH导入/DPAPI/Keystore、Windows原生适配及完整Android/SAF/前台服务。未列细项仍以V1.4为准，并非只剩平台实机测试。

## 恢复和构建

- 先读AGENTS/V1.4/本文/覆盖清单，检查git status/log/diff与中断日志；不覆盖未提交修改/未知数据。模块通过即提交并继续，不等待阶段验收。历史转发过程见docs/history/PROGRESS_2026-10-26_FORWARDING.md（其“在途”被本文最终结果取代）。
- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；Cargo/FRB/Flutter原生构建export CARGO_INCREMENTAL=0。生成文件仅正规FRB2.13.0生成，不能手改。
- cargo test --workspace --locked -- --test-threads=1；cargo clippy --workspace --all-targets --locked -- -D warnings；cargo fmt --all -- --check。Flutter analyze/test；GTK使用benchmark/external_editor_gtk.py隔离环境。
- lib/main.dart保留Phase2真实SSH，prototype_main.dart独立Mock，workbench_main.dart正式入口。桌面测试共用包目录，交付前顺序重建正式debug/release、核对SO及独立启动。
- 磁盘约1.5GiB。仅无活跃构建/测试时可cargo clean本项目四crate可再生缓存；先核对包SO独立inode，不删未知文件/源码/日志。Windows/Android实际软件编码仍未完成，实机/Claude真实账号测试待条件具备，见PLATFORM_VALIDATION.md。

## 未授权入站通道安全修复

- 已用受控真实russh peer复现默认回调接受未请求的forwarded-tcpip、agent、session、direct-tcpip、两类streamlocal及X11。Client现逐项明确AdministrativelyProhibited拒绝；未知类型保留默认拒绝，不访问本机目标/外部Agent，不关闭正常SSH。将来-R/内部Agent仅可在明确授权后逐项放行。
- 新红测先失败，修复后完整ssh-core141项与Clippy/all-targets拒绝警告通过，日志ssh-inbound-{red,core,clippy}.log。该测试是受控SSH协议测试，不计OpenSSH实测。
- 正在编写尚未接入编译的remote_forward.rs；不是已实现/已验证-R，保留文件继续开发，不能交付为可用API。

## 当前在途：远端-R核心（1087ae7之后，未提交）

- 已接原目标独立RemoteConnector/有界32规则与64入站流，ManagedSession只返回同代次能力；跳板各自独立Router，未知/未启用入站拒绝。仅明确规则触发本机目标连接，启动不探测目标。
- startup拥有句柄先返回、另等ACK；超时/owner Drop/等待Future abort保留原全局请求，迟到端口0分配成功后取消原端口；停止先释放本机socket/stream，再确认取消ACK。超时CleanupPending/拒绝CleanupDenied明确区分Stopped；前者继续等待原ACK不重发，后者再次stop才显式重试。
- 首轮8项真实SSH通过（4 OpenSSH+4受控peer），补充原端口重建/32规则上限/错误分配不得取消其他规则，28项旧+新转发通过；64流跨规则上限/释放追加专项通过。仍在最终回归，不能用局部通过宣称完整-R或正式GUI完成。
- 修复两处实测竞态：Stopped发布后旧路由清理间隙导致立即重建Busy；stop重试的watch旧版本导致提前返回上次拒绝。远端操作后SSH断开不提供远端OS监听瞬间销毁的ACK，测试正确观察最终关闭，不伪报Stopped。
- 入站forwarded-tcpip显式消费窗口补丁已接，慢本机目标不会堵共享PTY；正在临时关闭opt-in重现原慢消费问题，Python finally恢复lib.rs，再跑最终转发专项（ssh-remote-slow-before/forward-green.log）。若中断先核对flow_control_forwarded_tcpip必须返回true及进程状态。真实结果/完整回归尚待更新。

## 远端-R Rust核心稳定验证节点

- 13项-R专项通过10.47秒（6项真实OpenSSH，7项受控真实russh peer）；包括经一级跳板的实际目标Transport、8MiB+17二进制、半关闭、PTY/SFTP并行、32规则/64入站流跨能力与跨规则共享及释放、迟到ACK/中止/超时/拒绝/错端口保护。受控测试不计OpenSSH。
- 完整workspace275项通过（包含此前12项-R；第13项停止未确认启动的有限deadline已在后续专项单独通过），workspace/all-targets Clippy拒绝警告、匹配Native编译通过（ssh-remote-workspace/clippy-final/native-build.log）。新入站流控默认false，只有HSPTerm Client启用；原协议回归全部保留。
- 慢本机目标对照：关闭入站opt-in的真实红测3.57秒失败，finally已恢复true；启用后13专项/完整回归通过。不是精确输入延迟测量。29项转发整体27.99秒通过（最新两项追加后已有单项通过，后续完整全量会含）。
- NDK/API26 workspace检查、完整Flutter168回归/Analyze正在运行（ssh-remote-android/flutter-all/flutter-analyze.log）。正式GUI包仍23b27a3，尚未重建当前-R源码；没有FRB转发API/GUI业务，不计完整可视化转发完成。
- 下一模块forwarding_rules.rs已写入未接编译的加密配置代码与测试，独立保存，不纳入本次-R核心提交；继续原V1.4全范围，阶段不暂停。

## 转发规则配置当前在途（8af4c18之后）

- R节点最终匹配Native完整Flutter168项4:05通过，Analyze无问题，NDK/API26 workspace通过（ssh-remote-flutter-all/flutter-analyze/android.log）。该SO尚不含后续新配置模块；正式GUI包仍23b27a3，最终重建待配置模块稳定后进行。
- storage-sync::forwarding_rules已接编译：每保存主机独立版本化加密配置，至多32条；L/R/D字段/目标/重复ID/监听冲突验证、默认loopback、明确重连恢复布尔值，保存只写配置不联网、不保存运行状态或分配端口。读取SQL分配前限128KiB，未知版本/格式拒绝覆盖，不明文存规则。
- Repository复制主机时，规则与新主机草稿/凭据/目录同事务写入，新规则ID独立；未正式保存不能读取为正式配置，重开/草稿自动保存保持，丢弃新副本删规则、丢弃已保存主机编辑草稿不删正式规则。删除主机同事务删规则，运行Transport不受影响。
- 5项新增配置专项均通过（完整65项存储回归执行中），包括重开/密文/复制独立、配置错误/容量/未知版本/写失败保留、草稿恢复/正式保存/丢弃、复制与删除SQL故障时规则/凭据/目录全回滚。初次单测使用无效“host-missing”ID误触ID校验、Clippy提示clone切片，均已修正，失败日志保留。完整65项与workspace Clippy尚未确认结束（ssh-forwarding-storage-all/config-clippy.log）。
- 当前尚无配置FRB/正式表单/运行期管理器/明确恢复或临时链接转发，不计V1.4整项完成。稳定提交后直接接这些入口，不等用户阶段验收。

## 转发配置仓库稳定验证

- 完整storage-sync **65项通过（276.15秒）**，含5项新增配置/事务/草稿/复制/重开/安全边界；不是仅新增测试通过（ssh-forwarding-storage-all.log）。workspace/all-targets Clippy拒绝警告通过见ssh-forwarding-config-clippy.log，格式通过。
- 规则单独按保存主机ID加密，不增加HostConfig字段，普通主机编辑不会丢规则；复制副本的规则记录在正式保存前属于本机草稿，未来同步必须以正式catalog.hosts归属筛选，不能仅按key前缀上传。现有运行态不进此文档。
- 后续直接接配置FRB/验证和运行期管理/可视化；本仓库节点尚无应用端可用转发管理入口。当前工作台包仍23b27a3，Native/Flutter最终匹配与正式包将在接口节点完成后重建。

## 配置FRB接口在途与后续运行期文件

- cda1af7为加密规则仓库稳定提交；正式读取/显式保存规则的结构化FRB DTO已通过2.13.0官方生成器生成，匹配Native编译通过。新增真实Native配置测试1项7秒通过：三种规则、稳定ID、错误保留、重开/复制草稿正式保存/普通主机编辑保持/删除隔离，以及真实监听夹具收到连接数0，密文无规则名或密码。
- 新接口完整Flutter **169项4:12通过**、Analyze无问题；NDK/API26 workspace通过。Clippy首次发现函数放在cfg(test)模块后，已移动到测试模块前而未改变接口；修复后workspace/all-targets Clippy拒绝警告通过。完整Rust全量正在运行（ssh-forwarding-api-workspace.log），最终确认后提交接口与绑定。没有手改生成文件。
- 当前工作台包仍23b27a3，API Native已匹配而双模式正式包尚待新接口最终重建。
- forwardings/runtime.rs为正在编写、**尚未声明模块/编译/接入Entry或API**的运行期管理器初稿。不能当已实现业务；继续时先审查关闭/取消/旧代次/TOFU/Vault切换与端口0真实状态、停止ACK错误处理，再接测试。不要删除此文件或误计完成。

## 配置桥接稳定验证节点

- 最终完整Rust workspace **281项通过**（ssh-forwarding-api-workspace.log），包含当前13项-R和storage65项/5新增配置测试；workspace/all-targets Clippy拒绝警告、格式通过。Native库/正式FRB DTO一致；完整Flutter **169项4:12通过**，Analyze无问题；新配置Native1项7秒包含在169，未额外计数。NDK/API26 workspace check通过，不是APK/设备验收。
- 官方FRB2.13.0生成新增forwardings.dart，save_forwarding_rules只显式保存加密配置、不启动/恢复/停止任何监听；读取仅元数据。应用端运行管理与正式UI尚未接，未伪报整项完成。
- 当前源码将配置桥接作为稳定节点提交；正式工作台debug/release需重建和SO核对/独立启动，随后继续运行期Registry。未接编译的forwardings/runtime.rs初稿保留，不能当已验证。

## 配置节点正式包收尾

- 源码2d43f69的正式workbench_main debug/release构建通过；各包SO与target同模式SHA256一致（ssh-forwarding-api-bundle-hashes.log）。独立GTK启动/resize/正常退出app/wrapper均0，Rust加载，无Vault/终端历史/编辑工作副本，预览残留0，见validation/phase3b/ssh-forwarding-api-startup-*.json。
- 这两份5秒锁库/密码框焦点RSS/CPU只是启动样本，原样本均保留，不作优化/长期泄漏/Windows或Android结论。
- 无活跃构建或测试时，已通过cargo clean仅清本项目四crate的dev可再生成缓存355文件/2.3GiB，包SO独立inode；随后匹配Native重新编译通过，源码/记录/测试秘密未删或提交。现有可用空间约2.3GiB。
- 下一步正在接未声明的Registry初稿到Entry/API/销毁与断开；先保证旧代次/迟到准备/停止未知与原Root关闭顺序，再真实Native测试，不等待阶段验收。

## 当前在途：正式转发运行期FRB（fb9d1e1之后，未提交）

- Registry初稿已正式声明/接入Entry与API，不再是未编译文件；Rust check/首轮workspace Clippy已通过。新增start_forwarding/terminal_forwardings/stop_forwarding结构化接口，通过原NativeID/代次/实际目标与保存主机核对捕获单条已启用规则，原Transport L/R/D，不保存运行状态，不自动恢复。保存配置/删除主机不修改已有运行实例，停止不依赖凭据/主机仍存在。
- Entry销毁永久关闭准入、断开期间RAII计数关闭准入，多重关闭/调用方abort不提前重开；停止所有者在Root关闭前并行等待，有未知R取消时保留真实未知直到原Root关闭，不当作ACK成功；本机清理异常在所有原搜索/文档等待之后再报告，不能早退跳过释放。当前Registry仍需最终生命周期审查/全量回归，不计完整业务完成。
- 首个真实Native L/R/D三种65KiB+17回显与PTY均通过执行；测试错误等待已销毁Controller.connected变false导致20秒超时，已核对原Controller.shutdown在disposed后不再更新phase、id置空，改为等待共享shutdown Future并验证真实端口释放。未修改产品Controller伪造状态。
- 增加跨标签token隔离/第二标签关闭、断开与明确重连后旧token拒绝/不自动恢复、删除保存主机后既有转发继续/可停止、退出清理活动R监听的实际测试。两次Dart夹具编译错误（async谓词给sync helper/未插入局部变量）已修，日志保留，不代表产品测试通过。
- 当前正式FRB再次按2.13.0生成（私有类型已改唯一名避免生成器歧义），匹配Native/新增RAII单测2项和真实Native正在跑，日志ssh-forwarding-runtime-{codegen-final,native-final,unit,native-tests}.log；尚未确认结束。正式双模式包仍2d43f69的配置接口节点，不是运行期API节点。

## 当前全量回归发现的R状态竞态（正在修复，不能宣称全绿）

- Runtime节点完整Flutter170项4:15通过/NDK通过；完整Rust在受控peer的inconsistent_allocated_port测试失败：wait_started读到Err(Worker)后phase偶尔仍Starting，因为两次watch.send_modify分开。不是协议数据丢失，但属于公开状态一致性缺陷，保留ssh-forwarding-runtime-workspace.log失败记录，不能用旧281宣称当前全量通过。
- 已将全部启动失败的startup结果与phase合并为fail_start单次watch原子发布（保留原已定startup结果），包括取消/超时/拒绝/无效分配/断线。正在跑13项R专项、错误分配受控peer20次连续回归及匹配Native重建（ssh-forwarding-runtime-status-{fix,repeat,native}.log）；之后必须重新全量Rust/Clippy/Native回归。
- 正式管理界面新增forwarding_dialog.dart初稿（尚未接主机页），含真实Gateway、固定原会话选择、规则编辑/删除、显式启动/停止/未知状态及非回环绑定确认，配置删除后仍显示运行实例。新读取失败禁用保存/编辑，不能用空默认覆盖原配置。无空闲永久poll，仅明确操作后的有限过渡查询；完整事件推送/重连恢复仍待接。
- Dialog正在修复lint并待组件/布局/真实GTK测试，不能计为已交付界面。当前未经提交的所有Runtime/绑定/测试/新UI均在Git可见；最近稳定fb9d1e1（2d43f69正式包），根PROGRESS最新条优先于此前“在跑/待编译”记录。

## R失败状态原子发布修复验证

- 失败结果/phase现为同一次watch发布，已有startup结果不被后续清理覆盖。13项R专项10.16秒通过，错误分配受控peer连续20轮全部通过（ssh-forwarding-runtime-status-fix/repeat.log）；没有用等待/放宽断言掩盖产品竞态。
- 当前含尚未提交Runtime的完整工作树Rust **283项通过**（workspace-fixed.log），workspace Clippy拒绝警告通过（status-clippy.log）；匹配Native重建后，运行期/配置/原Phase2真实SSH+20次生命周期/真实Codex合成provider **4项27秒通过**（status-native-tests.log）。20次生命周期该窗口RSS差188416字节，不作泄漏结论。
- 新管理Dialog4项组件/缩放测试2秒通过，Analyze无问题（dialog-widget-final/dialog-analyze-final.log）；它尚未接主机页，因此不当正式入口验收。小窗1.6倍字体曾复现类型下拉横向溢出39px，已改为弹性省略；整个管理面板支持滚动。Root运行API待稳定提交及正式包更新，剩余范围不变。

## 正式运行期FRB稳定节点（待本次提交ID）

- Entry持独立ForwardingRegistry；结构化start/list/stop接口在原SSH代次/保存主机实际目标上捕获规则，数据走Rust流，不经Flutter。每终端最多32活动/待清理实例，旧token不能操作新代次或其他标签。规则保存/删除与启动/停止独立；原主机删除后运行实例仍可用并可停止，不能据旧凭据新建连接。
- 永久关闭与RAII重叠关闭准入2项单测通过；本机监听仅实际bind期间短持异步gate，actor能力获取与网络协议等待不持gate；R未知取消保留真实状态，原Root结束后才退休该代次，清理本机异常在完整释放等待后报告。
- 当前修复后完整Rust283/Clippy与4项匹配Native27秒通过；NDK前次Runtime检查通过、状态修复后将再次检查。Flutter170全量在R状态原子修复前通过，修复后已重跑4项Native（含原协议与Codex）；新UI接入后再全量，不将旧全量说成新UI验收。
- forwarding_dialog.dart与4项组件测试已实现但仍未接主机入口，暂不随运行期接口提交；4项Widget/小窗放大与Analyze通过。接入时必须保留Mock不加载Native、原主机脏编辑提示、原终端/代次固定和关闭释放。事件推送/重连恢复仍待实现，UI当前有限过渡观察与手动刷新，不冒充完整实时增强。
