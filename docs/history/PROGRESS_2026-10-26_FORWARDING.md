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
- 本次正式跳板业务提交（确切ID见git log）：统一路由工厂/继承唯一代理、独立目标TOFU命名空间、至多2槽的原尝试确认与取消、正式跳板选择器；真实双端指纹/跳板认证/目标PTY/SFTP/手动重连与删除行为已验。确认回调异常明确拒绝，Entry销毁永久阻止新准备，不能在取消后重新激活。

## 已实现的实际基础

- Rust终端协议/输入/Unicode/宽字符/颜色/光标、Kitty/CSI u、鼠标/Shift覆盖、OSC52、安全粘贴/IME、同步输出、RAM+临时磁盘历史/Reflow/当前终端搜索/流式导出；FRB2增量绘制与隐藏不拉帧，断线保留画面/明确重连。Phase2证据见PHASE2_VALIDATION.md。
- 加密主机/独立凭据/本机草稿/基础分组收藏、密钥生成导入导出与TOFU；正式多会话标签/自由分屏/焦点关联SFTP保持，原最小SSH/独立Mock入口保留。代理/时限/握手测试已接真实业务；其余高级网络/UI仍部分Mock。
- 真实SFTP分页/双限额缓存/缓存补全/基本CRUD/书签/递归文件名搜索；选区定位与可选OSC7跟随；受控系统预览/确认阈值、严格编码内置文本编辑/加密草稿恢复、外部文本与大原始字节分块编辑/监听回传/租约/保留及明确清理。
- 本地↔远端文件/目录队列：共享可配置FIFO/方向限速、暂停续传、冲突策略/失败重扫、分块加密恢复；远端↔远端明确内存中转复制/私有暂存发布屏障与失败目录重扫、复制到/移动到、部分入队重试。
- 同账户无覆盖移动Intent/ACK与编辑互斥；丢ACK不盲重发，不从缺失/大小推断成功。在线只读核对与离线本机结束分离，UserEnded不等于Confirmed，保留加密审计；删除主机/关SSH后仍能本机结束。各领域边界详见AGENTS.md及领域记录，不将部分实现计作整条完成。

## 最新真实验证

- 完整Rust239项通过（.local/ssh-jump-workspace.log），含51项真实OpenSSH；workspace/all-targets Clippy拒绝警告/格式通过。最终销毁永久关闭修复后，4项验证作用域回归通过（ssh-jump-verification-final.log），Clippy与NDK/API26 aarch64 workspace check再次通过（ssh-jump-clippy-final/ssh-jump-android-last），不是APK/设备验收。
- 完整Flutter168项4:43通过（ssh-jump-flutter-final.log），Analyze无问题。最终Native匹配库再次执行8项真实终端/Codex/代理/时限心跳/握手/跳板回归1:02通过（ssh-jump-native-last.log）。真实Codex使用隔离合成provider，不读取登录或付费任务。新主机图约束/草稿副本/加密重开存储5项在完整60项中通过。
- GTK跳板1项26秒通过（ssh-jump-gtk-fixed.log）：实际App分别确认跳板和目标，网络分类选择已保存跳板并单击保存、保持在线Native ID/代次；真实PTY/中文路径SFTP、另一跳板重新验证、删除后下次拒绝。原探测GTK回归1项11秒通过（ssh-jump-probe-gtk.log）。三张ssh-jump-{tofu,settings,workbench}.png在validation/phase3b，已查看。
- 最终workbench_main debug/release构建通过（ssh-jump-build-*-final.log），包内SO与target同模式SHA一致（ssh-jump-bundle-hashes-final.log）；独立启动/resize/退出结果见下方最终收尾。原lib/main.dart和prototype_main.dart保留。
- 之前probe节点的223/162全量与GTK/内存数据保留在历史；不是本次最终计数。此次Native20次生命周期窗口RSS差188416字节（完整Flutter日志），只记录窗口，不据单次RSS推断泄漏。
- 新增确认异常单测先误放widget假时钟导致退出等待，改为普通async测试，两项立即通过；GTK隐藏探测无动画须主动pump，首次停滞已中止，产品同时补齐回调异常finally拒绝。失败/中断日志保留，未跳过错误或修改协议掩盖夹具。真实秘密从未提交。

## 下一步直接编码

