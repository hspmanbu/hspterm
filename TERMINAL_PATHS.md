# 终端工作目录与远端路径

V1.4 §4、§5.3A 的被动 OSC 7 核心基础。仅消费已认证 SSH 字节流，不安装 Shell integration、不执行 pwd/hostname、不猜屏幕提示符。OSC 7 不是普通 Shell 安全输入状态证明，不据此开放路径注入/命令历史采集。

## 解析和生命周期

通过既有 vte/alacritty_terminal 解析器的类型化 Handler/Event 收集，未另建字节流扫描器。只接受 file://authority/absolute-path，严格单次百分号解码和UTF-8；拒绝userinfo/端口/查询/片段/控制字符/非法转义，16KiB上限。路径保留空格、中文、分号、百分号、引号及原始斜杠/..，不作Windows PathBuf或URL路径规范化，避免改变符号链接语义。无效新报告清掉旧上下文。

URI中分号作为字面量，不受普通OSC参数数组上限截断；OSC 7必须BEL或完整ESC\终止，CAN/SUB/其他ESC中止时不得发布。整体超限OSC的丢弃回调清掉被动目录，避免沿用旧值。其余OSC派发保持原行为。DECSET2026中与真正画面一起提交，不抢先公布。

上下文按Terminal独立保存，未进入终端字符、导出、诊断、配置/备份。备用屏幕进出、RIS、断线提交及新PTY代次清除；TUI内OSC7不接纳。重排和历史滚动不猜新目录。Debug只显示redacted，不含目录。

## 路径语义

resolve_remote_path仅解析字面POSIX路径：绝对路径不依赖CWD，其他路径要求OSC7 authority与实际SSH地址一致（DNS大小写/尾点、等价IP可匹配）或无authority且仅归属发出它的原SSH流。authority不同不做DNS/别名猜测，退化为绝对路径；localhost不自动等于任何远端服务器。不会解Shell引号、展开~或变量，也不剥离歧义的行列后缀。输出只是路径，无网络访问/PTY输入。

OSC7来自远端进程的自报，不能认证嵌套SSH/容器身份或Shell种类；authority不匹配时拒绝相对路径。显式定位/跟随只允许原nativeID/代次，网络回包还须再次校验。

## 实施边界与验证

当前核心已接WorkingDirectory及Snapshot元数据；正式终端选区→原会话SFTP定位已接。可选目录跟随已接（见后节）；自动路径/URL识别及安全输入发送仍待做，不计十项联动全部完成。7项专项覆盖每个双分片位置、中文/百分号/大量分号、无效/超长/被中止序列、完整ST、备用屏幕/重置/断线/重连、同步提交、主机隔离与保留..语义。真实双Transport OpenSSH测试验证自报目录仅在原终端、断线保留文本且清掉目录、新代次不继承旧值。Ubuntu默认Shell本身发送OSC7，测试仅在隔离SSH会话unset PROMPT_COMMAND/PS1，不改任何远端配置文件。

