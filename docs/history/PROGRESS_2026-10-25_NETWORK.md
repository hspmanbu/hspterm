# HSPTerm 当前开发进度

恢复基线：`HSPTerm_最终需求规格_v1.4.md`及用户后续连续开发/终端标签修订；需求逐项状态见`REQUIREMENTS_COVERAGE.md`（175项，不等于175项完成）。原200KB进度记录逐字保存在[开发历史](docs/history/PROGRESS_2026-10-25.md)，旧“在途”仅历史，不优先于本文。

## 当前阶段与执行规则
- Phase1/Phase2 Ubuntu A类基础验收及Phase3A交互原型已有；当前持续Phase3B真实业务与剩余V1.4开发，不在模块/阶段边界暂停，不再等待视觉验收。正式Windows/Android尚未完整实现，不能称全功能完成。
- 一标签一独立SSH Transport/PTY/SFTP；TabGroup/SplitTree只改显示，不复制/重连。Windows单窗口空白启动，无托盘/本地Shell/广播/自动重连。Android只单终端显示，全屏SFTP，不能复制桌面分屏。
- 当前Ubuntu有Flutter/Rust/NDK；Windows和Android实机验证排除，平台编码/适用构建仍须继续。真实Claude账号缺失不阻塞其他开发。只用隔离回环OpenSSH/合成数据；Codex测试不读取登录凭据，不做付费或生产操作。

## 已实现的真实业务基础
- Rust终端协议/Unicode/宽字符/颜色/输入、Kitty/CSI u、鼠标/Shift覆盖、OSC52、被动OSC7/同步输出、RAM+临时磁盘历史/Reflow/当前终端搜索；FRB2增量绘制、IME提交/剪贴板安全粘贴、断线保留画面/明确重连。具体Phase2真实TUI与性能证据见PHASE2_VALIDATION.md、PLATFORM_VALIDATION.md。
- 正式加密主机/独立凭据/草稿/基础分组收藏、密钥生成导入导出与TOFU；多SSH会话标签/自由分屏/焦点SFTP保持，旧最小SSH与独立Mock入口保留。高级网络配置/大部分高级设置仍待接，Mock不算业务完成。
- 真实SFTP目录分页/有界缓存/缓存路径补全、基本CRUD/书签、递归文件名搜索/终端选区定位、可选OSC7目录跟随（主机加密偏好默认关闭）、系统关联预览与确认阈值；内置严格编码文本编辑/本机加密草稿恢复、外部文本及大正文原始字节分块编辑/监听回传/租约/保留与明确清理。边界见FILE_SEARCH.md、REMOTE_EDITING.md、LARGE_EDITING.md等。
- 真实本地↔远端文件/目录队列，共享可配置FIFO/全局上下行限速、暂停续传/失败重试/冲突决定/加密分块恢复；远端↔远端显式内存中转复制、私有暂存发布屏障/失败目录候选重扫、独立复制到/移动到和部分入队重试。完整目录并行细节/安全直传/跨服务器剪切等仍待做。
- 同账户无覆盖移动Intent/ACK日志与编辑互斥；丢更名ACK不盲重发、不从缺失/大小推断成功。在线只读核对与离线本机审阅/明确结束分离，UserEnded不等于Confirmed，保留加密审计；删除主机/关SSH后仍能本机结束，网络检查/恢复身份规则不放宽。见REMOTE_FILE_OPERATIONS.md。

## 最新稳定节点与当前源码
- `217787c`：离线本机审阅/结束未知移动；完整Rust180/Flutter139、真实GTK及正式双模式验收。
- `967fd70`：被动OSC7核心：严格file URI/单次解码/完整ST/取消/超限失效，备用屏幕/RIS/断线/新PTY清上下文；字面POSIX相对路径匹配实际SSH authority，不猜别名，不规范化..破坏链接语义；不把CWD当安全Shell输入证明。
- `a9f701b`：正式“终端选区→原会话SFTP定位”已编码/测试/构建。FRB本机resolve不联网，明确定位才父REALPATH/最终lstat，文件链接选原条目；原ID/代次/目录请求/定位请求复查，迟到结果不覆盖用户新导航。A失焦不改B，菜单不跨重连，Future.sync接同步拒绝；FilesPanel一次性选择/显示隐藏目标/虚拟行滚动，无PTY注入/正文/传输。见TERMINAL_PATHS.md、WORKBENCH_VALIDATION.md。

