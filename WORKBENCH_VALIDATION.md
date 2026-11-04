# 真实工作台整合：Ubuntu 验证记录

> 2026-11-04最新收尾：正式Windows功能源码已接入，Ubuntu适用507个去重Flutter用例/143文件、29个GTK文件、Rust完整与安全补丁影响范围均已收齐；正式双模式构建/正常退出验证完成。见[最终验证目录](validation/windows-unified-2026-11-04/README.md)。本文件其余部分为历史节点，不据旧“尚未实现”重复开发；Windows MSVC/C++及真实系统行为、云账号待验，Android暂停。

本文件按开发节点追加，早期数量和未完成项是当时快照；最新代码/测试状态以末节及PROGRESS.md最新恢复入口为准。

范围：正式入口 `ui_flutter/lib/workbench_main.dart`，复用已验证的终端核心、Phase3A标签组布局；独立Mock入口继续保留。本记录不表示完整Phase3B/V1.4完成，也不代表Windows/Android实机通过。

已实现：Rust加密主机/独立凭据/分组/元数据批量编辑/草稿/复制与幂等旧格式迁移；工作台主密码打开/创建、显式保存、加密去抖草稿及离开保护；一标签一独立SSH/PTY/控制器；视图可见租约；显式断开/手动重连；同Transport/同代次SFTP目录导航/LRU、实际新建/重命名/删除/移动。二进制分块API只是传输原语，不是完整传输任务系统。

已执行：Rust workspace46项、all-target Clippy拒绝警告通过；Flutter全量34项通过（原Phase2/Codex12、原型21、真实工作台1）。最后元数据草稿/旧入口兼容补丁后真实原生工作台1项再次通过。最后全量34项再次通过，另有3项工作台创建/退出/可见性竞态测试通过。20次原生生命周期RSS差值+364,544字节是独立短样本，不作为长期泄漏判定。

真实GTK工作台集成1项最终通过，包含三会话/布局/键盘/真实SFTP，以及主密码不一致拒绝、首次建库、经主机编辑页面显式保存、草稿不提前生效、磁盘不含测试密码明文。最终截图[双组真实终端与关联SFTP](validation/phase3b/live-workbench.png)已查看，只有合成回环内容。

```sh
# 根目录
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked -- --test-threads=1
cargo build -p hspterm-frb-bridge --locked
# ui_flutter目录；Flutter/cargo须在PATH
flutter analyze
flutter test --reporter expanded
python3 benchmark/external_editor_gtk.py flutter test integration_test/live_workbench_test.dart -d linux --reporter expanded
flutter build linux --debug -t lib/workbench_main.dart
flutter build linux --release -t lib/workbench_main.dart
```

夹具使用运行时生成的临时密钥/加密库/回环sshd，不使用生产服务器。GTK窗口和真实SSH/SFTP均实际运行；文本输入通过明确注册的Flutter测试TextInputClient，物理按键经过TerminalView，不能当作目标平台IME验证。最初未注册测试客户端导致再次编辑确认密码没有送达，修复夹具后通过；无D-Bus的初次启动也失败，最终命令使用独立D-Bus。失败没有跳过断言或算作通过。

尚未完成：批次策略/局部重扫、预览编辑/外部关联程序、文件复制剪切粘贴/Explorer拖放、完整高级连接、持久设置/协议语义与增强、同步备份、Windows原生及Android业务。未接业务入口显示明确未完成提示；仅复制路径为安全降级，不能冒充可靠Shell路径注入。SFTP暂缺独立死通道重开与符号链接目录显式导航；局部文件选区/列状态重挂载保留继续跟踪。

Windows/Android后续实机事项和构建前提见PLATFORM_VALIDATION.md；完整条目状态见REQUIREMENTS_COVERAGE.md。构建最终结果与下一模块以PROGRESS.md最新节点为准。

正式入口debug/release构建通过。独立二进制启动/实际GTK关闭均退出0，Rust已加载，锁库首屏无SSH/历史/擅自建库。密码框聚焦的5秒样本：debug RSS439,926,784字节/CPU5.20%，release RSS278,339,584字节/CPU4.80%；原始JSON在validation/phase3b/smoke-*.json。不等同终端空闲或泄漏结论。复现：

```sh
xvfb-run -a dbus-run-session -- python3 ui_flutter/benchmark/workbench_smoke.py ui_flutter/build/linux/x64/release/bundle/hspterm
```

原SSH GUI及Codex隔离GUI最后各1项回归通过；原SSH GUI生命周期RSS差值-1,527,808字节。Codex仅临时HOME/CODEX_HOME和回环合成服务，不读取真实凭据或执行付费任务。

后续原子建库/目录容量修复后，storage-sync9项、真实原生工作台及GTK工作台各1项再次通过。完整有效新库才发布最终文件，已有文件永不替换；见PROGRESS最新节点。

## 密钥管理与目标快照后续回归

Rust全量55项与Clippy all-targets拒绝警告通过（`.local/identity-final-rust.log`、`identity-final-clippy.log`）；新增Ed25519/OpenSSH口令单测、主密码验证及真实生成密钥认证。Android aarch64/API26共享核心check再次通过，仍不是APK或设备验证。

原生GTK文件打开/保存、错误主密码/拒绝覆盖、公钥查看、草稿重启恢复实际执行；日志必须包含 `Verified native GTK key open/save and persisted draft recovery`。曾暴露密码弹窗提前释放控制器异常，已用路由State所有权修复并复验，未跳过断言。会话目标独立快照/显式重连更新、旧SFTP缓存失效与TOFU目标另外纳入真实三连接回归。详细边界见KEY_MANAGEMENT.md；本节点最终全量/GUI/双模式构建结果在PROGRESS末尾保存。

## 真实传输队列后续回归

正式工作台已接文件/目录选择上传、选中下载、真实FIFO/加密检查点与内联任务操作。详细生命周期/平台限制和未完成项见TRANSFER_ENGINE.md；早期“任务仅Mock/尚未接”的文字是对应历史节点，不代表当前状态。`transfer_bridge_test.dart`实际OpenSSH/FRB完成32MiB暂停/目标绑定/重开库恢复/目录冲突/下载/取消与断开保护。`transfer_queue_test.dart`明确为UI路由夹具，覆盖2000项按需创建/Ctrl多选/260px侧栏及1.5文字缩放，不能代替真实网络验证。GTK集成实际经原生选择器上传合成文件、核对远端内容并展开真实完成详情；日志有独立完成标记。

发现并修复空白行点击不选择、放大字号导致进度/标题栏溢出；不通过隐藏错误或放宽断言处理。原SSH/真实Codex隔离GUI和最终debug/release构建的结果见PROGRESS末尾及.local/tasks-last-*.log，不把早期通过日志当作最后代码的结果。

终验另复现隐藏在途帧竞态（native_bridge原断言15→16）：通过等待该帧处理完成后才返回隐藏，保留Rust已推进基线的增量；序列化原生显隐顺序并在关闭前排空。新增2项延迟回归通过，未放宽旧断言。最新全Flutter43项和Analyze通过；最终GUI/双模式结果见PROGRESS。

