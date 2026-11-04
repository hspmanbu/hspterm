# HSPTerm 开发恢复约定

- **当前内存反馈任务（2026-11-04）**：用户Windows启动200多MB、设置300多MB。已核实Windows run41813471598实际成功（MSVC/Analyze/启动退出，Artifact13314479216）；旧“尚无成功Windows包”已过时。发现设置挂载即枚举/布局最多4096字体，正在改为打开选择器时枚举+搜索虚拟列表。真实Release对照在validation/settings-memory-2026-11-04；Ubuntu相同4096目录首次增量180.51→35.52MiB，不能推断Windows实测降幅或长期无泄漏。19组件测试/真实SSH字体GTK通过、Analyze0项；正式release已恢复workbench_main入口并构建/真实启动退出成功，下一步提交触发新Windows包。工作区改动属于本轮，不覆盖或清理。原GitHub导入/失败记录见PROGRESS；不重跑旧import/force，完整旧历史在development-history。

- **最新恢复入口（2026-11-04，Ubuntu适用统一验证已收齐）**：Windows正式源码98fb042及后续测试风格修正已验证；完整Rust647、新锁Bridge75/SSH255、VTE56/alacritty178通过。Flutter按53中断+56续测去重507项/143文件均过；最终57号Analyze0项、305Dart格式/Rust格式、正式debug/release启动清理退出及Native散列全过。GTK29及新锁Kitty/Codex/SSH、19场景性能已过。没有在途runner或暂停进程，别重启旧53/56/57脚本；读PROGRESS顶部和validation/windows-unified-2026-11-04/README.md/results.json即可恢复。Windows MSVC/C++实际构建及系统行为、真实云账号仍待环境；Android暂缓。后文“静态阶段/未生成/待Shell决定”是历史，不能重复开发或恢复旧问题。

- 工作目录 /opt/hspterm；V1.4 是唯一产品需求基线。
- 最新明确决策（2026-11-03）：用户选择允许逐主机主动启用可选Shell集成，已写V1.4末尾；旧“等待Shell决策”已解除。默认false，复制重置，临时覆盖不继承；源码新增Bash助手/同VTE私有协议/输入跟踪与原actor Native历史sink。候选UI/受控动作/实际回执/同源路径插入及启动回退已新增静态源码，均待最终统一生成验证，详SHELL_INTEGRATION最新节与PROGRESS，不重复提同一许可问题。
- 最新恢复（2026-11-04）：19567d8后同步停用取消/准入回执与排序格式分类已修；OSC133实际Bash重绘覆盖证据确认，生产proof不放宽，静止Native1/实际SSH2通过。旧session失效已按日志恢复，剩46文件见/tmp/hspterm-flutter-file-results-7.json；debug工作台构建在途。最新细节读PROGRESS/UNIFIED末节，不将旧夹具失败当功能缺失，不启动重复runner。
- 最新续修（2026-11-04）：f86329e后修复SSH CLOSE确认、Bash中文/提示符缓存重放、Explorer/候选/确认状态；Bridge75与term-core42全过，OpenSSH局部13、Flutter交互回归及Analyze已过。完整Flutter第三轮/修正后OpenSSH126/原storage-sync213及release Native仍在途，详UNIFIED_VALIDATION.md；先确认进程/日志，不重复runner或回退源码期。
- 最新执行入口（2026-11-04）：b42cb1b后已进入最后集中生成/验证阶段，已正规FRB/两锁解析；Flutter Analyze 0项、workspace全目标check及严格Clippy通过，Python22项通过。真实运行测试/应用构建进行中，先确认Git和UNIFIED_VALIDATION.md及在途命令，别退回“尚未生成”的旧节点；最后完整已验仍0e96be4。
- 最新范围（用户恢复开发指令）：优先完善Windows，Android开发暂缓；清理工作已由用户处理，不再次清理其文件。现已恢复编码，不再沿用清理后的等待要求。共享核心保持可移植，Android不从最终需求删除。
- 最新执行策略（2026-10-28用户再次明确）：先连续编制全部剩余功能并进行跨层静态审查，最后统一在当前环境生成绑定、编译、测试、调试与修正；不逐模块启动构建或回归。源码完成/静态审查/运行验证分别记录，未验证不得称完成；旧在途验证先确认/保存再停止，不盲重跑。
- 每次会话先完整阅读 HSPTerm_最终需求规格_v1.4.md、PROGRESS.md，检查 git status、近期提交和未提交 diff。
- 从 PROGRESS.md 的下一步继续；先确认中断操作结果，不覆盖或清理未知修改。
- 当前用户指定静态编制期：先更新PROGRESS并保存源码，测试留统一收尾。可建立明确标注未验证的源码检查点提交，不能写成测试通过；集中验证通过后再创建稳定提交。重要节点立即保存进度。
- Explorer目录/普通文件正式拖出续作：现统一走transfers::explorer真实TreeTransfer源任务（不跟随最后链接），不再用每文件预览冒充目录队列。元数据扫描先停，Native请求才完整下载；一个目录一个FIFO任务，缓存/已确认偏移本机保留，ExportReady可从队列离线重新拖出。交付租约+逐文件本机读租约阻止早删缓存/切库；DragEnd不是消费结束，onDisposed及实际workers共同退休；显式“结束所有Explorer交付”及退出排空原请求。详WINDOWS_EXPLORER_DROP最新节，所有新源码未统一生成/编译/运行。旧reserve_explorer_file_export保留独立普通文件快照API，绝不改回允许解析末级链接的Purpose::Open。
- 原生固定super_native_extensions0.9.1维护补丁/准备器仍有效：最终pub get之前（flutter clean后也要）运行tools/prepare_native_extensions.py，生成忽略目录下显式fork，不改pub缓存；尚未执行准备器/依赖解析。原HWND OLE保留属性必须先于RegisterPlugins。目录扫描新增entry_limit早停，但普通任务保持原1m预算；Native整批32768项/128根/259UTF16规则不得截断。
- 不提交真实凭据、私钥、Token、真实服务器配置、测试生成的秘密或输出。
- 未编译/未运行/未验证的功能不可标为完成；平台缺失必须列明。
- 不自动重连 SSH，不增加本地 Shell；不可为增强功能修改原始终端内容。

- 字体/排版在storage-sync::typography、terminal/typography及workbench/typography_*；当前静态批次尚未生成新增API绑定/编译。元数据local-terminal-typography-v1和device-terminal-font-v1-*仅设备本机，禁止云同步字体正文/本机映射；完整备份已有未验证显式清单/预览接入（BACKUP_RESTORE.md）。原Vault/文档修订CAS、字节散列/结构复核、元数据正文原子发布、动态FontLoader进程预算保持；不要将读取失败当默认可覆盖。字体变化只更新绘制/布局和原PTY resize，不创建SSH。TERMINAL_TYPOGRAPHY.md记录待统一执行的测试与平台边界。
- Windows窗口静态实现见WINDOWS_WINDOW.md及runner/flutter_window.cpp；prototype_window初始化才整合非客户区，保留Flutter HandleTopLevelWindowProc优先处理WM_CLOSE，不允许直接销毁绕过保存。最大化矩形是Flutter客户区物理像素而非屏幕坐标；移除/缩放及时更新。Windows实测和脚本未执行，Ubuntu不能替代；Android暂缓。tools/build_windows.ps1仅Windows x64，正规生成再编译并复制匹配release DLL，不能混ARM64或旧SO。

## Phase 2 恢复提示
- FRB2.13.0绑定位于crates/frb-bridge和ui_flutter/lib/src/rust，不能手改生成文件；根目录flutter_rust_bridge.yaml固定版本和路径。
- ui_flutter/lib/main.dart是入口；TerminalController处理生命周期/帧拉取/输入顺序，TerminalView负责平台输入，TerminalPainter只消费真实快照，不改写缓冲。
- 颜色/尺寸查询必须由网络actor内部回复，不经UI回调等待同一个actor，避免有界事件队列死锁。
- 同时只允许一个未确认帧通知；不可见时不取帧但继续消费平台事件。Dart等待FRB stream onDone后再取消订阅/销毁端口。
- /opt/flutter/bin/flutter可用。Linux仅开发验收runner；Windows/Android平台验收不能由Linux替代。
- 当前已实现功能/剩余项/下一步以PROGRESS.md最新条目为准，不按早期空库状态重复生成工程。


## Phase 3A 原型恢复提示
- 原型入口ui_flutter/lib/prototype_main.dart；真实SSH仍为lib/main.dart。原型不启动NativeTerminalBackend，不加载FRB；TerminalPreview复用原TerminalPainter消费合成帧，不是新终端协议实现。
- UI模型/主题/工作区/文件/队列/主机/设置均在lib/prototype，Mock数据仅当前进程内存。不得把它们误接真实文件或当作已完成SFTP/同步业务。
- PHASE3A_REVIEW.md含运行、20张PNG与人工交互步骤；test/prototype及integration_test/prototype_test.dart为原型验收。原有SSH/Codex集成测试仍须保留。
- GUI测试和不同Dart入口共用Linux debug构建目录，交付前以-t lib/prototype_main.dart重建。benchmark/prototype_smoke.py可验证独立启动/退出、未加载Rust/未创建终端历史。
- Linux原型窗口通道只为Ubuntu验证；Windows原生标题栏/Snap现有未统一验证的静态接入，见WINDOWS_WINDOW.md；IME/Explorer拖放及Windows真实行为仍待做/验。
- 最新用户指令已取消逐阶段/视觉验收暂停，连续实现完整V1.4，禁止恢复旧暂停要求；阶段只用于进度追踪。依据PROGRESS.md和REQUIREMENTS_COVERAGE.md推进所有未完成项。

- 用户最新修订已写入V1.4 §3.1/§5.1及TERMINAL_LAYOUT.md：一个终端标签一个会话，TabGroup管理区域标签，SplitTree只管理布局。不得恢复DemoWorkspace容器模型；分屏/移动不创建SSH连接，空组自动清理，SFTP跟随焦点会话。

## 正式工作台恢复入口
- ui_flutter/lib/workbench_main.dart为真实业务工作台；lib/main.dart保留原最小SSH验收，prototype_main.dart保留独立Mock。
- LiveTerminalSession持有Controller/nativeID，视图挂载只改变可见性；布局操作不得关闭会话。SFTP协商不可阻塞PTY actor；目录响应必须核对会话代次。
- 主机/草稿正式业务通过Rust Repository/FRB，秘密不返回UI；草稿不是正式主机。旧profile迁移幂等且原验收入口可继续列出迁移记录。
- REQUIREMENTS_COVERAGE.md由tools/requirements_coverage.py从V1.4生成，先更新状态映射再生成；不得用PROGRESS替代需求源。真实业务验收见WORKBENCH_VALIDATION.md。