## 最新节点实际验证（OSC7跟随）
- 完整Rust190项（.local/osc7-follow-rust-all.log）、Clippy拒绝警告、正规FRB2.13生成/匹配Native、Analyze通过。OSC7核心8项、term-core全部32项、真实双SSH1项及上游VTE56/alacritty132项均通过。
- 完整Flutter147项（osc7-follow-flutter-all.log）通过；最终Analyze及Clippy拒绝警告、格式检查通过。真实双SSH跟随专项验证默认关闭/加密启停、侧栏隐藏延后/重显、authority不符不导航、挂起旧页后手动导航优先/忙时新报告优先、焦点隔离及布局/身份保持。仓库重开/旧字段兼容/草稿复制隔离及主机高级分类单次保存/每主机重载均通过。
- 原完整工作台真实GTK1项3:31通过（osc7-follow-workbench-gtk.log），全部既有主机/分屏/目录/Mousepad/编辑/复制移动/重扫保留；扩展路径定位/跟随GTK1项14秒通过（osc7-follow-gtk-fixed.log），实际鼠标路径定位→SFTP设置开关→单次加密保存→原终端标签→OSC7导航，ID/代次/其他会话保持且无新传输。validation/phase3b/directory-follow.png已查看，仅合成数据。
- 正规FRB2生成/匹配Native、NDK/API26 aarch64共享核心check通过（osc7-follow-android.log），不是APK/设备验收。正式workbench_main debug/release均重建，包内SO与target同模式SHA一致（osc7-follow-bundle-hashes.log）；两包独立GTK启动/resize/正常关闭wrapper/app均0，Rust加载，无Vault/历史/外部工作副本、预览残留0。
- directory-follow-startup-*.json仅密码框聚焦5秒：debug RSS453619712字节/CPU5.40%，release RSS287064064字节/CPU5.40%，旧样本保留，不作长期泄漏/终端空闲优化/Windows或Android结论。新全量测试中4000个OSC7报告合并为2次元数据事件、Native frame_pulls=0，200ms静默无新通知；此前单测实测1次，按批次/调度可变化，不声称固定1次。
- 红测/夹具与源码编译错误均修复、日志保留。新组件需等待主机单击的双击判定窗口，GTK需点击单标签组真实终端标签而非不存在的返回按钮；均未改产品交互迁就夹具。高级分类保存现已单次完成基本字段验证/加密保存，准备及保存期禁止切换，验证失败仍可编辑。详细测试见WORKBENCH_VALIDATION.md和TERMINAL_PATHS.md。
- 为磁盘余量，核对正式包SO独立inode后仅cargo clean本项目4crate的可再生成dev/release缓存，保留源码/包/日志/未知数据并重建；当前余量约2.8GiB。Flutter全量使用SHA核对的.local/osc7-follow-verified.so，不是交付库。

## 下一步直接开发
1. SSH代理/加密凭据/网络表单已提交991bda2；主机级时限/心跳及窄屏修复已通过完整Flutter154项和真实GTK25秒，正式双模式包及独立启动已验，见本文最新节点。接着实现已保存主机的明确握手测试，不认证/开PTY、不影响现存标签。OSC133阶段与冻结文本范围已稳定；可靠C/D历史锚点、Reflow映射及按命令复制/导航保留后续，禁止用phase或旧行号猜范围。
2. 安全Shell本地输入追踪，继而十项路径双向联动、合格单行命令加密历史与实时联想；不猜屏幕、不盲清行、不抢TUI/IME。CWD/OSC133自报本身均不能作为安全注入或采集证明。

3. 继续175项覆盖清单全部剩余：显示装饰/命令面板/链接通知/字体，完整跳板代理转发/tmux/内部Agent，文件并行/远端暂存审计与安全清理/跨服务器剪切/CRUD路径与编辑互斥，配置同步/备份/OpenSSH导入/平台密钥库，完整Windows原生适配和Android客户端/后台任务。未列细节仍以V1.4为准，不表示删除。