速率/明确覆盖节点最终：Rust65项/Clippy/Android核心check通过；Flutter45项/Analyze通过；GTK实际同名默认保留、明确从头覆盖及内容核对通过，并保留完整密钥/草稿流程。debug/release均已构建（.local/rate-restart-*.log）。32MiB原生传输回归继续通过；显示速率单位是确认字节有效吞吐，不是物理链路速率。最新截图validation/phase3b/live-workbench.png。


## 全局限速与持久并发节点

Rust70项/Clippy拒绝警告/Android核心check、Flutter47项及Analyze通过；真实GTK工作台1项实际修改并加密保存并发和带宽，再读Rust值核对；日志.local/limits-*.log。debug/release正式入口构建成功。设置截图[transfer-settings.png](validation/phase3b/transfer-settings.png)已查看。Windows/Android运行未验证，核心NDK check不等于APK。

测试包括虚拟时钟下三任务共享令牌、低速取消与动态调整、方向独立；合成SFTP逐个校验READ请求而非仅消费进度；真实OpenSSH三通道上传和下载核对。真实FRB另测1字节/秒等待时PTY响应、暂停/提高并发/不限速继续、重开配置恢复值、不自动传输。配置写失败/无效值/新版本记录明确拒绝，UI读失败不能保存默认值覆盖原数据。非传输设置仍标原型，未声称已全部接入。

## 目录扫描分页节点

目录任务通过按页READDIR释放属性数据，剩余项数/32MiB相对路径UTF-8预算提前检查；原收集API保持迭代顺序，用双端队列消除每页复制旧数据。分页/提前释放/EOF与关闭错误/2048文件扫描取消/容量边界回归通过。最终Rust74项、Flutter47项、GTK工作台1项、Clippy/NDK核心check及正式debug/release构建通过（.local/directory-*.log）。浏览器桥接全目录返回与大清单检查点成本仍未解决，不以此节点宣称所有目录性能完成。

## 任务内批次同名冲突

当前任务当前Conflict文件可在确认后全部明确覆盖/全部跳过，取消无动作；已完成/其他失败项不受影响。真实SSH/FRB混合冲突/普通失败及跳过回归通过；未知动作/无单项范围更名被拒且旧目标不变。Rust74/Flutter48及GTK工作台1项通过。最终560px确认框后另复验queue3/GTK1、原生FRB1；最终debug/release重建通过（.local/conflicts-final-*.log）。[实际GTK确认框](validation/phase3b/transfer-conflicts.png)已查看，仅合成数据。批次更名/默认策略/失败目录重扫等仍待实现。


## Windows路径映射与POSIX名称隔离

新增TRANSFER_PATH_SAFETY.md。清单保存POSIX分量，本地映射前做Windows规则/命名空间检查；名称不静默修改。4项Ubuntu规则测试、8种特殊名真实OpenSSH双向传输、单文件根更名的真实FRB源/目标/旧文件核对通过。最新全Rust79/Flutter48、Clippy/Android核心check、GTK完整工作台1项、正式debug/release构建通过（.local/paths-*.log）。真实Windows GNU目标仅对路径模块及测试做metadata编译，未链接或运行Windows程序；NTFS/UNC/重解析点/云文件和Android SAF仍待实机验收。

## 失败目录局部重扫

真实FRB用例在目录目标被普通文件阻挡后保留成功兄弟；修复障碍并添加新文件后，将重扫任务留在FIFO等待、暂停并重开加密库，验证不自动联网，显式继续后新旧子项均正确传输、已删除成功兄弟源不重读。GTK工作台在失败目录详情实际点取消、再点“重扫并继续”，确认旧目标未被取消动作修改、最终新文件内容和成功兄弟保留。截图validation/phase3b/transfer-rescan.png（仅合成回环数据）；最终命令/结果以PROGRESS为准。

## 当前任务批量更名

真实FRB/SSH覆盖两个冲突+普通失败、计划目标与磁盘数字后缀占名、成功兄弟源已删除仍不重读、排队暂停后重开库且不自动执行、根单文件队列实际目标更新。widget证明同时选中两个任务仅处理点击任务；GTK使用不同新旧内容实际点击“全部更名另存”，校验原目标不变、新后缀目标为新内容。截图validation/phase3b/transfer-rename.png；仅本机合成服务器数据。完整结果和构建状态见PROGRESS最新记录。

## 新任务默认同名策略

真实FRB隔离排队任务的入队快照、覆盖/跳过/更名的上传和下载、重开库保存、旧客户端空字段保留策略及未知策略拒绝均通过。普通新文件在Skip策略下仍传输；类型错误仍失败，不被自动覆盖。最大长度名称引发自动更名失败后，明确手选的已有名称保留冲突、不再次自动改名，随后另存可成功。GTK实际选“更名另存，保留旧目标”、保存并读回Rust配置，断言旧Mock同义控件不出现在正式设置。更新截图validation/phase3b/transfer-settings.png，所有账号/设备边界不变。

## SFTP列表排序工作量回归

共享真实/Mock FilesPanel的4096条合成列表原本每个惰性行重新排序全目录。相同测试修复前首次名称访问2,215,076次，修复后82,088次；修复后滚动38次，修复前滚动未测。测试验证只构建可见行、筛选与原地改名后的失效刷新；JSON在validation/phase3b/sftp-list-work.json，计数不等同CPU/帧率。GTK另实际读OpenSSH的4096项目录、滚动并明确刷新外部改名，最终结果见PROGRESS。该列表热点节点尚未接分页；现已接入，见下节。

## 正式浏览器桥接分页

正式loadDirectory使用每批最多256项/约256KiB的open/page/close，不再一次跨语言返回整目录。完整EOF与关闭后才替换LRU，失败/过期不发布半列表；完整目录仍在Dart保留以便排序。专门真实FRB用例读取4097条，验证多页完整性、旧请求清理不影响新请求、同号跨终端隔离、24次打开/替换/关闭、PTY、远端退出与手动重连；核心协议/阻塞取消及纯Dart错误路径另验。原GTK4096目录交互直接复用新分页路径。边界及命令见DIRECTORY_PAGING.md，最终运行结果见PROGRESS。

目录缓存增加每会话16目录/64MiB估算权重双限制，当前目录不截断；3项纯Dart缓存回归、分页权重累加及真实重连清理回归通过。全Flutter56项/Analyze、GTK1项及正式debug/release通过（.local/cache-*.log）。Rust/FRB此缓存节点未改。权重定义与超预算行为见DIRECTORY_PAGING.md。

## 真实目录书签

工具栏目录书签已接Rust加密配置与捕获的原SSH会话导航，支持全局/主机范围、添加/编辑/删除确认；不预读远端、不重建连接。Rust存储2项、widget3项、真实原生与GTK全流程通过；GTK确认代次和侧栏宽度不变，原独立SSH/SFTP/4096目录/传输/密钥回归全部保留。截图[bookmarks.png](validation/phase3b/bookmarks.png)，规则、命令及未接同步/备份边界见SFTP_BOOKMARKS.md。最终全Rust101/Flutter60/GTK1与Ubuntu双模式构建通过，目标平台实机仍待测。

最新书签版正式二进制另做独立GTK启动/resize/关闭：debug/release均退出0、不建Vault/终端历史。密码框自动聚焦的5秒样本debug RSS446,861,312字节/CPU5.20%，release RSS272,953,344字节/CPU5.20%；原始JSON为validation/phase3b/bookmarks-startup-*.json。与早先密码框样本比较仅作可复现记录，不等同终端空闲、持续增长或Windows/Android资源结论。