## 真实传输恢复约定
- ssh-core的transfer/tree_transfer/task_scheduler分别持有文件流、目录清单和FIFO准入；frb-bridge::transfers才是运行期任务registry/检查点整合，workbench/queue.dart不拥有SSH。一个目录一个顶层任务/名额，默认3并发。
- 检查点只入storage-sync::local_tasks本机加密命名空间，不入配置同步/备份。实际地址端口/用户/主机指纹与保存主机ID都要匹配，不能只凭当前主机配置或nativeID恢复。跨启动仅显式继续，不创建SSH。
- 新增任务/重试不得与终端关闭/断开、配置库切换竞争；先禁止新任务，暂停并落检查点，再释放Transport。不得把部分写入当成功，不删除取消后的文件。
- controller隐藏须排空在途帧（Rust增量基线已推进，不能直接丢帧）；显隐请求顺序化，关闭先等待可见性/帧再释放端口。

- bandwidth::BandwidthLimiter按方向全局共享，不为每文件创建独立限额；下载在首次读前禁用vendor/russh-sftp句柄预取，防止消费限速掩盖未限速READ请求。transfer_settings为加密用户配置，local_tasks仍是排除云端的设备检查点；保存成功后才生效。
- 传输清单relative字段是POSIX路径，不能按本机Path组件解析；Windows映射必须先检查原始分量再join，防止反斜杠/盘符逃逸。见local_path.rs与TRANSFER_PATH_SAFETY.md；不向Unix/Android误套Windows规则。单文件根更名要同步更新Header和清单实际目标，源身份不变；子文件更名不改根。
- 失败目录重试不能只重置状态：Header.rescan先落意图，后台rescan_failed生成独立候选并合并，原子保存候选/清除意图后才写目标；旧节点序号稳定，不重读已成功子树，不丢确认偏移。取消重扫保留旧检查点，重开库不自动联网。
- 批量更名不是覆盖：Header.rename_conflicts保存意图；后台仅对当前Conflict文件选择未占用的数字后缀目标，保存完整候选后才CreateNew；竞态同名仍须报冲突。恢复/根目标同步同手工更名，元数据查询不能持registry锁。
- 默认同名策略是入队Header快照，不追溯已有任务。仅首次Conflict且default_policy_pending为true的文件可自动处理；手工retry/rename清除该标记，旧清单缺字段为false。禁止默认Skip跳过不存在的目标、禁止默认策略覆盖类型错误或用户已明确选名后再次发生的冲突。
- 正式目录读取用open/page/close，request为同一SSH代次内单调递增的directoryEpoch，旧finally必须携带原nativeID/代次/request，不得关闭新游标。完整EOF与关闭后才发布缓存。DirectoryReader分页限项数和UTF-8展开字节；当前仍全目录完成后在Dart保留元数据，非视口请求/磁盘分页。见DIRECTORY_PAGING.md。

- 传输检查点按256节点分块，周期dirty集合只在事务成功后清空；初始写目标/结构变更前必须完整原子保存。local_tasks::load_parts同时读旧单记录/新根块格式，不可对新根直接serde解旧元组。缺块/修订/版本错误拒绝恢复；根/块/索引均设备本机数据，排除同步和配置备份。见TRANSFER_PERFORMANCE.md。

- SFTP书签属于加密配置（bookmarks::BookmarkRepository），不是设备目录缓存；保存不联网，选中才在捕获的原会话导航。全局/主机ID范围不可因焦点、标签移动或删除主机而错误重归属；同步/备份仍待接，见SFTP_BOOKMARKS.md。

- 文件打开走frb-bridge::previews与storage-sync::preview_cache：同步reserve先分配可取消票据，后台绑定原SSH/nativeID/代次，共享FIFO/下载限速，收到完整正文且远端CLOSE成功才发布。目录符号链接只在明确打开时解析，不在列表预读。预览仅系统关联打开、不回传修改；编辑缓存必须独立。应用退出（包括锁库首页）等待取消/清理，活动run不可被其他进程回收。FILE_PREVIEWS.md含测试与边界；真实GTK系统关联测试必须用benchmark/preview_association.py隔离用户MIME设置。GUI测试后重建正式workbench_main入口，不交付integration_test入口。
- FileOpenSettings为用户加密配置，不是预览正文或设备任务。默认严格超过100MiB才确认，0每次确认（含空文件）；票据首次准备后固定阈值，确认前后改设置不改旧票据。配置格式未知不能用默认覆盖；同步/备份待整体接入。设置表单以成功载入状态判断是否可保存，不能把用户编辑中的空文本当作配置读取失败。
- 编辑协议见REMOTE_EDITING.md：posix_rename与普通rename分开，只有VERSION通告扩展v1才发送，Ok(false)是未操作，不是保存成功；STATUS错误不得隐式删除/回退。当前内置编辑直接覆盖，不以该扩展冒充保存链路。
- 内置编辑走frb-bridge::editors/storage-sync::local_edits；持久edit-ID与运行editor-token分开。恢复草稿仅本机读，明确关联后核对主机ID/实际地址端口/用户/指纹再保存。文本IME提交后去抖合并入设备加密日志，Ctrl+S才回传；目录列表不解密正文，remote CLOSE/大小/通道关闭后才标清洁。取消保存可部分写入，完整草稿保留，绝不重连。预览清理不得删编辑草稿；编辑草稿不进同步/配置备份。DialogRoute出场卸载后才dispose文字控制器，退出持久化失败取消退出。正文16MiB限制仍为当前文本边界，外部文本监听回传已接（见末条），大文件/其他编码/Android页面仍待做，不能计完整条目完成。
- 路径补全只读源会话已有目录缓存，候选选择仅填入、明确提交才导航；不探测/预读/更新LRU，旧代次/失焦取消。IME同文本提交需共享原Future等待组合结束，不能篡改controller文字绕开RawAutocomplete限制。文件快捷键仅列表primary focus生效，不抢路径/过滤文本框按键。见CACHED_PATH_COMPLETION.md。

- 编辑进度使用editor_progress按操作票据返回正文外的小快照，Rust仅保留最后阶段/实际字节；Flutter只在读取/保存活动期间250ms查询，相同快照不通知，结束/关闭停表。字节100%不是CLOSE/通道/本机确认成功。Save在本机flush期间也必须记录取消意图，即使还没有operation票据；持久化完成后不得再开始上传，只有新一次明确Save才重置意图。编辑进度不经LiveWorkbenchModel.changed传播，不在dialog initState通知外层工作台；只注册/注销改变模型。GTK夹具须detach视图后再dispose控制器，进度查找用editor-progress-bar，不能匹配后方队列的所有LinearProgressIndicator。

- 外部文本编辑经external_editor.dart目录事件合并、editors::capture_external完整快照/严格解码后先落加密草稿，再沿原会话保存；没有空闲文件轮询。断线/取消/失败暂停，明确恢复才继续。external_directory在创建明文前加密落意图，工作副本不走preview退出清理；父进程退出不是编辑结束。关闭只释放租约，恢复确认读取不立即上传，仅确认所有编辑器关闭后先保留最新草稿再清理已知文件；未知兄弟/链接/其他租约拒绝。清理必须在持有租约时删正文，之后不得再次删正文；文件已删但DB清关联失败可显式修复缺失目录。原始API不允许通过keepDraft=false删除有pin草稿。GTK真实外部验证需要私有Xvfb/D-Bus与Mousepad/xclip；原生选择器路径仅一次性夹具，X11驱动核对PID/exe/精确文件argv，不对用户编辑器发键。最新验证/在途状态以PROGRESS末节为准。

- 文件文本编码使用local_edits::{Encoding,decode_with_encoding,encode}；默认仅Unicode/BOM，legacy/无BOM UTF-16须用户明确选择。输入和输出都严格无损往返，Shift JIS等best-fit不能静默改字；保存不可编码时须在远端截断前失败。本机草稿存Unicode正文+编码元数据，恢复不得重新解码；prepare_editor的可选input_encoding只用于首次远端读取。外部无BOM文件沿用原选定编码，有Unicode BOM才明确切换，不猜“像UTF-8”。失败load Future要清理以允许明确重试，ready正文不能被再次load覆盖。encoding_rs0.8.42关闭默认特性仅alloc，完整许可/边界见REMOTE_EDITING.md。

- 大文件经独立raw模式：storage-sync::{edit_blobs,raw_edits}保存设备本机加密块，唯一owner正文指针和草稿元数据在SQLite事务内比较发布；Complete仅本机完整，不是远端保存确认。EditorRuntime.raw复用原票据/gate/身份/退出，summary.raw_bytes非空表示原始字节模式，不能把空text当作可编辑正文或调用update。正文不经FRB全量传输，内联16MiB/严格编码路径保留；Android内置编辑仍待做。详见LARGE_EDITING.md。
- 外部大文件初始化无完成marker时不能普通打开/覆盖部分文件，仅明确确认清理可非破坏修复、捕获最新部分文件后删除已知文件，不上传远端。捕获在blocking worker逐块两次读取并比较、先加密发布再上传，旧正文仅持工作文件租约时退休，不能删其他在途staging。保存先验证全部加密块，再按64KiB流式上传，CLOSE/通道/本机确认全成功才标清洁。旧小文本初始化修复保持不变。

- 递归文件名搜索见FILE_SEARCH.md：ssh-core::search只读元数据，分页/工作量/目录路径预算均有界，子链接不遍历。Entry.file_searches是独立DirectoryListings实例，Reader枚举复用原目录的代次/request/gate/释放，不能和directories或终端SearchIndex合并；过期close不可关闭新搜索。Flutter FileSearchController绑定原nativeID/代次，取消/关闭等待在途RPC，不发布迟到页；10000项上限明确未完整。FilesPanel搜索选择回原目录并滚到选中文件，不打开/下载；内置目录筛选仍是本地操作。最新实际回归/未提交状态以PROGRESS末节为准。

- 远端复制走ssh-core::remote_tree和frb-bridge::remote_transfers，不能复用PathBuf解释两个POSIX根。CopyHeader分别绑定两端实际身份，活动期绑定两端代次；任一终端关闭先暂停相关复制，两端专用SFTP通道CLOSE也必须确认。with_relay_resources共享原FIFO/上下载Limiter，统一锁顺序transfers gate→remote registry→job→vault，不能反向取锁。设备日志用LocalTaskJournal::remote_copies独立命名空间，256节点块成对保存文件状态/暂存阶段；阶段/发布/冲突屏障不可用普通250ms进度去抖跳过。
- 文件复制剪贴板在LiveWorkbenchModel仅存原会话/nativeID/代次和路径元数据；FilesPanel确认固定剪贴板修订/目标代次，Native enqueue再次核对预期代次。切换同路径同代次的不同会话也须清选择，旧菜单/hover不能改操作目标；不新增Windows Ctrl+C/X/V文件快捷键。私有暂存Intent/Writing/Ready/Publishing/Published不能只看100%标完成，失败CLOSE不能隐藏成普通取消。见REMOTE_FILE_OPERATIONS.md；直传、剪切/复制到、剩余暂存清理及失败目录重扫仍待完成。最新验证/正式包状态以PROGRESS末节为准。