1. 继续端口转发核心：复用原目标Transport的受代次/生命周期约束TCP通道能力，随后本地/远端/动态转发及可视化配置/停止恢复；绝不为转发重连SSH。一级跳板/唯一代理/手动握手测试已接，不重复实现。另需全局网络默认、主机覆盖与独立心跳响应超时。
2. 保留终端后续入口：可靠OSC133 C/D历史锚点、裁剪/Reflow映射、命令段导航/复制。候选稳定Row身份及实际Grid位置变换；不改Cell空格/宽度语义，不凭文本相似度定位。冻结范围读取已在，不重做。
3. 安全Shell本地输入追踪→十项路径联动/合格单行命令加密历史与联想；OSC7/OSC133自报不能证明POSIX Shell/回显/光标安全，不能盲清行或向TUI注入。
4. 按175项覆盖清单持续实现全部剩余：显示装饰/字体/链接通知/命令面板、完整主机排序/批改、文件并行/安全直传/跨服务器剪切/暂存审计清理/CRUD编辑保护、全局网络默认与独立心跳响应超时、配置同步/备份/OpenSSH导入/DPAPI/Keystore、Windows原生适配及完整Android/SAF/前台服务。未列细项仍以V1.4为准，不表示删除。

## 重要未完成/恢复边界

- 选区定位/可选跟随不等于自动链接识别/Ctrl+Click、路径发送或Android长按；绝对路径可用，OSC7相对仅匹配实际SSH authority，不猜IP/DNS别名。输入跟踪/联想与完整命令复制尚未完成。
- 远端未知暂存/发布结果及跨服务器剪切源删除须持久化意图/ACK并保护后来重建的源；不能盲重试或删唯一恢复记录。旧F2/内部CRUD尚待完整统一编辑路径保护。
- 单SSH代理及最多一级跳板可用，不等于端口转发/云同步独立代理完成。HTTP Basic/SOCKS代理认证到代理TCP链路不加密，界面已说明；不读回用户名密码。完整同步/备份后续必须纳入正式代理秘密，草稿仍本机。
- Windows/Android实机与Claude真实账号测试待条件具备，见PLATFORM_VALIDATION.md；当前只是Ubuntu及NDK共享核心结果。其余Android/Windows编码未完成，不得称全功能交付。

## 可恢复构建约定

新会话先读AGENTS/V1.4/本文/覆盖清单，检查git status/log/diff和中断操作日志，不覆盖未提交修改、不清理未知文件。先确认在途进程/产物，再继续未完成模块。独立功能测试通过即更新并提交，不等待阶段/视觉验收。

- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；Cargo、FRB生成和Flutter原生构建前均export CARGO_INCREMENTAL=0。工具链固定，生成文件只能用flutter_rust_bridge_codegen generate再cargo fmt，不能手改绑定。
- Rust：cargo test --workspace --locked -- --test-threads=1；cargo clippy --workspace --all-targets --locked -- -D warnings；cargo fmt --all -- --check。新API要先正规生成/匹配Native，再跑Flutter。
- ui_flutter：flutter analyze；flutter test --reporter expanded。GTK用benchmark/external_editor_gtk.py私有Xvfb/D-Bus包装，桌面builder顺序执行。集成测试会覆盖debug包；交付前总是重建-t lib/workbench_main.dart的debug/release，核对SO及独立启动/退出。
- lib/main.dart为Phase2最小SSH验收；prototype_main.dart为独立Mock；workbench_main.dart才是正式业务。不要把测试入口打包交付。
- 最新磁盘约1.6GiB；本轮仅在测试结束、核对包SO独立inode后，cargo clean本项目四crate可再生成dev缓存两次释放2.5/2.1GiB；源码/正式包/日志保留。不可在测试使用库时清理或删除未知数据。

## 跳板正式节点收尾（2026-10-26）
- 最终debug/release独立GTK启动/resize/正常窗口关闭wrapper与app均0，Native加载，无Vault/历史/编辑工作副本，预览run残留0（ssh-jump-smoke-*.log）。
- 锁库密码框聚焦5秒样本：debug RSS452489216字节/CPU5.20%；release RSS281952256字节/CPU4.60%。数据见validation/phase3b/ssh-jump-startup-*.json，原probe/proxy/timing样本均保留；不作优化、长期泄漏或Windows/Android结论。
- 继续端口转发核心，不等待阶段验收。Windows/Android实际软件仍有未完成编码，全部剩余见175条覆盖清单；仅排除实机验收，不宣称V1.4整体完成。