## 重要未完成/边界
- 选区显式定位不是自动路径/URL识别/Ctrl+Click，也不是路径发送；OSC133、安全输入、Android长按入口仍未接。OSC7跟随只接纳匹配实际SSH地址的authority或无authority自报，不猜IP/DNS别名；不匹配时绝对路径定位仍可用。不能把十项联动计完成。
- 远端未知暂存/发布结果尚须明确协调及安全清理；跨服务器剪切源删除须持久化每节点意图/ACK，不能删后来重建的源。现有不确定项保持失败保护、保留成果，不能盲重试/静默清掉唯一恢复记录。
- 旧F2/内部拖动CRUD仍待完整统一路径保护；当前同账户队列移动已有互斥，不等于全部CRUD已安全整合。
- WebDAV/Drive同步、完整加密备份合并/替换、DPAPI/Keystore、Android正式界面/SAF/前台服务等仍未完成；目标平台实机待验证清单见PLATFORM_VALIDATION.md。

## 恢复与常用命令
先读AGENTS/V1.4/本文/覆盖清单并检查git status/log/diff，不重做通过模块，不覆盖未知修改；从上面第一项继续。历史深入细节按领域文档查，不把旧在途入口当当前状态。完成独立功能测试通过后更新本文并提交；新长过程立即登记在途，不只等阶段结束。

- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；Cargo/Flutter原生构建和FRB生成前均export CARGO_INCREMENTAL=0。剩余空间约2.8GiB，清理仅通过可确认的可再生成构建缓存，保留正式包/日志/未知文件。
- cargo test --workspace --locked -- --test-threads=1；cargo clippy --workspace --all-targets --locked -- -D warnings；cargo fmt --all -- --check。
- ui_flutter内flutter analyze / flutter test --reporter expanded；不要并行运行两个Flutter桌面builder。GTK用benchmark/external_editor_gtk.py私有Xvfb/D-Bus包装，真实外部编辑器还用隔离Mousepad关联。
- API变化仅正规flutter_rust_bridge_codegen generate后cargo fmt，不能手改生成绑定。测试库副本.local/osc7-follow-verified.so不是交付物；新API必须匹配新Native。
- GTK/integration入口覆盖debug目录，交付前始终以-t lib/workbench_main.dart重新构建debug/release；lib/main.dart是原SSH验收，prototype_main.dart是独立Mock。构建后核对包内SO、独立启动/退出；无必要不重复昂贵全量回归。

## 当前稳定提交入口
- 通知合并层eec7baf已提交：小元数据修订、无网格复制、首份变化起16.667ms固定窗口合并，无变化不设timer，隐藏也能通知且不拉帧。
- `60bc94f`：完整可选跟随/加密偏好/单次高级保存已通过上述检查。150ms串行跟随只在明确启用、原连接有效/SFTP已初始化、当前焦点/工作页及侧栏可见时执行；不自动展开/初始化/重连，不改变真实Shell CWD。普通导航/新报告/失焦/收起/配置关闭/退出使旧页失效，错误不对同一报告无限重试。具体代码/边界/恢复入口见TERMINAL_PATHS.md；下一步直接实施OSC133，不在此模块暂停。


## 最新核心节点：被动OSC133阶段上下文
- 起点60bc94f干净。新增VTE typed ShellMarker→alacritty Event→term-core ShellState，标准A/B/C/D仅记录最新阶段/本次提示符序号/可选0..255退出值，无命令文字、历史条目或跨语言通知。未知顺序/次提示符/不支持属性、CAN/SUB/非ST ESC/参数截断/超限失效；真实备用屏幕进出/RIS/重排/断线/新PTY清上下文。C;cmdline属性仅忽略、不复制/诊断。共享完整ST处理与OSC7，其他OSC保持原行为。
- 最终7项新专项/term-core39项、完整真实OpenSSH40项、上游VTE56项/alacritty132项、Clippy/格式及NDK共享核心check通过（osc133-*日志）。匹配Native编译/SHA隔离测试库后，真实终端/真实Codex TUI合成provider/目录跟随3项26秒通过（osc133-native-regression.log）。20次Native生命周期样本RSS差192512字节，仅该窗口不作长期/平台结论；缺接口红测保留。
- 这只是远端自报阶段，不能证明POSIX Shell/回显/光标或可安全填字，不接命令历史/输入注入。尚无历史区间锚点/重排映射/按命令复制或导航，不能计OSC133增强已完整实现。本节点未改FRB公开API/Dart/存储格式，未重跑存储全量或Flutter147；正式双模式包仍60bc94f，当前Native源码已编译验证。提交号看git log，接着实现可信历史范围/导航与复制，不在核心节点暂停。详见SHELL_INTEGRATION.md；不把39+40专项误报为全量Rust198。