## 真实文件打开与临时缓存

文件双击/Enter/右键“打开”使用独立临时下载，再用系统关联程序打开；不会将本地修改回传。超过100MiB先确认，失败CLOSE即使正文收齐也拒绝发布，取消清理部分内容；同一文件再次打开重新下载。符号链接在明确打开时解析，目录进入原SFTP会话。源会话代次及目录快照检查防止等待中将旧动作发给新连接。

测试分三层：Rust缓存锁/安全路径与CLOSE协议；Flutter模拟后端的迟到/取消/确认/无空闲轮询单测及真实FRB/OpenSSH；GTK使用benchmark/preview_association.py临时注册独立XDG查看器，验证两次Unicode正文摘要和含中文/空格/#/%的file URI、目录链接、取消大文件及退出清理。不修改用户系统默认程序。截图[file-preview.png](validation/phase3b/file-preview.png)仅含合成回环数据。详情与复现命令见FILE_PREVIEWS.md，最终结果见PROGRESS.md；Windows/Android、内置与外部编辑回传不能由这些结果代替。

文件打开确认阈值已替换正式设置的Mock选择器。默认100MiB，0每次确认（含空文件），每个准备票据固定原阈值；修改设置不能改变已显示提示。Rust覆盖严格边界/上界/配置重开及较新格式拒绝覆盖，真实FRB验证0/1MiB与旧提示，widget验证空字段保持可编辑、范围校验、保存失败与重读。GTK实际保存50MiB并读回Rust，旧Mock控件不在正式页面；截图[file-open-settings.png](validation/phase3b/file-open-settings.png)已查看，只含合成配置。配置云同步/备份仍待后续整体接入。

## 缓存目录路径补全与输入焦点

路径输入仅使用源会话的已有LRU/文件夹元数据，候选点击只填入，明确提交才导航，不预读/探测符号链接。最多12项，512行分段异步处理、失焦/新输入/会话切换取消；窄侧栏显示可区分尾部，Tooltip保留完整路径，键盘选项自动滚入可见区。IME同文本提交也能显示候选，不改写composing文本。

6项专项验证缓存范围/取消/有界结果、点击与提交、同文本IME与会话切换、键盘滚动，以及路径文本Delete/F2/Ctrl+A不误操作文件。旧文件删除确认误弹已先复现再修复（.local/path-shortcuts-before.log）；文件列表快捷键限定primary focus。GTK实际输入/点击时目录epoch不变，明确提交后路径正确且SSH代次/侧栏宽度保持；截图[cached-path.png](validation/phase3b/cached-path.png)，结果与构建状态见PROGRESS.md。规则及计算边界见CACHED_PATH_COMPLETION.md，原SSH/传输/主机/书签回归保留。

## 内置文本编辑与本机加密草稿

文件菜单“编辑”捕获源会话读取文本，编辑仅落本机加密草稿，Ctrl+S才按V1.4直接覆盖远端。支持UTF-8/UTF-8 BOM/带BOM UTF-16、换行保留或明确转换；内置正文16MiB上限，超限不截断。草稿元数据和正文分开加密，设备命名空间不进入配置同步/备份，不由预览退出清理删除。恢复不联网；明确关联后检查原主机ID/实际地址端口/用户/指纹，再允许保存。取消可部分写入远端，但完整草稿保留，不自动重连。

GTK已实际验证文件菜单→编辑中文/组合字符/Emoji→远端未变→Ctrl+S→准确正文；dirty关闭先取消再保留，原服务器保持上次保存；从本机草稿菜单离线恢复，Save禁用，明确关联后保存；SSH代次不变，干净关闭后本机草稿移除。截图[remote-editor.png](validation/phase3b/remote-editor.png)仅含合成文件。首次GTK复现退出动画访问已释放文字控制器，修复为等待DialogRoute.completed，之后完整GTK及系统关联预览回归通过。补充widget覆盖较大文字缩放、迟到关联不能恢复已关闭文档、读取失败不删除未检查草稿。

Rust/原生FRB还覆盖加密重开、旧版本/CAS、取消票据、规范路径固定、另一个Transport/目标变更拒绝、部分上传取消和WRITE成功但CLOSE失败保持dirty。精确执行数量/日志/构建以PROGRESS.md最新节点为准；REMOTE_EDITING.md有复现与人工步骤。外部文本编辑器/监听已接（下节），其他明确编码及外部大正文见后续节点，Android独立页面仍待做，不将本模块计为完整V1.4编辑功能。

编辑字节进度使用小快照：读取/保存时250ms查询，相同状态不通知，结束后无轮询，不重建整个工作台；写满字节后仍等CLOSE/通道确认。额外widget覆盖无空闲查询、旧操作忽略、等待确认失败仍dirty，原生测试验证UTF-16原始字节及限速/取消/全部WRITE后CLOSE失败。真实GTK以64KiB/s保存221,184字节合成中文正文，检查进度介于0和1、完整服务器正文及恢复小文档/草稿流程；结果/截图见PROGRESS.md最新节点。后台队列进度条与编辑器分开定位，测试退出先卸载视图再释放控制器，避免失败被清理异常遮蔽。

## 外部文本编辑与工作副本

正式编辑弹窗支持选择外部程序、父目录事件去抖、先加密保存本机草稿再自动回传原SSH、暂停/明确继续及确认清理；退出和GUI启动器退出不删除工作文件。恢复离线草稿后读取已有工作文件需确认，首次读取不立即上传；手动重连也不自行恢复上传。缓存、租约、故障恢复及平台边界见REMOTE_EDITING.md，完整测试/构建结果以PROGRESS.md最新节点为准。

`integration_test/live_workbench_test.dart`增加真实GTK原生选择器→启动Mousepad→通过私有X11剪贴板粘贴合成中文/组合字符/Emoji→真实Ctrl+S与退出→目录监听→原OpenSSH目标正文及修订确认→工作文件仍保留→明确确认清理的流程。执行`python3 benchmark/external_editor_gtk.py flutter test integration_test/live_workbench_test.dart -d linux --reporter expanded`隔离XDG设置，需要`mousepad`/`xclip`/Xvfb/D-Bus；辅助程序只允许测试临时路径并验证窗口PID和argv。不会访问真实编辑器或账号，不能代替Windows程序/通知/IME实测。截图生成于`/tmp/hspterm-external-editor.png`，通过并复核后归档到`validation/phase3b/external-editor.png`。

最终本节点Rust125/Flutter100、Clippy/Analyze/fmt、共享核心NDK/API26检查通过，正式debug/release已重建；两种独立启动/正常退出均0，包内Rust库哈希与target对应一致。GTK实际外部编辑及原系统关联各1项通过，失败与修复记录/测量边界见PROGRESS.md最新恢复入口。截图[external-editor.png](validation/phase3b/external-editor.png)已复核，仅合成内容。关闭会中止未回答的恢复确认，迟到回答不能重启程序/上传；该死等先超时复现后修复并纳入完整100项。

## 明确选择文本编码