## 当前在途：转发TCP能力核心（ef0bb9c之后）
- 正式跳板/双模式包稳定节点ef0bb9c已提交，工作区此前干净。继续原Transport direct-tcpip能力：actor只交付受原代次限制的TcpConnector，真正协商在actor外；全部clone/重复获取共享64个在途+活动名额，取消/超时不取消SSH，断线后旧能力永远不能改指向新Transport。
- russh0.64.1 channel_open future取消后可能迟到确认，不能直接drop它导致无ChannelCloseOnDrop。当前实现保留有界收尾worker，等待该次结果或原Transport取消，迟到流交给已丢弃receiver时会Close/释放名额，不添加空闲轮询。
- 4项真实OpenSSH首轮通过（5.04秒），受控真实SSH peer三种迟到确认/timeout/cancel/abort也已逐项关闭通道且原SSH未断，最后退出断言误要求取消TCP前必达SSH goodbye，已改为只接受已观察到的UnexpectedEof，保留失败日志。最终5专项/完整ssh-core/Clippy/匹配Native在跑（ssh-forward-*），尚未提交。不是完整-L/-R/-D或正式UI，不冒充可用转发配置。

- TCP通道核心最终5专项通过5.24秒（4项真实OpenSSH+1项受控真实SSH迟到确认协议夹具）；完整ssh-core122项通过，含OpenSSH目录56项，其中55项实际OpenSSH、1项受控SSH peer。Clippy/格式/NDK workspace及匹配Native编译通过；6项真实Native/Codex/代理/探测/跳板回归结果见ssh-forward-native-regression.log。没有FRB DTO或Flutter业务修改，不重跑无改动UI全量；正式双模式包仍ef0bb9c。
- 受控peer退出因所有者立即关闭TCP，可返回EOF或有未读channel-close时的ConnectionReset，两者只在明确close之后接受，任何其他错误仍失败；三种迟到通道在原SSH仍在线时均先验证EOF。未改产品关闭规则、未新增Debug泄露或忽略任意错误。下一步接实际本地监听转发/停止与状态，再远端/动态与正式配置。

## 本地-L监听核心（55445be之后）
- TCP通道基础已提交55445be；前次6项真实Native/Codex/代理/探测/跳板43秒通过，20次生命周期RSS窗口差675840字节，不作泄漏结论。正式双模式包仍ef0bb9c。
- LocalForward真实绑定本机地址，以原cap连接远端，copy_bidirectional有界流式/半关闭；每监听至多64子任务，所有监听仍共享Transport的64通道名额。watch状态只在accept/完成/失败/停止发布，失败不误记成功；stop await释放本监听及全部socket/stream所有者，兄弟转发与原SSH不受影响，根SSH断开关闭监听，重连旧能力拒绝，不自动重启。
- 9项转发专项10.37秒通过（8项真实OpenSSH+1受控真实SSH），完整ssh-core126项通过，Clippy拒绝警告与匹配Native编译通过（ssh-local-forward-final/core/clippy/native-build.log）；NDK与真实Native原终端回归运行中。无FRB/Dart公开接口变化，不将Rust监听核心计作正式可视化转发完成。
- 下一步直接继续远端-R/动态-D核心和对应加密规则/FRB生命周期/可视化管理/明确恢复。保持原阶段剩余任务与175条范围。

- 本地监听核心最终NDK/API26 workspace check/格式通过；真实Native原终端/Unicode/resize/TUI/手动重连/20次生命周期1项17秒通过（ssh-local-forward-native.log），该RSS窗口差以原日志为准。没有FRB/Dart改动，完整Flutter168与正式双模式GUI仍为ef0bb9c，未冒充新GUI转发入口。

## 当前在途：动态-D SOCKS5核心（7387c60之后）
- LocalForward::socks5共用原监听/有界runner/统计/停止，私有Mode区分固定目标与按请求目标。无认证CONNECT子集，IPv4/IPv6/ASCII域名严格有界解析/精确读取，合并包负载不丢；不支持方法/命令明确失败，目标通道确认后才成功回复，SSH禁止转发无本地回退。握手+名额等待+打开共享deadline，小回复写入另≤1秒；慢客户端/停止释放任务不影响原SSH。
- 2项解析单测、5项新增真实OpenSSH（含实际IPv6目标）通过；14项转发专项15.30秒、完整ssh-core133项通过（ssh-dynamic-interop/core.log），Clippy拒绝警告/匹配Native编译通过。最终workspace全量、NDK和6项Native/Codex/代理/探测/跳板回归正在运行（ssh-dynamic-workspace-final/android/native-regression.log）。正式GUI当前仍ef0bb9c，计划在源稳定后重建。不是已接入可视化-D。
- 剩余入口：远端-R有界入站路由/迟到全局请求ACK清理与取消未知状态，再正式加密转发规则/FRB生命周期/可视化管理/明确恢复。约束已写PORT_FORWARDING.md，不为阶段边界暂停，不恢复Mock完成声明。