## 最新核心节点：冻结历史的流式文本范围读取
- 前置50237a2已提交，起点干净。新增SearchDocument.export_range半开网格范围，仅提供实际文本流，不推断OSC133范围来源；调用方须绑定同一冻结文档/可靠坐标，不能用旧快照冒充当前保留历史。无效坐标/拆分宽字符在写任何字节前拒绝；硬行中间去网格尾填充、软换行不造换行、明确末列保留选中空格，组合字符/中文/UTF8逐字流式写。
- 新缺方法红测保留（command-range-before.log）；6项范围专项/term-core45项、Clippy/格式和Android共享核心check通过（command-range-*日志）。冷历史只读范围及不填视口缓存、空范围零冷页、写失败立即返回，领先宽字符占位和末端拆字先拒绝均验证。未改FRB/Dart/UI/存储，未重跑全量，正式包仍60bc94f。
- 下一步核对上述检查、必要格式/交叉检查，记录此低层读取节点；随后实现保留历史内可靠C/D锚点/裁剪及Reflow映射，再接按命令复制/导航。不能仅凭phase/旧物理行号/text相同猜范围；尤其不能向Cell添加影响is_empty/重排字符的假占位。可考虑旁路稳定Row身份/位置变换，重排沿实际Grid操作映射，不从文本相似度重定位，未知时拒绝而非混入相邻命令。范围读取本身不是命令复制功能完成，无阶段暂停。

## 当前在途：单SSH代理
- 基于4b7bbe3添加HTTP CONNECT/SOCKS5，既有总Budget内新增Proxy阶段；无直连回退，不改变SSH实际目标身份/信任。协议7项通过，真实服务器/失败恢复仍在实施。Cargo.lock仅引用已锁定base64。代理认证缓冲零化/Debug脱敏；HTTP Basic及SOCKS密码在到代理的TCP链路是明文，后续UI须说明可信代理边界。代理配置尚未持久化或接正式UI，不能算应用功能完成。

## 已验证节点：SSH单代理核心
- 10项协议专项通过（含新增校验红测后修复方括号域名/IPv4误接受）；3项新增真实OpenSSH代理测试通过，共享PTY/SFTP及原目标指纹/变化保护，无认证降级或直连回退。完整ssh-core全部107项通过（含43项真实OpenSSH）；workspace/all-targets Clippy拒绝警告通过，格式检查通过。日志ssh-proxy-core-*；NDK结果以对应日志为准。无FRB/API/UI改动，正式包仍60bc94f；代理加密配置/表单在下个节点接入。协议/边界详见SSH_NETWORK.md，不计跳板/转发或应用代理完整完成。

## 当前在途：代理配置业务接入
- 单代理核心3aa85b8已提交；NDK/API26 workspace check通过，不是设备验收。新增storage-sync::ssh_proxy元数据与独立按host-ID归属的加密凭据，草稿/复制/删除/禁用认证原子处理；3项首轮仓库专项通过，补事务失败回滚测试与全仓回归在运行。FRB公开API/绑定已正规生成，后续增加真实凭据存在标记需再次生成。Dart正式模型/Store正在接入，网络表单及真实Native/GTK尚未验收；当前不可交付未匹配Native的UI。

