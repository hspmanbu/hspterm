# Explorer → SFTP 拖入上传（源码检查点，未统一验证）

## 范围与入口

Windows runner的explorer_drop.cpp实现OLE IDropTarget及hspterm/explorer_drop通道。当前仅接入Explorer本地普通文件/目录拖到当前SFTP列表或目录行的上传请求。后续新增普通文件Alt拖出虚拟下载源码见末节，目录拖出及正式队列仍未接齐，不能将本模块计为完整系统拖放；原Flutter内部远端移动和终端路径拖放语义独立。Linux无此适配、不用其组件测试冒称Windows实测；Android继续暂停。

[RegisterDragDrop官方文档](https://learn.microsoft.com/en-us/windows/win32/api/ole2/nf-ole2-registerdragdrop)要求OLE初始化及STA消息泵；main.cpp改用有完整退出/创建失败收尾的OleInitialize/OleUninitialize，保持原窗口退出确认。View HWND注册只在首个可用区域bind时发生，不覆盖失败的其他注册；窗口销毁先禁用State/撤销注册/移除通道，再释放引擎。COM对象引用跟随实际Target，共享的晚引用仅见已停用状态，不借用已销毁窗口owner。尚未编译或验证重入/退出行为。

## 数据、安全与交互

- 仅查询CF_HDROP/获取Unicode名字块，不请求FILECONTENTS、不读本地正文或发Shell/SSH命令。[DROPFILES文档](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/ns-shlobj_core-dropfiles)的偏移、宽字符标志、双NUL均检查；4MiB块/UTF-8、4096项、32767 UTF-16单路径上限，非法代理项/相对路径/设备命名空间拒绝。仅拿到名字不是文件已上传，后续仍走原Rust扫描、源类型/链接/偏移与CLOSE规则。外部IDataObject可能延迟提供名字，不保证其内部实现无IO。
- Native同步按Flutter发布的实际物理客户区矩形返回Copy/None，不发送Move或要求Explorer删源；[DragOver官方文档](https://learn.microsoft.com/en-us/windows/win32/api/oleidl/nf-oleidl-idroptarget-dragover)规定所选效果必须属于来源允许范围。没有额外文件数量/路径/缩略图预览。复制效果只表示交付上传请求，真实进度/失败在原队列显示，无SFTP桌面通知。
- 每次拖动在首次接受时固定会话owner；焦点换到另一个会话后拒绝这次拖动，须重新进入。GetData可能重入COM泵，因此Drop在取数前后复核原owner/zone/drag及alive，不能将旧文件投到新标签/目录。
- hover最多一个在途事件加一份最新合并坐标，Dart无论接受还是拒绝旧事件都ACK；Drop/Leave有独立一次性事件，不按高频鼠标积压所有位置。无文件路径预读/目录轮询，名字仅Drop交付。
- ExplorerFileDropRegion将物理坐标按实际DPR换成Flutter全局坐标，并再次检查可见区域。source/view/几何/滚动/ModalRoute改变使旧token失效；底层确认框、重命名、加载中、断线、隐藏侧栏/队列最大化没有有效接收面。仅可见目录行做命中，目标高亮，750ms悬停进入子目录，离开取消。
- 释放时固定原会话、代次、目录及有序名字。目录一项仍一顶层任务；正式Model接管批次并加入退出pending，切换/卸载侧栏或后续浏览目录不把剩余文件误投到新位置。真实断线/关闭/重连则停止未入队项，已接受项由原队列处理，部分失败仅报告计数并要求核对队列，绝不自动重复整批。
- enqueue_transfer新增可选expected_generation，在捕获Connection时核对，原enqueue内部再次检查原Root及门控。上传/下载选择器也冻结用户选择前代次；Live Model拒绝退出期间的新入队，不在一轮选择后改用重连后的新Transport。新参数必须最终正规FRB生成，未手改生成代码。

## 待执行验证

新增Dart/组件9项源码：字名边界、物理坐标/ACK/一次Drop、旧源/旧目录拒绝、滚动令牌、确认框禁用、畸形数据/坐标、平台禁用、文件夹落点、延迟进入/重连停余项，以及侧栏卸载后冻结批次继续；已有真实Native并行传输夹具扩展错误代次拒绝/不产生任务。它们是路由/协议或源测试，全部尚未运行。实际仅Dart/Rust格式解析、206公共入口错误边界清单及diff；C++未编译/语义分析，未Win实测，未重新截图。

统一阶段先解析依赖/审核锁、正规FRB生成，再Flutter Analyze/全量测试与Rust检查；Windows上按WINDOWS_WINDOW.md和tools/build_windows.ps1构建，不可用旧DLL或旧API绑定测试新增字段。

Windows11人工验收：

1. 两台可控SSH会话，分别拖文件/空目录/Unicode及空格名字到空白与目录行；核对真实字节、空目录、源保留和一个目录一个任务。
2. 750ms悬停导航、离开、Esc取消、只读/失败目标、多选、部分入队；拖到终端/任务队列不上传，后台任务继续。
3. 快速切标签、重连、刷新/过滤/排序/滚动、关标签、打开确认框及退出，拒绝迟到目标，无意外新SSH或重复任务。
4. 100/125/150/200%缩放、跨屏DPI、侧栏宽高/队列最大化；Native光标效果和真实高亮/落点一致，无自绘预览。
5. Unicode CF_HDROP、缺双NUL/错误offset/无效代理项/超容量/仅虚拟文件格式；失败不入队、不删除本地源。COM GetData重入更新或窗口销毁的故障夹具仍待Windows执行。
6. 多轮开启/撤销注册/拖动/退出后核对句柄、引用和内存；Revoke异常只能保证共享State已禁用，真正OLE释放及原生消息顺序留实机确认，不以静态源码保证无任何泄漏。


## 普通文件反向虚拟拖出源码（未统一验证）

新增workbench/explorer_export.dart，Windows按住Alt拖动普通远端文件交给Explorer，普通手势保持原Flutter内部移动/路径拖动。冻结原会话/代次/路径/有序多选（128项），元数据构造不请求网络或正文；只允许Copy，不要求源删除。拒绝Windows设备名/ADS/路径分隔/无效UTF16/尾点空格/重复名称，不截断、自动改名或把路径混入名称。提示已接真实行。

依赖固定super_drag_and_drop与super_clipboard 0.9.1，MIT；此轮只声明清单，未安装、锁定、编译或进行平台语义验证。接口依据[官方包说明](https://pub.dev/packages/super_drag_and_drop)、[虚拟文件provider](https://pub.dev/documentation/super_clipboard/latest/super_clipboard/VirtualFileProvider.html)、[取消进度](https://pub.dev/documentation/super_clipboard/latest/super_clipboard/WriteProgress-class.html)及[临时磁盘存储](https://pub.dev/documentation/super_clipboard/latest/super_clipboard/VirtualFileStorage.html)；最终依赖审核须包含传递Rust依赖和许可，Flutter依赖许可查看入口保留。Windows源还核对了官方仓库的win32/data_object.rs及drag.rs中的虚拟文件和OLE实现，但尚未做C++/Rust平台编译。

接收方请求FILECONTENTS时才复用原previews Rust票据进行一次完整只读SFTP下载，复用FIFO/下载限速及文件CLOSE确认，不打开系统关联程序、不读取本机SSH凭据、不写PTY。未确认完整文件不交付正文。完整快照后异步64KiB块读取到明确磁盘存储的原生虚拟文件sink，无整文件readAll/FRB正文复制。会产生预览快照与原生spool两份临时磁盘数据；磁盘失败必须报失败，不能因此牺牲完整性。接收方可在OLE流程中提前请求数据，不能承诺所有外部应用都在最终Drop之后才请求正文。

取消连接原票据的实际cancel Future，释放异常被观察；完整读取与源释放之后才关闭sink。整个provider及本机结束信号纳入Model的pending，应用退出逐块取消并等待；原标签移动/焦点变化不重定向，准备前断线/重连拒绝旧代次。错误给接收方固定失败，不将OS路径/source错误链发给平台，也不把sink结束当Explorer目标已落盘。取消可能留下接收方部分文件，目标由Explorer管理，应用不猜路径或清理其他进程文件。

**仍未完整**：目录/符号链接拖出、独立HSPTerm队列展示/暂停恢复及Explorer接收方写入确认。没有用上述普通文件源码替代这些需求，下载选择器完整目录任务保留。原IDropTarget只接受CF_HDROP名字，反向虚拟来源不提供该格式，拖回本应用不能意外上传缓存文件；仍需Windows验证插件拖出与原注册的实际共存/COM重入/撤销与退出。不可将Linux导入或适配器测试算OLE实测。

新增4项纯适配器测试源码：Windows名称/UTF16边界、逐块完整字节与先释放后结束、取消等实际停止/源不删、长度不符与清理失败；均未运行。还需统一阶段真实私有SSH快照+接收方消费故障，以及Windows多选、慢盘、空文件、大文件、断线/关标签/退出、Esc、复制到Explorer冲突提示和多轮资源回收验收。

## 目录描述符与可复现依赖准备（2026-11-03源码，未统一验证）

`ssh-core::explorer_manifest`从同一个下载TreeTransfer投影描述符：每项保留原root/node索引，父先子后，目录（包括空目录）明确标识；不读取正文、不创建文件、不改名。整批最多128个所选根/32768描述符，完整Windows相对名最多259个UTF16单元，分量最多255。拒绝点段/设备名/ADS/尾点空格/Windows大小写冲突、链接特殊文件及扫描失败/跳过项；不把缺项导出伪装完整目录。仅核心清单接口，**尚未接实际目录拖出、缓存租约与正式队列**，正式UI当前仍拒绝目录。

核对固定`super_native_extensions 0.9.1`源码发现其虚拟文件描述符没有目录属性，并会截断过长名字。新增`tools/native_extensions_descriptor.rs`维护最小Windows补丁：明确`FILE_ATTRIBUTE_DIRECTORY/NORMAL`，文件`FD_FILESIZE`与64位长度（含空文件），拒绝全组超容量/重复名/不安全名及过长UTF16，绝不截断。应用私有格式`HSPTerm.VirtualDescriptor.v1`为固定10字节：版本1、目录标志0/1、8字节小端u64长度；目录长度必须0。目录同样保留虚拟项目索引，未来不能只平铺文件而丢空目录。未带标记的原普通虚拟文件仍可工作，当前正式普通文件入口未因UI旧尺寸而伪造`FD_FILESIZE`。元数据不是落地成功回执。

`tools/prepare_native_extensions.py`只下载固定公开归档（可`--archive`离线提供），SHA256固定`b9611dcb68f1047d6f3ef11af25e4e68a21b1a705bbcc3eb8cb4e9f5c3148569`，有压缩/展开预算、禁止链接与越界tar路径；核对唯一补丁锚点后写入`ui_flutter/.dart_tool/hspterm_native_extensions`，保留整个上游源码/MIT。pubspec显式path override指向该副本，**不是修改全局缓存，也不隐藏fork**；所有准备后源码/补丁都有散列清单，重跑遇修改拒绝覆盖，未完成目录也保留供检查。工具不执行上游代码、不运行pub get/构建；`tools/build_windows.ps1`已经在pub get前调用，新增Python3前置条件。手工Linux/Windows验证及`flutter clean`后须先运行准备器；当前开发轮没有运行准备器或重新建立依赖缓存，锁与传递依赖许可审查仍留统一阶段。

准备命令（最终统一阶段）：

```sh
python3 tools/prepare_native_extensions.py
cd ui_flutter
flutter pub get
```

依据[固定上游包](https://pub.dev/packages/super_native_extensions/versions/0.9.1)及[FILEDESCRIPTORW](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/ns-shlobj_core-filedescriptorw)。新增4项Rust清单/5项Python准备器/2项补丁内Windows属性测试源码，均未执行。实际仅Rust/Dart格式解析、Python AST及diff检查；并补正原Flutter普通文件设备别名`CONIN$/CONOUT$/dotless-i`拒绝和整批保守大写比较。未做C++/Windows Rust编译、COM/Explorer或目录消费队列验收。

下一步从原会话的后台扫描/原任务清单与独立缓存租约接真实目录导出，再接一个目录一个队列任务与实际provider消费生命周期。不得简单提供临时目录CF_HDROP后在DragEnd删除：接收方可能仍异步读取；不得将Native provider EOF当Explorer目标已持久化。

### 普通文件拖出与显式打开的链接语义分离（源码未验证）

新增同步`reserve_explorer_file_export`，绑定原SSH代次及不可改变的`Purpose::ExplorerCopy`；正式Alt拖出改用它，原`reserve_file_preview`保持`Purpose::Open`。两者复用实际下载/缓存/限速/取消与IO监督，但拖出仅规范化父目录，再对最终分量执行lstat及原下载的普通文件检查，不再通过预览的全路径REALPATH把符号链接解析成普通源文件。这避免旧目录条目变为链接后被静默作为其他目标下载；不声称SFTP v3的lstat→OPEN能防御任意恶意服务器或并发名称替换，原协议仍无原子NOFOLLOW保证。用户主动进入的符号链接父目录仍按既有规则解析。

原私有Native预览夹具扩展：同一链接用拖出票据失败且无本机发布，显式打开仍成功，普通文件拖出完整字节、源/链接不变且PTY继续连接。测试源码未执行；新增API必须最终正规生成FRB，不手改生成文件。原最终CLOSE失败、FIFO、确认阈值及取消测试保留。

### Native消费请求的有界准入与取消错误（源码未验证）

Explorer可能同时请求全部FILECONTENTS或重复请求同一项。正式拖出新增进程内有界FIFO准入（3个处理中的源请求、合计256请求上限），**在Rust票据预留之前**排队，避免128文件选择被原32票据预算直接拒掉。它只限制跨语言准备压力，真正传输仍走共享Rust FIFO/并发/带宽；不是另一套任务队列，也不作为实际IO退休证明。超过安全容量明确失败，不丢弃已有接收。等待中取消移出队列且不预留Rust票据；活动取消等待处理与清理尝试返回，未知实际IO仍由原Rust注册表持有，不借本机计数宣称远端CLOSE。

只有经过清理的本地类型化取消可安静结束；取消期间的停止/缓存释放失败仍进入Model错误监控及Native失败流，不因cancelled标志丢失。新增4项Dart测试源码覆盖FIFO/取消未启动与活动槽/容量及失败恢复/实际流取消后清理失败；未执行。使用Completer控制实际边界，不依赖固定延迟猜清理已结束。只做Dart格式解析，当前flutter_lints依赖缓存缺失警告保留，未声称Analyze。

公开上游归档另经只读静态审核：360998压缩字节/1502228普通文件展开字节、297成员，实际散列匹配固定值，零链接/特殊项/非规范名称，MIT文件存在，Rust edition2021。这只是公开依赖源检查；未执行准备器、依赖求解、补丁代码测试或平台编译。


### 拖入/拖出共用HWND的实际冲突修复（源码未验证）

进一步静态追踪固定包`super_drag_and_drop/lib/src/drag_internal.dart`：即使仅使用拖出，也会初始化raw.DropContext；上游Windows的assign_weak_self无条件RevokeDragDrop后再注册自己的目标，会撤销runner的现有拖入接收器。这不是仅“待实机观察”的风险，源码已明确发生争用。当前维护补丁同时修改win32/drop.rs：发现`HSPTerm.ExplorerDropOwner.v1`窗口属性就不撤销/不注册/不安装销毁回调；设置空hook并在Drop中安全跳过，避免Late未初始化或错误注销runner。

Runner把ExplorerDropBridge创建移至RegisterPlugins之前，以RAII属性租约保留HWND，失败拒绝初始化；构造中途异常也自动撤属性。实际IDropTarget仍仅有效区域bind时注册，失效区域保持拒绝；bind前复核自身属性，不替换其他owner。析构先禁State/取消通道，再仅在仍拥有属性时撤自己的Target，最后RAII移除属性。插件此窗口只提供拖出IDataObject，应用内接收仍由原CF_HDROP桥处理，不新增插件DropRegion。新增准备器源码测试核对保护在Revoke之前且空hook析构匹配，尚未运行；真实Windows消息泵/热重载/往返拖放和销毁仍必须最终验收，不以本次控制流审查冒称通过。

## 最新：真实目录源任务与消费接线（覆盖此前“目录仍拒绝”，源码未验证）

正式Alt拖出现统一支持普通文件/目录，冻结原SSH代次/有序选择/Windows名称和类型，不跟随链接。transfers::explorer提供7个新API，复用一个根一个TreeTransfer/FIFO/下载限速/内部3文件并行；目录扫描先停，Native请求才完整下载。扫描时早停32768项，普通任务仍原百万预算；整批128根/32768项/259UTF16规则保持，空目录保留，不截断。

storage-sync::export_cache是独立于预览/编辑的持久私有源缓存：owner/registry锁、安全namespace/payload/marker、链接及reparse拒绝、未知兄弟保留；Drop只关锁不删部分字节。未完成源任务与偏移进原设备加密日志，正文不经FRB/配置同步/备份。Unix检查UID/0700，Windows依赖应用私有support继承ACL，实机权限仍待验。

整树完整且真实文件/通道IO退休后才返回本机缓存路径，64KiB→Native磁盘spool。ExportReady仅是源快照就绪，队列条目可离线重新拖出，包括重开加密库后，不自动建立SSH。暂停/失败沿原偏移和成功节点继续；冻结清单不能更名/跳过/重扫改变Native身份，修改清单应重新发起。源就绪后的本机写入由Explorer控制，队列不伪造外部目标进度/速度/暂停。

交付租约及逐文件本机读租约阻止早删缓存/切库，文件关闭后才返还read票据；失败保留票据可明确重试。每租约共享冻结/就绪清单，避免逐文件解密整树的O(N²)成本。Native注册/Dispose与准备中晚票据/实际provider共同退休；DragEnd不是结束。纯空目录/零字节文件可以不请求FILECONTENTS，明确Copy时仍确认实际源任务和零文件元数据。旧Native租约不接管新SSH代次，重连恢复暂缓有活交付的源任务。

队列新增“结束所有Explorer交付…”：取消源并排空实际本机读取，保留未完成源快照/检查点，随后可切库；退出也先关Root、取消、等读者，再释缓存。无SSH的离线活交付同样退出确认。充分交付EOF/零文件描述符后显示“数据已交付·目标由Explorer确认”，不是目标落盘ACK；应用不猜外部路径或删其部分文件。后来的Native回调只得到已结束错误，不开始新源。

新测试源码均未运行：缓存锁/部分树/退休/未知兄弟2项Rust，真实私有OpenSSH目录扫描无正文/一个任务/Unicode空目录/字节/读租约阻清理/设备日志重开及离线交付1项Native，队列源就绪语义1项组件。原IO/取消FIFO/Preview和Phase2入口保留。新DTO在transfers/explorer，需最终正规FRB生成；本轮只有Rust/Dart格式解析、公共入口词法检查/diff，没有Analyze/编译/测试。flutter_lints缓存缺失警告保留。

统一阶段还须验证暂停偏移/部分失败、重复请求/慢盘、注册前取消/晚票据、返还ACK失败、退出/多进程锁、真实Windows OLE消息泵和DPI。未引用的异常残留源缓存仍缺全局清理工具；不能自动删除未知目录，保留为下一收尾项。


## 2026-11-03 孤立源副本显式清理（源码，UNVERIFIED）

队列增加“清理孤立导出副本”入口，只检查本机应用support缓存，不联网、不删除远端来源/Explorer目标，不在启动或定时自动回收。新导出使用v2 marker，归属随机ID来自本机加密 `local-explorer-owner-v1-*`；记录键绑定原Vault规范文件位置（Unix还绑定dev/inode），不会随配置同步/完整备份复制。不同位置的完整SQLite文件副本也必须生成不同归属；移动Vault不猜测认领旧namespace。Windows原路径上由应用外替换旧数据库不属于自动恢复机制，不能以复制数据库代替正式备份恢复；实际应用backup restore保留设备本机记录。

检查排除当前库全部设备任务根路径与运行owner，原owner.lock有活租约不可回收；其他归属、旧v1无归属、未知文件/类型不推断为本库垃圾。仅本批最多128项，目录扫描最多10000项；清单显示缓存自身不透明basename，不展示远端路径或下载正文。确认默认为取消，一次性票据5分钟、最多16个；关闭仅释放票据，无删除。确认时重新核对原Vault scope/归属/全部日志和运行引用，再逐个锁定原目录复核marker，返回已删除/保留/失败数，部分失败不能冒称全部清理。实际删除在blocking worker，Model pending覆盖工作；清理原registry顺序与任务入队/切库一致。

为避免清理先解密每个目录清单全部节点，LocalTaskJournal新增只读load_metadata及Bridge protected_local_reference；根损坏报错，正文块缺失时仍保留已认证根路径。这个接口**不能恢复传输**，原load_parts完整版本/块修订验证保持。

新增storage缓存归属/孤立过滤2、缺块仍保护1、Bridge根引用保护1、Flutter确认与小窗滚动2项测试源码，另备份排除清单扩展。均未运行。仅rustfmt/Dart format、公共错误词法清单与diff。3个新增API/DTO待最终FRB生成；Windows锁/ACL/目录删除与实际UI待统一验证。旧v1无归属缓存刻意不做自动升级清理，只有原任务已知路径的既有退休流程可处理，不删除未知目录。
