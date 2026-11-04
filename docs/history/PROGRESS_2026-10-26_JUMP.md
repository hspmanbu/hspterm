# HSPTerm 当前开发进度

唯一产品基线：[V1.4](HSPTerm_最终需求规格_v1.4.md)及用户后续终端标签修订/全功能连续开发指令。175项逐条状态见[覆盖清单](REQUIREMENTS_COVERAGE.md)，不表示175项已完成。原200KB历史见[早期记录](docs/history/PROGRESS_2026-10-25.md)，本轮网络节点完整原文见[网络开发记录](docs/history/PROGRESS_2026-10-25_NETWORK.md)；历史“在途”不优先于本文。

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
- 本次正式探测业务提交（确切ID见git log）：FRB/短生命周期隐藏Controller/真实主机页“测试连接”，只读正式配置、原目标复核、TOFU、可取消/退出等待，不建立可见标签或最近记录；未保存编辑需先保存。结果明确不证明目标登录成功。过期Dialog的Future不能取消后来测试；长目标弹窗可滚动。详见SSH_NETWORK.md。

## 已实现的实际基础

- Rust终端协议/输入/Unicode/宽字符/颜色/光标、Kitty/CSI u、鼠标/Shift覆盖、OSC52、安全粘贴/IME、同步输出、RAM+临时磁盘历史/Reflow/当前终端搜索/流式导出；FRB2增量绘制与隐藏不拉帧，断线保留画面/明确重连。Phase2证据见PHASE2_VALIDATION.md。
- 加密主机/独立凭据/本机草稿/基础分组收藏、密钥生成导入导出与TOFU；正式多会话标签/自由分屏/焦点关联SFTP保持，原最小SSH/独立Mock入口保留。代理/时限/握手测试已接真实业务；其余高级网络/UI仍部分Mock。
- 真实SFTP分页/双限额缓存/缓存补全/基本CRUD/书签/递归文件名搜索；选区定位与可选OSC7跟随；受控系统预览/确认阈值、严格编码内置文本编辑/加密草稿恢复、外部文本与大原始字节分块编辑/监听回传/租约/保留及明确清理。
- 本地↔远端文件/目录队列：共享可配置FIFO/方向限速、暂停续传、冲突策略/失败重扫、分块加密恢复；远端↔远端明确内存中转复制/私有暂存发布屏障与失败目录重扫、复制到/移动到、部分入队重试。
- 同账户无覆盖移动Intent/ACK与编辑互斥；丢ACK不盲重发，不从缺失/大小推断成功。在线只读核对与离线本机结束分离，UserEnded不等于Confirmed，保留加密审计；删除主机/关SSH后仍能本机结束。各领域边界详见AGENTS.md及领域记录，不将部分实现计作整条完成。

## 最新真实验证