## 代理接入中途验证
- storage-sync全55项通过；代理元数据/独立凭据/草稿/复制删除/禁用认证/故障回滚专项4项，正式表单/生命周期6项、Analyze/Clippy通过。正规FRB生成后编译匹配Native；真实两代理Native/OpenSSH/PTY/SFTP/加密库重开/副本与手动重连1项18秒通过（ssh-proxy-native-fixed.log）。首次无视图夹具未开启帧拉取导致等待画面超时，已按既有隐藏终端规则修复夹具，未改协议掩盖。
- 完整Rust/Flutter回归仍运行（ssh-proxy-rust-all/ssh-proxy-flutter-all），GTK真实网络表单/两图/正式双模式重建及独立启动仍待执行。存储及界面代码尚未提交，不能交付旧Native配新绑定。磁盘余量约0.5GiB，回归完成后只cargo clean本项目crate的可再生成缓存，保留正式包/日志/全部源文件。

## 代理最终回归与当前构建状态
- 完整Rust221项通过（ssh-proxy-rust-all.log，含43项真实OpenSSH），完整Flutter150项3:37通过（ssh-proxy-flutter-all.log，含真实Codex二进制/隔离合成provider，无账户凭据/付费请求）。20次Native生命周期RSS差339968字节，仅样本不作泄漏结论。Analyze及Clippy拒绝警告/格式/NDK workspace check通过。
- 网络表单/生命周期最终6项通过；真实GTK最终1项24秒通过（ssh-proxy-gtk-final.log），实际鼠标网络分类→填写认证→一次保存→原会话手动重连，ID/代次保持，界面不回读用户名/密码。第一次GTK夹具在attach前注册的合成指纹回调被App初始化覆盖，按既有夹具在attach后注册已修复；未改产品指纹验证。正式“代理认证已设置”状态文字已补并重新布局验收。
- PNG已生成并查看，保存validation/phase3b/ssh-proxy-{settings,workbench}.png；仅合成数据。Cargo clean仅本项目四crate可再生成dev缓存释放2.5GiB，正式包已核对独立inode、源码/日志均保留。当时debug/release workbench_main顺序构建；已在下节完成核对SO及独立启动，交付正式入口。

## 已验证交付节点：SSH单代理正式业务
- 正式workbench_main debug/release构建均通过（ssh-proxy-build-*.log），包内SO分别与target同模式SHA一致（ssh-proxy-bundle-hashes.log）。两包独立GTK启动/resize/正常退出wrapper与app均0，Native已加载，无Vault/终端历史/编辑工作副本，预览run残留0；当前正式包已更新为本代理节点，不再是60bc94f。
- ssh-proxy-startup-debug.json样本RSS458969088字节/CPU5.40%，release283807744字节/CPU4.80%；仅锁库密码框聚焦5秒窗口，与旧directory-follow样本并存，不作长期泄漏、终端空闲优化或目标平台结论。完整回归/最终GTK/NDK检查见上文；所有测试均真实执行，未跳过失败。
- 下一步直接接通主机级SSH超时/心跳编辑控件（已有Rust核心/存储字段，避免重做）；保持全功能连续策略。全局默认/独立响应超时、连接测试/跳板/转发、可靠命令区间锚点、其余覆盖清单仍未完成，不在此节点暂停。

## 当前在途：主机级超时与心跳表单
- 代理正式业务已提交991bda2，工作区起点干净。接通既有timeout_seconds/keepalive_seconds/keepalive_failures的Dart模型与主机网络表单，保留草稿/复制/重开语义，不把UI原型值冒充已生效配置。新增字段校验与真实代理阻塞后的总超时、心跳超时/关闭及手动重连验证。全局默认/独立响应超时仍另列未完成；本节点不改变总Budget/不自动重连。

## 主机时限/心跳实施中途验证
- 已接通DemoHost快照/副本/Live映射→既有HostConfig存储字段→核心ConnectConfig；网络表单总超时1..3600、心跳0..86400（0关闭）、失败阈值1..100，校验回网络页及原字段聚焦，草稿/正式保存区分不变。无Rust/FRB API变更，已有221项Rust证据仍对应同一核心。
- 新真实Native总超时/取消与丢心跳2项通过：1秒预算确实在Proxy阶段失败，保留标签；8秒重试可取消；1秒/1失败配置下，暂停合成代理转发会明确断线并保留画面，不自动重连；明确重连后0间隔跨4秒同一停流窗口保持连接，仍可手动断开。日志ssh-timing-fixed.log（连表单共5项23秒）。首轮新测试同isolate重复初始化FRB已移至setUpAll；代理字段新增前置时限后需要ensureVisible点击，已修复夹具未关闭命中警告。
- 新增640x480逻辑尺寸/1.5缩放表单布局与边界值测试待最终结果；完整Flutter回归、扩展GTK时限控件/加密保存/重连与PNG、正式双模式重建仍待做。全局默认及独立响应超时未实现，不将本节点计为§3.2全部完成。