文件菜单可选择原文件编码再读取，失败可明确重试；内置格式支持UTF-8/带及不带BOM UTF-16/GB18030/GBK/Big5/Shift JIS/Windows-1252。两向无损检查拒绝静默替换、best-fit变义和重新解码覆盖已有草稿。真实SSH测试4项、完整Flutter103及Rust128、GTK/双模式构建/独立启动退出通过；具体记录/边界见PROGRESS最新节和REMOTE_EDITING.md。GTK实际选择GBK→中文→准确CRLF字节，截图[legacy-editor.png](validation/phase3b/legacy-editor.png)。后续外部大正文分块编辑见下节；内联16MiB边界不作为删除Android内置大文件需求。

## 外部大正文原始字节编辑

正式文件菜单“外部编辑大文件…”显示原始字节数和明确外部编辑说明，不展示可写空正文或编码转换控件。选择本机程序后，复用目录事件合并、原会话回传、失败暂停、手动恢复与确认清理；分块加密快照和明文工作副本均不入配置同步/备份。核心与安全边界见[LARGE_EDITING.md](LARGE_EDITING.md)。

原生FRB测试17MiB以上故意无效Unicode字节，准确读写/取消/离线恢复，外部程序退出后继续改文件仍可捕获；另一个Transport即使同主机也不能在原票据上保存。初始化缺marker的部分文件拒绝普通启动，明确清理先保留最新部分正文且远端保持原字节。widget确保没有内联假正文/去抖写入，未持外部租约禁Save。GTK使用20.48MB合成文本、原生选择器和真实Mousepad键盘保存/目录监听/SSH回传；最终日志、截图与构建结果以PROGRESS最新条目为准。

最终GTK完整1项、完整Flutter105项、Rust144项通过；正式debug/release构建与独立启动/resize/正常关闭通过，SO与target对应模式哈希一致。截图[raw-editor.png](validation/phase3b/raw-editor.png)已查看，只有合成主机/路径；启动原始样本为validation/phase3b/raw-startup-*.json，不能作已连接终端空闲或目标平台结论。

## 递归文件名搜索

文件视图溢出“递归查找文件…”明确搜索当前目录及子目录的文件名文字，支持大小写与取消/结果定位，不读取正文。Root/generation/request/通道与当前侧栏目录游标独立，关闭或断线取消在途请求；CLOSE失败、容量及结果上限明确提示未完整。原目录本地筛选保留。核心及验收边界见[FILE_SEARCH.md](FILE_SEARCH.md)。

自动化包含真实OpenSSH的Unicode/子链接/根链接/空目录工作量和取消，受控卡住READDIR/失败CLOSE，真实FRB301项分页与代次/跨会话隔离、原目录游标不被搜索关闭，组件迟到结果/关闭等待/小窗口缩放及1000行结果选择滚动。最后GTK、全量测试与构建结果以PROGRESS最新节点为准，不把在途记录计为通过。

本节点最终Rust147、Flutter115、实际GTK完整1项均通过。GTK扫描4112项/6目录定位到原会话中文深层文件，选中状态与SSH代次已核对；[file-search.png](validation/phase3b/file-search.png)只含合成内容。正式双模式构建与单独启动/resize/正常关闭通过，原始样本search-startup-*.json；NDK仅共享核心编译，不代表目标平台运行。


## 真实远端复制任务及文件剪贴板

正式工作台右键复制只保存原会话和路径元数据；粘贴明确确认目标与内存中转策略后才入队。应用级剪贴板不随侧栏重建/焦点切换丢失，不新增Windows SFTP Ctrl+C/X/V快捷键。源nativeID/代次、目标代次与确认时剪贴板修订均固定。工作台菜单、队列暂停/继续/详情/单项及批次冲突动作已路由到真实双端任务；复制目录为一个顶层任务，空目录保留，子链接明确失败不遍历。

完整Rust173项、Flutter118项、GTK1项通过；Clippy拒绝警告、Analyze、格式、正规FRB2生成及NDK/API26共享核心check通过。GTK完整流程包含真实右键复制→取消粘贴不写→明确允许中转→实际SSH复制→展开真实队列任务及源/目标路径，原PTY代次不变；主机/分屏/4096目录/搜索/书签/队列/普通及原始字节编辑/真实Mousepad回传全部保留。第一轮完整GTK已通过；补截图的两轮查找器/任务key失败均保留并修复，最终remote-runtime-gtk-queue-key-fixed.log完整1项再次通过，未删除测试。截图[远端复制与实际队列](validation/phase3b/remote-copy.png)已查看，仅合成回环数据。

日志以.local/remote-runtime-rust-all、remote-runtime-flutter-all、remote-runtime-rust-all-clippy、remote-runtime-gtk-analyze-fixed、remote-runtime-android及remote-runtime-gtk-queue-key-fixed.log为准。正式workbench_main debug/release按最终源码重新构建成功（remote-runtime-{debug,release}-final.log），包内/target同模式SO SHA256相同（remote-runtime-bundle-hashes.log）。两包在其他测试/构建结束后分别独立启动、resize、正常关闭，wrapper/app均0，Rust加载、不创建Vault/终端历史/外部工作副本、预览残留0。

5秒聚焦锁库密码框样本保留于validation/phase3b/remote-copy-startup-{debug,release}.json：debug RSS451,485,696字节/CPU约5.00%；release RSS283,586,560字节/CPU约4.40%。与既有search/raw样本一并保留，不将一次波动判为泄漏，不代替已连接终端空闲或长时间压力测试；118项中20次native生命周期RSS差值196,608字节亦仅短样本。未做Windows/Android实机或APK验收。

当前仅显式允许的内存中转，不声称安全rsync/scp直传已完成。不复制凭据到远端，不借系统Agent/SSH配置；两端活动期监听原代次，共用原全局FIFO及上下行限速，重开配置库仅暂停且手动继续。复制头/节点块仅本机加密日志，不入同步/备份。完整设计、私有暂存屏障和已知边界见REMOTE_FILE_OPERATIONS.md。剪切/跨服务器来源删除、复制到/移动到、失败目录重扫、残留暂存的明确清理/未知发布结果协调及真正安全直传仍待继续实现，不能计全部V1.4完成。


## 同账户剪切、移动意图与编辑互斥

正式工作台剪切/粘贴现通过真实移动任务执行。同账户指实际地址/端口/用户/指纹一致，不以保存主机名/同host key推断可跨账户rename；不同保存主机ID的独立Transport可指向同账户。元数据移动保持空目录及符号链接对象，不下载正文、不开新SSH、不改变PTY身份或Shell CWD。源/目标侧栏刷新，移动子树缓存失效；成功接受的剪切路径被消费，失败未入队项与后来新修订保留，旧选择不能重复提交。复制操作保留原中转策略。

Pending/Intent/Confirmed在设备加密日志中区分未发送/结果未知/已ACK。Intent落盘才rename，ACK后先保存Confirmed，后续失败恢复只收尾。Intent未知不盲重发，取消不丢唯一记录。元数据移动详情不伪造内部统计或字节速率。同名不覆盖，不同服务器剪切拒绝，未知状态协调/跨服务器删除来源等仍待开发。编辑器互斥防止已打开文档自动回传重建旧路径，允许已准备的无关文档继续；同host key按可能地址别名保守检查。旧拖放/F2 CRUD完整路径互斥尚待统一。