- 完整Rust223项通过（.local/ssh-probe-rust-all.log），含45项真实OpenSSH；workspace/all-targets Clippy拒绝警告、格式检查通过。正规FRB2.13生成/匹配Native编译、NDK/API26 aarch64 workspace check通过（ssh-probe-bridge-android.log），不是APK/设备验收。
- 最终完整Flutter162项3:48通过（ssh-probe-flutter-final-all.log），Analyze无问题。含真实Codex TUI合成provider、原编辑/传输/移动/路径回归和新增8项探测专项。当前Native目录burst仍4000报告→有界合并/隐藏0帧，无变化不持续通知。
- 真实GTK探测最终1项11秒通过（ssh-probe-gtk-final.log）：App默认首次指纹“信任并保存”，不存在用户/无效合成密码仅报告握手通过，不建终端；停流代理取消等EOF且无全局错误。网络表单/两代理回归1项26秒通过（ssh-probe-network-gtk.log），单次保存/手动重连/其他会话身份保持。
- 代理协议10项、仓库独立加密/事务回滚4项；真实Native时限/心跳：1秒总预算在Proxy超时、8秒重试可取消；1秒心跳/1阈值对显式停流断线并保留屏幕，0间隔在4秒对照窗口保持，仍可手动断开。8项新探测专项覆盖原目标复查/旧取消不误伤/创建中取消/隐藏0帧一次释放/未保存不联网/取消等待/合法长目标窄窗滚动。
- 最终workbench_main debug/release构建通过（ssh-probe-build-final-*.log），包内SO与target同模式SHA一致（ssh-probe-bundle-hashes.log）。两包独立GTK启动/resize/正常退出wrapper/app均0，Native加载，无Vault/终端历史/编辑工作副本、预览run残留0。
- 图片：validation/phase3b/connection-test.png、ssh-network-timing.png、ssh-proxy-settings.png、ssh-proxy-workbench.png；实际运行合成数据截图，已查看相关图。运行/领域说明见WORKBENCH_VALIDATION.md、SSH_NETWORK.md。
- ssh-probe-startup-debug.json：RSS452517888字节/CPU7.40%；release280256512字节/CPU5.40%。只是锁库密码框聚焦5秒样本，旧proxy/timing/follow样本均保留，不作优化、长期泄漏或目标平台结论。20次Native生命周期最近样本RSS差-7618560字节，仅记录该窗口。
- 缺方法红测、夹具初始化/可见性/确认回调及布局失败日志均保留；没有跳过失败。窄主机页32px溢出已换行修复，合法长目标弹窗滚动修复后全量重跑通过；未改协议来掩盖夹具问题。

## 下一步直接编码

1. 当前在途：最多一级跳板核心，起点3562b5d干净；两台独立OpenSSH的双TOFU/独立认证/PTy/SFTP、拒绝无回退、外层唯一HTTP/SOCKS代理及总Budget/取消与资源释放。核对russh0.64.1真实通道流/Handle生命周期及RFC4254 §7.2后写红测；随后再接加密记录/FRB/正式选择器。代理与手动探测不要重复实现。
2. 保留终端后续入口：可靠OSC133 C/D历史锚点、裁剪/Reflow映射、命令段导航/复制。候选稳定Row身份及实际Grid位置变换；不改Cell空格/宽度语义，不凭文本相似度定位。冻结范围读取已在，不重做。
3. 安全Shell本地输入追踪→十项路径联动/合格单行命令加密历史与联想；OSC7/OSC133自报不能证明POSIX Shell/回显/光标安全，不能盲清行或向TUI注入。
4. 按175项覆盖清单持续实现全部剩余：显示装饰/字体/链接通知/命令面板、完整主机排序/批改、文件并行/安全直传/跨服务器剪切/暂存审计清理/CRUD编辑保护、全局网络默认与独立心跳响应超时、配置同步/备份/OpenSSH导入/DPAPI/Keystore、Windows原生适配及完整Android/SAF/前台服务。未列细项仍以V1.4为准，不表示删除。

## 重要未完成/恢复边界

- 选区定位/可选跟随不等于自动链接识别/Ctrl+Click、路径发送或Android长按；绝对路径可用，OSC7相对仅匹配实际SSH authority，不猜IP/DNS别名。输入跟踪/联想与完整命令复制尚未完成。
- 远端未知暂存/发布结果及跨服务器剪切源删除须持久化意图/ACK并保护后来重建的源；不能盲重试或删唯一恢复记录。旧F2/内部CRUD尚待完整统一编辑路径保护。
- 单SSH代理可用，不等于跳板/转发/云同步独立代理完成。HTTP Basic/SOCKS代理认证到代理TCP链路不加密，界面已说明；不读回用户名密码。完整同步/备份后续必须纳入正式代理秘密，草稿仍本机。
- Windows/Android实机与Claude真实账号测试待条件具备，见PLATFORM_VALIDATION.md；当前只是Ubuntu及NDK共享核心结果。其余Android/Windows编码未完成，不得称全功能交付。

## 可恢复构建约定

新会话先读AGENTS/V1.4/本文/覆盖清单，检查git status/log/diff和中断操作日志，不覆盖未提交修改、不清理未知文件。先确认在途进程/产物，再继续未完成模块。独立功能测试通过即更新并提交，不等待阶段/视觉验收。

- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；Cargo、FRB生成和Flutter原生构建前均export CARGO_INCREMENTAL=0。工具链固定，生成文件只能用flutter_rust_bridge_codegen generate再cargo fmt，不能手改绑定。
- Rust：cargo test --workspace --locked -- --test-threads=1；cargo clippy --workspace --all-targets --locked -- -D warnings；cargo fmt --all -- --check。新API要先正规生成/匹配Native，再跑Flutter。
- ui_flutter：flutter analyze；flutter test --reporter expanded。GTK用benchmark/external_editor_gtk.py私有Xvfb/D-Bus包装，桌面builder顺序执行。集成测试会覆盖debug包；交付前总是重建-t lib/workbench_main.dart的debug/release，核对SO及独立启动/退出。
- lib/main.dart为Phase2最小SSH验收；prototype_main.dart为独立Mock；workbench_main.dart才是正式业务。不要把测试入口打包交付。
- 最新磁盘约2.1GiB；本轮仅在测试结束、核对包SO独立inode后，cargo clean本项目四crate可再生成dev缓存两次释放2.5/2.1GiB；源码/正式包/日志保留。不可在测试使用库时清理或删除未知数据。

## 当前在途：一级跳板核心（2026-10-26）
- 最新正式业务3562b5d已提交，正式双模式仍该节点。新核心采用target配置中的唯一外层代理→跳板SSH→direct-tcpip→目标SSH，跳板类型不含递归跳板配置；两端独立host key/选定认证，整个请求一个Budget/取消根，任何失败不直连或认证回退。不暗中在跳板执行Shell/安装工具。先写真实协议测试，不把核心或Mock算正式选择器完成。

## 一级跳板核心首轮验证
- JumpHost不可嵌套/不含第二代理，目标ConnectConfig持唯一外层代理/总Budget/心跳；独立选定认证及两端TOFU，通过direct-tcpip承载目标SSH。JumpStream持跳板Handle及通道，嵌套I/O同取消根；失败无直连/认证/Shell回退。跳板错误明确前缀，取消保留Cancelled，目标错误不伪装为跳板错误。
- 缺类型/字段红测后，6项真实协议专项13.82秒及2项配置/Debug脱敏单元通过（ssh-jump-core-final/ssh-jump-unit）：双OpenSSH独立密钥/账号认证→PTY/resize/256KiB中文路径SFTP；两端key/auth失败分类及禁止转发；唯一HTTP/SOCKS外层代理仅解析虚拟跳板域名；一秒代理延迟+跳板认证+目标停流共用3秒Budget；中止嵌套探测关闭转发socket/释放actor。
- 当前完整ssh-core/Clippy/匹配Native与NDK check运行中（ssh-jump-core-all/clippy/native-build/android）。无FRB公开API/存储/Dart改动，正式双模式仍3562b5d。核心不等于加密主机跳板选择器已完成；通过后接存储/FRB/正式UI继续，不在此节点暂停。

- 一级跳板完整ssh-core首轮通过；Clippy发现新增路由使私有Command/Action变体膨胀到至少400字节，已只对私有Connect命令的config使用Box、actor接收时解包，保持公开ConnectConfig接口及生命周期；同时修复可折叠条件，未关闭任何lint。最终Clippy/ssh-core回归与Native重新运行ssh-jump-clippy-fixed/core-fixed-all/native-build，之前失败日志保留。下一步FRB接入前必须处理按跳板命名空间隔离目标TOFU（同10.x地址经不同跳板不能误用直连pin），并准确显示实际跳板/目标身份、绑定该次验证取消作用域；现有App尚不启用跳板。

- 最终一级跳板ssh-core117项（含51项真实OpenSSH）及workspace/all-targets Clippy拒绝警告通过（ssh-jump-core-fixed-all/ssh-jump-clippy-fixed）；已编译匹配Native，最终Box命令版本NDK check/格式及7项真实Native/Codex/代理/时限心跳/明确探测回归运行中（ssh-jump-android-final/ssh-jump-native-regression）。没有公开FRB或Dart改动，不重跑无更改存储全量或Flutter162/GTK，正式包仍3562b5d。