## 主机网络窄屏修复与最终回归在途
- 640x480逻辑像素/1.5缩放复现主机页底部固定横排32px溢出，已改可用宽度<400时两行操作，普通宽屏排列保持；时限字段<420竖排。统一使用既有save()保护，而非按钮另行切页后重复准备。最终布局/代理表单/生命周期8项5秒全部通过，Analyze无问题；未靠丢弃异常/禁用命中警告通过。
- 代理停流夹具无真实账户/费用/生产资源，协议原样转发，只在显式测试标记后阻塞。缺方法红测/重复初始化夹具失败/布局溢出日志保留。当前完整Flutter回归运行ssh-timing-flutter-all.log，之后实际GTK时限表单及加密保存/重连、三图与双模式构建/独立启动，未通过前不提交本节点。

## 主机时限/心跳完整Flutter回归
- 最终完整Flutter154项3:41全部通过（ssh-timing-flutter-all.log），包含新2表单/2真实Native时限心跳试验，以及既有真实Codex/编辑器/传输/未知移动/OSC7回归。Analyze无问题，diff检查通过。本节点没有更改Rust/FRB/存储格式，核心仍991bda2/221项Rust与既有NDK检查，不冒称新增Rust测试。
- 当前扩展GTK网络页→改总超时19/心跳0/阈值4→单次加密保存→真实HTTP手动重连验证中，成功后脚本顺序重建workbench_main debug/release（ssh-timing-gtk/build-*.log）。截图将另增加ssh-network-timing.png并更新代理两图；构建后独立启动和提交仍需完成。

## 已验证节点：主机级时限、心跳与窄屏操作栏
- 最终扩展真实GTK1项25秒通过（ssh-timing-gtk.log），总超时19/间隔0/阈值4经实际表单鼠标单次保存，Native读取一致，HTTP明确重连后会话配置一致，其他活动SOCKS会话ID/代次保持。三图已查看/保存；完整Flutter154、Analyze/格式/diff通过；Rust/FRB未改，沿用同核心221项和NDK证据。
- 正式workbench_main debug/release重建通过（ssh-timing-build-*.log），两包SO与target哈希一致（ssh-timing-bundle-hashes.log）；两包独立启动/resize/正常退出wrapper与app均0，无Vault/历史/外部工作副本、预览残留0，当前正式包包含本节点。
- ssh-timing-startup-debug.json样本RSS451907584字节/CPU5.00%，release286396416字节/CPU4.80%；仅锁库密码框聚焦5秒，不作长期泄漏/目标平台结论。前后代理/跟随样本保留。
- 下一步继续保存主机手动握手测试：复用SSH核心test_connection与总Budget/TOFU，界面须区分“不验证目标登录”，可取消/关闭清理，不建PTY或标签、不自动重连。全局默认/独立响应超时及所有其他覆盖缺项仍保留。

## 当前在途：明确握手测试
- 起点3437a28干净，先为ManagedSession加入不认证/不开PTY的可取消探测操作，复用原Budget/TOFU/生命周期，保留画面/历史；再接FRB/主机页。正式双模式包仍3437a28，未将核心方法当作GUI完成。先写真实OpenSSH生命周期/忙状态/取消及关闭测试，红测日志ssh-probe-*。

## 明确握手测试核心首轮
- ManagedSession.test_connection已接同一串行actor/Busy及代次/Budget/TOFU；无Authentication参数，不开通道/PTY，成功回Idle或原已断线状态，不重排/重置/改历史或插重连标记。丢弃Future以原子代次token的drop_guard取消该次探测，不能取消后来的连接；取消/关闭共用现有生命周期。
- 缺方法红测后，两项新真实OpenSSH首轮1.45秒通过（ssh-probe-core-first.log）：不存在用户仍握手成功、输入/SFTP不可用、在线Busy不影响原PTY、断线屏幕/修订保持、变化密钥阻止；确认等待可取消、abort调用方、关闭并释放，均不会成为Connected。当前完整ssh-core/Clippy/匹配Native编译运行中（ssh-probe-core-*/native-build），之后继续FRB/正式页，不把本核心节点计作按钮已接入。正式包仍3437a28。