全Rust177项、Flutter121项、GTK1项通过；Clippy拒绝警告、Analyze、格式、正规FRB2生成、Native及NDK/API26共享核心check通过。新真实OpenSSH验证目录/空目录/链接对象移动、不同服务器/同名保护、共享FIFO；隔离SQLite trigger注入Intent落盘失败时源不动/目标不建，移除后明确继续成功；相关编辑拒绝、无关编辑允许、排队移动不接受新关联编辑。LiveWorkbenchModel真实跨会话剪切验证原文件消失、目标准确、剪切选择消费/重放拒绝且SSH代次不变。新菜单确认/取消/元数据任务显示专项8项通过。

最终完整GTK（remote-move-gtk.log）验证实际剪切图标→取消不动→确认移动→源消失/目标准确→移动队列详情，以及旧复制、主机/分屏/4096目录/搜索/书签/普通编辑/真实Mousepad和原始字节编辑等全链路。截图[同账户移动](validation/phase3b/remote-move.png)已查看，仅合成回环数据。曾有测试断言误插生产闭包导致编译失败，已移回cfg(test)，未执行该错误版本（remote-move-editor-tests.log保留，后续fixed及完整回归通过）。

正式workbench_main debug/release构建成功（remote-move-{debug,release}.log），包内/target同模式SO SHA256一致（remote-move-bundle-hashes.log）。其他测试/构建结束后，两包分别单独GTK启动、resize及正常退出，wrapper/app均0、Rust加载、不建Vault/终端历史/外部工作副本、预览残留0。5秒聚焦密码框采样保留于remote-move-startup-*.json：debug RSS451,051,520字节/CPU4.80%，release RSS276,578,304字节/CPU4.60%；不将短样本波动当泄漏/优化结论，不代替终端长期负载或Windows/Android实机验证。此前复制/search/raw样本均保留。

日志入口：.local/remote-move-{rust-all,rust-clippy,flutter-all,refresh-analyze,android,gtk}.log。175项覆盖清单仍标部分，接着开发复制到/移动到、未知结果协调、跨服务器剪切、完整网络/同步与平台客户端，不等待阶段验收。


### 独立目标复制/移动（Ubuntu）

正式文件菜单的复制到/移动到已接真实任务。源选择固定，独立目标只用已连接SSH，不修改普通文件剪贴板；批次部分失败只重试未接受项。两端代次和IME组合输入保护、停止后的迟到响应保护及紧凑缩放布局7项弹窗/5项菜单测试通过（remote-destination-widgets-final.log）。真实LiveWorkbenchModel/OpenSSH验证导航后来源不变、剪贴板不变、第二项被编辑拒绝后仅剩余项明确重试通过。完整Flutter129项通过（remote-destination-flutter-all.log），Analyze清零（remote-destination-analyze-final.log）。本节点只改Dart及测试，不修改RustAPI/生成绑定；此前Rust177/NDK共享核心验收保留，不宣称本节点重复执行。

完整GTK1项通过，3:25（remote-destination-gtk.log）：右键复制到→关闭无目标写入→重新明确目标后正文正确；移动到→源消失/目标准确/文件剪贴板与SSH代次保持；既有目录/主机/分屏/预览/书签/搜索/真实Mousepad及大文件全链路保留。截图[复制到](validation/phase3b/remote-destination.png)已查看，仅合成回环数据。正式workbench_main debug/release构建成功，包内/target同模式SO SHA256一致（remote-destination-{debug,release}.log、remote-destination-bundle-hashes.log）；单独启动/退出结果见同名startup JSON及PROGRESS最新记录，不以GTK替代目标平台实机测试。

两包独立启动/resize/关闭wrapper/app均0，Rust加载，无Vault/历史/外部工作文件、预览残留0。remote-destination-startup-*.json密码框聚焦5秒：debug RSS447,709,184字节/CPU5.20%，release RSS283,316,224字节/CPU4.40%；旧样本保留，不作长期泄漏/优化或目标平台结论。


### 远端失败目录重扫（Ubuntu）

Runtime现保存目录重扫意图并在完整候选原子发布成功后才写目标，旧检查点/成功兄弟/所有私有快照阶段与确认偏移保持。旧Header缺rescan按空处理，编码与解码两端拒绝无清单、重复/越界/文件/非失败索引、Move误用及完成任务残留意图；源重扫候选先于已保存目标批量更名意图恢复。

完整Rust180项（remote-rescan-rust-all.log）、Clippy拒绝警告（remote-rescan-clippy-final.log）、完整Flutter129项（remote-rescan-flutter-all.log）、Analyze和NDK/API26共享核心check通过；正规FRB2生成/最终Native成功，无生成绑定接口差异。真实双服务器Native用隔离SQLite trigger拒绝候选提交，验证未创建目标/旧节点保持，移除故障重开库保持Paused，错误端点拒绝，明确继续发现新增中文组合名并保留已完成目标的后来改动。补充整任务retry/普通文件不走rescan专项单独通过（remote-rescan-runtime-retry-all.log）。

完整GTK1项3:31通过（remote-rescan-gtk-fixed.log），远端复制目录部分失败→取消重扫不写入→明确重扫成功及成功兄弟保留，所有原主机/分屏/目录/预览/搜索/真实Mousepad和大文件链路保留。截图[远端重扫确认](validation/phase3b/remote-rescan.png)已查看，仅合成回环数据。首轮remote-rescan-gtk.log因测试错误查找标题行后代失败：详情实际是相邻节点；已改正确队列范围并等待异步详情，未改业务/未跳过交互，首轮失败不计通过。正式workbench_main debug/release已构建，包内与target同模式SO哈希一致；单独启动/退出最终结果见PROGRESS及remote-rescan-startup-*.json。NDK不是APK或设备验收，Windows/Android实机仍待测。

两包单独GTK启动/resize/正常退出wrapper/app均0，Rust加载，无Vault/终端历史/外部工作副本、预览残留0。remote-rescan-startup-*.json锁库密码框5秒采样：debug RSS446,808,064字节/CPU5.00%，release RSS287,203,328字节/CPU4.60%；旧样本保留，不作长期泄漏/优化或目标平台结论。


### 未确认移动检查与明确本机结束（Ubuntu）

正式队列已接只读路径检查、按job/修订/两端NativeID及代次绑定的一次性票据、明确“结束本机等待”。UserEnded+Cancelled与服务器Confirmed分离，不能伪计完成或重发；保存失败保留Intent保护/票据，成功保留加密审计。本动作不再发更名/写入/删除，但不能撤销旧请求或保证服务器已停止。后续离线本机处理已接（见下节）；网络检查仍要求原保存主机身份的已连接会话。

最新完整Rust180项（remote-move-resolution-rust-all-final.log）、Clippy拒绝警告、完整Flutter135项（remote-move-resolution-flutter-all.log）、Analyze及NDK/API26共享核心check通过。正规FRB2生成/匹配Native通过；Flutter回归使用从修复后Native复制且校验SHA的独立测试库，避免并行Cargo改映射文件（remote-move-resolution-test-library.log），不作为交付库。