- 同账户移动复用remote_transfers，CopyHeader操作字段缺失时默认Copy；Move的Pending/Intent/Confirmed与复制暂存阶段不可混用，codec禁止Move带复制树或未ACK记完成。实际地址/端口/用户/指纹均一致才走原SFTP rename，不凭同host key执行跨账户移动。Intent先落盘才rename，ACK后先保存Confirmed；Intent未知不重发、不清掉唯一记录，Confirmed恢复只收尾，不能再移后来重建的来源。prepare_remote_move只读路径且不预留名称。
- 移动与编辑互斥用Editor registry gate→transfers gate→remote registry→job→vault；同步动作只检查元数据/持久化，持有gate时不得网络await或读正文。移动排队/未知来源禁止新建或关联编辑，移动前再次按规范路径检查活动编辑；同host key保守防地址别名，准备中路径未确定则拒绝，已准备的无关文档不受影响。不要在持remote registry锁时反向取Editor gate。
- 剪切仅消耗实际接受的路径，保留未入队项，旧finally不能清掉后来新修订；同一剪切修订不得并发重复提交。移动后源/目标SFTP当前目录更新及源子树缓存失效；不更改SSH CWD，不发PTY输入。显式任务变更后先join已在途的旧列表，再取新快照，不能把变更前响应当新状态；普通活跃轮询仍合并且结束停表。元数据移动不伪造内部文件数/传输字节。最新验证/未提交状态见PROGRESS末节。

- 独立复制到/移动到使用workbench/remote_destination.dart，RemoteFileSelection为固定源nativeID/代次/不可变路径元数据；与剪贴板共用enqueueRemoteFileSelection但绝不能借覆盖/恢复剪贴板实现。RemoteFileSubmissionFailure只携带acceptedIds及未提交剩余选择，重试不得重入已接受项；停止仅阻止后续入队，不冒充取消队列任务。目标列表只捕获已连接会话，显式提交才解析目录并二次核对源/目标，IME候选不提交、不trim路径、不因切焦点改目标。真实Native与GTK结果/正式包状态以PROGRESS末节为准。

- 远端失败目录重扫复用RemoteTree::rescan_failed只读候选，稳定旧节点序号/暂存路径/阶段/确认偏移，新发现只追加；完成/跳过/冲突来源不重读。CopyHeader.rescan（默认空、旧格式可读）先落意图，后台候选与清意图同事务保存后才写目标；源重扫先于已存目标批量更名意图。取消/容量/持久化失败保留旧计划，不自动建SSH。编码/解码均拒绝无清单、重复/越界/文件/非失败索引、Move误用或完成状态残留意图；失败详情rescan标志复用原队列确认。最新真实Native/GTK/正式包状态见PROGRESS末节。

- 未确认移动处理见remote_transfers/move_resolution.rs及workbench/move_resolution.dart：lstat仅当前元数据，不据缺失/大小推断rename结果。检查IO前预留ready=false票据使旧请求失效，完成且CLOSE/代次/job对象/修订/最新请求均匹配才ready；不能持锁网络await。结束仅本机原子保存UserEnded+Cancelled，不能冒充Confirmed或重发，不撤销原请求，保留加密审计；保存失败不释放原Intent编辑保护/不消费票据。UI明确“结果未判定”，批量继续跳过未知移动。网络检查/网络票据仍绑定原保存主机ID及实际端点；另有本机审阅/结束能力见下一条，不能为此放宽普通传输恢复。最新测试/正式包状态见PROGRESS末节。

- 离线结束未知移动使用prepare_remote_move_end/end_remote_move_wait，无Connection参数，仅原加密任务审阅/原子审计，不查询文件/重建主机/刷新SFTP。move-end与move-inspect票据隔离，绑定job/修订/Vault，新审阅使旧票据失效，保存失败保留Intent保护和票据；UserEnded不记ACK/成功，不撤销已发请求。UI本机审阅先行，可选属性检查不阻塞明确结束，迟到结果不能覆盖保存失败；所有网络检查/恢复继续严格验证原HostID/实际端点/代次。最新Native/GTK/正式包状态见PROGRESS末节。

- 被动OSC7核心见TERMINAL_PATHS.md与term-core::working_directory：同一VTE解析器typed Handler/Event→Collector，本机元数据不进字符/平台队列/日志。只接受严格file URI并单次解码，保留POSIX斜杠/..避免破坏链接语义；authority不同不猜别名。OSC7完整ST才发布，取消/超限/无效新报告清旧上下文，备用屏幕进出/RIS/断线/新PTY清除。不能把CWD作为Shell安全输入证明，路径注入/历史收集不能据此启用。桥接/定位/跟随最新状态见PROGRESS。

- 终端选区定位正式入口TerminalView.onLocatePath→LiveWorkbenchModel.locateTerminalPath→FRB sftp_locate_terminal_path；resolve_terminal_path只本机解析，明确动作才SFTP读取父REALPATH/最终lstat。原Entry实际SSH地址/代次和模型原目录请求序号/定位序号必须复查；A失焦不改B。菜单固定源controller/代次/选区，Future.sync接同步拒绝，不吞远端鼠标，Shift覆盖保留。RemoteFileLocation为一次性内存选择请求，FilesPanel消费/显示隐藏/滚至行，导航清旧请求；不注入PTY、不自动联网恢复。TERMINAL_PATHS.md列范围/测试，跟随/识别/发送未完成，不能据OSC7启用Shell联想。

- OSC7 directory_context为独立修订/小快照，取CWD不能克隆完整网格。Actor按输出批次取最终变化，FRB workingDirectory事件按首份起16.667ms固定窗口合并最新，变化停止后不保留timer；隐藏也通知，不拉帧。事件仍是未验证自报，正式跟随必须核对原实际端点/代次和焦点/已启用SFTP，不据此证明Shell安全输入。新Native burst测试4000报告→1事件/0帧，最新状态见PROGRESS。

- 可选OSC7跟随见TERMINAL_PATHS.md：HostRecord.follow_osc7默认false/serde旧字段兼容，加密主机/草稿/复制，只有正式保存改运行策略；open_sftp独立。Controller目录报告只作触发，Rust terminal_working_directory核对原实际端点/代次，未知/authority不符返回None。模型仅当前焦点/工作页和侧栏可见且已启用SFTP时150ms合并、全局至多一个跟随；普通导航消费当前报告并取消旧token/目录epoch，旧页不能覆盖，失焦/收起/关闭/退出同理，无新报告不设持续timer、不自动展开/初始化/重连。HostManager高级保存等待基本Form挂载一次完成，准备/保存期禁止切换、失败恢复操作。原型与真实业务区分不变。

- OSC133前置见SHELL_INTEGRATION.md及term-core::shell：同VTE typed ShellMarker，只保留最新自报phase/本次序号/可选u8状态，不复制cmdline属性/诊断/建立命令历史。标准主提示符A-B-C-D，次提示符/未知属性/异常顺序保守失效；完整ST才提交，中止/超限/参数截断不采纳局部标记；备用屏幕/RIS/实际重排/断线/新PTY失效。phase=Input不是POSIX Shell/回显/光标/可安全输入证明，禁止直接据此开联想或注入。历史范围锚点/复制/导航尚待实现；当前Native/正式包版本以PROGRESS为准。

- SSH单代理见SSH_NETWORK.md：ConnectConfig.proxy只改TCP路由，总Budget新增Stage::Proxy，代理失败绝无直连/认证降级；原目标地址/端口仍用于TOFU和任务身份。HostRecord.proxy默认None，独立代理秘密按host-ID归属加密，save_with_proxy与主机/目录/草稿同事务；copy_to_draft复制秘密但新ID独立，关闭认证保存删除旧秘密，重新启用须明确提供。FRB仅返回元数据/credential_set，不能回读用户名密码。新Native桥接夹具无视图须setVisible(true)才取帧，GTK合成指纹回调须在attach后设置以免App初始化覆盖。正式包/最新验证见PROGRESS，别将代理计为跳板/转发/云同步代理完成。

- 主机级时限/心跳已接通DemoHost→HostConfig既有字段；快照/复制/草稿必须保留timeoutSeconds、keepaliveSeconds、keepaliveFailures，prepareConnection仅明确重连刷新运行期快照。网络页校验总超时1..3600、间隔0..86400（0关闭）、阈值1..100；全局默认/独立响应超时尚待做。窄窗底部hostFooter按可用宽度换行，save()统一处理切页/验证/导航保护。真实停流试验用LocalProxy显式hold文件，只有测试夹具轮询，不给产品增加空闲轮询。Native多test同isolate只setUpAll初始化FRB一次，超时重试取消必须等实际新代理请求，不消费旧连接事件。最新正式包及测试见PROGRESS。

- ManagedSession.test_connection是无Authentication参数的显式握手探测，复用同actor/Busy/总Budget/TOFU/代次；成功Idle或原Disconnected，不开PTY/SFTP、不改画面历史或重连标记。probe Future持本次子token的drop_guard，abort只取消本次，不能取消后来的连接；shutdown仍等待actor退出。真实openssh_probe两项及Native/Codex/代理/心跳回归见PROGRESS。正式主机页/FRB探测接口仍待接，不能把核心方法当可用按钮。

- 正式握手测试入口已接，见SSH_NETWORK.md：connections::configuration与登录共用路由/时限；test_host_connection只读正式主机元数据/必要代理秘密，不读目标SSH凭据，网络边界复核保存ID/预期地址端口用户。HostConnectionTest隐藏0帧、无标签/最近/SFTP，销毁等待Native/FRB；Live模型退出先取消，取消必须绑定原Future，旧Dialog dispose不能取消新测试。主机页未保存编辑只能提示先保存，不能隐式正式保存；挂载后启动避免build期通知，明确取消不写全局错误、实际异常仍向调用方返回。长目标AlertDialog.scrollable保持关闭可达。最终Rust223/Flutter162/GTK真实TOFU/NDK及正式包见最新PROGRESS；旧段“待接按钮”已被本条取代。

- 一级跳板Rust核心已验：JumpHost无递归/第二代理，JumpStream持跳板Handle，唯一外层代理→direct-tcpip→目标共享Budget/取消；私有Command.config装Box，不改公开模型。117项核心/51真实SSH及7 Native/NDK回归通过。正式配置接入须隔离按跳板路线的目标TOFU并准确标识跳板/目标；当前正式包与具体状态见PROGRESS，核心通过不代表UI已接。