- 明确握手核心最终ssh-core全部109项（含45项真实OpenSSH）通过，workspace/all-targets Clippy拒绝警告、格式、NDK共享核心check及匹配Native编译通过（ssh-probe-core-*/native-build）。当前正在跑真实Native/Codex/两代理/心跳与超时5项回归（ssh-probe-native-regression），无公开FRB变更；正式双模式包仍3437a28，不混报新核心已重建正式包。

## 已验证节点：ManagedSession握手探测
- 最终真实Native/真实Codex合成provider/代理/时限心跳5项53秒全部通过（ssh-probe-native-regression.log），20次Native生命周期RSS差-7618560字节，仅此样本，不作优化/无泄漏结论。ssh-core109项、workspace/all-targets Clippy拒绝警告/格式/NDK check通过。无FRB公开接口或Dart改动，本节点未重新运行Flutter154全量，也未重建正式双模式；正式包仍3437a28，匹配新核心Native已编译且上述5项通过。
- 下一步实际接入FRB及主机页测试连接：仅正式保存配置可测，未保存编辑不能隐式写成正式配置；短生命周期隐藏controller，不创建可见终端标签；原目标TOFU确认/目标变更复查、可取消、退出等待清理。测试结果明确不证明目标认证成功。接着所有覆盖缺项，不在核心节点暂停。

## 当前在途：正式握手测试桥接/界面
- 核心稳定提交2bb0812；当前新增connections::configuration统一正式连接/探测的路由与时限快照（不在探测读取目标SSH凭据），test_host_connection复查原host-ID/地址/端口/用户并复用原TOFU。正在正规FRB生成新绑定，Dart控制器/主机页与新桥接测试待实现/验收，源码在途不可交付混配Native。正式双模式仍3437a28。新增connection_test_bridge_test缺方法红测保留。

## 正式握手桥接/弹窗实施中
- connections::configuration统一正式登录与探测路由/时限，探测不读取目标密码/私钥；test_host_connection复核保存host-ID/地址/端口/用户再网络与TOFU。正规FRB已生成、Clippy及匹配Native编译通过。新增HostConnectionTest只持隐藏短生命周期Controller，等待创建/FRB流结束，成功/取消均释放，不造标签或最近连接。Live模型退出先取消测试，完成Future身份绑定取消，旧弹窗不能取消后来探测。
- 正式主机页按钮已编码，未保存编辑仅提示先保存（不隐式写正式配置）；原目标快照/进度/取消/失败/握手通过及“不验证目标登录”说明。弹窗挂载后启动，避免构建中通知；关闭等待取消，dispose携带原Future作用域。明确取消不写全局错误，返回Future仍保留取消结果给调用方。
- 两项真实Native桥接首轮7秒通过（ssh-probe-bridge-first.log）：无效目标账号密码仍握手成功/首次TOFU及加密复用、无标签/任务、停流代理取消后EOF释放。3项弹窗首轮通过：未保存不联网、原目标快照/结果范围、取消等待资源与Future身份。追加调用方过期取消不影响后来测试/Native边界目标复查/待创建取消及隐藏零帧清理后，目前7项最终专项运行ssh-probe-bridge-final，Analyze lint修复后已重新执行。完整回归、真实GTK嵌套TOFU弹窗/取消、双模式构建仍未验，正式包仍3437a28。