真实OpenSSH代理转发系统sftp-server后丢成功RENAME响应，验证实际已移动但客户端不猜成功、等大小重建源不盲发；Missing不算成功，新检查/交换Transport/明确一次重连/Vault重载的票据失效。FIFO阻塞源lstat使旧结果晚到，红测确实复现旧检查覆盖新票据（remote-move-resolution-newer-before.log）；改为IO前ready=false预留后，最新检查与跨Vault迟到结果均明确拒绝，完整专项17秒通过（remote-move-resolution-newer-fixed.log），SQLite trigger失败仍保留编辑保护，明确本机结束不更改两文件、不重发、审计保留。

5项新弹窗/4项原队列路由专项通过（remote-move-resolution-widgets-fixed.log）；初次夹具缺正式Desk主题导致行高溢出及未pump查选中后按钮，已修正夹具，非业务绕过。新专用GTK真实队列/弹窗1项11秒通过（remote-move-resolution-gtk-final.log），关闭检查不结束、明确结束标“结果未判定”、原两文件保留且只执行一次真实rename；原完整工作台GTK1项3:32通过（remote-move-resolution-workbench-gtk.log），所有既有主机/分屏/目录/预览/搜索/真实Mousepad/目录重扫等保留。截图[检查未确认移动](validation/phase3b/move-resolution.png)已查看，仅合成回环数据。首张截图边界未含Navigator覆盖层，修正到MaterialApp外并重新实跑，未把空图当完成。

正式workbench_main debug/release均成功（remote-move-resolution-{debug,release}.log），包内与target同模式SO哈希一致（remote-move-resolution-bundle-hashes.log）。全部其他任务结束后两包单独GTK启动/resize/正常退出wrapper/app均0，Rust加载，无Vault/终端历史/外部工作副本、预览残留0。move-resolution-startup-*.json锁库密码框聚焦5秒：debug RSS456,171,520字节/CPU5.20%，release RSS283,557,888字节/CPU4.80%；旧样本保留，不作长期泄漏/性能优化或目标平台结论。Windows/Android实机仍未验证，NDK不等于APK/设备验收。


### 离线结束本机等待（Ubuntu）

新增独立本机审阅/结束API与正式弹窗：原保存主机删除、Transport关闭或服务器不可达时仍可审阅原账户/指纹/路径并明确结束等待。未获得的远端属性明确标未核对，不把本机原记录当当前事实。结束无需等待可选网络检查，迟到结果不能覆盖保存失败；本机结束不触发完成任务的远端目录刷新。两种票据分离，网络检查及普通恢复的身份规则不变。

完整Rust180项、Flutter139项、Clippy/Analyze、正规FRB生成/Native及NDK/API26共享核心check通过（.local/remote-move-offline-*日志）。新的真实Native测试remote_move_offline_end_test.dart验证活动/排队拒绝、票据不能互换、新审阅/跨Vault失效、删除主机后关闭SSH/停止SSHD、本机重开审阅、SQLite故障不改Intent及明确重试、源/目标正文保持和仅一次rename，未重建主机/凭据。原网络检查回归保留。

完整工作台GTK1项3:39通过；扩展专用GTK1项14秒通过在线及离线两次真实丢ACK、取消不结束、明确本机结束、两文件保留及rename计数不增加。最终错误文案/不刷新目录修正后Analyze、13项组件/真实模型及专用GTK1项14秒再次通过。截图[离线审阅](validation/phase3b/move-offline-end.png)及[在线核对](validation/phase3b/move-resolution.png)已由实跑生成，离线图已查看，仅合成回环数据。

正式双模式构建及独立启动结果以PROGRESS最新记录为准；Android仅共享核心编译，不是APK/设备验证，Windows/Android实机仍待测。审计管理/远端暂存清理/跨服务器剪切等仍未完成，不把本机结束当恢复成功。


### 被动OSC7与终端选区路径定位（Ubuntu）

详见[TERMINAL_PATHS.md](TERMINAL_PATHS.md)。同一解析器被动消费OSC7，严格URI/单次解码、完整ST、取消/超限/无效报告清旧值，备用屏幕/RIS/断线/新PTY失效；不作为安全输入证明。正式本地终端菜单可将选区中的字面路径定位到原SSH/SFTP：匹配authority的相对路径或绝对路径，文件打开父目录并选中、目录直接进入；不传正文、不发PTY输入或重连，不做URL/别名网络探测。文件链接保留原条目。

核心7项/原term-core全部31项、真实双Transport专项1项、上游VTE56项/alacritty132项通过。新Bridge/正式UI模块完整Rust188项、Clippy、Flutter143项、Analyze及NDK/API26共享核心check通过（terminal-path-rust-all/clippy/flutter-all/android.log）。最后补菜单同步抛错处理/中文错误上下文后匹配Native重建，5项新Native/组件专项再次通过（terminal-path-last-tests.log），未把中途测试加载数混算成144项完整回归。

新增真实Native验证特殊字符/中文路径、authority不符拒绝相对路径/绝对兜底、过期代次、文件链接、焦点B不被A改动、故意阻塞旧目录页后新导航优先；新组件验证远端鼠标捕获/Shift覆盖、重连后旧菜单拒绝、隐藏目标虚拟行滚动和菜单同步异常有序显示。新真实GTK1项11秒通过实际鼠标拖选→正式菜单→SFTP，260个目录后的隐藏特殊名文件滚动选中，侧栏原宽度/其他会话/正文/SSH身份保持且没有新传输。[终端路径定位截图](validation/phase3b/terminal-path.png)已查看，仅合成数据。最终同场景GTK和原完整工作台GTK/正式构建状态见PROGRESS最新记录。

保留首轮缺接口/测试辅助方法名/泛型推断/Analyze及printf错误日志；printf测试URI改为%s参数防百分号解释，终端未为夹具绕过协议。一次相对工作目录复制测试库/PNG的准备命令路径错误，源文件未改；随后按绝对路径复制SHA核对库，完整143项无失败/全部实际通过，文件准备失败不计通过。

尚未实现自动链接识别/Ctrl+Click/可选OSC7目录跟随/安全路径注入/OSC133与Android长按入口，不把本模块当十项联动全部完成。Windows原生输入及Android设备仍待验收；NDK编译不代表APK/设备运行。


### 可选OSC7目录跟随与加密主机偏好（Ubuntu）

正式主机管理SFTP分类的“打开SFTP/OSC7跟随”字段已接既有加密仓库/草稿/复制，跟随默认关闭且兼容旧记录。高级分类单次保存、准备期导航保护已修；草稿不直接影响活跃连接。模型按原实际端点/代次、焦点与可见性串行导航，不自动展开、初始化未启用SFTP或重连；普通导航/新报告/配置关闭能使旧页失效。细节及严格authority别名限制见TERMINAL_PATHS.md。

新仓库重开/复制/草稿隔离专项通过；真实双SSH目录跟随1项6秒通过（osc7-follow-real-first.log），包括故意挂起旧页后手动导航/最新报告优先、收起延后/重显、失焦不改其他终端及关闭后不导航。主机分类保存/每主机重载及原型10项通过（osc7-follow-preferences-final.log）。首轮新组件夹具在双击判定窗口内过早读新主机页，增加实际单击判定等待后通过，未改产品双击行为。

扩展实际GTK1项14秒通过（osc7-follow-gtk-fixed.log），保留鼠标选区路径定位，新增真实SFTP选项保存到加密主机并驱动原SFTP，原会话ID/代次/其他会话/侧栏宽度保持、无新增传输。首轮夹具误找只在多标签组显示的“返回终端”，已点击实际原终端标签，不改产品布局。[目录跟随截图](validation/phase3b/directory-follow.png)已查看，仅合成回环数据。