- 动态核心首轮14项转发/133项完整core、6项真实Native49秒及NDK通过；最终workspace执行中。额外生命周期审查发现stop()先take JoinHandle，若调用方中止后第二次stop可能在清理结束前返回。已用current-thread真实OpenSSH的单次手动poll精确写红测并复现，改为await期间保留原handle；正在重跑15项转发与Clippy/Native编译（ssh-dynamic-stop-red/stop-green/clippy-last/native-last-build.log），不会把旧14项当修复后验收。

## 慢TCP消费阻塞共享PTY（已修复并通过完整Rust回归）
- 新增local::a_slow_local_tcp_reader_does_not_block_pty_on_the_shared_ssh_transport，远端16MiB分块发送、本机客户不读，2MiB实际开始后等待500ms，PTY marker在2秒内不出现；先清理再assert，日志ssh-forward-backpressure-before.log。该测试当前失败，不能称转发核心已全部验收。
- 已定位russh0.64.1 client/encrypted.rs先自动按收到字节WINDOW_ADJUST，再await有界ChannelRef.send(Data)，channel_buffer_size32被慢forward堵满后整个client actor停止处理独立PTY。不能只扩大队列或改无界内存，不能丢SSH/转发字节。
- 准备对russh0.64.1作局部、显式opt-in的接收流控补丁，仅TCP能力调用新API；默认PTY/SFTP/跳板原调用不变。方案：接收队列按协商字节窗口有界、64KiB合并块/有界控制项，消费后才发窗口credit；credit经原priority消息通道按channel合并至多1个在途，取消/EOF/CLOSE正确收尾。保留原有迟到open清理/64cap。先vendor真实固定版本及许可证，禁止改registry全局缓存，必须跑真实慢读回归与二进制完整性/所有原协议回归。
- 当前D模块仍未提交，最近稳定Git7387c60；其前已通过workspace255（停止取消小修前）、133 core、修复后15转发专项、6 Native49秒/最终Native1项18秒、NDK、正式双模式构建。新慢读红测加入后这些旧通过不表示当前全绿。正式包目前是慢读修复前本轮D源码，不对外宣称新转发功能可用，转发FRB/UI尚未接。

- 流控补丁已实现并通过：慢读PTY红测原3.53秒失败→新1.53秒完整测试通过；8MiB+17/4093字节碎片读/多轮window grant逐字节一致；17项转发专项18.91秒通过（ssh-flow-slow-green/interop.log）；精确生产FlowQueue对实际russh消息类型的4项边界/合并/credit/FIFO/EOF/CLOSE/wake通过（ssh-flow-queue.log）。workspace/all-targets Clippy拒绝警告通过（ssh-flow-clippy.log），无新增unsafe。
- vendor/russh固定0.64.1，来源与原crate校验和、10个修改/新增生产文件、许可与公开上游测试向量边界写HSPTERM_PATCH.md；不改全局registry缓存、不增新版本依赖。正常PTY/SFTP/跳板默认API不变；只TcpConnector选择新流控API。窗口按实际消费补充、字节窗口+128项双界限，priority credit按channel合并，不无界队列/丢数据/磁盘转发。
- 新补丁影响协议依赖，已清理仅本项目四crate的dev可再生缓存2.6GiB（无活跃测试/独立包SO保留）后运行修复后完整workspace（ssh-flow-workspace.log）及匹配Native编译；这些运行中，不能用旧255/168替代本补丁回归。当前D/流控仍未提交，最后稳定7387c60。

## 动态转发/接收窗口核心验证节点
- 固定版本vendor补丁后完整workspace262项通过（ssh-flow-workspace.log），包括ssh-core140项、目录68项真实SSH测试中的67项OpenSSH与1项受控peer；4项生产队列源码/真实消息边界专项已包含在262。正常PTY/SFTP/主机/加密存储/终端全部原Rust回归保留。
- 匹配Native库已编译（ssh-flow-native-build.log），workspace/all-targets Clippy拒绝警告、格式已通过；Flutter完整回归/Analyze及API26 NDK检查正在跑（ssh-flow-flutter-all/flutter-analyze/android.log）。正式GUI包暂仍为补丁前D源码，等回归与重建确认后更新；当前不把转发核心算作可视化业务或全功能完成。
- 最近稳定7387c60；本次将D/stop取消安全/消费窗口补丁及其完整Rust证据一起提交（确切ID见git log），完成后继续远端-R与正式转发业务。不得丢失已有完整V1.4剩余范围，不能恢复阶段等待。