- 正式一级跳板已接：HostRecord.jump_host_id引用已保存且无跳板的主机，删除保留失效引用，未来连接拒绝而不直连。Repository正反向验证至多1跳/1代理，credentials只在明确连接/探测时读；探测只认证跳板、不读目标秘密。Route同Vault锁捕获，目标TOFU按跳板地址/端口/用户名+目标端点的版本tuple隔离，直连旧键保持。Entry验证槽至多2个，ConfirmTagged context匹配原尝试/端点，取消/销毁撤销；Vault→verification锁顺序，无锁跨await。Attempt Drop只取消本次Connecting，不断已Connected。App用jumpHostKey与hostKey区别实际角色，回调异常finally拒绝。完整证据/正式包版本见PROGRESS与SSH_NETWORK.md；旧“正式选择器待接”已由本条取代。

- Entry destroy须调用verification.close永久关闭准备入口，再有序停编辑/预览/传输/actor；只cancel当前槽不足以阻止已取Entry的迟到准备在shutdown前重开。最终验证作用域4项/Native8项通过。完整239 Rust/168 Flutter与正式双模式包/独立启动见PROGRESS，继续转发核心。

- 端口转发TCP基础见PORT_FORWARDING.md：TcpConnector只绑定原Transport，ManagedSession actor仅返能力；全部clone共享64在途/活动名额。不得直接timeout/drop russh channel-open Future（迟到确认可能漏关），保留有界worker收尾，失效receiver丢ChannelStream触发Close。根Transport取消终止所有worker/旧能力，新SSH必须新获取；独立操作取消不得取消原SSH。真实OpenSSH与受控迟到peer区分计数。正式-L/-R/-D尚未接，不恢复Mock完成声明。

- LocalForward监听核心见PORT_FORWARDING.md：start只证明bind，不证明目标可连；watch active包括协商中。每监听64子任务，跨监听共用同TcpConnector 64名额；stop必须await，Drop只安全取消。SSH断开取消对应监听，旧cap不追随新Transport，任何恢复须明确。服务拒绝/IO错误如实计数，无静默成功；无空闲计时器。正式FRB/配置/可视化转发仍未接。

- 动态-D核心LocalForward::socks5复用同一有界runner/统计/停止；SOCKS5仅无认证CONNECT子集，精确读取不丢合并包负载，未知方法/BIND/UDP/畸形请求拒绝，目标通道确认后才回成功。握手/名额等待/通道打开共用deadline，小回复另有≤1秒写界限。域名只交SSH端解析；本机D监听代理不复用外层SSH代理秘密。正式FRB/配置/可视化仍待接；远端-R尤其不得丢弃迟到tcpip_forward/cancel ACK、不得给目标与跳板共享入站路由，见PORT_FORWARDING.md。

- TCP慢消费已真实复现russh共享dispatcher await有界Data队列阻塞PTY；固定vendor/russh0.64.1新增显式消费驱动direct-tcpip API，仅TcpConnector选择。字节窗口+64KiB合并块/128项有界FIFO，实际消费后按channel合并priority credit，不扩大无界缓冲/丢数据/磁盘中转。原库默认API及跳板策略不变；产品PTY/SFTP后续已显式选择session消费窗口（见SESSION_FLOW）；生命周期/EOF/错误边界及patch源校验/许可见vendor/russh/HSPTERM_PATCH.md、PORT_FORWARDING.md。R入站也须做相应流控，不能只复用默认IncomingChannel队列。最新全量/正式包是否已通过以PROGRESS末节为准。

- 远端-R见remote_forward.rs/PORT_FORWARDING.md：每实际Client独立Router，jump与target不可共享；32规则（含未知清理）/64入站流/每规则inbox16。全局启动/取消Future不能被本机deadline或owner Drop丢弃，迟到port0分配须原Transport清理；CleanupPending不是Stopped，不重复发未知取消，CleanupDenied再次stop才显式重试。stop先撤销路由/清本机所有者，再等ACK；旧Stopped不能取消后来同端口。服务器地址label歧义拒绝，不猜路由。非-R的Agent/X11/其他七类未授权入站明确拒绝；正常通道不受影响。Rust核心通过不表示正式FRB/规则/GUI已接，最新在途/包状态见PROGRESS。

- 转发规则见storage-sync::forwarding_rules：每主机独立加密/版本/32条/读取前128KiB，配置不保存运行状态/分配端口。普通HostConfig保存不覆盖它；Repository复制新ID规则与草稿/凭据/catalog同事务，未正式保存仍属本机草稿。丢弃副本清配置，丢弃已保存主机编辑草稿保正式规则；删除同事务。未来同步/备份必须按正式catalog.hosts归属筛选，不能只扫host-forwarding前缀。最新FRB/正式GUI是否已接以PROGRESS为准。

- Entry.forwardings持正式运行实例，start/list/stop必须原NativeID/代次/规则ID；saved Rule与runtime token分开，数据不得经FRB。开始前核对原实际目标，原Vault只捕获元数据；能力获取在registry gate外，gate只保护本机字面IP bind与登记，不跨外部响应。关闭RAII计数跨整个Root操作，销毁永久拒绝晚准备；未知R取消仍是未知直到Root结束，退休只清原代次。保存/删配置不改已有实例，删主机后stop不依赖凭据。正式UI/重连恢复/推送是否已接以PROGRESS为准。

- 正式端口转发入口见workbench/forwarding_dialog.dart、HostManager进阶和GroupActions当前终端；Mock只提示，脏主机先保存。Source捕获原NativeID/代次及生命周期监听，后续焦点/布局不换目标；读取失败禁用配置写入，但原运行实例仍可停止。保存/删规则不停止实例；界面关闭不释放监听，Entry才拥有。运行状态推送/按配置手动重连恢复/临时链接与完整规则草稿尚待接，以最新PROGRESS为准，不能标整项完成。

- 转发运行变化以原watch receiver+Weak registry任务驱动，不能持owner/SSH形成循环；watch_events首个变更起100ms固定窗口合并，不因洪流推迟到永远。Controller.forwardingChanges独立且核对代次，不notify全局/拉帧；面板合并在途查询、旧源结果丢弃、关闭注销，无空闲/过渡poll。实际GTK外部停止自动更新与完整结果见PROGRESS。重连恢复/临时链接与完整草稿仍待接。

- 明确重连转发恢复只由connect_terminal成功后触发，首次不启动；捕获原Vault规则并核对最后成功Target完整身份，新代次只试enabled+restore规则。局部失败单独元数据，不改SSH连接状态；并发手动实例不能复制。RuleDraft用local-forwarding-draft-v1本机命名空间，修订墓碑/CAS/原规则快照，正式提交与退休同事务；不能同步/复制草稿或静默覆盖未来格式。GUI关闭/退出先等合并写入，Modal打开不等于busy IO。
- 临时链接Native只准明确loopback/localhost，固定本机127.0.0.1:0，复用原Entry/代次registry，不保存/探测/恢复。terminal/links.dart只读网格/有界软换行/隐藏文本拒绝，不改终端或主动联网；TUI鼠标优先/Shift覆盖。workbench/terminal_links.dart确认和浏览器都绑定原源，打开失败只停本次token。普通URL允许保留历史中显式打开，不重新SSH。系统浏览器实际交付及OSC8/Android适配待整体核实，详PORT_FORWARDING及最新PROGRESS。

- 全局SSH默认见network_defaults/network_settings/heartbeat及SSH_NETWORK.md：旧Host默认false/None保留旧策略，新UI主机选择继承；原Route捕获一次，不热改。response Some才启用独立ACK监视并关闭旧内置keepalive；interval0完全关闭。send_ping_checked保持全局FIFO，不能把任意PTY输出当ACK；弱Handle/原Root取消/await监视器，sftp_opener必须保持static克隆能力，不借self跨Future。当前294 Rust/188 Flutter及最终包见PROGRESS。

- OpenSSH显式导入见OPENSSH_IMPORT.md：只消费用户源快照、首值优先/明确Host候选；Match不执行/Include不读取、ProxyCommand非none和不支持路线阻止候选；IdentityFile只提示类型不读路径。预览绑定Vault.instance_id，每次打开不同。Repository::import_openssh是唯一允许创建无凭据正式元数据的路径，普通save仍需凭据；Host默认值快照/跳板同批有效引用/新ID/CAS/同名拒绝，后续认证配置明确完成才可连接。导入源不入持久草稿/诊断/同步。

- 显示增强见TERMINAL_DECORATIONS.md：只派生RenderFrame样式，不能改Snapshot/SSH/历史/搜索/复制；变化可见行扫描，有界regex/行长/单元与8ms匹配边界预算，非硬实时。原ANSI/DIM/反色优先，显式force可覆盖适用色；备用屏幕默认停用。同词高亮只读完整单词、可见区域与原物理宽度，缓存Controller身份/帧计数/选区。DisplaySettings用本次Vault scope+修订墓碑/CAS；主机复制草稿/丢弃/删除同事务。连接准备须在原Vault门控内绑定策略，避免迟到旧准备覆盖新Save；previous→display锁顺序且无锁跨SSH await；设置更新不重连、不触发隐藏取帧。当前最终结果/在途与规则测试行边界补验以PROGRESS为准。

- 纯显示设置可强制full RenderFrame但不能额外清空真实选区。Controller需核对原文/映射、内容修订、视口、几何、备用屏幕/鼠标模式；只有这些均不变才保留选择，不按颜色/下划线变化清除。未知或真实内容改变仍失效，禁止为保选区放宽原代次/范围约束；display_selection_test与Native/Codex等24项回归见PROGRESS。

- RSA/Agent核心见SSH_AGENT.md：ring-only SHA2/OpenSSH2048–4096，不启用有未修复通告的RustCrypto rsa；OpenSSH bcrypt派生前限1–256，私钥解析临时缓冲清零。Agent默认不申请/不授权；PTY前申请socket、原epoch限时明确同意，4流/单crypto worker/退出await，新Root不继承。RFC9987 agent-forward值0、agent-req、agent-connect，兼容OpenSSH旧别名；revoke不能把未申请的端点提升为可授权。ManagedSession所有退休分支必须等待close。
- 消费驱动流的发送WindowSizeRef须增量grant ACK，不能按dispatcher当前wire窗口绝对重置（会恢复已排队预留→超发→全局pending门控停PTY）；默认非流控通道保持原策略，不删全局有界门控掩盖问题。send_window.rs直接源码回归、Agent真实慢消费和原L/R/D均须保留。正式FRB/UI接入是否已完成，以PROGRESS最新记录和Git实际源码为准。

- 正式Agent见frb-bridge::agents/api与workbench/agent_dialog：每Entry单名额（先于全局读锁取得）跟随blocking私钥工作，切库写门控→Vault内同步invalidate epoch；原nativeID/代次/实际Target/Vault/来源凭据标签/公钥复核和120秒一次性预览，确认才安装。来源密钥改/删撤销，不影响PTY；新Root不继承。crypto panic明确Failed/收尾报错。agentChanges独立100ms推送，普通绘制生命周期通知不得读密钥列表；失败读列表仍可撤销。正式包/330 Rust与206 Flutter/GTK/截图状态见最新PROGRESS；未来备份替换凭据也须在同Vault临界区撤销相关授权，不能只更新记录。