完整Rust190项（osc7-follow-rust-all.log）、Clippy、完整Flutter147项（osc7-follow-flutter-all.log）、Analyze、正规FRB/匹配Native、NDK共享核心check通过。最终原完整工作台GTK/正式双模式构建/独立退出状态见PROGRESS，不把集成入口当交付。Cargo仅清理本项目4crate的已确认可再生成dev/release缓存后重建，包内SO独立inode已核对，源码/正式包/日志/未知数据未清理。Flutter全量加载SHA核对的隔离测试库，非交付库。Windows/Android实机仍待验收。

最终完整工作台GTK1项3:31通过，正式workbench_main debug/release构建、同模式SO哈希及独立GTK启动/resize/正常退出wrapper/app均0（osc7-follow-*日志）。Rust加载，无Vault/终端历史/外部工作文件、预览残留0。directory-follow-startup-*.json为锁库密码框5秒采样：debug453619712字节/5.40%，release287064064字节/5.40%，非长期泄漏/终端空闲优化/目标平台结论。完整Flutter147中4000个报告实测合并2次事件/Native帧拉取0，早先独立专项1次，调度可变，不保证固定1次。

## SSH 单代理正式接入（2026-10-25）

V1.4 §3.1单HTTP CONNECT/SOCKS5已接入正式主机网络页及加密配置，协议及生命周期边界见SSH_NETWORK.md。完整Rust221/Flutter150、Analyze/Clippy/格式/NDK核心检查通过；新增真实Native1项18秒与最终GTK1项24秒通过。夹具两类失败日志均保留：无视图未启用帧拉取、App初始化覆盖合成指纹回调；修复夹具后产品协议/信任机制保持。GTK实际进入网络分类，用户名密码不回填、明确已设置状态，重填后单次保存并对原HTTP会话明确重连成功；另一个活动SOCKS会话ID/代次不变。两种代理均有真实PTY输出/SFTP读取、加密库重开及副本凭据隔离验收。

截图：validation/phase3b/ssh-proxy-settings.png、ssh-proxy-workbench.png。构建入口仍workbench_main；正式包哈希/独立启动结果见PROGRESS。Linux/NDK结果不是Windows/Android实机验收；跳板/转发/同步代理未计完成。不使用真实代理密码或服务器配置。

## 主机级时限与心跳（2026-10-25）

复用既有Rust核心/加密字段，新增正式网络页总时限、心跳间隔/关闭及连续无响应阈值；模型/草稿/副本与库重开保持。完整Flutter154项3:41通过，含真实回环代理超时及OpenSSH停流心跳/关闭对照2项；实际网络试验没有自动重连，失败/断线标签及屏幕保留。窄窗口640x480逻辑像素/1.5缩放发现并修复底部操作Row 32像素溢出，最终表单/生命周期8项通过。Analyze/格式检查无问题，无Rust/FRB/数据库格式变更，核心证据沿用同源码221项/NDK检查。

扩展真实GTK1项25秒通过：网络页更改19秒总时限、0关闭心跳、阈值4，与代理认证一并单次加密保存，Native元数据确认，HTTP明确重连后终端快照值一致；其他SOCKS会话ID/代次不变。截图ssh-network-timing.png及更新的ssh-proxy-settings/workbench.png已实际查看，滚动表单有单独的时限/认证视图。两模式正式workbench_main重建、匹配Native与独立启动结果见PROGRESS及ssh-timing-*日志。不把本机结果计作目标平台实机验收；全局默认/独立响应超时/测试连接GUI仍未完成。

## 正式主机握手测试（2026-10-25）

ManagedSession核心2bb0812之后的完整接入：共享connections路由/时限快照，FRB复查保存host-ID/预期地址端口用户，只读目标元数据及必要代理认证，不读取目标SSH凭据。主机页“测试连接”拒绝未保存编辑的隐式保存；独立隐藏Controller收TOFU，无终端标签/最近/SFTP，成功/取消/退出均等待资源释放，过期Future取消不影响后来操作。结果明确只证明握手/主机指纹，不证明目标认证；明确取消不成为全局错误。

完整Rust223项通过（含45真实OpenSSH）；最终完整Flutter162项3:48通过；正规FRB/Clippy/Analyze/格式/NDK核心check通过。8项专项覆盖无效目标用户/密码仍可测、加密指纹复用、原生目标复查、取消及退出EOF、旧取消作用域、Native创建中取消/隐藏0帧一次释放、未保存不联网、取消等待及合法长目标在缩放窄窗可滚动关闭。合法长目标溢出红测保留，scrollable修复后全量重新通过。

真实GTK探测最终1项11秒通过（ssh-probe-gtk-final.log），实际App首次指纹“信任并保存”，没有fixture接受回调，报告范围及停流代理取消正确；网络表单回归1项26秒通过。connection-test.png及更新的network-timing/proxy-settings/workbench三图已归档，相关图片实际查看。最终workbench_main debug/release、包内Native同模式SHA、两包独立启动/resize/正常退出均通过，无Vault/历史/编辑副本或预览残留；数据见ssh-probe-startup-*.json，只是锁库密码框聚焦5秒，不推断泄漏或性能优化。Windows/Android实机未验，跳板/完整转发等仍待开发。

## 一级跳板正式网络验证（2026-10-26）
`flutter test test/ssh_jump_bridge_test.dart test/host_jump_form_test.dart test/host_key_failure_test.dart --reporter expanded`验证加密引用/草稿副本/重开、唯一外层SOCKS、跳板认证和独立目标信任、实际PTY/SFTP、手动重连/删除跳板无直连回退与确认回调异常拒绝。GTK：`python3 benchmark/external_editor_gtk.py flutter test integration_test/ssh_jump_test.dart -d linux --reporter expanded`真实App两端信任、网络分类选择器/一次保存/在线身份保持通过26秒，图片`validation/phase3b/ssh-jump-{tofu,settings,workbench}.png`均已查看。原握手GTK回归1项11秒通过。只用一次性回环sshd/合成代理，不读取外部凭据；Ubuntu结果不计Windows/Android实机。完整回归/最终交付入口以PROGRESS为准。

## 原会话L/R/D转发配置和手动管理

正式主机进阶页与当前终端菜单已接真实加密规则、原NativeID/代次运行期FRB和L/R/D启动/停止/断开销毁；保存/删配置不改实例，主机删除后仍能停原实例。Mock仍只提示，脏主机不隐式保存；6项组件与GTK真实表单/TCP回显/资源释放通过。三图为validation/phase3b/hspterm-forwarding-{config,running,host-settings}.png；PORT_FORWARDING.md记API/界面/复现命令。当前完整Rust283/Flutter176与双模式构建、NDK、启动数据见PROGRESS。运行事件推送/明确重连恢复/localhost临时链接及规则完整草稿待完成，不能计整个V1.4端口转发条目完成。

## 转发恢复、加密草稿与确认链接整批