- 一级跳板核心最终恢复确认：117项ssh-core（51项真实OpenSSH）、Clippy/格式、匹配Native、API26 NDK workspace check均通过；7项真实Native/Codex/代理/时限心跳/握手探测回归45秒全部通过（ssh-jump-native-regression.log），20次生命周期该窗口RSS差729088字节，不据此判断泄漏。无公开FRB/存储/Dart变化，正式打包仍3562b5d。当前继续加密跳板引用与路线隔离TOFU/正式界面，不把核心当全功能完成。

## 一级跳板加密引用（2026-10-26）
- 核心已提交93a770c；HostRecord.jump_host_id默认None，引用已保存主机，不复制/泄露其凭据。保存和运行解析拒绝自身/草稿/两级跳板、反向编辑引入嵌套及目标与跳板双代理。删除保留失效引用，未来连接明确拒绝，不直连。草稿/复制/重开保留引用，复制目标凭据仍独立。
- 存储完整60项通过83.27秒（ssh-jump-storage-fixed.log），含5项新增图约束/加密/草稿/副本/删除/失败保存/旧格式测试。首次测试误将允许明文存储的opaque记录主键当秘密，修正为检查加密关联载荷与秘密；失败日志保留，未改存储协议规避测试。
- 正在接FRB按路由隔离目标TOFU、至多2槽原尝试验证/取消及正式界面；目前尚不可把跳板当应用端到端完成。

## 跳板正式桥接/界面在途
- 加密引用节点7a2d561已提交；正式route工厂已读取保存跳板认证/唯一代理并生成独立JumpHost，手动探测不读目标认证。按版本化长度前缀tuple对跳板端点/用户名+目标端点散列隔离目标TOFU，直连旧键保持。原尝试至多两个验证槽，opaque context由客户端生成，取消/退出撤销，过期确认不能存到新路线；真实待验证跳板与目标分别显示。
- 3项新桥接验证单元连同原信任竞争测试4项通过；新增真实Native跳板+3项选择器/缺失引用/双代理，与既有表单/探测共10项17秒通过（ssh-jump-native-forms.log）。Native验证了独立指纹、继承SOCKS代理、草稿/复制/重开、不存在目标用户探测成功而实际认证失败、明确修正/重连、真实PTY/SFTP、变更路由重验、删除跳板不影响现有SSH但下次拒绝。
- 首次Native尾部断言错误复用了成功重连前的旧PTY文本，已在新PTY明确打印后检查失败重连保留，未改变产品重连规则；失败日志保留。完整Rust/Flutter、真实GTK、最终NDK/双模式构建尚待本轮执行，不宣称端到端全部完成。

- 正式路由完整Rust239项通过（含51项真实OpenSSH；ssh-jump-workspace.log），Clippy拒绝警告/格式通过，API26 NDK workspace check通过（ssh-jump-integrated-android.log）；正规FRB2.13生成与匹配Native通过。真实GTK跳板1项26秒/原探测1项11秒通过，三张PNG已查看。首次GTK无动画的隐藏测试未驱动弹窗帧而停滞，已修复夹具主动pump；同时产品确认回调异常finally拒绝，防永久等待。
- 完整Flutter首轮166项完成后停在新增确认异常测试的widget假时钟退出；已中止保留日志ssh-jump-flutter-before-fixture，改为该无UI测试适用的普通async单测，两项0秒通过，不改Native退出逻辑。最终完整Flutter/双模式包正运行（ssh-jump-flutter-final/ssh-jump-build-*），不能以中断166声称完整通过。磁盘不足前已确认无Native测试进程及SO独立inode，用cargo clean仅清本项目四crate dev再生成缓存2.3GiB并重建匹配Native；未删源码/包/日志/未知文件。