- RSA扩展见SSH_RSA：Ring验证KEX/hostkeys-proof/userauth，签名算法必须匹配协商；每次rekey检查信任，Client缓存原已接受身份不重问。PKCS1/PKCS8/PBES2/遗留AES PEM导入有派生前成本上限，DER整数借用、原CRT由ring真实签名检查，不能丢弃损坏字段后重算。SshConnection.verified_host_key是实际证明，Bridge是否已接回执以PROGRESS为准；禁止用当前Vault旧/新记录替代原Transport身份。

- 原连接身份见CONNECTION_IDENTITY：ManagedSession.connect_verified经原actor响应返回generation/实际HostKey/username，Bridge用回执关联Target并核对状态/原目标，不能重读当前Vault指纹或用显示设置推断来源。Verification在policy准备绑定原Vault.instance_id，最终answer复核；成功重开/切库在Vault门控内清旧slots/pending oneshot，不断开已受信任SSH，错误密码不改变状态。原审查副本已过时，不能覆盖正式源码；新Root回执/旧Vault和Node布局生命周期必须分别处理。

- PTY/SFTP背压见SESSION_FLOW：默认旧策略已真实复现未读PTY堵塞共享SFTP。产品显式channel_open_session_flow_controlled，原库默认接口不变；字节窗口/64KiB合并/128项FIFO/priority实际消费credit及发送增量grant均保留。read和PTY/SFTP确认等待必须显式处理ReceiveWindowError，不能忽略为成功；不得用删全局门控或无界缓冲掩盖。真实8MiB逐字验证与5次重复、185核心/Native7见PROGRESS。

- 单次覆盖见TEMPORARY_CONNECTIONS：temporary_connection_source/connect_terminal_once复用原连接路径；Source原Vault+Host/Jump元数据前后复核，认证显式三选一，不持久化/不回退。临时Root未来历史收集必须排除；断线只预填元数据且重新确认新秘密，取消不建Root。四文件worker名额跟随实际阻塞IO，关闭释放UI秘密引用；旧一次性脚本不可重跑。最新测试/包/首次release窗口失败及重测结果见PROGRESS。

- OSC8见OSC8_LINKS：Snapshot共享Hyperlink→变化行半开列span，不逐单元复制URI；URI/id保留前限长、span/字节/扫描预算，超限显式无目标禁止标签URL回退。VTE URI尾分号、完整ST/BEL/取消专用discard/UTF8必须保持；URI元数据不能改复制/导出；file URI只在原SSH的SFTP定位，永不交本机系统/浏览器/转发，authority与解码由实际Root复核，见TERMINAL_PATHS。Grid滚动须饱和运算，保留i32极值回归。GTK逐文件私有桌面，隐藏LiveSession取帧测试须明确可见，不放宽产品隐藏策略。最新完整/专项的实际范围与包哈希见PROGRESS。

- tmux见TMUX.md：正式Host默认关闭，认证后原连接专用有界exec读取/明确选择，再启动PTY；不向活Shell/TUI注入。只读-r含ignore-size，控制-d分离其他客户端含观看端，须风险同意，禁止-x；仅尽力单控制。票据绑定原Vault/Attempt/代次，切库/取消/关闭失效，等待不消耗网络预算。元数据ID/PID/创建时间校验，新建不用-A；初始PTY锁取实际回执。测试先真实核对私有TMUX_TMPDIR及无继承TMUX，所有本机操作显式-S私有socket，禁止用户默认服务。当前逐次手动重选，按配置恢复仍待完成。tests/openssh_tmux/mod.rs是openssh子模块，不放tests根造成额外Cargo目标。最新完整回归/正式包见PROGRESS。

- 命令历史基础见COMMAND_HISTORY.md与storage-sync::command_history：有界加密仓库/精确去重、原Vault和主机绑定内存索引、关闭/单主机或全局清空epoch/旧设备载荷抑制及CAS已接；当前没有实际终端采集/候选UI/网络同步，不能标完整联想完成。record_qualified是调用方证明契约，Host存在/OSC7/133均不能替代普通Shell输入证明；未来Bridge须检查原SSH身份/代次/Vault及temporary_connection排除，隐藏输入/TUI/IME/复杂编辑不采集。每键用已载入HistoryIndex，不每键解密，新增/开关/清空/切库必须失效旧快照。纯载荷必须先加端到端信封才能云端/备份，device-command-history-writer-v1不参与；容量/格式/合并失败保留两端，不以静默丢弃消除冲突。旧.local草稿不能覆盖正式模块，最新测试见PROGRESS。

- 主机排序工具见HOST_ORDERING.md：load/apply_host_ordering只投影非秘密元数据，原Vault实例+全主机元数据修订，Catalog与变动行CAS原子提交；不得复用该入口修改认证/网络或凭据。保存ACK与列表刷新失败分开，旧提案不自动重放；拖动owner/预览前冻结/HostManager未保存表单门控保持。正式分组导航用ID，不与“收藏/全部主机”等显示名混用。工具不代表主列表直接树拖排/完整高级批改已完成；实际测试、在途管道与正式包以PROGRESS最新条目为准。

- 命令历史管理在command_history/controls.rs及workbench/history_controls.dart；controls只投影计数/名称/开关，FRB没有记录命令或导出正文的入口。保存/清除必须原Vault scope+历史修订，明确确认后生成删除epoch；零条仍有清除意义，全部包括已删除主机遗留数据。清除不保存未提交开关，不清终端滚动历史；Model追踪写入等待退出。可靠Shell采集/实时联想/同步未接，不能据已实现管理页启用盲采集或宣称完整联想完成。最新在途验证以PROGRESS为准。

- 应用命令面板见COMMAND_PALETTE.md；extraCommands是打开时调用的provider，不能在Workbench build提前捕获未挂载view。终端动作绑定原view/Controller代次并检查焦点，变化后撤销；只保存最多8个运行期应用操作ID，不存查询/终端命令，不入云端。可用性监听先比较可见ID/标签，不能每个远端帧重绘面板。IME候选键skipRemainingHandlers交平台，路由退出/关闭消费后拒绝迟到点击。自定义快捷键持久化/完整捕获冲突路由仍未接，不能改原TerminalView吞TUI键来冒充完成。最新验证/构建以PROGRESS为准。

- 备份/恢复静态实现见BACKUP_RESTORE.md：backup::Snapshot明确白名单，严禁导出所有记录；字体仅完整备份，云同步另设投影。原Vault/snapshot修订、SQLite data_version及缺失键在IMMEDIATE事务中比较，候选内存校验，提交旋转运行scope，主机新独立凭据ID、历史清除epoch合并及本机草稿保留。Bridge先Agent写门控→传输注册表→Vault，预编译显示/验证后撤销Agent、原子提交、发布共享限额；不强断原SSH/SFTP/任务。数据库ACK与UI刷新分离，不得对刷新失败重放恢复；文件no-clobber，页退役迟到预览，退出等待。新6个API与测试未生成/运行，旧绑定不可调用。

- Windows便捷解锁见WINDOWS_UNLOCK.md：默认关闭，原Vault scope+稳定元数据token+主密码验证后仅写用户DPAPI密文；不入配置备份/云端。正式入口用createConfigurationVault或unlockExistingVault，不能以open-or-create吞掉删除/替换竞态。退出须等待_openingVault及Model.runLocalSettings；生成绑定未更新前不可用旧SO验证。Native只派生固定token缓存路径，不允许UI传任意删除路径；原生/Flutter明文内部副本无法保证全擦除。Windows DPAPI实测仍待执行。

- 主机非敏感批量编辑见HOST_BULK_EDIT.md；正式入口走host_bulk原库/原所选记录与目录修订CAS，默认字段不选，不读凭据。继承只改开关保留覆盖值；ACK在事务前构造，提交后刷新失败不得重放旧批量。Mock仍内存，主列表直接排序另做；新2个API未生成/测试，不能计完成。

- 主机主列表拖放见HOST_CATALOG_DRAG.md；host_catalog_drag只持非敏感原排序快照，onDragStarted每次重新读，build/悬停不读。落点必须原Model+原scope/修订，不能在用户保存未提交编辑后静默重定基。顺序写入沿saveHostOrdering退出等待/ACK刷新分离，禁止误触SSH重连；测试源码未执行。

- 终端默认设置见TERMINAL_PREFERENCES.md；新NativeBackend走createConfiguredTerminal，旧createTerminal显式history语义保留。config-terminal-preferences-v1已入备份允许清单/候选验证，非字体正文可同步配置。光标/颜色保持远端OSC/DECSCUSR优先，协议颜色查询与绘制一致；既有历史不因偏好裁剪。发布前Validated、原Vault运行绑定、ACK后无失败发布，恢复须迁移绑定；新3个API及RenderFrame可选OSC52/right-click字段待正规生成，不能手改绑定。粘贴先捕获原Controller/id/代次，路由自己持编辑控制器到卸载，不能恢复旧的提前dispose/迟到粘贴逻辑。测试源已补但未运行。

- 运行诊断见RUNTIME_DIAGNOSTICS.md：diagnostics只收固定枚举/数字ID/代次，最多1000条进程内存，不加任意文本/路径/error字段或入库/日志文件。连接guard Drop是等待中断，入队不当完成，watch状态可合并。UI手动读/筛选不poll，清空ACK与刷新分开；不能把诊断读失败作为空成功。新2个API/测试均未生成运行，全应用错误详情脱敏尚待继续审查。

- RTT/底栏见RTT_STATUS.md：只复用已有独立ACK心跳，无额外探测；旧兼容/关闭/无样本为未知，超时和新Root清空。Heartbeat数字watch→SessionStatus→latency事件→Controller.transportInfo独立通知，不能用普通PTY字节算RTT、为统计取帧/轮询或每次写“已连接”诊断。PTY只用确认帧几何；任务数为已载入记录，不伪称远端CPU指标。新BridgeEvent可选字段待正规生成，旧心跳期限测试保留；本批所有新测试源未执行，Android暂缓。

- 相对路径复制见TERMINAL_PATHS.md末节；只用原SSH/代次/实际目标/OSC7修订和字面子树，不构造有歧义的..、不联网/PTY注入；未知时菜单禁用并保留绝对路径。菜单选择/文件路径需在await前冻结，旧请求/切源/退出拒绝迟到菜单，点击再核对目录版本。runLocalSettings(reportFailure:false)仅用于有本地禁用原因的可用性读，不取消退出等待，也不能抑制正式保存失败。新1个API/测试源未生成运行，不能计全部联动完成。