协议参考：[WezTerm OSC7](https://wezterm.org/shell-integration.html#osc-7-escape-sequence-to-set-the-working-directory)、[kitty开发者说明](https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers)。本实现不注入其中的Shell脚本；kitty-shell-cwd私有URI扩展暂不接纳，绝对路径定位不受影响。


## 明确选择路径定位

FRB resolve_terminal_path使用原Entry记录的实际SSH目标/代次，只读取终端元数据，不联网；sftp_locate_terminal_path仅在用户明确动作后复用该Transport的SFTP查询父目录和最终lstat。父目录由服务器REALPATH解析，保留链接/..真实语义；文件链接选原链接对象，不隐式跳转至链接目标。普通目录打开，文件打开父目录并选择；不读取正文、不传输、不更改PTY/CWD。

正式TerminalView仅在有本地选区及已连接会话时提供“在关联 SFTP 中定位”。远端鼠标捕获优先，Shift+右键仍可使用本地菜单。菜单固定源Controller/代次/文字，过期/重连/换Controller时拒绝，不把同一回调指向新会话。复制/粘贴和最小SSH验收入口保留，Mock不连接Native。

LiveWorkbenchModel绑定原session/nativeID/代次、最新定位请求及原目录序号，跨异步步骤复查。原目录被用户导航/新定位替换后，迟到结果不覆盖；定位A过程中焦点切B时仅更新A，不改变B目录或展开B侧栏。匹配原焦点时可打开原侧栏，但保持宽度/队列布局。一次性RemoteFileLocation只在内存，FilesPanel消费后清空，显示隐藏目标/清本地过滤并滚动至可见行；不做系统文件拖放或输入注入。

测试：terminal_path_bridge_test.dart真实双OpenSSH覆盖中文/特殊名、相对路径/authority不符/绝对兜底/过期代次/文件链接、延迟原目录页后新导航保持；terminal_path_ui_test.dart覆盖远端捕获与Shift覆盖、旧菜单重连拒绝、虚拟列表隐藏目标。integration_test/terminal_path_test.dart在真实GTK中鼠标拖选文件名→正式右键菜单→原SFTP，260个目录之后的隐藏文件滚动选中，原Transport/代次/其他会话/文件正文保持且未创建传输。截图validation/phase3b/terminal-path.png仅合成回环数据。

人工补验：普通Shell发送现成OSC7后选绝对/相对路径，经本地右键定位；无CWD或authority不同的相对路径应明确拒绝，绝对路径仍可。Vim/tmux开启鼠标时先验证普通右键交由远端，再Shift+右键本地定位；删除/断线/重连旧菜单不可操作其他会话。Windows原生鼠标/IME及Android长按菜单尚待对应平台接入/验收。


## 小元数据通知（跟随前置）

Terminal的目录修订独立于输出/网格修订：重复报告、普通输出和重复失效不递增。directory_context仅复制有界路径元数据，不读取/克隆任何可见网格或冷历史。原resolve_terminal_path已改用此读法。Actor每轮合并到最后一份变化，FRB watch_events以首份变化起16.667ms固定窗口继续合并最新值（新报告不延后窗口），每窗口至多一次小事件；无变化不设定时器，无需renderer/帧拉取，断线None同样通知。事件只携带被动自报，不作为已验证端点或安全Shell证明；本通知层不直接执行导航；保存选项与正式跟随见后节。

新真实Native在隐藏终端发送4000个OSC7报告，最终值可解析且实测仅1次跨语言元数据事件、Native frame_pulls为0，随后200ms静默无额外通知。真实SSH专项验证无renderer时的路径事件及断线失效，term-core32项、相关Native/可见性4项、Clippy/Analyze/格式及NDK共享核心check通过；不是全量189项或目标平台实机结论。正式包仍a9f701b，通知层匹配Native已编译，不把它当完整跟随功能。


## 可选OSC7目录跟随

HostRecord.follow_osc7默认false、旧记录缺字段默认为false；与open_sftp独立，位于既有加密主机/草稿记录，复制主机继承配置但凭据依然独立。HostConfig正规FRB Option<bool>保留旧构造调用的默认关闭语义，正式映射总是带当前值；DemoHost snapshot/copy及主机管理SFTP分类读写对应字段。仅正式保存生效，未正式保存的草稿不改变运行策略。高级分类单次保存会先等待基本Form挂载后验证，准备/保存期间禁止切换，验证失败可继续编辑。

TerminalController只把workingDirectory事件记为“未验证自报版本/文字”；状态或代次失效清除，不用它证明Shell输入安全。terminal_working_directory在Rust校验原实际SSH端点与代次，仅本机读小元数据；未知/authority不符返回None，没有SFTP探测/自动连接。配置地址为IP、远端报告不同hostname时不会猜别名或DNS，应使用匹配报告或绝对路径定位；不宣称任意nested SSH/容器报告都能可靠关联。

LiveWorkbenchModel只协调一个当前焦点目标：明确启用、原连接有效、SFTP已初始化、当前工作页/侧栏可见时，150ms固定窗口合并到最新报告。无新报告不设持续timer，不因报告展开侧栏/创建SSH/初始化未启用SFTP。隐藏时保留版本，重新可见/切回原终端只处理未消费报告；目标不变不重读目录。侧栏宽度/队列布局保持。

普通导航/选区定位会消费当前报告并取消旧跟随；新报告、失焦、侧栏收起、配置关闭、代次改变或退出使旧请求token失效。在途目录页还有原directoryEpoch校验，不能用迟到页覆盖用户选择。旧读取完整关闭/退出后才继续最新报告，活动跟随至多一个。网络失败明确显示在SFTP，不对同一失败报告无限定时重试。跟随读取不写文件/传正文/发PTY输入，不更改真实Shell CWD；只是浏览器导航响应远端自报。

真实双SSH模型专项覆盖默认关闭、正式保存/关闭、收起/展开、authority不符、明确导航取消被挂起旧页、忙时新报告、焦点切换/恢复与身份布局保持；实际GTK点击SFTP配置→单次加密保存→点击原终端标签→新OSC7驱动原SFTP，截图validation/phase3b/directory-follow.png。全部测试及正式包状态以PROGRESS最新记录为准；本功能不等于OSC133、路径发送或Android长按入口已完成。

## OSC8及明确file URI定位

resolve_remote_reference仅为终端引用增加file URI入口，原resolve_remote_path仍处理原样POSIX路径。URI只解码一次，保留百分号、中文、引号、分号、括号及斜杠/..；不调用URL路径规范化、Windows PathBuf或本机文件打开。大小写file方案可接受；authority为空表示输出它的原SSH流，有authority时须与原实际SSH目标匹配（包括IPv6语法归一），不猜DNS/hostname别名，不把localhost视作任意远端机器。此绝对URI不依赖OSC7 CWD；普通相对路径仍须原可信CWD。

userinfo、端口、查询/片段、非法百分号/UTF8、解码后控制/双向控制均拒绝。Flutter remoteFileUri与浏览器uri/port字段分开；CtrlClick或本地菜单只调用原source的SFTP定位，不创建转发/新连接，不打开本机文件或下载正文，即使是file:///C:/...形状也只解释为远端路径。明确OSC8目标不回退激活伪装标签URL；普通未引用file URI保留尾部标点，对引号/包裹等歧义退化到手动选择，不猜测截断文件名。

Native原URI目标/代次与SFTP目录请求守卫均复用原链路；hover只显示目标，不改目录或创建任务。原选区定位同样可明确定位file URI；文件夹在原SFTP进入，文件选择父目录中的原对象。真实双SSH与GTK证据见OSC8_LINKS.md和PROGRESS；Windows/Android实机、Android长按以及更多path:line识别仍待做。

## 相对路径复制静态批次（2026-10-29，未统一验证）

SFTP菜单新增「复制相对路径」。仅当原SSH已连接、原代次/实际目标匹配且OSC7目录authority可接纳时，提供当前目录及其子树的字面POSIX相对表示：自身为`.`、子项以`./`开头，避免选项型文件名被当作参数开关。保留空格、中文、引号、美元符号、百分号及文件名换行，不展开变量、不解Shell引号/URI、不作Windows路径转换。

不生成`..`：逻辑CWD穿过符号链接时，父路径归约可能改变含义。非子树、含`.`/`..`/中间空分量、双斜杠根或不可靠CWD时禁用该项并保留绝对路径复制，不执行REALPATH、pwd或任何附加网络查询。此范围是安全可确认的相对表示，绝不把未知路径猜成父目录跳转。

菜单前仅本机读一份有界预览，点击时用原目录修订重新核对；工作目录、连接或文件选择改变则拒绝迟到复制。选中文件/路径在菜单前固定，菜单请求代号避免晚完成的旧右键请求覆盖新操作，退出/切页时不迟到弹菜单。可用性读取失败只展示禁用原因，不反复报全局操作错误；已开始RPC仍纳入退出等待。

Rust与Dart均限制最多1024路径/总UTF-8 1MiB；Dart在FRB复制前检查。结果只去本机文本剪贴板，不发送PTY按键、不导航/初始化SFTP、不上传/下载、不改变Shell CWD。并不据OSC7推断Shell种类或开放路径注入。

新增核心2项、Flutter菜单3项、真实双SSH Native1项测试源码，全部未执行；新增1个API及DTO尚未FRB生成。Native源覆盖原会话authority、修订改变、隐藏零取帧、断线、字面百分号和无SFTP/任务副作用。菜单源覆盖明确复制、未知目录禁用、旧目录拒绝、退出期间迟到结果。仅格式化解析与diff检查，不算编译或实测。

统一运行后的人工步骤：同会话OSC7目录与SFTP目录相同/下级时复制多选相对路径，检查剪贴板、中文及特殊名；打开菜单后改变CWD，再点复制须明确失败；陌生authority/上级/符号链接父归约时禁用相对项，绝对/引用路径复制仍保留；全屏TUI中不向终端发送任何数据。Windows原生鼠标实测仍待目标平台。


## 2026-11-03 普通路径及行列引用（源码，UNVERIFIED）

新增Flutter只读显示识别remote_reference：绝对/显式相对/含目录分隔的字面POSIX路径，带扩展名的文件名，以及 `path:line[:column]`（可含编译器末尾冒号）。单token至多4096 UTF16单元，行列1–999999999；不把变量/tilde/Windows盘符/反斜杠/URI/控制及双向控制当作该路径。空格/引号/歧义包裹路径继续用OSC8或原选区定位，不能猜截断。没有扫描其他历史/联网/文件探测/PTY输入，原文及真实缓冲完全保持。

URL/IP/localhost端口保持原浏览器或转发链路；形似文件名的非回环host:port也可能是路径，保留地址复制并必须在路径选择界面确认，绝不因识别而解析DNS/探测。OSC8仍只接受既有许可URI：非法显式目标屏蔽标签，不能回落将标签当路径。

Ctrl+Click/本地菜单经原terminal_links分流到同一会话SFTP。带行列引用默认取消，明确选择剥离行列的文件路径或“按原文路径定位”，因为冒号数字可能是合法文件名；无行列的单文件名也先确认。行列仅信息提示，本动作只定位文件，不声称编辑器已经跳到该行。选区菜单增加含行列引用的选择入口，同时保留原字面选区定位。原nativeID/generation和标签身份跨确认复核；断线/重连/标签关闭不将迟到确认发给别的会话。

最终路径解释与SFTP请求仍由现有Rust resolver/ManagedSession校验实际SSH authority及匹配OSC7目录；未知CWD的相对引用明确失败，不猜当前浏览器目录、不展开变量、不执行pwd。文件URI仍独立单次解码，不交本机浏览器；新普通路径不做URL解码、父目录归约或命令注入。复杂TUI鼠标捕获/Shift本地覆盖保持。

新增2项纯识别/宽字软换行与OSC8优先测试、3类明确确认分支及重连失效4项Widget源码，共6项，全部未执行；旧路径URI/真实私有SSH解析与原终端入口均保留。只Dart format/diff，未Analyze/编译/实际窗口或服务器验证。真实路径含冒号/中文/冷历史、无CWD/换焦点及原菜单TUI回归留统一阶段。