新实现与契约见PORT_FORWARDING.md末节。真实GTK管理/手动重连1项29秒和临时链接确认/取消/浏览器失败局部清理/断线迟到保护1项14秒通过（ssh-forwarding-batch-gtk-{forwarding,links}.log）。后者注入记录型浏览器，不访问第三方页面，不据此称系统浏览器实测。原终端身份/代次、三类TCP数据、临时配置不入库均验证；草稿3项仓库、22项Bridge及修复后23项Flutter专项通过。整批完整回归/构建以PROGRESS最终结果为准。复现运行integration_test/forwarding_test.dart和terminal_link_test.dart，各自用benchmark/external_editor_gtk.py隔离桌面。恢复及编辑开关截图hspterm-forwarding-{restore-rule,restored}.png已查看，均合成回环配置。

## 2026-10-26 全局网络默认与独立心跳

全局连接时限/心跳间隔/ACK响应时限/连续失败阈值已接加密配置、正式设置及主机继承选项。默认30/30/10秒、失败3次；间隔0完全关闭。旧主机保留明确参数与旧心跳策略，新建UI主机默认继承。读取损坏或未来版本拒绝覆盖；修改只影响下一次明确连接，不热改原Transport。独立监视器仅等待真实全局请求ACK，PTY输出不能代替回应；有界失败后结束原连接，不自动重连，关闭等待任务退出。

集中验证：Rust294、Flutter188通过；all-target Clippy拒绝警告、Analyze、格式、NDK/API26 aarch64共享核心check通过。真实OpenSSH/合成代理验证ACK保持在线、2000行PTY、停流超时、修改默认不热生效、手动重连读取0关闭；实际GTK设置/主机保存14秒通过。截图validation/phase3b/ssh-network-{defaults,host-policy}.png已查看，无可见溢出。重现GTK：`python3 benchmark/external_editor_gtk.py flutter test integration_test/ssh_defaults_test.dart -d linux --reporter expanded`（ui_flutter目录）。旧代理表单测试需真实滚动到下方控件，修正后8项通过。

正式workbench_main debug/release构建、同模式SO SHA256匹配及独立GTK启动/缩放/关闭0通过，无历史/工作副本/preview残留。5秒启动样本debug RSS516710400字节/聚焦CPU37.00%，失焦518504448/5.00%；release338276352/9.00%，失焦338616320/5.20%。原始JSON为validation/phase3b/ssh-network-defaults-startup-{debug,release}.json；短样本不证明长期泄漏与否，也不宣称失焦开销已消除。Windows/Android实机及完整应用仍未完成，NDK检查不是APK验证。

## OpenSSH导入整批最终验证（2026-10-26）

完整Rust300项/Flutter192项（4:42）通过，原Phase2/真实Codex合成provider/SSH与SFTP/编辑/传输/转发回归保留；Clippy all-targets拒绝警告、Analyze无问题、格式、NDK/API26 aarch64共享核心check通过。GTK实际导入预览/选中保存11秒通过，两张PNG已查看。源文件解析/事务回滚/旧Vault作用域/无凭据拒绝/明确配置后真实中文PTY均已实际运行；早期FakeAsync文件流失败已通过真实事件循环修复，未跳过断言。

正式workbench_main debug/release重建，SO与target同模式SHA256匹配，独立启动/resize/退出均0，无历史/工作副本/preview残留。debug SO30f8a3cc48ba0d810d79c26a901f771707de02202083d9c68fdaa4a01bf44307；release faf0d3906f37c09d354a10c91ef54708ac3cce7db305065d8dab0880aa49ab3e。日志.local/openssh-import-*，原始startup JSON在validation/phase3b。5秒样本debug RSS501514240/聚焦CPU37.80%、失焦513253376/5.80%；release351154176/9.20%、失焦351490048/5.20%。不据短采样认定无泄漏或优化。不是Windows/Android实机或APK验证。

## 2026-10-26 只读终端显示增强

全局/主机加密覆盖、真实关键词/正则/属性/顺序/测试/JSON预导入、变化可见行语义着色/彩虹括号与同词高亮已接；原ANSI/TUI优先，不改原文。完整Rust308/Flutter198回归通过，随后仅样例按行/预算语义修复补Core6和Flutter/真实SSH6项通过。实际GTK设置/继承/SSH绘制16秒，三张PNG已查看且无真实hostname。Clippy/Analyze/格式/NDK共享核心check、最新双模式包及匹配SO已通过；不是Windows/Android实机，也不表示配置云同步或完整Android业务完成。

32规则重复扫描压力32.174→8.007ms，原文完整保留，预算帧可无装饰；正常场景引擎p95最高0.443886ms。单次有界匹配不可抢占，不宣称硬实时/Flutter整帧性能。数据与复现见TERMINAL_DECORATIONS及validation/phase3b/display-*；短启动RSS不证明长期泄漏与否。

选区补验：纯颜色/下划线完整刷新现在保留实际选区，内容/视口/几何/隐藏或宽度映射/TUI模式变化仍清除失效选区。Core6/Flutter6样例专项后，又补原键盘/可见性/Native及真实Codex合成provider等24项29秒通过；没有把预计309/200称为最后全量。20次生命周期RSS差761856字节仅短样本。正式debug/release再次重建并匹配同模式SO，两个独立启动/resize/退出0，均无历史/工作副本/preview残留。最新5秒启动样本debug511193088字节/聚焦CPU37.40%、失焦512860160/5.20%；release345436160/7.60%、失焦345776128/5.20%，数据display-selection-startup-*.json。短样本不等于长期无泄漏或所有平台性能已验。


## 2026-10-27 正式应用内 Agent

主机默认关闭开关、下一次明确连接申请socket、原终端限时选择密钥/实际目标及公钥指纹预览/风险勾选/撤销已接真实业务。原Transport/Vault/代次一次性票据、源密钥更改删除和切库撤销、关闭等待blocking crypto、独立状态推送均有自动化覆盖。完整Rust330/Flutter206项通过，Clippy/Analyze/NDK共享核心check通过；实际GTK授权、远端真实签名验签与撤销19秒通过，三张agent-{host-option,consent,active}.png在validation/phase3b。正式debug/release构建、匹配SO、独立启动/resize/退出通过，GTK后已恢复正式debug入口。

RSA私钥签名已支持OpenSSH2048–4096/SHA2；RSA host-key及PKCS导入仍待接，不能当全RSA支持。5秒启动数据agent-*startup*.json保留；release聚焦RSS341331968B/CPU14.80%，失焦6.00%，不是长期泄漏结论。Windows/Android真实构建/输入/挂起授权生命周期待平台验证，共享aarch64 check不是APK/实机。详细边界、哈希、日志及下一步见SSH_AGENT和PROGRESS。


## 2026-10-27 RSA 与原连接身份回执

RSA SHA2 host/KEX/hostkeys证明与六种RSA私钥格式导入已通过真实OpenSSH/Native验证，CRT/KDF有界，详SSH_RSA。原actor回执替代当前Vault信任记录重读，跨/同路径重开旧确认失效、已建立SSH保留，详CONNECTION_IDENTITY。完整workspace341项、本批Native8项49秒、Clippy/Analyze/NDK共享核心check通过；前一RSA节点全Flutter207项通过。本批正式debug/release与同模式SO匹配，两个独立窗口启动/resize/退出0，原始数据connection-receipt-startup-*.json保留。不是Windows/Android实机或APK验证，短CPU/RSS不证明长期泄漏与否。