- 配置同步静态前置见CLOUD_SYNC.md，公开storage-sync::cloud_sync实现在backup/cloud_sync复用快照/恢复。云捕获不能先读完整备份/字体再过滤；只准正式主机/独立凭据/允许配置/书签/历史，TOFU和本机数据保留本机。主机秘密ID云端规范化防恢复新ID回环，历史用clear-epoch CRDT不能整体LWW/删行。原本机提案不能以未应用下载替代；网络期间源变化拒绝，配置与local-cloud-sync-ledger-v1基线同事务，未来Bridge须原Agent→传输→Vault门控/预编译与ACK后发布。
- WebDAV只HTTPS精确对象/强ETag条件PUT，412重读限三轮；未确认写入不得更新基线或盲重发，代理独立且失败不直连。当前仅领域和真实HTTP传输源码，正式目标设置/FRB/真实修改时间记录/去抖调度/Drive仍未接。新增reqwest0.13.5/Rustls ring清单未解析更新Cargo.lock；依用户策略最后统一解析/生成/编译测试，16项新测试源未运行，不能称同步完成或用旧lock执行--locked。

- 上条“设置/修改时间未接”已由当前静态批次覆盖，见CLOUD_SYNC_SETTINGS.md：journal在原Vault普通/CAS/删除事务内比较正式单位变化并记录真实时间，提交后只广播scope；目标/秘密/初始记录原子启用，已有记录未来格式拒绝覆盖，设备任务/草稿/无变化不记。ACK同事务清待同步/观察远端时钟且不重新广播，不能把后来同步时间当本机编辑时间；网络驱动与去抖仍未接。
- settings存唯一local-cloud-sync-target/secrets，load/save新2个API只返回元数据及是否设置，正式工作台已接保存页但明确不上传；未生成绑定/编译。目标/秘密也绑定LocalProposal及最终SQL；PreparedRestore额外前置须保留这两行原值，不能因不在candidate而删除。切换对象/集合需确认并本机归档基线（8份上限），不同origin/代理不可Keep旧认证，密码更改不得破坏已有集合。runLocalSettings追踪保存与退出；新Rust16/Flutter7/Native1测试全未执行，下一步接真实运行/风险确认/取消/Agent门控/去抖/Drive，不重复已写设置。

- 2026-10-30用户要求不在模块边界暂停等“继续”；持续编码/静态审核，最后统一编译测试。WebDAV运行已静态接入，见CLOUD_SYNC_RUNTIME.md：应用级Controller/原owner-operation-review票据/真实条件HTTP/750ms编辑去抖/风险审阅/412新票据/取消与worker真实结束及流onDone退出等待。新增8个API未生成；Google Drive/引用冲突/归档管理仍未完成。设置提示“保存不上传”已改为启用后真实配置变更触发，不恢复旧Mock语义。
- 普通云同步保持运行scope，不能调用configuration_restored误清无关连接确认/tmux/Agent；通过原账本/修改记录/配置/目标秘密CAS拒绝旧云提案，按替换主机来源撤销授权，configuration_synchronized只发布确有变化的样式/偏好。无变化ACK不拉帧/重设限额/刷新主机。NativeRPC的Arc名额租约必须跟随blocking worker，取消不能假装工作已经结束；已提交SQL ACK不能被迟到取消改失败。新11项测试源均未运行，继续其余Windows业务，不把源码提交当验收。

- Drive授权见GOOGLE_DRIVE.md及drive_oauth/google_drive_account/drive_authorization：仅用户自有桌面client、PKCE/外部浏览器/原state回环，禁止读取账号凭据；授权只存设备本机刷新令牌，AccessToken不跨FRB，local-google-drive-account-v1不备份/同步。原账号与独立代理/秘密最终同事务比较，单操作/5分钟退役/阻塞租约真实等待，取消撤销未知不当成功；16项固定码内存结果非日志。7个新API未生成/18项新测试未运行，Drive文件/条件传输仍未接，不能称云同步完成。完整备份恢复须取消原OAuth/旧sync owner并重新绑定；retiring owner必须保留到实际worker门控释放，不能因registry移除使退出丢失等待。普通云合并不走完整恢复分支。

- 归档管理见CLOUD_SYNC_ARCHIVES.md及cloud_sync::archives/workbench/configuration_sync_archives：设置+归档同读快照，最多8份/逐份释放正文，原scope/全列表修订与最终IMMEDIATE data_version复核。只允许明确确认删除旧非活动归档，不碰当前LEDGER/正式配置/云端，不把损坏行当空；ACK不后读。2个API/7项测试尚未生成运行。未来Drive对象须纳入同一目标身份规则，不能绕过当前目标归档保护。

- 工作台主题见APPLICATION_APPEARANCE.md：config-appearance-v1严格版本/原scope修订CAS，只有保存ACK更新Model.light；原型通过chooseTheme保留内存模式，正式卡片/菜单不得直接赋light绕过持久化。失败不默认覆盖，禁用并显式重读；解锁和恢复/云配置变化加载，关闭等待。主题入备份/云GLOBALS及候选验证，不改终端颜色/SSH或存窗口布局。2个新API/7项测试未生成运行，主机字体/Nerd候选及全Windows审查仍待做。

- Drive文件层源码见cloud_sync::drive_files及GOOGLE_DRIVE.md末节：固定API/appDataFolder/本应用属性，有界完整分页/同集合多ID不任选、生成ID能力明确创建加密正文，已存对象404不当Missing。读取和PATCH要求强原etag/对象集合复核，新etag+完整相同id才ACK，未知写不重发。6项新测试未执行；Google v3媒体条件/响应etag真实语义尚未核实，禁止据HTTP夹具标云端完成或降级无条件覆盖。正式Target/账号绑定/刷新令牌轮换/驱动/选择UI仍待接。

- tmux附着恢复最新静态源码覆盖旧“每次重选”：显式checkbox只记本终端/保存主机/原Vault/实际SSH HostKey+username及Session PID/ID/创建时间，下一次用户手动重连重新发现匹配才回答原请求。原owner/显示owner/代次分别保护，实际连接回执才激活，临时连接不继承。新2个API+2可选DTO字段待生成，3项测试未运行；可在应用命令关闭以后恢复而不动当前SSH/PTY。新建会话尚未确认实际身份，仍不得按同名盲记；继续此入口，不称tmux全部完成，见TMUX.md末节。

- tmux新建恢复覆盖上条新建待接：Core CreateRemembered用户确认后延到PTY/Agent准备，再专用exec new-session -d -P -F/-x/-y取严格身份/成功回执；不可按同名回查或-A。CoreIdentity经原ConnectionReceipt传Bridge，模式/尺寸/身份一致才激活。Agent按原协商向创建通道请求并检查Socket，缺环境前置失败不静默丢功能；绝不读取私钥/真实Agent。新建ACK后取消保留会话，UI已明示。4项新测试源码未运行，详细恢复入口见TMUX.md最新节，统一生成/编译/回归仍未开始。

- 同步ActiveTarget必须与LocalProposal.settings同一scope/完整检查点配对；不能因同集合/同对象相同就把外部编辑后的新提案与旧HTTP认证混用。prepare后ensure_proposal，网络前ensure_current+原提案，最终SQL CAS均保留。新增1项源码测试未执行；未来Drive账户/轮换秘密同样纳入此门控，见CLOUD_SYNC_RUNTIME.md末节。

- Drive Refreshed为原请求能力，access不公开，Account.accept_refresh在原账号及route前置事务ACK后才交出token；轮换保持authorization ID，无变化不写/不通知。正式驱动须先轮换ACK后再捕获最新账号提案，禁止混用新旧检查点。3项源码测试未运行；远端已轮换但本机CAS失败只能重新明确授权，不能声称回滚Google。见GOOGLE_DRIVE.md末节。

- Drive既有对象正式接线见GOOGLE_DRIVE.md最新节：Target.drive绑定file/client/authorization，真实账号原记录加入LocalProposal/最终SQL且保留本机数据；WebDAV不读无关Google行。共享OAuth名额下轮换ACK后才捕获提案，authorization_unknown与write_unknown分开；监视器失败可明确重读，无启动HTTP。发现/选择/首次创建仍待接；所有新增源码未统一生成验证。
- 含密码/凭据/命令的UI修订禁止裸SHA256：storage-sync::revision用Vault私有派生HMAC-SHA256+scope/域/长度分帧，现覆盖同步秘密/账号/备份与云提案/历史管理/归档正文，Snapshot.revision现收&Vault。旧标识非持久化，无DB迁移；SQL逐行CAS原样保留。hmac0.13依赖与lock待统一解析，不能手写生成绑定或称格式化等于编译。

- Drive正式发现/选择见drive_authorization::{Discover,Objects}与workbench/google_drive_objects{,_panel}：原账号+原路由/设置，轮换ACK后完整有界发现，仅选原候选ID；同集合不同ID不得任选，新目标须明确E2E密码及切换确认。3API/7测试源未生成运行。Model先关闭对象控制器再账号，取消退出/完整恢复都接；只读元数据，打开页无HTTP。现有Drive设置可直接禁用/改超时代理，地址集合只读；首次创建未知恢复仍待做，不能假称全部Drive完成。

- Drive首次创建见drive_setup及GOOGLE_DRIVE最新节：实际生成ID能力+确切E2E正文/原目标秘密先在本机两记录原子保存，排除所有备份/云载荷。每次明确继续GET原ID/完整正文，只有生成能力404准POST同一正文；attempted先落盘，未知/409不换ID。当前配置/账号/路由变化拒绝旧上传保留意图；最终设置与意图退休同SQL，源检查前data_version不能在末尾重新采样。5API/11测试源未生成运行。UI读取元数据无HTTP、明确核对/继续/仅本机清理（不删云对象）；staged/create_unknown/created/committed不同，真实Google条件能力仍待验。

- 云引用解决见cloud_sync::references、ExchangeStep::References及workbench/configuration_sync_references：不同原单位元数据独立RPC，不将秘密/历史正文或大列表入状态流；缺失不当删除、历史固定CRDT。原owner/op/review/source下选整单位，改变LWW结果才取新时钟；无效保留候选，完整校验成功换新普通审阅再确认上传，不能直接confirm引用阶段。412安全摘要始终对照最初Vault快照，本次提案不冒称本机已入库。2API/7测试源未统一生成运行；当前源码入口见最新PROGRESS。

- OSC133范围新源码见term-core::commands/SHELL_INTEGRATION最新节：C/D精确位置与单调行坐标、Row身份/可变访问修订，分页不得改证明，改后还原不可复活，完整输出才可冻结读取；只原NativeID/代次/帧坐标本地菜单操作，不是输入证明或命令采集。全终端8192范围/32768行证明；当前实际resize/ALT/RIS保守撤销，旧范围Reflow精确映射仍待做，不把它说成已完成。3API/17测试源未生成运行。Entry.search_gate现Arc拥有租约，search/export/copy blocking worker持有，RPC丢弃及销毁须等真实线程，不能恢复旧borrowed guard提前释放。