## 握手测试完整回归在途
- 7项新最终专项7秒通过（ssh-probe-bridge-final.log），含Native地址/端口/用户边界复查、过期Future取消不作用后来探测、创建中取消、隐藏零帧/不登录/一次释放、3项真实按钮语义组件；Analyze通过。追加同一停流代理下应用shutdown取消/EOF，显式取消不报全局错误。
- 当前完整Rust/Flutter回归分别ssh-probe-rust-all/ssh-probe-flutter-all运行中；新增integration_test/connection_test_test.dart待真实GTK，使用App默认首次TOFU弹窗实际“信任并保存”，不用fixture接受回调，验证无效目标认证账号仍可报告握手范围，随后停流代理取消。待PNG/NDK/正式双模式构建及启动。可用磁盘约0.7GiB，待两套回归结束后按已验证Cargo清理四crate dev缓存（当前不可清正在使用库），保留正式包/所有源码日志。

## 正式握手测试完整回归通过/GTK在途
- 完整Rust223项通过（ssh-probe-rust-all.log，含45项真实OpenSSH），完整Flutter161项4分钟通过（ssh-probe-flutter-all.log），包括新增7项专项/实际退出取消停流连接、旧取消作用域及既有真实Codex/编辑器/传输恢复。两进程退出0已确认；正规FRB、Clippy、Analyze/格式通过。
- 确认包内SO独立inode并保存当前全量测试Native SHA后，仅cargo clean本项目四crate dev可再生成缓存，释放2.1GiB；源码/日志/3437a28正式包保留。当前真实GTK首次指纹/测试范围/取消→代理网络页回归→正式双模式构建按依赖串行运行（ssh-probe-gtk-first/network-gtk/build-*）；NDK新API check并行target运行，不是设备验证。失败须先修复，未声称GTK/新正式包已通过。

## 握手GTK已验与长目标弹窗修复在途
- 真实GTK首次TOFU/握手范围/停流取消1项11秒通过（ssh-probe-gtk-first.log），App真实“信任并保存”点击，无fixture接受回调；无效目标用户名/密码仍只验证握手，无标签/最近/SFTP，取消等EOF并无全局错误。网络时限/代理GTK回归1项26秒通过（ssh-probe-network-gtk.log），NDK新API check通过。首轮正式双模式构建通过，但尚未独立启动/提交。
- 补合法长度的长主机名/地址/用户在640x480逻辑尺寸/1.5缩放的弹窗测试，实际复现竖向溢出（ssh-probe-long-target-before.log；更早超规格夹具日志单独保留，不作有效需求结论）。已用AlertDialog.scrollable修复，底部关闭/取消保持可达。当前8项新专项/最终完整Flutter162项重跑中（ssh-probe-final-eight/ssh-probe-flutter-final-all）；通过后重新GTK/最终双模式及独立启动，不能将首轮包当最终标记。

## 握手测试最终全量通过/最后GTK与打包
- 滚动弹窗修复后8项专项通过，最终完整Flutter162项3:48通过（ssh-probe-flutter-final-all.log），Analyze无问题；完整Rust223项/Clippy/格式/NDK同最终Native代码，未重跑无更改Rust。当前仅最终GTK探测与workbench_main双模式构建顺序运行（ssh-probe-gtk-final/build-final-*），之后核对哈希/独立启动、归档冗余进度并提交。没有新增未测试功能。

## 正式握手测试已完成当前Ubuntu验收
- 最终GTK真实信任/范围/取消1项11秒通过（ssh-probe-gtk-final.log）；网络时限/代理GTK1项26秒通过。合法长元数据弹窗通过滚动布局保持关闭可达，最终8项专项/完整Flutter162项3:48通过；Rust全223/Clippy/Analyze/格式/NDK新API check通过。
- 正式workbench_main debug/release最终构建通过（ssh-probe-build-final-*.log）；包内SO均匹配target同模式哈希（ssh-probe-bundle-hashes.log）。两模式独立GTK启动/resize/正常退出wrapper/app均0，Native加载，无Vault/终端历史/外部工作副本，预览残留0。connection-test.png及更新的network-timing/proxy-settings/workbench三图均为实际合成夹具截图，connection-test及前两节点图片已查看。正式包现已包含完整手动握手测试，不再是3437a28旧包。
- ssh-probe-startup-debug.json样本RSS452517888字节/CPU7.40%，release280256512字节/CPU5.40%；仅锁库密码框聚焦5秒，与旧样本并存，不作性能优化、长期泄漏或目标平台结论。下一步继续最多一级跳板等剩余网络模块，不在本功能节点暂停。