- Nerd内置候选见TERMINAL_TYPOGRAPHY最新节及assets/fonts/README：JetBrainsMonoNerd主字体仍原JBM，只增加明确1111码点MIT符号子集回退，不改默认/网格。HarfBuzz资产源工具固定输入SHA及允许列表，Font/Manifest/完整六份许可一起审核提交；应用不联网取字体。已生成455944字节资产，但2测试源未运行/未编译渲染；主机覆盖/共享偏好仍待做。不要把许可子集宣传为全量Nerd或恢复整包未审组件。

- 主机字体覆盖沿typography原本机文档hosts映射，不建新用户可见层级或云端字体文件；save_host原Vault/修订+正式Catalog/Host+所用字体正文CAS，None恢复继承。工作台forHost按各会话ID取值，不能全窗格用焦点字体；ensureHost仅open/文档变更/明确重试触发，构建/帧读取无IO，旧源失败不污染新源，退出等真实加载。删除字体回退全部引用的主机与全局但保留几何。本批新增API/测试未生成运行，见TERMINAL_TYPOGRAPHY.md和PROGRESS；下一步继续其余Windows源码，不提前启动全量编译。

- 通知静态接线见TERMINAL_NOTIFICATIONS.md：notifications属于原config-terminal-preferences-v1向后兼容字段，Prepared在提交前编译，Engine策略ID随配置发布；旧Notice必须核原nativeID/代次/策略，关闭/重连不得投递旧内容。BEL/OSC9/777及明确规则/静默共用有界预算，不走SFTP；普通文本/输入/历史不改。Hub拥有订阅/真实OS工作，退出等待，取消退出恢复；Windows通知默认关、正文默认隐藏，FFI插件仅Windows初始化通知身份，Linux不得构造Windows插件实例。新依赖3.1.1/锁和FRB/测试均待统一阶段，不能声称Windows送达已验。

- HostManager静态点击路径已核实TERM/初始SFTP目录/压缩是原型遗留的未保存控件，正式页现为当前真实值只读，Mock才保留模拟编辑；不能重新让它们标脏假装保存。V1.4没有额外确认这些主机覆盖，原正式SFTP/OSC7/tmux/字体不改；host_form_capabilities_test两项源码待统一执行，完整点击审核尚未结束。

- FRB错误安全见ERROR_BOUNDARIES.md：2.13正式生成的anyhow codec用Debug，不可仅加context脱敏。api.rs的202个Result现由业务源码PublicFailure包无source摘要；新增API先运行tools/bridge_error_boundaries.py --write并审查，再--check静态清单，不能手改生成编码器。只信任生产精确静态摘要和明确数字/枚举域，未知错误不打印原文；元数据失败字段也用public_errors::summary。Bridge私有产品边界log/max_level_off和编译常量阻止依赖原文日志；Core独立测试仍可捕获脱敏trace。此批8项测试源未运行，panic/tracing/其他UI错误仍须继续审核，不能宣称全部编码或脱敏完成。

- 错误边界续批在202入口加入guard/guard_sync捕获原函数体panic，不spawn脱离资源生命周期；工具能词法升级旧边界与rustfmt单表达式。首次调用先建固定诊断store再装一次不打印payload的hook，try_lock失败仅原dropped累计，UI新CoreWorkerPanicked枚举待生成；源码/4项新增测试均未验证。catch不保证abort/栈溢出或入口前FFI恢复，不可当成功/自动重试。见ERROR_BOUNDARIES和PROGRESS最新条目。

- 通用排版最新源码覆盖早期“所有排版仅本机”：共享terminal_preferences.typography只含有限几何/三个内置家族预设，系统/导入字体与host覆盖仍本机。typography::View组合共享与本机，HMAC修订/最终CAS覆盖两原行，全局save同SQL写两记录；旧无字段不读迁移，坏共享设置不默认覆盖。本机显式家族优先，选择本机字体保留共享内置预设。load等待真实原保存后重读；9项新增测试源码未运行，统一阶段再生成/编译。见TERMINAL_TYPOGRAPHY最新节。

- 可选资源/进程见REMOTE_INSPECTION.md：原Root单槽Inspector只固定隔离Python/Linux procfs，无任意exec/PTY输入。Entry.inspection原代次分别同意，进程列表30秒修订消费一次，SIGTERM必须原行且二次确认；pidfd前置创建身份检查，不fallback普通kill，不称进程已退出。前台焦点完成后5秒采样，其他情况下无timer，失败停表。Native关闭撤销，原SSH close根取消后等真实单槽worker（包括晚open和未知close）；不要在本地timeout丢russh open或让重试无限堆积。四API/14项测试源码未生成运行，Android仍暂停。

- TreeTransfer内部并行最新入口parallel.rs/run_parallel_observed，正式transfers内部3文件共享原SFTP/限速/单FIFO名额；原顺序接口保留。仅一份合并ACK/文件，所有Future归run并收尾，目录先验/失败子树不写、成功不重传、同目标（Windows大小写）串行。active_files仅UI运行元数据，dirty仍按每个原稳定节点；不能让瞬时重试恢复重写成功文件或把元数据100%当文件CLOSE。6项新测试/DTO/依赖未统一生成运行；远端中转并行仍待做。原SFTP session.close只排本机停止请求，不当对端退休ACK，后续生命周期继续审核，见PROGRESS末节。

- SFTP恢复最新源码见SFTP_RECOVERY.md：原Root SftpConnector64名额跟随未知open/真实stream（不是API），Root cancel后await全部退休。不要恢复timeout直接drop未知SSH open。vendor Session.close等两本机IO任务，非SSH peer CLOSE ACK；取消包含阻塞write/shutdown，typed ConnectionClosed与协议UnexpectedPacket/末端固定分类分离，不凭字符串自动重试。新open_sftp_with_retry绑定原generation最多3次，内容任务中通道故障停内部准入/排空Future，旧IO退役+完整检查点后最多2次恢复，只reset故障节点，保留ACK/成功/永久失败。中转工作中恢复仍待接，9项新源码未执行，统一最后验证。

- 远端中转最新并行/恢复见remote_tree/{file,parallel,recovery}及SFTP_RECOVERY末节：一个主清单、每file单节点副本、实际路径保持原index，同步checkpoint屏障后才继续远端mutation；3文件共原两端通道/限速/一个FIFO名额。主故障停止准入并排空全部Future，未知Intent/Publishing/Published不自动重放，普通失败不吞成通道错误。两旧IO均退休+原双端身份复核+全量落盘后最多2次更换通道，移动rename不纳入重试。vendor server::run原来detach，故障fixture必须用新增run_owned才能abort/await实际服务；此前生命周期夹具已改，11项新测试源码未运行，统一验证策略不变。

- OSC133旧范围Reflow新源码见commands/reflow及SHELL_INTEGRATION末节，覆盖旧“所有resize都撤销”：先旧行证明，再前后完整逻辑UTF-8摘要/长度与确切字节端点映射，重建原ID/新尾行证明。signed内部Anchor不改事件wire字段；宽字/组合完整，冷行逐行无整Grid克隆。16Mi单元/64MiB/每扫描250ms软预算，裁剪/不明确填充/超限降级，不恢复已失效行或未完成输出，不作输入采集证明。新Core8/原Native扩展未运行，sha2清单/lock和统一编译测试待收尾。

- Explorer单向拖入新源码见WINDOWS_EXPLORER_DROP.md和platform/explorer_drop.dart/windows/runner/explorer_drop.cpp：只CF_HDROP名字/Copy，不请求FILECONTENTS或删源；原会话固定/GetData重入后复核，hover一在途一合并，所有旧事件也ACK；DPR/可见区域/token/ModalRoute保护。FilesPanel只可见目录命中/750ms进入，Model owns批次与退出pending，视图卸载不改原冻结目标。enqueue_transfer新增expected_generation待正规生成，文件选择器同捕获原代次。9新测试及原Native扩展未运行；C++未编译或Windows实测，反向Explorer下载仍待做，不能说系统拖放全部完成。

- 任务异常收尾最新源在transfer_channels：Job/CopyJob拥有原SFTP Arc，run仅借用；supervise捕获原Future unwind后实际close_all，旧IO未退休禁止下一轮work并保留owner。FIFO permit现在跟随真实blocking worker，不跟外层await。vendor local_io_closed仅双本机IO位，非peer ACK；clear ended/switch Vault/非busy取消必须保留未退休owner，普通配置同步不重置任务。local run末尾dirty块落盘后才释放IO/删日志，最终DELETE失败不能重传成功文件。3项新Bridge与原Native故障扩展源未执行，统一最后验证策略不变。


- 2026-11-02继续：上传/下载选择器与Explorer现在共用Model.submitFileTransfers冻结请求批次、原会话代次、退出pending及部分接受计数。下载先校验全部选中文件名再入第一项，避免后续非法名字造成意外部分批次；文件选择前冻结下载列表，后续焦点/目录变化不改目标。新增3项模型测试源码未运行，仅Dart格式解析/diff；剩余Windows功能和统一验证仍未完成，Android暂停。

- FilesPanel列显示/排列已补运行期交互：_columnOrder/_hiddenColumns统一表头/数据/宽度，名称不隐藏但可移动。取消不发布候选，变更同步撤销Explorer旧view token，不做SSH/SFTP重连。新2项组件源未运行，不根据旧文件列表结构重写回固定四列；布局持久化未新增。

- 暂存清理见STAGING_CLEANUP.md：队列独立清单分页读取设备日志，已结束归档只进清理入口不恢复普通队列。原目标实际身份/代次与完整日志绑定一次性检查；REMOVE意图先落盘，未知不重发。未知创建/发布/删除后旧任务禁止续传，必须新任务随机名字；仅结束等待不判成功、不丢引用。检查/删除worker由CopyJob持通道及finished，清理持FIFO，局部元数据不能证明文件身份。新增6个API未生成、7项源码测试未运行，212错误边界仅词法清单；Windows其他编码继续、Android暂停。

- 手动重连传输恢复源码见TRANSFER_RECONNECT.md：resume_on_reconnect默认false、旧API None保持原设置。只保留本次原标签中断候选；主动暂停/取消撤销、库重开/跨启动不重建。连接前等旧检查点，实际回执代次/原scope/目标精确匹配，双端复制两端nativeID均已连接；不自动SSH、不复位失败或冲突、不重发未知操作。暂存检查也用cleaning，不得成为复制候选。Native固定报告与SSH状态分离，可选backend能力/顶部报告及队列一次刷新；5项源码测试未运行，213入口源码保护不是编译。

- 反向Explorer普通文件源码在workbench/explorer_export.dart，Alt拖出区分原内部手势；0.9.1两项MIT依赖仅声明未解析/锁定。原会话/代次/有序名字冻结，FILECONTENTS请求才原Rust预览票据完整下载，64KiB→原生临时磁盘sink，非CF_HDROP缓存路径/不打开关联程序。取消实际Future/源释放/EOF均在Model pending，不能把sink关闭算Explorer落盘。4项适配器源码测试未执行。目录/链接拖出、队列展示暂停恢复与COM注册共存仍待补，勿误标完整Explorer功能；详WINDOWS_EXPLORER_DROP末节。

- 未确认移动的只读检查已接ChannelBatch，独立批次关闭自己的IO、父任务保留全部未退休owner，Native blocking worker拥有实际查询；新旧票据规则保持。1项新协议测试源码未运行。全量生命周期审核下一入口包括previews::PreviewJob/release、editors::work/with_sftp与directories::ChannelLease::Drop；Root已限64槽/真实流退休，但不能因此把隐式Drop或丢close错误当完整业务收尾。

- PreviewJob已续接Channels监督与run外TaskPermit、并发cancel原finished屏障；cancel/shutdown先确认实际worker/IO再移registry或cache，清理失败保留owner/slot/运行锁且计32项预算。Root关闭后可明确重试；不保证故障时IO一定完成，清理超时仍报错误，许可仅覆盖这次清理尝试。1项新私有Native源码测试未运行，详FILE_PREVIEWS末节。编辑/目录收尾审核继续，Windows所有源码仍未齐。

- 当前跨服剪切源码入口：remote_tree/source_retirement.rs及SOURCE_RETIREMENT.md。新SourceRetirement只整树复制已确认后按后序删除来源，稳定元数据摘要+O(1)确认游标/当前Intent；未知不重发/不推断缺失，ACK后checkpoint，完成不删后来重建来源。本机结束只未知审计；类型/大小不是身份。4项源码测试未执行，sha2锁待最后。**正式Bridge/CopyOperation/队列/风险确认/源编辑互斥仍未接，旧跨服Move仍拒绝**，下步从该接入继续，不误算已可用或重复核心。Header-only增量发布须避免每删文件全树重写，结构/恢复仍完整验证。

- 跨服剪切正式源码现覆盖上条“入口未接”：Relocate独立操作，旧API默认不许中转，同账户仍rename。原整树确认后有界source_retirement元数据Intent/ACK，错误重读持久日志，JournalUnknown不得以内存覆盖。原父目录规范化/同密钥重叠源预留/编辑gate与双端代次；来源阶段仅continue，未知禁止重发。3来源未知API/离线本机一次票据及队列分阶段进度已接，所有保留设备日志的结束项保留隐藏owner。新增6项源码测试未执行，216错误保护仅词法；SOURCE_RETIREMENT.md最新节是接续依据，最后完整已验仍0e96be4。Windows其余继续，统一验证未开始。

- 编辑生命周期续源码：EditorEntry.channels持实际IO，remote(doc,...)统一原代次监督与select外FIFO；work在blocking线程guard_sync并最终retire，取消/关闭/stop_terminal同gate等实际IO，失败保留文档/草稿/外部租约并阻止替换通道。2项新源码测试未运行，不把Root界限当peer ACK；目录ChannelLease取消兜底仍待后续。

- DirectoryListings续源码已删除ChannelLease::Drop detached close；Cursor.channels +State.retired保留失败owner/reader/gate，opening barrier防止尚在open时提前prune。显式close按原代次/request，close_all遍历活动+退休，失败阻止下一打开；Root监视器只尽力，不能当成功。扩展原owned-peer目录/搜索RPC取消路径及1项barrier测试源未运行；普通CRUD的api::remote_sftp仍待审核。

- 普通CRUD cache续源码：remote_sftp首await前捕获generation并贯穿cache锁/退休/协商复核，close失败保留cacheowner；不借新Root。create/rename/remove可选expected_generation待FRB，正式Model固定原id/gen/有序多选并每项检查，pending持请求，原dir/epoch才刷新，更名用源文件原父目录。新私有Native1项源码未执行。

- 安全直传准备器新源码direct_transfer::{DirectProbe,probe.py}只做公共端点/原Agent epoch期限、固定probe命令和响应，无派发/正文。KnownHostsCommand原目标SHA256重算、StrictHostKeyCheckingyes、禁默认配置/密钥/外部Agent、固定argv/环境；Rust3+Python2测试源未运行。后续必须原Root独立exec所有权/请求原应用Agentendpoint/任务暂存回执后才接正式直传，DIRECT_TRANSFERS.md记录入口；不得把当前编译器/探测准备记完成。

- 安全直传续接覆盖上条“无派发”：Core DirectConnector已原Root单槽只读probe，ManagedSession需generation，原关闭等待slot，已协商Agentendpoint与原授权epoch前后核对，未知OPEN/CLOSE仍保留原槽。新私有双OpenSSH1项源码未执行；Bridge任务/正文/暂存发布/策略UI仍未接，DIRECT_TRANSFERS.md为恢复入口，别重复编写准备器。

- 2026-11-03直传新增正文/正式任务源码，恢复从DIRECT_TRANSFERS.md最新节，不再重复准备器：原目标SFTP一次cap/EXCL0600确认后固定rsync只写私有暂存，原Root/Agent/目标回执、原Vault跨await绑定；Header新direct默认false/旧relay默认true，正式UI显式直传/中转策略及SSH/SFTP路径一致条件。每任务Operations真实worker而非全Root槽计空闲，未知不清唯一owner或日志。仅整文件回执后确认，SourceRetire仍独立，直传中途未知的精确续传/结果再确认仍缺。全部新测试源未运行，DTO/API待FRB，216边界是词法而非编译。Shell可选集成问题已异步提出尚未获允许，继续Explorer等独立模块，勿偷偷注入/以OSC单独启用历史。

- 直传恢复续接以DIRECT_TRANSFERS最新节为准：Direct能力/单调attempt仅本机加密日志，原inode HMAC xattr/flock/进程组证明。明确继续只读核对，Complete不重读源，Partial仅旧进程组消失后rsync delta（--ignore-times、无append），pgid0/未知Busy保守失败，旧Intent不可收养。非秘密回执xattr随rename保留，FS必须支持；不改变Agent显式授权/不自动SSH。新测试源码未执行，统一最后验证，勿按前文“再确认尚无源码”重复实现。

- 孤立Explorer缓存清理新源在transfers/export_cleanup与workbench/explorer_cache_cleanup：新v2marker只匹配原Vault本机location owner，队列显式一次票据/确认/原scope与日志重查/活锁保留。旧v1/外库/可恢复引用不自动清。load_metadata仅用于保留根引用，缺块不撤保护，不能当完整恢复验证。3API未FRB/编译/测试，新增6项源码未运行，WINDOWS_EXPLORER_DROP最新节为准。

- openssh_direct_probe新增错误部分basis→真实rsync恢复/attempt2测试源码、receiver测试新增空成功/pgid0拒绝。均未执行，不当真实网络中断。当前两源码检查点f4c8942（直传回执）/c2c93ee（孤立缓存清理）未验证；最后完整已验仍0e96be4。

- 标题空白拖动源WindowDragRegion仅标题文字/顶栏余白，TerminalTabStrip可选onWindowAction仅顶栏传入，分屏内不传；标签拖动仍为TerminalTabDrag且会话不重建。新3测试未运行，WINDOWS_WINDOW最新节为准。正式Tooltip不再写模拟连接。

- 普通path:line[:col]新源terminal/remote_reference.dart，仅显示识别；原Rust resolver核CWD/authority，行列/单文件名确认后才SFTP定位，可选原文字面路径，不本机打开/不执行/不跳编辑器行。非法OSC8裸路径继续屏蔽。新6测试未运行，TERMINAL_PATHS末节覆盖旧path:line尚无源码。

- 批量跨语言源码名/命名字段审核可运行PYTHONDONTWRITEBYTECODE=1 python3 tools/bridge_contracts.py；230函数/72唯一Bridge结构/259Dart源当前0发现，仅词法、不是Analyze/FRB/编译。6项工具测试源码未运行，STATIC_REVIEW.md列盲区，不能将0发现当全Windows静态审核完成。

- 最新静态审核修复见PROGRESS 2026-11-03点击路径节：Native destroy保留closing Entry/close_state并允许原ID重试，普通entry拒绝closing；Dart Controller分Native/stream退休并保留晚create，Model退休session集合/显式命令及退出重试。主机choose/密钥ACK与FilesPanel危险确认/导航历史已补23项回归源码（含SFTP默认Core/云/Flutter），全部未运行。两代理后续因额度中断，主线程核对并补齐部分sftp_view_settings源码接线。新record已纳入云/备份，默认修订才重置列表局部选项。下一步load快照竞态、设置dirty离开守卫、队列正确候选及Shell决策；禁止按此节点宣布全Windows源码齐。

- 主机目录新源Repository::metadata_snapshot同SQLite读事务→host_catalog_snapshot→NativeHostStore可选能力；Model catalog epoch/关闭及scope保护，host/draft保存ACK使旧读失效，load Future入pending。旧FakeHostStore接口保留；6新测试源码未运行，新DTO/API待生成。38a060c为前批未验证检查点，下一步设置dirty/队列候选/Shell决策，最后统一构建不变。

- 设置八类正式表单已接SettingsLeaveScope/guardSettings，类别/外部initialCategory/整页离开统一检查。保存busy不可丢，dirty默认返回编辑或明确放弃；注册无秘密副本。5项新UI回归未跑。队列chooseTransferConnection先原id+gen再当前焦点，3项新源码未跑；完整目标身份仍Native校验。主机metadata_snapshot逐条有界草稿读取，不还原全量凭据Vec。新节点仍未编译/测试，Shell可选集成决策尚无回答，后续按PROGRESS继续，不能冒称全Windows编码齐。

- 队列恢复可显式选择现有源/目标SSH标签，TransferConnectionRef固定对象/nativeID/generation，任务/连接变化禁确认；resume_transfer及resume_remote_copy新增可选代次参数，正式队列始终传，完整Native实际端点身份仍必核。队列control/clear及列表读取已接退出pending/closing守卫；6项UI/引用及原Native代次扩展未运行。见TRANSFER_RECONNECT最新节，新参数待正规生成，不手改旧FRB。历史记录开关也补离页保护（八类之外的第九类），通知导航走PrototypeAppState.activateTab。

- 2076328为新可选集成基础UNVERIFIED；后续已补固定只读Bash版本/devfd预检、明确不支持同Root普通Shell回退和3项私有HOME OpenSSH源码（均未运行）。输入proof是私有State的元数据，不能将Host开关/integration_scope或OSC133当Ready。候选/受控actor动作/路径发送仍接续，详PROGRESS最新节。
