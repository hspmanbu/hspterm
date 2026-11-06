# HSPTerm 开发进度

## 2026-11-06 第六轮 Windows 反馈八项修正（已发布：源码ca7d515，Windows CI成功）

- Windows发布：源码482ee8b首次run42205715999在Build formal workbench失败——Rust端DiagnosticCode新增directorySizeRemote/Fallback后本地未重生成FRB，CI重生成枚举使diagnostics.dart穷举switch编译错误。修复ca7d515：本地正规FRB重生成入库+switch补两个带标签case（diagnostics/run_log 8项过、Analyze0）。run42208860724/job127862228889全部成功（11:15–11:37Z）：正规FRB、MSVC Release、Analyze0、CI固定14文件组件测试、原生启动/正常退出、正常关闭重开窗口几何恢复均过。完整包：https://github.com/hspmanbu/hspterm/actions/runs/42208860724/artifacts/13498499563 （HSPTerm-windows-x64，40,140,568字节，2026-11-20到期）。锁库启动工作集116.11/112.11/112.09MiB（artifact13498559405，Server2022口径，与上轮114/111持平）。旧run42165775926为d80edad基线，未重发。

- 范围：重命名框高度、滚动条、中文选区、二级菜单、目录大小速度、双击编辑回传、内存、日志。修订已写入V1.4末尾“第六轮”。
- #1 重命名框：上一轮 SizedBox.expand 在编辑混乱中丢失从未生效。本轮落地（Padding(34,10)>SizedBox.expand>Focus>TextField(textAlignVertical.center)），装饰框贴满 _rowHeight、文字居中；回车/Esc/失焦逻辑不变。
- #2 滚动条：新像素级测试（toImage+runAsync）证实上一轮结构两个拇指都不画——根因1：竖向条收到的列表通知 depth=1（冒泡穿过横向滚动器）被默认 depth==0 谓词拒绝；根因2：底部横条没有任何可滚动后代，永远收不到通知。修复：嵌套 RawScrollbar，外层竖向 scrollbarOrientation:right + notificationPredicate 按通知轴过滤 + padding bottom:14，内层横向 orientation:bottom 包住横向滚动器。像素测试断言右缘带内确有拇指绘制、横向滚动后轨道不动；几何测试断言外层轨道右缘==面板右缘。旧独立底条删除。
- #3 中文选区：真正的错位源是终点吸附——终点落在宽字上被吸到整字左缘（排除该字），框比所指字少一格。改为整字边界：起点落宽字后半格→回退整字左缘；终点落宽字（前半或后半）→扩展覆盖整字。新组件测试（宽字 lead/spacer 标志合成行）固定吸附语义；上轮的字形居中绘制保留。
- #4 二级菜单：恢复 SubmenuButton 级联（悬停意图延迟展开、移入保持、离开关闭、自动左右翻转、一级菜单不消失）；上轮“仅点击”方案废除。测试更新为点击 submenu 再点目标。
- #5 目录大小：关键 bug——生产命令 `python3 -c '<script>' -- <path>` 里的 `--` 被脚本当 sys.argv[1]，远端快速路径自第五轮起从未成功过、一直退回慢速 SFTP 扫描。删除 `--` 并加本地回归测试（临时树+符号链接，与 du/find 对拍 size/files/dirs）。diagnostics 新增 DirectorySizeRemote/Fallback 记录实际路径。
- #6 双击编辑回传（新 workbench/local_edit_launch.dart）：下载（≤16MiB，1MiB 分块）→临时副本→系统编辑器打开（cmd start/open/xdg-open）→目录事件+800ms 轮询监测→700ms 写入稳定→与上次上传尺寸去重→整文件分块上传（首块 truncate）→远端大小与下载快照不一致=冲突不覆盖→失败/断开保留副本可重试→dispose 清理。双击路由从 showFilePreview 改为 openLocalEdit。新日志事件 editDownloaded/editOpened/editUploaded/editUploadFailed/editConflict（仅尺寸/耗时）。
- #7 内存：TerminalPainter 缓存上限 4096/128→2048/96（多窗格布局下保留段落内存减半）；files 面板 _folderBounds/_folderObjects 在每次目录重建时裁剪（此前仅在 Explorer 拖拽时清理）；其余审查项（DirectoryCache 64MiB 上限、run_log 2MiB、行图片缓存按视口）均已有界未动。
- #8 日志：connectionTiming（Connecting→Connected ms）、sftpDirectoryTiming（加载 ms）、memorySample（每分钟 ProcessInfo.currentRss KiB，WorkbenchApp 定时器）+ 编辑五事件+大小统计路径事件。无路径/正文/凭据。
- 验证：Flutter Analyze0；受影响组件测试 55 项全过（新增 sftp_scrollbar_pixels/wide_selection_snap；sftp_scrollbar_layout 重写为嵌套结构断言）；Rust fmt/严格Clippy0、ssh-core80（+dir_size 脚本测试）/term-core42、storage-sync 本轮未改存储层（沿用上轮219）；FRB 无新 API（无需重生成）；bridge_contracts 253函数/80DTO/306Dart 0发现；Ubuntu clean 构建需先 cargo build frb-bridge+prepare+pub get（build/native_assets 空目录需预建，本机构建怪癖）后 debug 构建成功，真实 GTK 冒烟启动/失焦CPU0%/正常退出0，RSS 494MiB（Linux debug 口径）。
- 边界：远端du速度、双击编辑回传（Windows系统编辑器/稳定检测/冲突）、重命名框高度、滚动条、中文选区、二级菜单、内存与日志事件均待用户Windows11实机复测；Linux冒烟不能替代。双击行为已从预览改为本地编辑，预览入口（右键打开）不变。

## 2026-11-06 第五轮 Windows 反馈十一项修正（已发布：源码d80edad，Windows CI成功）

- Windows发布：源码d80edad已推送，run42165775926/job127721804998全部成功（05:00–05:23Z）：正规FRB、MSVC Release、Analyze0、CI固定14文件组件测试、原生启动/正常退出、正常关闭重开窗口几何恢复均过。完整包：https://github.com/hspmanbu/hspterm/actions/runs/42165775926/artifacts/13480081341 （HSPTerm-windows-x64，40,095,322字节，2026-11-20到期）。锁库启动工作集114.10/111.08/111.06MiB（artifact13479786899，Server2022口径，低于上两轮的~117-121MiB）。旧run42055723033为de00e3a基线，未重发。

- #1 横幅根因（实验确证）：在本机真实 Ubuntu sshd 上验证——exec 会话（含 -t PTY）永不打印 PAM/MOTD，只有 request_shell 打印。上一轮"PTY 上 exec 探针"前提错误。现改为 shell-first：主通道 request_shell（横幅+上次登录如实进入终端流），探测走旁路 exec 通道 `probe_on_exec_channel`（输出丢弃、退出码42判定）；探测成功后排干 shell 输出（首字节3s耐心+350ms静默窗）再换新交互通道 exec 集成 Bash（PAM 每连接一次，横幅不重复）；失败零扰动继续默认 shell。探针脚本保持 stderr 静默+括号平衡+bash -n 回归。
- #6 多标签：日志证实 `api.rs:552/510 create_configured_terminal`→Terminal::new→HistoryPager IO 错误被 SshError::Terminal 字面量白名单短路吞成"终端尺寸无效"。修复一：summary() 的 SshError 分派移到白名单之前（变体摘要区分 InvalidSize/History+io ErrorKind 枚举）；修复二：term-core 历史降级——HistoryPager::new 失败改为有界 RAM-only 模式（MemoryRow backing，上限8192行），终端创建不再因临时目录 IO 失败而失败；Windows 真实 io 类别待下一份日志确认。
- #2 重命名编辑器：SizedBox.expand 占满行高 + textAlignVertical.center 同中线；`SelectionTarget.onTapDown` 在 editing==f.id 时不再抢焦点（框内点击不退出）；框外失焦/Escape 仍取消，回车应用。修正上一轮 expands:true 与 maxLines:1 的运行时断言冲突（已撤）。
- #3 拖拽悬停不打开：Explorer hover 与内部拖拽 hover 的 750ms 导航 Timer 全部移除，仅保留高亮；落点为唯一目标。
- #4 滚动条（组件测试固定几何）：竖向 Scrollbar 包裹横向视口→轨道钉在面板右缘（横向滚动后仍钉住，断言通过）；横向条为底部独立短条（SizedBox 14px + Scrollbar(controller:_horizontal)）；两轨道不相交（≤相切）。新增 test/sftp_scrollbar_layout_test.dart。
- #5 分割条不跟鼠标：根因是 onDelta 闭包捕获构建期基值（width/ratio/queueHeight/listWidth），重建间的连续 pan 事件相互覆盖；列宽因读实时 `widths[i]` 而正确。四处全部改为实时值累加（sidebar-grip/split-grip/queue-grip/host-list-grip）。
- #7 中文选区：painter 单字路径字形在 cell.width*wide 跨度内水平居中（CJK 回退字形宽度≠格宽整数倍导致文字与选区框错位）；选区两端 spacer 吸附保持。
- #8 失焦空白：桌面失焦是 AppLifecycleState.inactive，_active 现把 inactive 视为可见（仅 hidden/paused/detached 停止渲染）。
- #9a 复制到/移动到：SubmenuButton 悬停弹出改为普通菜单项"复制/移动到其他主机…"，点击后在原位置附近弹二级目标列表（沿用 copy-target/move-target 处理链）；测试同步更新。
- #9b 远端 du：`inspection/dir_size.py` 固定只读扫描（scandir+lstat、跳链接、1M条目/128深度上限、argv 传参无 shell 拼接）+ Inspector::directory_size（120s 窗口、JSON 末行解析）；`sftp_directory_size_step` 优先远端一次往返（complete 页），失败置 inspector_failed 回退 SFTP 分页扫描。
- #10 排序：_compareText 大小写不敏感+原拼写稳定次序（名称/类型列）；新增 storage-sync `sftp_host_prefs`（device-sftp-host-prefs-v1，64主机、column≤3）+ `load/record_sftp_sort_pref` FRB API；WorkbenchModel.rememberedSort/rememberSort 钩子（Mock 空实现），面板应用记忆并在表头点击时记录。
- #11 内存：RAM-only 降级含懒盘历史（不可用即不建临时目录）；Ubuntu debug 真实 GTK 冒烟 RSS 491.5MiB（软件渲染 debug 包口径，上轮483MiB 同量级），失焦 CPU 0%。
- 自动重连：断开后 3s 延迟单次尝试（用户澄清日志中被拒为自行重启服务器，行为正确；延迟仅防抖）；注释已如实更正。
- 验证：cargo fmt/严格Clippy(-D warnings)0；ssh-core79/term-core42/storage-sync219 单测过（新增 sftp_host_prefs、探针语法回归保持）；FRB 重生成（+2 API、SftpSortPref DTO）；bridge_contracts 253函数/80DTO/303Dart 0发现；Flutter Analyze0；受影响组件测试86项全过（含新滚动条几何、二级菜单点击、重命名交互）；Ubuntu debug 真实 GTK 构建+启动/失焦CPU0%/正常退出0 冒烟通过（本机编译验证，按用户要求执行）。
- 本机验证脚本 benchmark/workbench_smoke.py+resize_x11.py 自 git 历史恢复（未跟踪目录重建）；截图辅助未完成（X11 帧缓冲抓取 BadMatch，改用组件测试验证布局几何）。
- 边界：Windows 真机（横幅 shell-first 流、第二标签 RAM 降级、远端 du、失焦渲染、分割条）待用户实测；codex kitty 尾巴遗留未变。

## 2026-11-05 第四轮 Windows 反馈十五项修正（已发布：源码de00e3a，Windows CI成功）

- Windows发布：源码de00e3a已推送，run42055723033/job127343453179全部成功（15:30–15:52Z，约21分钟）：正规FRB、MSVC Release、Analyze0、CI固定14文件组件测试（含本轮重写的file_properties_dialog/sftp_feedback_ui）、原生启动/正常退出、正常关闭重开窗口几何恢复均过。完整包：https://github.com/hspmanbu/hspterm/actions/runs/42055723033/artifacts/13431500392 （HSPTerm-windows-x64，40,087,426字节，2026-11-19到期）。锁库启动工作集120.73/117.56/117.53MiB（artifact13431345518，Server2022口径，与上轮121.59/117.40/117.38持平）。旧run42021544762为e9368f8基线，未重发。

- 根因修复（#1/#5 同源）：e9368f8重写探测时把版本判定表达式抄错一个右括号（旧代码表达式本来平衡，cf13882前路径直送正常），旧探测通道丢弃stderr故从未暴露；新探测在PTY上运行导致bash报错直接可见且探测退出码非42→集成被禁用。现恢复平衡表达式+内层检查2>/dev/null+括号平衡与bash -n双重回归测试；探测成功路径直送随之恢复。
- #2 多标签"终端尺寸无效"：日志定位api.rs:510 create_configured_terminal→Terminal::new→HistoryPager IO错误被SshError::Terminal统一显示为"尺寸无效"。public_errors新增Terminal分支区分InvalidSize与History（含io ErrorKind枚举，无原始文本）；HistoryPager创建加120/240ms退避重试3次（AV/索引器瞬时失败）。真实Windows根因待下一份日志的io类别确认。
- SFTP UI：#3编辑框Center包裹与原文字同中线同字号；#4竖向滚动条改为固定可视区右缘（外层Scrollbar(controller:_vertical)包裹横向视口），横向条独立14px底行不再交叉；#6底部计数行与终端联动3按钮合并一行（SftpTerminalActions类删除，_terminalLinkActions内联）；#9列表Ctrl+滚轮字号0.8–1.6（行高/名称/元数据/表头全缩放，本次运行有效）。
- #10 Explorer拖入热区：列表右侧72px热区强制上传到当前目录（hover/drop双路径判定），拖拽悬浮反馈=顶部文字横幅（热区/文件夹/当前目录三态）+热区高亮，IgnorePointer不挡列表。
- #11 中文选区：select()两端都做宽字符spacer列吸附，框选与整字对齐。
- #12 右键与残留鼠标：捕获模式下右键（无Shift、开启右键粘贴）不再转发远端而是本地粘贴；shellInput事件detail新增"ready"（integration_input证明就绪），controller.shellInputReady驱动_forwardRemoteMouse——TUI退出后残留mouse reporting不再把事件注入回显流（codex退出"35;..M"尾巴的主因）。kitty keyboard响应尾巴("9::..u")未完全消除，待复测。
- #13 日志：AppLogEvent新增12个固定事件（SFTP目录加载/缓存命中/失败、导航、传输冲突提示/解决、Explorer拖入、自动重连触发/禁用等），model/queue/files接线，仍无路径/命令/正文。
- #14 会话目录缓存+上次目录：loadDirectory先查session缓存（同连接代次+已连接+非刷新/非OSC7才复用；刷新按钮/变异后refresh:true强制网络），断开重连代次变化自动失效；storage-sync新模块sftp_last_dirs（device-sftp-last-dirs-v1，64主机上限、绝对路径校验、损坏报错）+load/record API；SFTP浏览设置新增"连接后进入上次目录"（默认关，serde兼容旧3字段记录），_restoreSftp按开关恢复，每次列表成功2s去抖落盘。
- #15 断联自动重连（用户修订默认关）：NetworkDefaults.auto_reconnect（serde默认false），SSH连接设置新开关；LiveTerminalSession每代次一次自动重连尝试（wasConnected边沿触发，临时连接排除，异步读取全局默认判定），日志记录触发/禁用。V1.4末尾已修订"绝不自动重连"硬性边界。
- #7 冲突自动弹窗：LiveTransferQueue检测conflicts>0且非busy且未提示过的任务，postFrame自动resolveBatch（每任务一次，_operations中不弹）。
- #8 菜单去重：区域标签菜单升级为"全部SSH会话·仅导航"（跨组+区域标注），app.dart删除session-list按钮。
- 验证：FRB2.13重新生成（+3 API：load/record_sftp_last_dir、SftpLastDir DTO、autoReconnect字段）；Rust fmt/严格Clippy(-D warnings)0；term-core42/ssh-core79/storage-sync218单测过（新增sftp_last_dirs、探测脚本语法回归、auto_reconnect初值）；bridge_contracts 251函数/79DTO/302Dart 0发现；Flutter Analyze0；受影响组件测试78项全过（含workbench sidebar回归——Stack包裹后Column需stretch，已修；file_navigation_ownership两测试为存量失败，按面包屑UI重写；terminal_paste_lifecycle按新右键策略更新断言）。
- 边界：Native桥接测试仍因本机无SO未跑；真实Ubuntu横幅+集成、codex复测（右键粘贴/退出乱码）、Windows第二标签HistoryPager重试、热区/字号/缓存/自动重连实测待用户。kitty keyboard响应回显尾巴未完全解决。

## 2026-11-05 第三轮 Windows 反馈九项修正（已发布：源码e9368f8，Windows CI成功）

- Windows发布：源码e9368f8已推送，run42021544762/job127225263699全部成功（约23分钟）：正规FRB、MSVC Release、Analyze0、CI固定14文件组件测试（含本轮重写的file_properties_dialog/sftp_feedback_ui）、原生启动/正常退出、正常关闭重开窗口几何恢复均过。完整包：https://github.com/hspmanbu/hspterm/actions/runs/42021544762/artifacts/13412329605 （HSPTerm-windows-x64，40,064,513字节，2026-11-19到期）。锁库启动工作集121.59/117.40/117.38MiB（artifact13413136935，Windows Server2022 runner口径，上轮115.00/111.97/111.94，差值在runner噪声与新增功能范围内，不替代用户Win11实测）。旧run41971663339为a0910ce基线，未重发。
- 范围：welcome横幅显示、命令历史全主机共用+本会话可见、SFTP地址栏/列表/重命名、属性分页统计+九宫格+下拉、最近使用持久化、选中即复制、IME候选框下一行。修订已写入V1.4末尾"第三轮 Windows 反馈修订"。
- welcome根因与修复（crates/ssh-core）：集成能力探测原先开无PTY exec通道并丢弃输出，Debian/Ubuntu把PAM/MOTD绑定到首个启动命令的会话通道，横幅因此丢失。现`open_interactive_channel`先建PTY通道，`integration::probe_on_pty`在PTY上exec探测：脚本零输出、独立退出码42判定（无stdout重放窗口），全部服务器输出逐字节进`early_output`如实回放；探测消耗通道后另开新交互通道跑正式会话（agent转发只在首个通道回报endpoint结果），每次连接仍一份横幅。非集成路径顺序不变、零行为差异。
- 命令历史（storage-sync + frb-bridge）：`HistoryIndex`改`host_id: Option`，新增`index_all()`全主机合并池（同文本取最近使用、上限MAX_ENTRIES）；`candidates`接受`Option<&str>`。`terminal_suggestions`改用全局池（缓存仍按主机绑定以强制复查集成授权）；`record_integration_commands`成功后递增新`HISTORY_RECORD_EPOCH`并入`history_version()`三元组，本会话刚执行命令立即可联想。按主机/全局清除仍走HISTORY_IMPORT_EPOCH全局失效。
- 最近使用（storage-sync新模块recent_hosts + FRB）：设备本机记录`device-recent-hosts-v1`（上限10、去重、置顶、防御解析、损坏报错不覆盖），不入备份/云同步。`load_recent_hosts/record_recent_host`（仅正式已保存主机可记录）；LiveWorkbenchModel目录载入后恢复、`_openHost`记录并刷新；首页"最近使用"按最近顺序排列（不再按目录序）。
- SFTP地址栏（prototype/files.dart + cached_path_field.dart）：面包屑左对齐（去reverse）、移除编辑图标、点面包屑空白进入编辑（key `sftp-path-bar`）、输入框用主题填充边框占满36px行高、autofocus；进入编辑未改文本时候选=本会话访问目录（LRU缓存键、排除当前目录、全路径显示）；失焦退出编辑不导航。
- SFTP列表（files.dart）：`ListView`外包竖向`Scrollbar(thumbVisibility)`（复用`_vertical`控制器）。
- 重命名（files.dart）：整行编辑器（padding左34右10、全宽TextField）；点击外部（焦点离开`_renameFocus`且非busy）取消编辑；仅回车应用（onSubmitted→commitRename），Esc仍取消；未应用不改远端名。
- 属性对话框（frb-bridge + workbench/file_properties.dart 重写）：Rust新增`sftp_directory_size_begin/step/stop`（Entry级`dir_size_jobs`注册表：票绑定原SSH代次、每Entry≤4个、600s闲置回收、每步默认16目录上限256、20s步超时，出错/超时退役票且半读目录绝不重读进同一累计）与`DirectorySizePage`累计DTO；`sftp_account_options`经原SFTP会话有界(256KiB)读取解析/etc/passwd、/etc/group（去重、上限4096、不可用返回空）。Dart：大小逐页增长显示+"停止统计"按钮+已停止标注、文件/目录计数随页更新；权限3×3九宫格（行移位6/3/0）显示等效八进制；所有者/组下拉（含未知当前值合成项），账户列表不可用回退数字输入；保存仍只提交与基线差异字段，递归确认保留。
- 选中即复制（term-core/storage-sync/帧/面板/视图）：`Settings.copy_on_selection`（serde默认false，旧记录兼容）、Terminal/Snapshot/RenderFrame全链下发；终端设置面板新开关（key `terminal-copy-selection`）+确认摘要；`TerminalView`指针松开时若偏好开启且选区非全空白才`Clipboard.setData`。默认关闭。
- IME候选框（terminal/view.dart）：新增`_syncImeGeometry`，在原`setCaretRect`（macOS音调菜单）之外同时`setComposingRect`（Windows引擎`TextInput.setMarkedTextRect`定位候选窗）锚点为光标行下一行同列；attach后postFrame补报首帧几何，随帧/滚动/光标更新。
- 正规FRB2.13重新生成（新增5个API、RenderFrame.copyOnSelection、RemoteIdName/RemoteAccountOptions/DirectorySizePage DTO）。Rust fmt/严格Clippy(-D warnings)0；term-core42/ssh-core79/storage-sync217单测过（新增recent_hosts3项、全局历史池1项、探测脚本2项改写）；`bridge_contracts.py`249函数/78DTO/302Dart 0发现。
- Flutter Analyze0；受影响组件测试59项全过（file_properties_dialog 6项重写、cached_path_field 7项含会话历史候选/点空白进编辑/失焦退出、新sftp_inline_rename 2项、新terminal_selection_copy 2项含空白不复制与候选框下一行断言、sftp_feedback/file_columns/terminal_preferences/terminal_paste/workbench/terminal_layout/sftp_view/sftp_list_performance全过）。存量cached_path_field 'path text editing…'在HEAD本机复跑即失败（与本轮无关），已按新交互修复并扩入断言。
- 未验证边界：本机Native SO已按用户授权清理，`sftp_properties_bridge`/`sftp_mutation_generation_bridge`等Native测试本轮未跑（报"找不到Rust核心库"），须重建后统一执行；真实OpenSSH横幅/集成探测、GTK、云同步回归未跑。Windows CI通过不等于用户Windows11实机验收：欢迎横幅（Ubuntu+已启用Bash集成）、TSF中文输入与候选框下一行定位、属性实时大小统计/停止、选中即复制、最近使用持久化、地址栏/重命名新交互均待用户实测。

## 2026-11-05 第二轮 Windows 反馈正式交付

- 产品源码a0910ce（主修55ad8c7）已实际Windows MSVC Release构建成功；run41971663339/job127061543477已completed/success。Flutter Analyze0、66组件、原生启动退出、正常关闭后位置/大小恢复均过。完整包：https://github.com/hspmanbu/hspterm/actions/runs/41971663339/artifacts/13390548974 （HSPTerm-windows-x64，40,000,381字节，2026-11-19到期）。后续19194de和文档提交只改Ubuntu脚本/证据，产品源码与云构建逐项diff相同。不要重跑旧CI。
- 本轮已实现IME增量/迟到快照抑制/组合期受控操作保护、无效/隐藏viewport不resize、Bash连字符误判修复+OSC7/133+独立Readline证明、6秒可关闭统一通知、Ctrl滚轮/右键搜索及完整反馈SFTP导航/书签/新建/属性/同机和跨机操作。Ubuntu验证见上一节和validation/windows-feedback-second-2026-11-05。
- 云端锁库启动工作集：上轮115.66/111.66/111.64MiB，本轮115.00/111.97/111.94MiB，未见本轮额外启动内存增长；这是Windows Server2022云runner，不能替代用户Windows11的70–80MB实测。原始非敏感三样本JSON/构建结果行已保留。
- 当前无在途本机runner或构建。已清理本轮中间构建物和测试截图，释放3.70GiB，可用约13GiB；用户原始.log、ssh-screen/及tools/AGENTS.md仍原样未跟踪，不提交、不清理。下一次编译须prepare_native_extensions.py、pub get；不能运行已删除bundle。
- 仍待用户Win11实际复测TSF中文、真实最小化恢复，以及新SFTP交互。路径直送只用于已启用助手且可靠的普通Bash提示符；Codex/Vim/tmux/隐藏输入等仍安全复制降级。新助手只对新连接及完整新命令产生OSC7/133，旧输出不补造。welcome/机器信息究竟恢复显示还是隐藏仍未明确，未改写终端输出。Android按用户要求暂停。

## 2026-11-05 本轮验证收齐与缓存清理

- 应用源码a0910ce已推送；19194de仅同步Linux GTK旧按钮选择器及测试记录，正式产品源代码与a0910ce相同，已用git diff逐项验证。该维护提交避免重复构建同一应用，Windows仍验run41971663339/job127061543477，不要换回旧run或重发dispatch。
- 真实GTK整例2项、原Mock GTK1项、组件去重65、Native真实SSH/SFTP5、term全105/bridge77/ssh单元79/可选Bash真实9、Python与桥接静态/Clippy/Analyze/格式均过；源码与实际测试边界见validation/windows-feedback-second-2026-11-05。
- 所有GUI后最终又恢复并成功构建正式workbench_main.dart；此前同产品源码独立启动/缩放/正常关闭退出0，空闲/失焦各5秒CPU0%，预览run0。随后安全清理本轮target/build/.dart_tool/ephemeral/生成插件元数据及测试PNG，释放3,969,970,176字节，可用约12.97GiB。旧bundle现在已不存在，不能直接运行；下次需prepare_native_extensions.py、pub get后重建。用户原始.log、ssh-screen/、tools/AGENTS.md未跟踪且原样保留。
- Windows云构建结果仍待收取；welcome显示/隐藏仍待用户明确，未过滤或伪造正文。Windows11真实TSF中文输入与最小化/恢复需用户复测；Android暂停。

## 2026-11-05 第二轮发布与补充回归（最新a0910ce）

- 正式修正55ad8c7及IME门控/回归补充a0910ce均已正常Git推送。最新Windows run41971663339/job127061543477已实际运行：https://github.com/hspmanbu/hspterm/actions/runs/41971663339 。旧run41970895508由新head替代，不重复触发；当前尚不能宣称新Windows包通过，更不等于用户Windows11实机通过。
- 补充发现IME组合期间受控路径操作需UI门控：Controller标记组合态，开始及排队执行时双重检查；失焦/销毁清理，已分离TextInput连接的旧快照不再发送。该补充24项回归已通过，Analyze0。
- 与本次明确修订对应的旧相对路径菜单测试改为断言四项菜单/绝对路径不探测CWD，真实相对路径Native能力继续保留并通过；此组4项过。旧GTK脚本同步双书签、直接主机子菜单、同机无下载任务及显式路径编辑，未删除原目录重扫/编辑/队列覆盖。大GTK第三轮在/tmp/hspterm-second-full-gtk3.log；首轮因ensureVisible后未pump点击旧坐标失败，已修。第二轮已通过远端重扫/候选补全，随后发现旧脚本仍找上轮已取消的子页保存按钮，现改为统一settings-apply并跑第三轮。第三轮已实际03:34 +1 All tests passed，包含大目录/编辑/同机与跨机/失败重扫/补全/统一应用及Vault真实UI。组件去重65、Native5、GTK2均过；正式入口最后重建与独立启动/缩放/正常退出0已通过；各5秒空闲/失焦CPU0%，无历史/编辑副本/预览run残留。保留原Mock入口的GTK脚本同步菜单后已00:29 +1通过（只是原型回归，不当正式SFTP业务验收）；随后重新恢复正式workbench_main.dart入口。
- 补充已随a0910ce推送，Actions已用新head替代前一轮；恢复先查询最新head对应run，不手动dispatch重复作业。原用户.log、ssh-screen/和tools/AGENTS.md仍原样未跟踪。

## 2026-11-05 第二轮 Windows 实机反馈（Ubuntu验证完成，待发布Windows构建）

用户日志/截图/复制的 tools/AGENTS.md 为用户未跟踪文件，保留且不提交。当前范围：IME 重复、最小化历史、Shell/OSC7/133/历史联想、6秒可关闭统一提示、字体滚轮/搜索菜单，以及本轮明确修订的 SFTP 导航/书签/新建/属性/同机与跨机操作。Bash 已确认5.2.21。welcome 项含义已异步询问，其他工作继续；本轮已进入集中验证，具体实际结果见 validation/windows-feedback-second-2026-11-05/README.md；不沿用上一轮通过冒称本轮验收。

- 已编制：TerminalImeBuffer（平台模型保留、增量提交、不重发 composing）、无效/隐藏 viewport 不发送 PTY resize、普通已证明 Readline 的 legacy keypad 支持、OSC133 锚点失效不撤销独立私有输入证明（RIS/Alt/私有损坏包仍撤销）、Bash OSC7/133、Ctrl+滚轮/右键搜索、统一6秒提示并显式 persist=false。
- SFTP 源码：面包屑/路径编辑、首行父目录、主机/全局书签弹出菜单、新文件EXCL与新建后选中可视、底部路径联动/跟随/跳转、紧凑带框菜单、空白右键、跨主机二级菜单、按标签隔离文件剪贴板、UID/GID/权限递归/链接目标/真实内容大小属性。服务器内复制固定 Python 程序经原 SSH 代次的 Inspector，SFTP 私有命名空间回执、O_EXCL/O_NOFOLLOW，正文不经过本机；不可用不回退下载。大小分页元数据聚合，基本权限读取与大小计算分离，失败仍可编辑权限。
- 正规 FRB2.13 生成已完成；Dart Analyze 第一轮0。新IME/通知/尺寸等组件28项通过，服务器复制Python3项通过。Rust三库串行单测正在 /tmp/hspterm-second-rust3.log，之前编译错误已修，真实SSH/SFTP、菜单交互/属性布局、GTK/Windows CI仍待执行。勿把上述源码算实机通过；现已进入集中验证，不再停在规划。
- 最新测试：Flutter60项及后补置尾滚动回归（去重61项）、真实Native4项、实际可选Bash9项、服务器复制Python3项及Bash控制字符校验1项通过；严格Clippy已修最后一处字段初始化提示并通过。修复了Bash字符类将正常连字符误判为控制字符的根因。GTK真实工作台1项、term105/bridge77/ssh79、严格Clippy、Analyze0/格式/桥接契约及Python测试通过。Native4项含逐标签同机复制/剪切、完整LiveWorkbench回归；最终受控路径截图已实际检查。正式Debug工作台已重建并独立启动/缩放/正常退出0，空闲/失焦各5秒CPU均0%，预览run残留0（debug-startup.json）；Linux Debug软件图形RSS约483MiB，不当Windows Release实测。下一步提交/发布并查询新Windows CI，不能重复触发旧run。
- 用户仅回复继续，welcome含义问题仍未明确；尚未为此隐藏或伪造服务器输出。用户原始日志、ssh-screen截图、tools/AGENTS.md均未跟踪且必须保留，不提交、不清理。

## 2026-11-05 四项反馈修复：Ubuntu 与 Windows CI 验证通过

- Shell 路径：resize 保留未改变的真实 Readline proof；能力探测兼容 banner；失败显示具体固定原因并记录阶段。仍要求同会话、主动启用与远端原子比较/回执，不能盲目注入 TUI。
- 设置：详细字段外部留白，诊断筛选加宽/展开，九分类×大小两种窗口 GTK 无溢出并已视觉检查。
- 日志：本次启动 Rust/UI 有界内存环形日志，UTC/INFO/WARN/ERROR、模块、错误分类和代码位置，支持导出 `.log` 覆盖写入；不读旧日志，不记录秘密、命令、正文、路径或剪贴板。
- Windows：Flutter 子 HWND 边缘转交父窗体，父边框判断优先于 Flutter 默认处理；WM_DESTROY 清除 HWND 前保存本机 HKCU 正常矩形/最大化，下次启动恢复。CI 新增正常关闭后的位置/大小恢复检查；真实边框拖动、Snap/DPI 等待用户 Win11 实测。
- 已执行：正规 FRB2.13；Bridge 串行77、term-core104、真实隔离 OpenSSH8、能力探测单测2；严格 Clippy；Flutter组件66、最终日志/错误边界10及路径5复测；Analyze0；GTK设置1（18分类/尺寸组合，含真实 Native 日志 API）；正式 Ubuntu debug 构建/启动/正常退出0，SO散列匹配，无残留 run。详 validation/windows-feedback-2026-11-05/results.json。
- 失败均保留说明：Bridge 默认并行会相互替换测试全局 Vault，完整串行77通过；日志文件测试先见字节不等于 flush 已完成，已改为真实 ACK；无桌面环境旧门户阻塞，正式 smoke 使用独立 D-Bus 会话通过。未将失败算通过。
- 已发布源码 cf13882（本机等树原提交 3f15f60 保留 windows-feedback-nov5-local-3f15f60），Windows run [41933717144](https://github.com/hspmanbu/hspterm/actions/runs/41933717144)、job126936779459全部成功：正规 FRB、MSVC Release、Analyze0、52组件、原生启动/正常退出、正常关闭重开的位置/大小恢复。完整包 HSPTerm-windows-x64（artifact13374471855，约38MiB）；Windows Server2022 CI不是用户Windows11实测，解锁后自定义边框拖动/Snap/DPI仍需复测。
- 测试后已清理 root target、Flutter build/.dart_tool/ephemeral/生成插件及临时截图，再释放3.29GiB，当前可用12.81GiB。源码/正式FRB/vendor/锁文件/文字JSON证据保留；新构建先 python3 tools/prepare_native_extensions.py 再 ui_flutter/flutter pub get。Android暂停。

## 最新操作：用户授权磁盘清理（2026-11-04）

- 确认无在途本机编译/测试/SSH夹具、Git原先干净后，按用户要求删除Cargo target、Flutter build/.dart_tool/平台ephemeral及插件生成注册、中间验证SO/性能旧包/静态副本/日志、临时截图及旧源码zip。没有删除源码、Rust vendor、字体/图标、测试夹具、工具链、共享依赖缓存、文字/JSON验证结果或Git历史。
- 实际文件系统释放14,972,358,656字节（约13.94GiB）；非特权可用空间从0恢复至14,580,408,320字节（约13.58GiB），df显示14G。项目约15G降至391M。96张已跟踪验证截图移出当前树，历史仍可查；新增validation截图忽略规则，最新截图链接已转向保留版本。
- 先前103组件/7个GTK/两模式构建启动结果仍有效，但本机二进制/中间库/Flutter包配置已清除，不能直接运行旧bundle路径或把缺失产物误判功能缺失。下次构建先运行python3 tools/prepare_native_extensions.py，再在ui_flutter执行flutter pub get，之后按现有构建说明重新编译；保留Cargo.lock/pubspec.lock、正式生成桥接源码。
- 没有为本次纯清理重新编译或生成截图，只检查Git差异、必要源文件/资源及生成目录缺失，避免立即重新占满磁盘。GitHub Windows run41849076983仍是七项反馈修正构建入口；云端任务与本机清理独立，清理不改变该构建源码。

## 最新任务：Windows首轮使用反馈七项修正（2026-11-04，Ubuntu回归通过，准备Windows构建）

- 用户确认新包启动约70–80MB；这是用户Windows观测，未与Ubuntu压力数据混为同一口径。
- 主机配置重开仍存在；原首页总显示首次创建文案，已改为启动先读取固定应用数据目录是否已有Vault，只在新建显示确认密码，已有库显示解锁。未取消加密、不自动建立连接。
- 用户确认Enter/方向/Ctrl有效，只有字母/中文无效。已核对固定Flutter Windows text_input_plugin.cc：setClient的viewId必须是整数，否则在创建active_model_之前拒绝。TerminalView自定义TextInputConfiguration遗漏viewId，现明确使用View.of(context).viewId，已补原文字/IME组合测试中的配置断言，不采用猜测性延时键盘回退。
- 设置页按新修订保留懒创建的各分类状态/草稿、隐藏页停Ticker/焦点，右上角统一取消/应用/确定；不因切分类弹窗，离开整页才提示。九类表单加应用回调，原独立/主机编辑入口保存按钮保留。SFTP默认值/主题在设置页也变草稿。应用失败保留/定位分类、已确认保存不重做。字体与终端偏好共享portable记录时仅可对确认未变的非本页字段重新取得CAS，实际跨分类Native集成已过。
- 增加设置留白/字段辅助文本换行/小开关，缩短纯技术说明；不隐藏必要安全提示。SFTP大小改KB/MB/GB，保留byteSize排序/传输；移除Explorer拖出行提示。路径安全复制保留，新增发送说明及配置原主机入口（不自动启用/重连）。V1.4末尾已写最新用户修订。
- 最后17文件103项回归全部通过（1:01），新增丢回执仍不能假成功的保护/测试。7个不同GTK用例均通过：新设置/实际Vault与跨类别回读，真实OpenSSH字体/PTY、终端偏好、历史、显示、SSH默认值、Kitty快捷键；重复运行不虚增用例。早期旧交互断言、主题基线和模态取消重名失败均已修，原失败日志保留。九分类1280×720/760×620的18张真实截图已归档，人工检查还修正加密页面板间距及过时说明。
- 归档入口validation/windows-feedback-2026-11-04/README.md、checks.json及18张截图；组件最终日志/tmp/hspterm-feedback-103.log，GTK最终数据/tmp/hspterm-feedback-gtk-suite-resume.json及新设置all-settings/delivery-settings日志。Analyze0项、164文件格式0变更、actionlint通过；正式debug/release已恢复并正常启动/退出0、Rust加载和preview run清理通过。最后加密页间距补修后GTK九分类/18图再次通过，正式debug/release也已最终重建/实际启动关闭0（日志/tmp/hspterm-feedback-delivery-*），不是集成测试入口。即将提交/推送新Windows构建。不重复Rust/FRB测试，本轮未改核心协议或绑定。

## 最新用户反馈：设置页面内存优化（2026-11-04）

- Windows首个成功包来自run41813471598，Artifact13314479216（39,819,157字节）；实际正规FRB生成、MSVC/Rust/C++编译、Analyze、窗口启动/正常关闭及打包全部通过。此前尚未成功的条目保留作历史，不能再将Windows MSVC标为未编译；这仍不等于Windows11完整系统交互验收。
- 用户反馈启动200多MB/设置300多MB。定位到TypographySettingsPanel初始化立即枚举系统字体，普通DropdownButton的IndexedStack即使未展开也为最多4096个选项创建/布局隐藏文本。现在改为打开字体选择器才枚举，并以搜索+虚拟列表显示；关闭设置不保留目录缓存，仍只改草稿、显式保存。内置/系统/导入字体及主机覆盖保留。
- 相同4096项合成目录、两个独立Ubuntu Release进程、四次进入/退出的实际对照：首个设置RSS432.13→289.71MiB，各自基线增量180.51→35.52MiB，目录读取4→0（从未展开选择器）；完整原始JSON与说明见validation/settings-memory-2026-11-04。不能把Linux压力场景当用户Windows实际降幅；启动基础内存尚未完成Windows分层归因，未宣称长期无泄漏。
- 新增大型目录不预读/隐藏不创建、搜索末项/仅改草稿/明确保存、枚举失败内置兜底、取消后异步完成安全、窄窗1.5倍字号/键盘Enter选择；相关19项测试通过，Analyze0项，实际OpenSSH导入字体/保存/PTY尺寸调整/同会话身份GTK1项通过。首次基准缺少导入和ScrollCacheExtent未导出导致编译失败已修；初次Analyze的unused/deprecation也已修，最后运行日志/tmp/hspterm-font-lazy-final19.log、*-final-analyze.log、*-gtk-final.log。
- 正式release已恢复lib/workbench_main.dart并构建成功，实际GTK启动/缩放/正常关闭退出0，Rust库已加载、无终端历史/编辑工作文件创建、preview run残留0。19项最终组件测试、GTK1项、Analyze0项、5个Dart文件格式0变更、actionlint通过，checks.json已存档。本次未改Rust/协议/加密，未重复无关647项。
- Windows workflow新增相同19项组件测试及锁库无SSH的三个内存样本（工作集/专用字节/线程数），作为单独windows-startup-memory Artifact；不读取配置、账号或凭据，不能当用户Win11设置页复测。即将提交/推送修正并读取新Windows run结果，不交付benchmark或integration_test入口。

## 当前阶段与恢复（2026-11-04，Ubuntu适用统一验证收尾完成）

Windows功能源码已接入正式工作台，本机可执行的统一验证已收齐；Android按用户要求暂缓。Windows Server2022/MSVC/C++正式云构建及基础窗口启动退出已通过（run41813471598）；Windows11系统行为及真实云服务账号测试仍待对应环境，不能将Ubuntu结果视为Windows客户端已验收。V1.4、标签组及逐主机可选Shell修订仍为基线；Shell许可已获确认，不重复询问、不默认启用。

- 源码修正检查点`98fb042`；后续仅测试辅助函数花括号风格修正和验证记录，最新提交以Git日志为准。正式键位即时应用、原SSH修饰键释放、取消错误稳定、真实通道/worker退休、停用同步取消和两项密码学安全补丁均已实测。
- Rust完整workspace647项通过；安全补丁后Bridge75/SSH255项重跑通过；VTE56/alacritty178项通过。Linux/Windows GNU全目标严格Clippy0警告，Rust格式通过；Cargo audit当前数据库0漏洞/0警告。
- Flutter143文件、507个去重用例全部有通过证据：53轮123个完整文件455项，最后文件中断后按清单续20文件52项，原已过3项重复不计。不是伪称一条完整命令507通过。第56轮20文件全部通过；最后Analyze0项、305个Dart文件格式0变更；桥接源码审查237API/74DTO/282Dart文件0发现，233公开Result有错误边界，Python22项通过。
- Ubuntu适用GTK29文件均有真实通过证据，新锁Kitty/Codex/SSH再次通过；大型SFTP/Mousepad/大文件/编码/队列流程通过。真实Codex仅使用隔离HOME与合成回环provider，无账号/付费；Claude真实账号当前不要求。
- 第53轮新锁19场景release性能及正式debug/release构建通过；第57轮两模式真实GTK启动、Native加载、未擅自建库/历史、预览run退出清理/退出0通过。两种bundle内Rust散列与对应构建一致，均为`lib/workbench_main.dart`正式入口。
- 当前没有在途验证runner或待恢复SIGSTOP。中断/复核原日志保留在/tmp，完成状态、去重清单、性能/启动JSON和安全截图已固化到`validation/windows-unified-2026-11-04/`，不依赖聊天或临时日志才能恢复。
- 下一入口：读取该验证目录README、REQUIREMENTS_COVERAGE及PLATFORM_VALIDATION，在具备Windows工具链/系统后按`tools/build_windows.ps1`实际构建与验收，具备明确授权云测试账号后补服务商端到端；Android继续暂缓。本机已无未处理的测试失败，不重复编码已验功能或退回“静态阶段”。
- 性能边界：终端5.603秒空闲0桥接/0渲染帧、负载输入中位30ms/P95 46ms；Ubuntu软件图形栈高输出raster约90ms、负载约47ms，锁库页焦点CPU/图形缓存仍有开销。没有宣称Windows60fps、最低RSS或长期无泄漏，详聚合数据与验证README。

以下保留历史节点用于追溯，所有“最新/未统一验证/待Shell决定/下一步”均由本节和最终记录覆盖。

## 历史源码阶段摘要（已被2026-11-04恢复入口覆盖）

**最新续作：Explorer目录与正式队列接线源码已编制，尚未统一验证。** 从d0f4eb6继续，transfers::explorer/ExportReady、私有持久快照/原Root交付与逐文件读取租约、真实目录Source任务和队列离线再拖出已经接线；不能再按“只有描述符、目录入口仍拒绝”重复实现。具体边界及尚待测试项见本记录末节和WINDOWS_EXPLORER_DROP最新节。直传未知结果/精确续传、可靠Shell输入与路径注入及全量审核仍未齐；85%仅此前粗估，不作为已验证统计。


**2026-11-03最新入口（优先于下方历史摘要）**：10b4bc7已保存安全直传正文/策略/任务接线源码；随后继续Explorer目录清单与固定原生依赖补丁。最后完整已验证仍0e96be4，新增均未统一生成/编译/测试。跨服务器Relocate正式源码已经接入，不能再按早期“正式入口未接”重复开发；直传未知结果/精确续传、Explorer目录实际消费队列、可靠单行Shell输入与路径注入仍未齐。Shell可选集成的重大边界问题已请求用户选择，尚无答复，不按允许处理。Windows继续、Android暂停，最终统一验证策略保持。

最新已提交源码链包括d090612暂存清理、42d3239手动重连待传恢复、80325de普通文件Explorer虚拟下载、cef35fa清理后释放无日志任务、40dde05独立移动检查通道、ff63b37/b3cf8ca预览取消与监督、d942482清理原会话身份。全部未统一生成/编译/测试；最新跨服务器来源删除核心见SOURCE_RETIREMENT，正式入口仍待接，不得误称跨服务器剪切已可用。继续该接入、其余Windows源码与全量静态审核，不按模块暂停；Android暂停。

最新静态续作：已接暂存清理核心/桥接/独立分页清单及风险确认（STAGING_CLEANUP.md），仅格式解析/手工跨层审核，未统一生成编译测试。继续安全直传/跨服剪切、反向Explorer、可靠单行历史与路径发送和手动重连传输恢复源码已继续接入（TRANSFER_RECONNECT.md）；不能标Windows全部完成。

最新源码链：c82d2a3原SFTP所有权/本机IO退休/有限恢复，4eff048远端中转并行/双端恢复，cada108有界可验证OSC133旧范围Reflow；随后Explorer拖入上传与原代次入队源码见末节及最新Git。**均未统一生成/编译/运行；最后完整已验证仍0e96be4。** Windows其余源码与全量静态审核未结束，Android暂停，不能依据源码提交标全部完成。

2026-11-01继续：已保存Drive正式对象接线/密钥修订efb0c45、明确发现选择fa9def2、首次创建持久同ID恢复2935ee2、引用冲突可操作解决4620d60源码检查点；OSC133保留范围/输出复制/命令导航、Nerd许可子集、主机级本机字体覆盖与终端通知源码见末节。全部新增均未统一生成编译测试；Windows先行、Android暂缓、不中途模块验收暂停。

2026-10-30持续执行覆盖：用户明确不在模块边界停下等待“继续”；当前继续Windows编码/跨层静态审核，最后统一生成/编译测试，Android暂缓。已新增d2378e9的Drive桌面授权源码检查点，已新增bc8b918的真实界面深浅主题源码，已新增df1e180的Drive对象源码检查点，已新增5869f4c的既有tmux附着恢复，已新增7a1bee5的新建tmux身份与恢复源码，已新增6bc39ef轮换token源码；当前Drive已有对象正式运行接线及秘密修订标识安全修复已有源码，对象选择/首次创建与其余Windows功能继续；具体在末节，尚未统一验证。

2026-10-29恢复：从干净8f5bd1e（配置同步领域/WebDAV）继续同事务修改记录和本机正式同步设置/秘密/代理保存页，见末节。全部仍是未统一验证的静态源码；不以提交/格式化替代编译、Analyze或测试。Windows完整功能与全量静态审核尚未结束，Android暂缓。

最近源码检查点：8f5bd1e（同步协议/WebDAV）、9fb85ec（相对路径）、3afba8a（RTT）、100981a（诊断）、16ea2ea（终端偏好），及989fa05备份/e78fd6e DPAPI等；之后正式同步设置源码见末尾及最新Git。这些均未统一生成/编译/测试，最后完整已验证节点仍0e96be4；Windows全部编码及全量静态审核尚未结束。

工作目录`/opt/hspterm`。唯一产品基线V1.4（含一个标签一个SSH会话的布局修订），按完整功能连续开发，不按阶段/原型验收暂停。用户最新策略：成批静态编码及跨层审查后集中编译、测试、修正；不重复正确功能，不覆盖未知改动。先读AGENTS、需求、覆盖表、Git状态/近期提交。本记录简要恢复；175条对应关系见REQUIREMENTS_COVERAGE，不能把Mock计真实能力。

当前为Phase 3 Windows正式业务整合，Ubuntu负责核心/Flutter开发验证；Android正式UI/平台业务尚未完整开发。Phase1/2及3A已有稳定成果保留；完整功能远未全部交付，不把物理设备缺失当停止其他编码的理由。

**最新用户范围覆盖**：Windows优先，Android开发暂缓（需求保留）。用户已自行清理中间构建文件并明确恢复开发；不再次删除缓存或已有文件。2026-10-28恢复时Git仍有上一轮快捷键整合未提交代码，完整保留；磁盘可用约12GiB。继续先成批静态源码/跨层审查，最后统一生成桥接、编译及测试。本批从Windows终端字体/排版持久配置、实际字体导入和渲染接入推进；快捷键假时钟测试未结束的问题仍待统一调试。

## 最近稳定节点

- `a3a83f7`：真实加密分组/主机排序、跨组/收藏拖放、多选、原Vault/全元数据修订/CAS原子保存；凭据/草稿/原活SSH/SFTP保持。HostManager分组导航用ID，真实“收藏/全部主机”分组不冲突，搜索跨组平铺。HOST_ORDERING.md含边界；主列表直接树拖排/完整高级批改仍未做。
- `4bfbc40`：命令历史加密管理页，非秘密计数、开关、主机/全局明确清除（零条仍保存删除epoch），原Vault/历史修订保护、清除不提交未保存开关、Model退出等写入。**无实际输入采集/候选UI/云同步**，不能因管理页已接而盲采集TUI/秘密或开放记录API；见COMMAND_HISTORY.md。
- 最新命令面板节点（提交号以git log为准）：打开时捕获原view/Controller代次，中文搜索、上下/Enter/Esc、可用动作过滤/原焦点改变撤下、最多8个本次运行应用操作ID、虚拟列表/选中滚入视口、IME候选键交平台、关闭与路由退出迟到点击保护。相同Controller通知不调度面板新帧；操作保持原确认。**自定义快捷键持久化/完整冲突路由尚未接**；TerminalView协议输入未改。见COMMAND_PALETTE.md。
- 更早OSC8/file URI、单次临时连接、tmux明确选择、Agent/RSA/实际连接回执、PTY/SFTP背压隔离、真实文件管理/编辑/复制/同账户移动/未知移动本机审阅等不要重复实现。细节见对应专项文档及Git。

## 最后实际验证

- **完整Flutter252项6:13通过**（.local/workbench-final-flutter-full.log），含真实Codex CLI隔离HOME/CODEX_HOME及loopback合成provider、原SSH/SFTP/编辑传输/键位和本轮全部新增。无真实账号/付费任务/Claude账号测试。
- 本轮排序storage94项118秒/Bridge33项24.51秒、Flutter239项5:54、GTK1项11秒通过。历史管理首轮旧94项通过、新3项夹具缺凭据失败；仅修正夹具后完整历史12项14.22秒、Bridge33项24.69秒通过，严格workspace all-target Clippy/Analyze/NDK通过。不是同轮完整97通过。
- 历史相关Flutter50项37秒/GTK1项10秒；面板最终相关54项19秒/专项7项3秒/真实双SSH GTK1项16秒通过。面板未改Rust/FRB，不重复不相关Rust测试。最新共享NDK25/API26 workspace check来自4bfbc40，不是APK/设备。
- 正式debug/release均为`lib/workbench_main.dart`，已在最后GTK之后重建，并独立真实窗口启动/resize/正常关闭0，无未连接历史/编辑工作副本/preview run残留。完整unit测试不覆盖Linux正式bundle，交付入口仍正确。
- 同模式SO已核对：debug `9ce3565cbd87e9f133f37a8086166f1de6525840f9b527c605edeeb33c18b2be`；release `288b6e8653ad28975c757774ce573354136a726b3e3dfe303a212b5285f3af78`。Dart/Native绑定必须匹配。
- 关键失败/恢复完整保留于docs/history/PROGRESS_2026-10-28_WORKBENCH.md：排序Material/确认无限动画修正；历史夹具CredentialRequired/curly lint；面板post-frame滚动测试待帧、const Set检查修正；76486在debug Built后退出143无smoke/release日志，确认无在途后从启动续跑35868并全部通过。35868/31051/4846等已结束0，不再等待旧session。

## 性能与截图

- validation/phase3b/{host-order,history-controls,command-palette}-*.png均实际GTK生成并查看，只含合成主机/私有SSH横幅，非静态设计图。运行/测试命令见三个专项文档。
- 最新command-palette-startup短样本debug RSS513523712B/聚焦CPU38.59%、失焦515190784B/6.20%；release339017728B/9.20%、失焦349425664B/5.20%。不是优化对照/长期泄漏证明，旧基线不得删。
- benchmark/workbench_idle_threads.py已实际执行，只启动私有锁库窗口，不附加用户进程/用ptrace/访问账号。独立release失焦5秒CPU4.40%，线程计数主线程5ticks、raster3、llvmpipe16（100ticks/s）。只能说明分布，具体重绘/调度根因仍未定位，未牺牲正确功能来降低数字。

## 统一验证前的历史待办（非当前开发入口）

1. 快捷键及Windows字体/排版已经静态接入，均未完成统一运行验证；见末节。继续Windows其余未完成设置/业务，最后正规生成新增API并统一编译/测试/修正，不能用旧绑定/SO调用字体接口。保留快捷键Fake时钟未结束问题；Android暂缓。
2. 可靠普通Shell/本地编辑证明→合格单行历史采集、纵向候选、Enter执行/Tab只填入和实际清除失效；**OSC7/133不能单独证明安全**，禁止盲Ctrl-U/backspace或TUI注入。可靠OSC133历史C/D范围、导航和输出复制；十项路径安全发送、path:line、Android长按仍待接；现有选区/file URI定位/OSC7跟随不要重做。
3. tmux按配置恢复（当前每次明确重连重新选择）、完整可继续任务恢复；文件任务内部并行、直接复制、跨服务器剪切、安全暂存清理/编辑互斥；主机主列表直接排序与高级非敏感批改；真实状态栏/可选远端指标。
4. 完整加密备份差异预览/原子合并与替换、WebDAV/Drive E2E/条件请求/冲突、DPAPI/Keystore。只准正式catalog/独立凭据/允许设置/书签/合格历史；排除草稿/布局/设备任务/正文/滚动缓存/临时秘密/Agent授权/tmux运行态/运行scope与本机history writer。凭据恢复必须原Vault门控撤销Agent，不能强断已建SSH。
5. Windows原生窗口/Explorer拖放等代码及构建方案；Android单终端/全屏SFTP/SAF、本地文件、IME/触控/扩展键盘/前台服务/APK等共享与平台业务。物理Windows/Android验证除外，不能因此停止可做编码；也不能把Ubuntu/NDK check冒充实机或APK。
6. 所有其他未完成项按REQUIREMENTS_COVERAGE继续，不能将此简表视为范围删减。不进入逐阶段等待验收流程。

## 可复现环境与限制

- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；CARGO_INCREMENTAL=0、CARGO_BUILD_JOBS=2传全部FRB/Flutter/CMake子构建，同一时间一条重构建管道。FRB2.13正规生成后cargo fmt，不手改绑定。
- 正式入口ui_flutter/lib/workbench_main.dart；Phase2 lib/main.dart和纯Mock prototype_main.dart保留。GTK每个文件独立私有桌面benchmark/external_editor_gtk.py；之后必须恢复正式入口。窗口smoke用benchmark/workbench_smoke.py。
- 无Windows实机、Android设备/模拟器，SDK许可证未擅自接受；现有NDK可共享check。用户已清理中间构建文件，恢复时磁盘可用约12GiB；旧包/SO/依赖缓存不可假定存在，不盲重跑已结束操作或再次清理用户文件。此前构建哈希和测试数字仅历史证据，统一收尾须重新正规生成并核对新包。
- .local为忽略的实际日志/私有fixture；旧一次性integrate_*脚本/静态草稿不能覆盖正式源码。绝不提交真实私钥、Token、密码或服务器配置。没有运行中的验证管道（最终结果见git status与本次工具实际状态）。

## 在途快捷键配置/本地按键所有权（静态未注册）

稳定面板提交0e96be4，完整252项/正式双模式包均完成。开始下一批：storage-sync/src/shortcut_settings.rs与terminal/application_keys.dart已静态编制但尚未注册/接入口/编译。配置默认Ctrl+Shift+P、终端仍远端优先，用户可明确选择该单一组合键在终端归应用；原库/设置修订CAS、严格版本和保留键冲突拒绝。跨Navigator的本地按键所有权用于配对App组合键及面板Enter/Esc释放，避免关闭弹窗后向Kitty终端发孤立release；这是待验证的防护设计，尚未证明已有缺陷。下一步先补原生DTO/正式设置与Scope接入/单元和真实TUI测试再集中生成构建，不能宣称新文件已生效。不要把未注册静态文件误当完成或覆盖稳定终端。

快捷键静态编制继续：Rust配置模块已注册、3项仓库测试源码及Bridge DTO/读取/原scope修订CAS保存已补；尚未FRB生成，不能用新调用加载旧SO。UI路由原事件标记改弱Expando，只存物理键所有权，不保留最后输入字符；原生终端/导航/正式设置与测试仍待接。此在途批次尚无编译/运行结果，不影响已提交0e96be4的可复现252项稳定节点。

快捷键批次已接Rust模块/Bridge接口源码、正式设置表单与预览（冻结原提案/确认等待不动画/载入失败禁止默认覆盖/保存后上下文变化单独ACK）、Model只在显式load读取一次且追踪保存；读取失败明确报错并禁用该未知组合键，不拦截SSH。原Fake生命周期测试通过注入只读配置loader保持不加载Native（测试尚未运行）。根Scope包住Navigator，TerminalView只增加可缺省UI路由钩子，Phase2入口无Scope时原样；远端优先决定不能在祖先再被应用截获，IME composing不抢组合；面板本地键配对归属，弱事件标记不留字符。所有源码尚未正规生成/编译。下一步补UI/路由/Native/GTK测试、复核优先级及释放，再集中FRB/构建和回归。

快捷键批次静态测试源码：Rust3项、Scope与原TerminalView路由3项（远端优先完整press/release、应用键及弹窗Enter跨Navigator不入SSH、关闭配置不吞键/不可变键映射）、设置4项、真实加密Native1项。尚未生成/运行；GTK真实Kitty输入收集/实际保存与新组合键仍需补，先完成后统一验证。新增Scope默认远端优先，原Phase2无Scope时回退原编码；Root旧硬编码P快捷键已移除，尚未编译不能称UI可运行。

快捷键批次静态源码与真实GTK夹具均已补：GTK私有SSH的raw Python TUI主动协商Kitty事件报告，分别检查默认远端组合键确实到达、明确保存自定义F8应用优先后组合键和弹窗关闭后迟到Enter释放为零远端输入；这还是待运行测试，不是已证明通过。设置通过实际菜单选择/预览/保存并截图，原SSH身份保持。静态复核修正claim先取owner后执行弹窗动作（避免无动画pop后查询已卸载context）、去掉无用Fake Controller并修正下拉测试访问真实DropdownButton回调。下一步开始统一FRB生成/编译/测试，不重复旧一次性补丁脚本。

快捷键首轮63513已结束1：FRB正规生成、完整storage100项111.94秒/Bridge33项24.50秒、严格Clippy/Native构建通过；只停于新设置测试private type lint，已改私有helper。93662第二轮Analyze无问题，相关50项通过后新Scope首项在Widget Fake时钟等待关闭未结束（worker约3分钟CPU1秒，非忙循环）。仅核对后终止该自有flutter_tester PID285092，保留日志；将关闭Future显式泵时钟并设有界检查后专项验证，不把未结束组合回归写成通过，GTK尚未开始。新增Meta不匹配CtrlShift组合保护，未改SSH编码。

## 最新用户开发节奏覆盖

2026-10-28用户再次明确：先完成全部剩余功能静态开发/跨层审查，最后统一生成绑定、编译、测试、调试修正，期间不逐模块构建。此前37580路由专项仍在假时钟下未完成，已核对仅终止其自有worker287845，保留问题记录，不称通过；清理后的原始.local日志是否仍存在须以文件为准。最新稳定仍0e96be4/全252历史通过；当前快捷键整合未稳定，源码保留、最终统一验证清单不删。**之后的范围覆盖是Windows优先、Android暂缓，不能继续此处旧Android下一批安排。**

## 当前静态批次：Windows终端字体与排版

- 新增Rust typography仓库与五个Bridge接口：加密排版参数/系统家族名/导入字体元数据，明确TTF/OTF字节导入、原scope/修订CAS、32MiB单份/8份/128MiB容量、内容散列复核、SFNT目录结构验证、元数据/正文原子发布、明确删除副本及当前字体回退。文件选择器只读用户选定文件，未存源路径。字体正文/本机映射不参与云同步；完整备份仍待显式清单及恢复预览，不据本机记录宣称备份已完成。
- Flutter实际设置表单/系统字体选择/有界文件读取/导入与删除确认/明确保存、读取失败禁覆盖、原视图之外的写入生命周期；Windows GDI系统家族枚举与Ubuntu Pango验证通道源码。默认外观保持，字号命令保留运行期缩放。动态加载按内容共享，Flutter无卸载接口，进程16次/128MiB预算限制切库/重复加载增长。
- 复用原TerminalView/Painter，统一字体测量/正文/IME预编辑，样式变化清行/字形缓存；连字默认关闭，启用仍验证固定网格段宽。字体/行高/内边距经原PTY尺寸通路更新，不重建SSH/SFTP，不改原字符。修正块状光标反色字形按真实高度居中。
- 已编写Rust4项/Flutter组件与控制器5项/Native1项/真实SSH GTK1项测试源码；**全部待统一执行**。GTK计划截图尚未生成。静态跨层检查修正了设置页init阶段通知祖先、旧表单覆盖、失败读取保护、动态字体失败重试与退出等待；这不是运行验证结论。
- 实际仅执行`cargo fmt --all`、13份Dart源码格式化（解析成功）与`git diff --check`。清理后的Dart依赖解析缓存缺失，格式化提示flutter_lints include无法解析，未伪称Analyze通过；未编译、运行测试、生成FRB或重建缓存。新增字体API尚未出现在旧生成Dart/Native中，统一收尾必须先正规生成，再编译，不能混用旧SO。
- 详TERMINAL_TYPOGRAPHY.md。字体条目仍为部分：Nerd glyph专用内置候选、完整光标/颜色/主题持久配置、主机覆盖/允许偏好同步与Windows实测仍待补。下一批继续Windows设置/配置备份同步和剩余业务源码；Android不推进，不重复之前已验证模块。此批只可作明确“未统一验证”的源码检查点。

## 同批继续：Windows原生窗口与构建脚本

- runner接原有窗口通道，原生最小化/最大化还原/移动循环/Logo系统菜单/WM_CLOSE；工作台明确initialize后DWM整合标题栏、去重复系统标题区、DPI边缘及四角命中/最大化工作区。最小720×540保持现有UI边界；小Snap区域容量不是已验证支持。
- 最大化按钮用真实Flutter渲染位置×DPR更新客户端物理矩形，原生HTMAXBUTTON接系统Snap入口；Linux不调用该几何方法，Phase2无initialize保留系统标题栏。窗口关闭仍先交Flutter engine的可取消生命周期和既有退出确认/持久化；没有DestroyWindow/exit捷径、托盘或多窗口。
- 本机Flutter engine源码已核对WindowsLifecycleManager确实处理WM_CLOSE并等待框架响应，保留HandleTopLevelWindowProc最先处理的顺序，没有重写退出协议。新增2项坐标/平台隔离测试源码，尚未执行；DWM/Snap/跨屏/真实关闭行为仅静态编写，目标平台待验。
- 新增tools/build_windows.ps1：Windows x64环境检测、固定FRB2.13、正规生成→Rust MSVC release→正式Flutter工作台→匹配DLL散列核对→可选整个bundle ZIP（不覆盖已有ZIP），恢复调用前环境变量。脚本未执行，未产出Windows包；WINDOWS_WINDOW.md列构建与真实平台验收步骤。
- 本批不运行构建/测试，仅源码格式化、跨层控制流/版本/坐标/退出审查和diff检查；仍有大量Windows正式功能未完成，不计全功能交付，也不开展Android。下一入口：剩余正式设置、配置备份/同步及需求覆盖表中的Windows业务；最终统一生成字体新API/构建/修复快捷键未结束测试及全部回归。

## 在途：Windows完整加密备份与恢复（未统一验证）

本批起点为986f8d6，源码检查点989fa05（未统一验证）。用户最新要求先完成全部Windows编码/全量静态审核；Android继续暂缓，编译运行留统一收尾。不覆盖/重做上一节点字体和窗口。

- Rust新增backup::{crypto,restore}：允许配置投影、独立凭据、主机分组/排序/设置/信任/书签/历史/本机字体；固定Argon2id/AES-GCM流式1MiB段、认证终止、256MiB/80000条有界解包，密文同目录临时文件no-clobber发布。未知config-*拒绝静默漏备份，原草稿/任务/正文/布局/writer排除。
- 恢复按项目预览和本机/备份单项及批量选择，合并默认本机、替换默认备份；候选先内存Vault验证引用/格式，源scope+全允许配置修订，最终SQLite IMMEDIATE比较原行/缺失键/data_version，拒绝跨连接幻行。草稿及必要分组保留，历史合并清除epoch，凭据新ID。提交旋转运行scope使所有旧提案失效，不改数据密钥或强断SSH/SFTP。
- Bridge单操作/单预览/5分钟退役，原库/原票据/密码验证；Agent写门控、提交前撤销授权、原Root显示策略先编译后发布，传输注册表→Vault顺序下ACK后更新共享并发/带宽，活任务保留。失败可保守撤销授权但不记恢复成功。
- 正式设置/全局菜单已接文件选择、密码与恢复确认、差异虚拟列表、选择/筛选、ACK与刷新失败分离；页面离开清理迟到预览，Model退出等待操作。控件仅Mock测试的文件选择依赖可注入，默认真实系统选择器；密码不入控制器长寿命字段。
- 新增Rust仓库7+加密流1+data_version1、Flutter控制器/组件5、真实OpenSSH Native1、GTK1测试源码，全部未运行；新增6个API尚未生成FRB，旧绑定不能调用。GTK计划截图未生成。只有格式化/解析与diff检查实际执行，依赖缓存仍缺失flutter_lints提示，不称Analyze通过。
- 已做跨层静态审核并修正：源修订/作用域、幻行、长度加法溢出、字段版本、草稿保留、历史删除epoch、独立凭据、Agent与传输锁序、存储ACK/界面刷新分离、对话框与迟到预览所有权。完整Windows静态审核尚未完成；详BACKUP_RESTORE.md。
- 后续仍需Windows DPAPI、完整云同步、普通Shell安全输入证明/历史联想和路径发送、可靠OSC133范围/导航、其余设置/文件传输/原生拖放等。先完成本批进一步静态核对和源码检查点，再连续推进独立剩余模块；不进入逐模块验收暂停。

## 在途：Windows DPAPI便捷解锁与精确开库（未统一验证）

- 起点989fa05；新增secure_unlock元数据只读身份、原Vault scope/稳定token/主密码再验证；正式入口区分create-only与open-existing并在安装全局库前核对token，防止检查后替换/删除时意外创建或打开别库。兼容旧验收API保留，新增5个接口尚未FRB生成。
- Windows原生MethodChannel默认当前账户DPAPI+UI_FORBIDDEN，固定KnownFolder本机目录与64位十六进制token派生文件名；有界密文格式、随机CREATE_NEW临时文件/Flush/发布、拒绝目录/重解析点。默认关闭，明确验证才启用；清理仅已选token缓存，手动主密码始终保留。不把密码或缓存加入SQLite配置/备份/云同步。
- 设置接真实Windows通道，非Windows不调用；读取未知状态禁启用覆盖，可明确清理。ACK与界面刷新失败分离；作用域变化重新载入。可控UTF8/原生密码缓冲擦除，Dart不可变字符串/平台编码内部副本无法保证全擦除，不宣称无内存副本。
- 根解锁页增加明确Windows账户入口，无启动自动解锁或连接；锁库首页退出等待在途开库及Model清理，原生写缓存纳入Model退出等待，防止销毁平台通道后遗留操作。
- 新增Rust2项、Flutter6项、Native桥接2项（含模拟Windows通道，仅验证核心）、Windows真实DPAPI集成1项测试源码，全部留统一执行；Windows-only测试不能计Ubuntu DPAPI实测。尚无Windows构建产物。
- 静态复核修正临时文件先关句柄再删除、KnownFolder内存RAII、缺失/损坏缓存状态、读库不创建、Vault替换竞态、退出窗口交接；Runner单独启用标准库异常，不改Flutter/plugin默认。详WINDOWS_UNLOCK.md。仅格式化/解析和diff检查，未编译/Analyze/测试。
- Windows全功能编码及全量审核仍未完成；继续主机管理高级批量/排序、云同步、可靠Shell输入与联想/路径、OSC133范围、完整终端设置、跨服务器传输/原生拖放等剩余项。Android暂缓。

## 当前静态批次：Windows主机高级批量编辑（未统一验证）

起点e78fd6e（DPAPI源码检查点）；此前989fa05备份和986f8d6字体/窗口均仍待统一验证，不以提交代替测试。

- 已编写storage-sync::host_bulk选择与非敏感字段投影/8MiB前后镜像限额、原scope及所选记录+分组目录修订、SQLite事务CAS；分组/收藏/打开SFTP/OSC7跟随/网络继承或覆盖。凭据/端点/代理/跳板/转发/Agent授权不在patch类型中，不读凭据正文。
- 正式主机管理多选入口已改用真实预览表单，默认无勾选，逐台差异/参数校验/确认/取消；Mock入口保留旧内存动作。原会话与传输不重启，网络下次明确连接生效，跟随偏好遵循原行为；退出等待在途保存，SQL ACK与列表刷新失败分开。
- 新增2个FRB接口尚未生成；Rust3项、Flutter4项、真实OpenSSH Native1项测试源码全部未执行。仅cargo fmt、Dart格式化解析和diff检查，不称静态Analyze/编译测试通过。
- 静态跨层检查已修正事务ACK后重读误报失败、无选择默认覆盖、继承破坏原覆盖值、IME未提交参数、group/host快照校验及原会话语义。详HOST_BULK_EDIT.md。
- 下一入口仍是Windows其余正式编码：主机主列表直接排序、终端输入/光标/主题完整设置、云同步、可靠Shell输入与联想/路径、OSC133历史范围、跨服务器/目录内部并发与原生Explorer拖放等；Android暂缓。当前Windows编码和全量静态审核尚未完成，不能开始宣称交付；所有编译测试依用户指令留最后统一阶段。

## 同批继续：主机主列表直接拖放（未统一验证）

- fa9461f已保存非敏感批量编辑源码。当前继续补主列表行间排序/多选稳定顺序、分组与收藏明确落点、组顺序拖动；保留旧排序预览窗口及Mock入口，复用原加密排序CAS，不增加SSH或FRB接口。
- 每次真实手势开始才读原Vault/目录版本，构建/悬停不读库；取消后新手势重新捕获，按原Model隔离。落点遵守未保存提示，过期不静默重定基；保存后只刷新，不重连原会话。若提示中保存主机使原提案过期，明确重拖，不覆盖刚保存配置。
- 新增Dart/Widget4项、真实GTK加密仓库1项测试源码，均未执行；计划截图未生成。只格式化解析/diff检查，依赖缓存缺失提示仍在，不声称Analyze/编译通过。详HOST_CATALOG_DRAG.md。
- 静态核对本机Flutter Draggable的data捕获/onDragStarted顺序及pointer anchor；修正取消后复用旧快照、接收异Model、重复落点和ACK/刷新错误分离。全量Windows静态审核仍未完成；下一入口为完整终端设置、同步与其余未完成需求，最终统一生成绑定/编译/调试/测试。Android继续暂缓。

## 在途：终端持久默认设置与粘贴生命周期（未统一验证）

起点9e43ead（主列表拖放源码检查点）。当前新增term-core::preferences、storage-sync::terminal_preferences及正式设置页源码：新终端历史上限、光标形状/闪烁、OSC52总开关、右键粘贴/Shift本地菜单、深浅预设与RGB/ANSI16色。原始终端单元及TrueColor不改，远端OSC/DECSCUSR优先；协议颜色查询同一默认值；原会话历史不因设置修改而裁剪，上限下次新建终端生效。

新增创建/读取/保存3个API及两个可选渲染元数据尚未FRB生成；原显式history构造API保留。运行偏好按原Vault作用域更新，设置事务ACK后仅用预验证类型无失败发布；备份允许清单/恢复候选校验/原作用域切换同步接入，字体设备限制不变。

静态审查顺带修正终端粘贴：异步读剪贴板前捕获原Controller/id/代次，重连后拒绝迟到内容；预览控件自己拥有文字控制器直到路由卸载，确认IME候选后才发送确认版本，取消不发送。远端鼠标捕获优先于自定义右键粘贴。

当前仅Rust/Dart格式化解析和diff检查，未编译/Analyze/运行；Rust核心3项与仓库1项测试源码已编写，UI/Native/交互测试及进一步跨层审核继续补，不能计模块完成。整个Windows编码与全量审核仍未结束，Android暂缓；集中构建测试继续留最后执行。

终端偏好本批源码继续完成：Rust核心3/仓库2、Flutter设置4/粘贴鼠标3、真实OpenSSH Native1及GTK1测试源码已补，全部未运行，计划PNG未生成。已跨层核对原网格/ANSI/TrueColor不变、远端OSC/DECSCUSR覆盖、协议颜色查询、隐藏更新合并、原Vault范围、无失败运行发布、备份清单与恢复、退出等待；改为一次读取记录决定平台缺省历史，避免先读值再检查存在的竞态。仅格式化解析/diff检查，不计Analyze/运行通过。详TERMINAL_PREFERENCES.md。Nerd内置候选仍未引入，授权混合集合需完整核对；字体主机覆盖/界面主题等子项保持待做。后续继续其余Windows完整业务，Android暂停。

## 当前静态批次：运行期有界诊断（2026-10-29，未统一验证）

- 以16ea2ea干净工作区恢复；先核对AGENTS/V1.4/进度/覆盖及近期源码，不重复前序终端偏好。新增frb-bridge::diagnostics全进程1000条内存环形队列：固定枚举、数字ID/代次/单调时间，类型不含任意文本/路径/错误/凭据；绝不入SQLite、文件、备份、同步或遥测。
- 已接连接请求含取消Future、主机密钥ACK、终端/状态、开库/恢复/偏好保存与传输入队边界。正确区分请求、观察状态和真正成功；未接所有业务细分结束事件，不当逐包完整日志。
- 正式设置运行诊断分类、读取/刷新、本地编号及失败筛选、虚拟列表、明确清空及清空ACK/刷新分离已编写；Mock不读Native。无后台查询/空闲timer，退出沿Model等待。
- 新增2个API/DTO未生成；Rust3/Flutter4/真实OpenSSH Native1测试源码待统一执行。仅cargo fmt、Dart格式化解析和git diff --check，flutter_lints缓存仍缺失，不称Analyze/编译通过。
- 跨层静态核对锁序、生命周期、常量代码/字段隐私和成功语义；修正前一批api.rs漏导入ensure宏，格式化不能替代语义检查。全应用错误详情脱敏及全量Windows静态审核仍未完成。详RUNTIME_DIAGNOSTICS.md。
- 接着推进实际RTT/状态栏及其余Windows功能；云同步、可靠Shell输入/历史联想和路径、OSC133历史命令范围、跨服务器完整策略、原生Explorer拖放等继续保留。Android暂缓，所有编译测试仍最后统一执行。

## 在途：真实SSH RTT与底部状态栏（未统一验证）

- 起点100981a诊断源码检查点；当前复用原目标Heartbeat的send_ping_checked ACK耗时（含本机全局请求队列及SSH路线），不加探测/ICMP/exec。禁用或旧兼容心跳/无成功样本为未知；超时、监视器退出与断线清空，原Root receiver不跨代次复用。
- 心跳watch→ManagedSession独立状态→Bridge latency事件→Controller独立transportInfo→真实底栏已接源码；RTT变化不发终端帧、不checkpoint历史、不notify终端绘制/全工作台，不把RTT更新重复写成诊断“已连接”。PTY列行/尺寸锁只消费已接受真实渲染元数据，任务数明确是已载入实际任务记录；原Mock状态栏不冒充实测。
- 修改SessionStatus/BridgeEvent可选rtt_micros，未新增API，新增绑定字段尚未正规生成。Rust时钟2+状态1、Dart/组件3、真实OpenSSH Native1、GTK1测试源码已补但未运行；PNG计划路径尚未生成。只有格式化/解析及diff检查，未编译/Analyze。
- 静态检查保持read取消安全（vendor wait取得消息后同步消费credit，不在其中await）、原Root弱Handle、状态/帧与诊断锁序、旧样本失效和receiver关闭不忙循环。可选CPU/内存/进程等远端按需采集仍待做，不能将§5.5整体标完成。详RTT_STATUS.md。

## 同批继续：SFTP相对路径复制与菜单所有权（未统一验证）

- 起点3afba8a（RTT源码检查点）；新增term-core字面子树相对路径、原Root/实际地址/代次/OSC7修订桥接、本机元数据预览及点击再核对、正式SFTP菜单入口。自身`.`、子项`./`，不猜符号链接相关`..`，不可靠时明确禁用且保留绝对路径操作。
- 不触发SFTP/exec/PTY/传输，不把OSC7当安全Shell证明；保留Unicode/引号/百分号/字面文件名换行，双方1024项/1MiB限额，Dart提前阻止大载荷进FRB。
- 菜单固定原会话/代次/目录/选择与文件元数据，旧菜单请求、选择改变、应用退出不迟到弹出/复制。可用性失败在禁用tooltip解释，runLocalSettings保留退出等待并可显式关闭重复全局报错，其他调用默认错误处理不变。
- 新增1个API/DTO未生成；核心2/Flutter菜单3/真实双SSH Native1测试源全部未运行。格式化解析和diff检查已执行；未编译/Analyze/测试，未生成新截图。静态复核修正默认目录夹具假设、记录数硬编码和关闭期间异步结果。
- 详TERMINAL_PATHS.md末节。全功能Windows编码/全量静态审核仍未完成；下一入口是配置同步、可靠Shell输入/历史联想与路径注入、OSC133命令历史范围、完整跨服务器传输与Explorer拖放等其余需求，Android暂缓，不进入逐模块验收等待。

## 当前静态批次：配置同步领域协议与WebDAV（未统一验证）

- 从干净9fb85ec恢复；storage-sync::cloud_sync新增正式配置允许投影、主机及独立秘密原子单位/规范化凭据ID、分组与排序/LWW时钟及永久墓碑、历史CRDT清除epoch、独立HSPSYN01 Argon2id/AES-GCM信封。云捕获不读取字体/设备正文/TOFU/草稿，不把完整备份发云端。
- 新增原Vault/本机源修订/本机基线固定提案、三轮GET/条件PUT交换、强ETag/首次If-None-Match *、相同文档不上传；412重读与未确认写入区别。配置和新基线同一SQL事务发布，复用原候选校验/data_version/独立秘密/草稿保留及scope退役，网络期间新修改拒绝覆盖。仅领域契约，正式Agent门控/运行发布仍须Bridge接入。
- WebDAV实际HTTP请求源码、HTTPS精确对象、有界流式读/取消、独立HTTP CONNECT/SOCKS5h认证及代理侧DNS、不自动重试/重定向/环境代理已编制；不含任何周期或启动网络动作，未实际访问服务。
- 新增领域/信封/交换10项、本机HTTP/SOCKS6项测试源码，共16项未运行；本机HTTP-only字节夹具不冒充E2E或真实云账号测试。仅cargo fmt解析、需求表生成和git diff --check实际执行；未编译/Clippy/Analyze/运行。新增reqwest0.13.5+Rustls ring清单按官方API编写，遵用户最后统一解析指令**尚未更新Cargo.lock**，必须在最终构建前统一解析/审核依赖与许可，不能先--locked声称成功。
- 静态跨层审查修正：网络期间编辑/外部SQLite竞争窗口、相同时间不同内容、云端凭据重映射引发回环更新、排序补齐误判新编辑、重复JSON单位/记录键、公开明文Serialize、缺失ACK误当成功与SOCKS认证长度。限额明确失败不丢墓碑；详CLOUD_SYNC.md。
- 同步仍未完整：正式加密目标/凭据及独立代理设置、目标切换与旧集合基线、同事务真实修改时间记录/离线变更和历史去抖触发、FRB及UI/退出等待/Agent撤销和运行偏好发布、Google Drive、引用冲突人工入口、真实HTTPS/云服务验证待做。继续此入口，不把库源码当成已经可用的同步按钮；其他Windows剩余项及Android暂缓保持不变。

## 同批继续：同事务同步修改记录与正式设置（未统一验证）

- 起点8f5bd1e；新增cloud_sync::journal，正式配置/秘密/关联规则/分组顺序/全局允许配置的实际修改时间与原Vault普通写/CAS/删除同事务保存。只含单位ID/时钟，初次明确设置才启用，草稿/设备正文/相同字节/失败CAS不记变动；提交后有界64项scope通知，无后台网络消费者。云提案用实际提交时间，缺失记录拒绝，不在以后同步按钮点击时重新盖时间；网络期间改后还原也因记录修订使旧提案失效。
- 云ACK同时观察远端时钟、退休已确认待同步标记且不触发回环；原配置/基线/修改记录及同步目标/秘密两行同时CAS，禁用或认证改变也拒绝旧云结果。原恢复事务保持本机目标行，不能把只作前置比较的行误删。原SSH/终端/SFTP/任务业务不重写，普通任务路径前缀过滤后不读修改记录。
- 新增本机加密target/独立secrets仓库与2个读取/保存API、原Vault/修订及data_version保护、Keep/Replace/Remove、元数据仅有已保存标志；真实工作台设置页接HTTPS对象/集合/超时/认证/独立代理保存，读取失败禁覆盖、IME/原owner/晚回包/退出等待。明确显示保存不上传，无假同步按钮；新API尚未生成FRB，旧绑定不可调用。
- 明确切换目标把旧集合基线归档/返回时恢复，设置/秘密/基线/时钟重建同事务；最多8份历史归档，满/未来格式保留数据报错，不自动清除。更换服务器origin或代理地址不能自动Keep旧认证；成功同步的集合不能仅改本机解密密码，需原密码或明确新集合。详CLOUD_SYNC_SETTINGS.md。
- 新增Rust16项（journal7/settings9）、Flutter7项及Native1项，共24项测试源码，**全部未运行**；前一批16项也仍待统一执行。实际仅cargo fmt、Dart4文件格式化解析、覆盖表生成及git diff --check；flutter_lints清理后依赖仍缺失有提示，不称Analyze通过。未解析依赖/更新lock、未生成绑定、未编译或截图，不把模型内存测试当真实云端/Windows结果。当前磁盘实测约5GiB可用；未重建缓存或清理用户文件。
- 静态跨层核对修正：rusqlite错误显式转换、源修改时间/改后还原、设置与秘密变更的SQL前置、候选保留本机设置而非误删、前端真实字段数及包名、同owner重建不重读、原确认/迟到写入、旧认证跨新地址保护、SOCKS认证边界、归档未知格式与无提交后重读。全量Windows审核仍未完成，格式解析不替代语义编译。
- 下一入口：真实同步运行驱动/单操作与取消/退出等待/原Agent→传输→Vault门控和无失败运行发布、手动同步与冲突风险确认、通知合并去抖/离线机会处理、Google Drive/引用冲突及归档管理。当前仍不能称完整同步或全部Windows编码完成；继续源码开发，Android暂缓，集中编译测试策略不变。

## 连续静态开发：WebDAV实际运行链路（2026-10-30，未统一验证）

- 从026b334补configuration_sync原owner/操作/候选票据、真实GET/合并/条件PUT/ACK后原子发布；8个新API及状态/配置编辑事件流尚未生成。单全局名额、blocking worker Arc租约、5分钟单次退役/取消与退出等待，旧owner不能关新owner；切库成功才撤销旧监视器。没有启动HTTP/空闲poll。
- Model独立控制器消费实际scope版本，750ms一次去抖；工作中合并变更，敏感主机单位/冲突/新删除需审阅，普通历史CRDT可自动继续，手动同步总给明确审阅。412换新票据，原确认不复用；取消PUT标记结果未知，云ACK后本机新变动仍保留。正式运行面板/全局内联提示与工作台/关闭生命周期已接，保存页提示现改为启用后配置变化可触发，纯Mock仍不联网。
- 关键静态修正：普通同步不旋转运行scope，不误撤销无关SSH确认/tmux/Agent；Core用账本/源/修改记录/目标秘密CAS使旧提案失效。独立configuration_synchronized仅发布变化的显示/输入偏好，按替换来源撤Agent；无变化ACK不取终端帧/重设限额/刷新主机列表。完整备份恢复原广泛失效及scope旋转语义保留。
- 新增Core1/Bridge3/Flutter7共11项测试源码，未运行；原Core删除测试补incoming_deletions区别，设置组件提示随真实触发语义更新。仅Rust/Dart格式化解析与diff检查，无绑定生成/依赖解析/lock更新/编译/Analyze/网络实测。全量Windows静态审核尚未结束；详CLOUD_SYNC_RUNTIME.md。Google Drive、引用冲突可操作解决、归档管理及其他Windows功能继续；不是完整功能完成声明，不等待模块验收。


## 连续静态开发：Google Drive 桌面授权（2026-10-30，未统一验证）

- 从干净de53f02恢复，保留此前源码/测试；补Desktop OAuth PKCE S256、外部系统浏览器、127.0.0.1随机端口、state/Host/路径/重复字段/容量/超时校验、有界回调连接和用户取消。只申请drive.appdata，不读取浏览器凭据/其他应用登录。按当前官方文档DPoP可选，未加入设备绑定密钥；Android禁止使用该桌面loopback路径，Android开发继续暂缓。
- 新local-google-drive-account-v1仅本机加密保存刷新令牌/可选client secret；访问令牌仅原Rust操作内存，UI只见client ID/随机本机授权ID/原库scope与修订。授权替换、仅本机移除和Google端撤销明确分开；撤销未知不删本机原凭据，成功撤销后本机变动仍不删后来账号。16项固定码内存结果保留避免退役竞态丢失撤销未知状态；不入日志/备份/同步。
- 新7个FRB API源码/应用级Controller/真实授权设置页/Model关闭与取消退出接入；先分配可取消票据再监听/浏览器，原账号及独立同步代理快照绑定最终SQL，账号+代理/秘密同事务CAS。单全局名额、5分钟单次退役、blocking实际租约等待；保存ACK不因迟到取消改成失败。WebDAV/OAuth共用禁重定向/禁环境代理/HTTPS校验/独立代理策略，SSH凭据不参与。
- 跨层审核修正完整备份恢复后的生命周期：退役同步owner保留到原worker真实结束，旧close仍可等待；完整恢复取消旧OAuth和同步，Model重建本机监视器/授权元数据，不启动HTTP。普通云合并不走广泛失效路径，不断开SSH。静态修正浏览器参数字段数和原client绑定、最终路由CAS、回调尾随body、grant读取双读竞态等。
- 新Rust OAuth5/账号3/Bridge授权2/旧同步退役1及Flutter控制器7，共18项测试源码未运行；既有备份/云白名单用例增OAuth记录排除。实际仅cargo fmt、Dart格式化解析/diff检查；flutter_lints缓存缺失提示仍在。未解析依赖/更新Cargo.lock/生成7个新增API/编译/Analyze/执行测试或真实授权；没有访问真实账号或用户凭据。磁盘实测约5GiB可用，无构建和清理。
- Google Drive仍未完整：应用数据文件发现/明确选择/首次创建与原对象条件传输尚未接入；不能把本机OAuth状态计为配置同步成功。授权真实验收需要用户自有桌面OAuth项目和明确授权账号，当前未提供，不阻塞其他独立编码。GOOGLE_DRIVE.md含安全约定/官方依据和后续入口。继续Drive传输/引用冲突/归档及其余Windows源码与全量静态审核；不在模块边界等待确认。


## 同批继续：同步基线归档管理（未统一验证）

- 新cloud_sync::archives仅加载最多八份本机旧目标基线的集合/单位数/删除标记数，不返回明文配置/ETag/凭据。逐份读取并立即释放正文；设置与归档来自同一SQLite读快照，未知/超量/损坏格式明确失败，不伪装为空或自动清除。
- 清理要求原Vault/全列表修订、原已选非当前归档及明确丢失本机基线确认；IMMEDIATE内data_version复核，与删除同事务。不能删除活动LEDGER/当前目标归档，不能删除后来替换/新增状态，不联网、不删除正式配置或云端文件，结果ACK在SQL前构造、成功后不重读/重放。
- 新2个FRB API及正式设置多选/确认/清理/读取错误状态已编写，沿Model.runLocalSettings追踪关闭；换owner/晚回包失效。新增Rust3/Flutter4共7项测试源码未执行；仅Rust/Dart格式解析/diff检查。FRB/依赖/编译/Analyze/运行统一留收尾，当前不称已验证或全部Windows完成。
- 前一源码检查点d2378e9保留；详CLOUD_SYNC_ARCHIVES.md。继续Drive对象与条件请求、引用冲突解决及其他Windows未完成项，不在本机归档节点暂停等用户验收。


## 同批继续：真实工作台深浅主题持久化（未统一验证）

- 原型中的深浅主题原为进程内模拟状态；新增storage-sync::appearance/config-appearance-v1默认深色、严格版本和原Vault/修订CAS、SQL ACK前构造结果。新增2个API源码；工作台只有收到加密保存ACK才更新主题，失败保留最后视觉/禁用旧源并提供明确重新读取。
- 原主题卡片/应用菜单统一调用chooseTheme，Mock仍只操作内存；正式UI根据加载/保存状态禁用，隐藏原仅Mock的界面密度选项，避免假业务控件。解锁后加载，普通云配置合并/完整备份恢复重新载入，关闭等待实际保存，取消退出恢复；没有新建/断开SSH/PTY或改终端配色及字符缓冲。
- 加入备份/云GLOBALS明确允许清单、严格候选验证与恢复中文范围名称；既有journal自动识别真实主题修改/同值不重复通知。未来版本拒绝导出/覆盖，不把默认主题当损坏格式的回退。
- 新Rust2/云备份投影1/Flutter4共7项测试源码未执行。仅Rust/Dart格式解析、diff及源码接口名称映射检查：当前Drive授权/归档/外观的11个Dart调用均有Rust公开函数源定义；不等于已生成、Analyze或编译通过。flutter_lints仍缺失，所有绑定生成/依赖/编译/测试统一最后执行。
- 详APPLICATION_APPEARANCE.md。Windows全部编码及全量静态审核仍未结束，Drive对象/条件传输与引用冲突、可靠Shell输入/历史联想/路径、OSC133命令范围、tmux配置恢复、传输策略/Explorer原生拖放、主机字体覆盖/Nerd候选、远端指标和通知/全应用脱敏等继续保留。Android暂缓，不因本模块源码检查点等待用户验收。


## 同批继续：Drive appDataFolder 文件层（未统一验证、未接正式目标）

- 新drive_files固定API和应用数据范围、完整有界分页/重复token与不完整搜索拒绝、同集合多ID明确保留；预生成ID能力/明确multipart加密创建，已有对象404不当空集合/不重建。只发送加密正文，不扫描账号普通文件，不做DELETE或空占位。
- 条件媒体读取/大小核对与三轮竞态上限、更新先按原ETag复核对象/集合再If-Match PATCH；创建/更新必须有强新etag+完整相同对象ID回执才ACK。取消/网络失败/缺tag/错ID均不伪造成功，不无条件覆盖。修订PendingUpload只读集合访问器/WebDAV tag校验内部复用，无原稳定核心重写。
- 新6项Rust传输/边界测试源码未运行；仅cargo fmt/diff，未访问真实Google服务或生成/编译任何绑定。Google v3媒体/元数据ETag实际语义仍待用户授权私有测试对象验证，不能凭HTTP夹具宣称支持安全CAS；缺条件能力时必须调整设计，不降级覆盖。详GOOGLE_DRIVE.md新增节。
- 同批审核修正外观/本机归档RPC回执丢失文案，不把可能已提交的SQL说成绝对没变；提示重新读取，不重放旧操作。下一入口仍为Drive正式单目标扩展/账号及轮换token原子CAS/工作流/文件选择和审阅UI，以及引用冲突和全部其余Windows项；Android暂停，继续源码编制，不做模块验收暂停。


## 同批继续：tmux既有会话附着的手动重连恢复（未统一验证）

- 从df1e180继续Core/Bridge/Flutter，既有附着弹窗可显式记住本终端后续手动重连，默认不记；只在实际连接回执后激活原选择。Scope/保存主机/已认证实际HostKey+username/tmux PID+ID+创建时间均匹配，重新发现后才回答原选择；不匹配回弹窗，不按同名新建、降级Shell或向PTY注入。控制模式未来接管效果明确随勾选确认，临时覆盖不继承/不允许记忆。
- 新内存owner/独立显示owner/代次保护、旧owner Drop/取消/晚bind隔离；切库/完整备份恢复/关闭撤销记忆，取消一次尝试保留上次成功选择。实际tmux模式与恢复授权分离，不能因撤销配置导致原SSH模式回执不显示。
- 新2个读取/关闭API及应用命令，用户可关闭后续恢复而保持当前SSH/tmux；同样清在途候选避免重启用。TmuxPrompt.restoreAvailable与TmuxSelection.restoreOnReconnect为可选字段，尚未正规生成，旧bindings不能验证。
- 新Core1/Bridge1（多来源变体）/Flutter1共3项测试源码未执行，仅格式解析/diff。仍需实现新建tmux的真实身份确认与恢复，当前不能据已有附着覆盖完整tmux需求；不按同名猜测创建归属。详TMUX.md最新节；下一步可继续新建确认/记忆，随后Drive正式目标与全部其余Windows未完成项。Android暂缓，编译测试最后统一执行。


## 同批继续：tmux新建身份确认与恢复（未统一验证）

- 原先新建身份待接现已有源码：新建可明确勾选恢复，Core先名称校验，原PTY/Agent准备后才在同一Transport专用exec以new-session -d -P -F取得状态0及严格PID/ID/创建时间，之后按原身份guarded attach，不按同名猜测或-A。原未勾选新建策略保持；新建ACK后失败/取消明确保留远端会话，不删除/重建。
- 新Core Identity和ConnectionReceipt携带实际tmux身份，Bridge仅在原选择/回执/模式/尺寸锁一致后激活。新建控制端勾选文案包含未来重连分离其他客户端风险同意；首次附着不分离创建后竞态加入者。源Vault/主机/实际SSH/owner/代次校验保持，临时覆盖不继承；具体TMUX.md最新节覆盖先前“新建待接”。
- 静态审核发现若先创建pane再设置Agent，会丢SSH_AUTH_SOCK。已延后创建、在专用通道按原协商请求端点并在创建前检查实际Socket环境，兼容OpenSSH重复请求拒绝/其他逐通道服务器；环境不可用明确失败，不静默损失Agent或输出路径/秘密。原Root仍须显式限时授权，无真实账号访问。远端旧tmux pane的旧Agent环境仍由远端维护，不注入Shell修正。
- 新增Core1/Bridge1/真实私有OpenSSH1/Flutter1共4项测试源码，未执行，前节点3项亦待统一阶段；真实夹具已编写先私有-S/-f /dev/null，验证新建、Agent环境、身份重附着、同名失败与保留原会话。实际仅Rust/Dart格式解析/diff，未编译/生成/运行任何测试，不把官方手册或静态核对当通过。
- 继续Drive正式目标/运行驱动、引用冲突以及其余Windows功能/全量静态审核。完整Windows编码仍未结束；Android暂缓，统一生成与编译测试顺序不变，不在此模块等验收。


## 同批静态安全修复：同步HTTP能力与提案检查点同源（未统一验证）

- 复核Drive接线发现旧WebDAV运行层也有外部写者竞态：ActiveTarget捕获与Baseline.capture_local之间若设置发生变化，可能把旧HTTP认证/地址与新提案的目标检查点配对。ActiveTarget现持原scope/配置及秘密快照，准备后ensure_proposal比较整个原提案检查点；网络前同时ensure_current和原提案校验，不一致报Changed而不发送。
- 最终SQL原配置/目标秘密CAS保留，不缩小安全门控。新增1项领域测试源码，覆盖同对象/同集合的目标参数改变、旧能力/新提案错配拒绝及新能力成功配对。仅格式解析/diff，未编译/执行。后续Drive账户及刷新轮换也必须纳入同源边界，详CLOUD_SYNC_RUNTIME.md。
- 从7a1bee5继续全部Windows编码；Drive正式目标与运行、引用冲突、输入证明/历史联想及路径、OSC133历史范围、传输策略与Explorer、字体覆盖/Nerd候选、指标/通知/全应用脱敏等仍未全部完成，不能结束为全功能完成。Android继续暂缓，生成与编译测试最后统一。


## 同批继续：原账号OAuth轮换提交（未统一验证）

- Refreshed能力绑定原客户端/secret/refresh请求，不公开访问令牌给Bridge提前使用；Account.accept_refresh先核对原账号/Scope及目标代理前置，SQL事务确认后才返回AccessToken和最新账号能力。新刷新令牌严格校验/本机加密原子写入，authorization ID保持，未轮换不重写；不进配置修改记录/通知，不制造同步回环。
- 不覆盖后来浏览器授权/其他客户端/新路由，SQL失败不发本机ACK；远端已轮换而本机提交失败不能回滚Google，明确需要重新读取/授权，不谎称旧token可用。未来DriveDriver需在此ACK后捕获最新账号检查点的本机提案。
- 新增3项Rust测试源码未运行，实际仅cargo fmt/diff；无账号请求/依赖/生成/编译。详GOOGLE_DRIVE.md末节，正式Drive单目标与运行仍待接；其他Windows剩余功能继续，Android暂停。


## 同批继续：Drive既有对象运行与秘密修订保护（未统一验证）

- Target增加可选Drive对象/client/本机authorization绑定，旧WebDAV六字段不变；Drive账号真实原记录加入提案/网络前/最终SQL检查点并在配置合并中保留，不用只比较显示clientID。WebDAV不读取不相关Google记录。旧目标归档ID保持，Drive额外隔离客户端。
- 正式Workflow支持Drive既有对象GET/条件PATCH，先在共享OAuth名额内刷新，再原账号+路由CAS确认轮换，之后捕获新账号的本机提案；不混用前后凭据。授权变更只撤销当前Drive提案，不取消WebDAV；刷新结果未知与配置写入未知单独显示，取消/退出等待真实worker。已存404拒绝、不重建；无启动HTTP。
- Flutter保护Drive目标不被WebDAV表单意外覆盖，显式确认才能改提供方。同步监视器初始化失败允许明确重读（无网络）、关闭失败不假成功。Drive发现/选择及首次创建UI尚未接；下一入口继续此模块，不称Drive已完整。
- 静态安全审核发现对含密码/命令/凭据的原文直接SHA256作为UI修订可能给离线猜测提供校验值。新增Vault内部域分离HMAC-SHA256修订，覆盖同步设置/本机OAuth/备份与云提案/历史管理/基线归档正文。原事务逐行CAS不变；派生MAC密钥不出Rust、不入存储或FRB；不改变加密格式。纯字体校验/非秘密元数据摘要保持。直接hmac0.13清单按官方API编制，lock仍留统一解析，未假称可--locked。
- 本批新增Core3/Native2/Flutter4及修订边界1共10项测试源码未运行；现有备份往返测试随keyed接口更新。实际仅cargo fmt、Dart format解析、需求表生成及git diff检查；未解析依赖/生成FRB/编译/Analyze/Clippy/运行，Windows实机与真实Google条件语义均未验。
- 未完成Windows输入证明/历史联想与路径、OSC133历史范围、引用冲突操作、Drive新集合、目录并发和安全直传、Explorer拖放、字体覆盖/候选、指标/通知/全应用脱敏及统一静态收尾仍保留。Android暂停，最后完整已验证节点0e96be4不变。


## 同批继续：Drive正式发现与既有对象选择（未统一验证）

- 新增3个Native API源码：先预留原账号/目标路由票据，再实际刷新/确认轮换并完整发现，最后明确选择原结果中的ID。只读本应用appDataFolder，保留同集合多个不同ID，不猜默认对象；新对象选择必须明确填写集合E2E密码，更换目标经确认/原归档规则，不上传配置。
- 发现与账号授权/删除/同步刷新共享同一实际租约；最长五分钟选择能力，取消/切库/退出等待worker，旧账号或目标/代理改变拒绝保存。访问令牌发现后释放，不进入返回元数据；未知刷新单独返回，不称配置成功。
- 新应用级GoogleDriveObjectsController及正式紧凑对象列表/手动发现/明确选择/取消/密码/确认接入设置，Model管理完整恢复/取消退出/最终释放。页面打开不请求HTTP；不同对象不沿用上个密码，IME composing不提交，SQL回执与退出分别处理。已有Drive目标可直接编辑启用、超时和独立代理，地址/集合只读，切WebDAV仍显式确认；保存回执不明必须重读，不重复旧提案。
- 新Native2/Flutter模型4与Widget1共7项测试源码，已有Drive设置组件随正式编辑语义调整。仅cargo fmt/Dart格式解析/git diff，未生成绑定、Analyze、编译或运行。Google真实条件请求仍待授权对象验收；首次创建/创建未知结果恢复仍未实现，不能把发现页称完整Drive功能。
- 下一入口继续Drive明确首次创建与持久未知结果保护、引用冲突解决，以及其余Windows编码/静态全审；Android暂停。当前不停止在模块边界，统一编译测试策略保持。


## 同批继续：Drive首次创建、持久恢复与同ID核对（未统一验证）

- 新drive_setup元数据/密文两个设备本机排除记录，实际预生成ID能力、白名单完整初始快照、明确敏感范围及同步密码、原子保存后才允许远端创建；界面仅显示单位数/加密字节/ID/状态，不返回正文或秘密。中断/重启保留确切密文和ID，已有记录拒绝再准备第二个。
- 每次明确继续先同ID GET/集合/强etag/整个密文核对；只有生成能力404才创建，普通saved404仍失败。开始POST前保存attempted，未知结果/409不重建、不换ID；源配置/账号/目标路由改变拒绝旧上传并保留恢复记录。已创建但本机未ACK与创建未知明确区分，取消不删除云端。
- 远端确认后设置/秘密/归档/初始变更与意图退休同SQL事务，源检查前data_version延续到最终事务；不让外部修改落入检查与新版本采样之间。SQL回滚保留恢复，只有实际ACK更新UI；首次创建不伪造普通双向同步成功。明确仅清理本机需风险确认，远端可能仍存在，后续发现选择原ID。
- 新5个FRB API与正式准备/核对/开始或继续/本机读取及清理UI源码，应用级原操作/共享OAuth租约/取消退出/恢复重读已接。仅本机读取无HTTP，跨重启不自动重试。新增Core5/HTTP1/Native1/Flutter4共11项测试源码，全部待统一执行。
- 实际仅Rust/Dart格式解析、需求表生成和diff检查，无依赖解析/FRB生成/编译/Analyze/运行/云账号请求。Google真实媒体强ETag/CAS语义仍待授权私有对象验证，不能据源码与HTTP夹具宣称Drive真实验收。该项若服务不支持安全条件发布，须继续修正，不能无条件覆盖。
- 下一入口为引用冲突可操作审阅，以及输入证明/命令联想/路径、OSC133历史范围、传输策略/Explorer、字体覆盖候选、远端指标/通知/脱敏和全Windows静态收尾。Android仍暂停；继续开发不在源码检查点等验收。


## 同批继续：云同步引用冲突可操作解决（未统一验证）

- 原本References错误只保留两端但无解决入口；新增Exchange不可发布引用步骤，独立元数据RPC只返回名称/来源可用性/删除状态和分组跳板ID，不返回秘密/命令正文。UI逐项及批量选择完整单位，主机凭据成组，缺失不当删除，历史保持CRDT。
- 原票据/冻结源/目标账号检查点下校验，错误选择保留原候选继续修正，未知重复/不可用侧/历史整体覆盖拒绝。改变LWW结果的显式选择取当下新逻辑时钟；引用/完整配置全部有效后才有可发布正文，并换新普通审阅票据，再次明确确认后才条件写入。直接确认引用阶段拒绝，无假上传/落库。
- 412保留接受的本次提案但不复用确认，累计安全摘要始终与最初Vault投影比较，修正重试期间可能低报已选凭据变化的问题。选择二分查找，列表虚拟化/大JSON工作隔离解码，不把成千上万选项复制到普通状态流。
- 新2个API未生成；新增Core3/Native1/Flutter模型1/控制器1/Widget1共7项测试源码，未运行。实际仅Rust/Dart格式解析及diff检查，未编译/Analyze/Clippy/真实网络。完整Windows仍有其他功能及统一静态收尾未完成，Android暂停。
- 下一入口继续可靠单行输入证明/采集与实时历史候选、安全路径插入/cd、OSC133历史命令范围、传输策略/Explorer、字体覆盖候选、指标/通知/脱敏等；不在引用模块等用户验收。


## 同批继续：OSC133保留范围、复制导航与真实历史worker等待（未统一验证）

- 新Commands通过原解析器精确C/D网格位置/滚动计数及Row数值身份、可变访问修订证明保留半开输出范围。标记不复制命令/正文、不猜回显、不作为安全Shell输入证明；分页不改变Row身份，已结束范围跨RAM/冷历史只在实际读取时解密，断线完整范围保留，新PTY旧标记失效且ID不复用。
- 后续覆盖（含改后还原）、裁剪、字符插删/局部滚动、向输出起点之前写入、不完整/畸形标记保守降级。全终端8192个范围和32768行证明预算，不持有每命令Grid/冷段副本。当前真实resize/Reflow/备用屏幕/RIS撤销旧锚点，**旧范围跨Reflow精确映射仍未做**；原终端重排/搜索/全文导出不删改，新尺寸完整标记可重新记录，tmux尺寸锁保持原规则。
- 新3API源码/真实Native可选Backend能力/终端本地菜单复制所在命令输出与上/下命令导航。原NativeID/代次/帧修订校验、冻结文档流式UTF-8/10MiB剪贴板预算，无部分结果、无PTY输入或SSH请求，Shift本地菜单与既有鼠标捕获不变。缺/失效范围明确手动选取，不假称识别所有Shell。
- 静态审核修正原搜索/历史导出租约只随RPC Future而非真实worker的问题：拥有的search_gate跟随blocking线程，退出等待实际任务，不提前释放冻结Grid及临时历史段。新增真实Entry关闭等待丢弃RPC句柄的测试源码。
- 新Core10/Native1/Flutter3+Widget1/真实私有OpenSSH1/GTK1共17项测试源码，均待统一阶段。实际仅cargo fmt、vendor三文件rustfmt仅输出解析、Dart格式化、覆盖表及git diff；未生成绑定、编译/Analyze/Clippy/运行/截图。最后完整已验证0e96be4不变。
- 后续仍需旧锚点Reflow映射、可靠单行输入与实时候选/安全路径、传输策略及Explorer、主机字体覆盖/Nerd候选、指标/通知/全应用脱敏与全Windows静态收尾；Android暂停。继续开发，不在本模块等验收。


## 同批继续：内置Nerd符号候选与许可资产（静态源码，未统一验证）

- 从89a2f39继续字体。新增显式JetBrainsMonoNerd选项，主字体/测量仍是原JetBrainsMono，Nerd子集字形优先回退后再中文/系统；不改默认、字符或网格，不改变SSH。Rust/Dart验证及正式下拉框已接原持久设置。
- 官方Nerd Fonts v3.5.1许可审阅后，使用已安装HarfBuzz8.3.0 C子集接口生成1111码点/455944字节TTF；仅Devicon/Octicons/Seti-original/Powerline/Powerline Extra的MIT组件，明确不是全量Nerd。源码工具固定下载SHA/码点及别名边界，结果manifest/父及五组件完整许可均入Flutter资产；应用不下载字体或依赖生成工具。原整包含不同许可组件，未把父MIT当成全部组件的许可。
- 已实际执行`python3 tools/prepare_nerd_symbols.py --write`并核对下载散列/实际cmap；这是资源源文件准备，不是应用构建/测试。新增延迟许可注册和查看入口，保留原两字体许可。新增Rust1/Dart1测试源未运行，仅Rust/Dart格式解析和diff；没有FRB生成/依赖解析/编译/Analyze/运行或截图。
- 主机级字体覆盖、通用可同步排版偏好及全Windows静态收尾继续；当前仍有其他Windows编码待完成，Android暂停，不在此节点停下等验收。

- Nerd许可资产补充：首次暂存检查发现Seti原文带尾随空格，已在生成器仅规范化尾随空白，完整措辞/换行保留，并加入合并许可资产SHA。重新执行资源生成，TTF散列未变；重新检查diff通过。后续提交命令在检查失败时停止，不能把原尾空格告警当通过。


## 同批继续：本机主机字体覆盖与继承（未统一验证）

- 从4f37730未完成的typography.rs改动恢复。原本机文档新增有界唯一host-ID→Settings映射，兼容原无hosts记录；10000项/2MiB元数据与原字体容量分离，未知/重复/悬空字体引用拒绝覆盖。save_host复核正式Catalog及Host并将其原行、原文档与已校验字体正文纳入同一SQLite CAS；不改认证、主机网络或SSH。全局保存也补正文最终CAS，关闭读取校验后外部改正文的窗口。
- 新第六个排版API及可选HostTypographyGateway；主机“终端”页只在原主机正式保存后打开覆盖表单，显式保存/恢复全局继承，字体库导入/删除仍在全局页。删除本机字体会在同事务恢复所有引用它的全局/主机字体为内置JBM，保留各自几何。全量字体备份沿既有明确白名单包含host映射，本机映射仍排除云端；通用排版同步尚未接。
- 工作台每个窗格用其自己的host-ID取样式，不按焦点给其他分屏误用字体；切换/移动UI不建SSH。主机覆盖独立运行期字号缩放，全局继承保持旧缩放语义；只改主机设置不重置全局缩放。导入主机字体只在打开会话/文档改变/明确重试时懒加载，build/每帧读取无IO，同源请求合并，旧修订失败不污染新库，临时回退/可重试明确显示，退出等待真实字体Future。2MiB元数据JSON在compute隔离解析。
- 新Rust3/Dart控制器3+Widget1及原真实SSH GTK场景新增host保存/恢复与原nativeID/代次保持检查源码，全部未运行，截图未生成。实际仅绝对路径cargo fmt、Dart格式解析、覆盖表生成、diff检查；首次环境PATH找不到cargo已改绝对路径，未运行构建或测试。新增API未正规生成，不用旧SO验收。
- 后续继续Windows其余源码与静态审核，最后统一依赖/FRB/构建/Analyze/Clippy/测试；0e96be4仍最后完整已验证节点，Android暂缓。


## 同批继续：终端通知、显式输出规则与静默提示（未统一验证）

- 从a816691继续Windows剩余源码。VTE被动解析OSC9文本/777 notify的严格UTF-8、有界正文/分号；OSC9数字子命令（如9;4进度）不误报，未知777不执行不打印。Core统一BEL/OSC/显式规则/静默通知，250ms单终端预算、最多16条待处理与5秒16项散列去重；默认不带任何远端正文，预览显式开关、控制/Bidi过滤。普通终端字节/历史/选择/导出不变，不注入Shell或执行通知动作。
- config-terminal-preferences-v1向后兼容新增notifications，沿原Vault/修订CAS、预编译后发布与既有备份/加密同步允许清单。规则最多16×256 UTF-8字节，Rust regex程序/DFA/嵌套预算；仅显式配置时捕获普通屏幕CR/LF完成片段，跨读取/Unicode与视觉换行不中断，超4KiB/备用屏幕拒绝匹配，不扫描历史。静默0关闭或5–86400秒，输出批次重置一个deadline、仅提示一次、断线取消；共用actor同步输出的最近deadline，没有空闲周期轮询。
- Bridge用原nativeID/代次和进程内单调策略ID撤销旧排队事件；前端独立notices通知器不拉帧、不经Model普通绘制通知。工作台App-owned Hub跟随真实会话集合，不依赖终端视图挂载，焦点/应用失焦区分，原会话关闭/策略改变/代次更新后不投递迟到内容或激活其他会话。应用内最多每250ms一条、桌面每秒一条/固定一个系统槽/最多16个短期候选；关闭等待真正in-flight，取消退出可恢复。新PTY在冲刷旧同步输出后退休旧通知，避免误绑定新代次。
- 正式终端设置页已接通知开关/前后台/BEL/OSC/Windows桌面/正文隐私/静默/每条正则与大小写；仍原页明确确认并保存，不自动保存。Windows桌面默认关，新增固定flutter_local_notifications_windows 3.1.1 BSD-3-Clause依赖，官方API和包源已只读审核；Windows才初始化本应用通知身份，Flutter生成的Windows插件registrant可能提前加载DLL但不注册本应用。Ubuntu仅应用内提示，不模拟已送达桌面；未打包Windows不能保证撤回通知，界面说明。固定AUMID/GUID，激活只含本次进程nonce+原会话数字身份，不包含远端路径/命令/账号。明确点击才定位现有标签并调用原窗口activate，尊重SetForegroundWindow拒绝，不新建窗口/连接。构建脚本检查插件DLL，需VS ATL/WinRT。未实际安装/注册或改Windows设置。
- 本批新Core引擎3/真实解析2、存储旧格式加密1、Dart模型/控制器/前后台Hub/在途退出/组件5与真实私有OpenSSH隐藏OSC/静默/SFTP隔离/关闭策略1共12项源码，均未运行；旧入口/所有原测试保留。依赖锁、FRB正规生成、Analyze/Clippy/构建/测试/Windows实际投递留统一阶段。只有格式化解析/diff和公共文档/包源阅读；不能称原生API或通知送达已验证。
- 继续Windows其余传输/Explorer、可靠单行输入与路径发送、旧命令范围Reflow、可选指标/进程和全应用静态审核；Android暂停，不在通知节点等验收。


## 同批静态点击路径审核：主机表单真实能力边界

- 核对HostManager→DemoHost快照→Native HostRecord→SSH PTY链路，发现原型遗留TERM选择、固定初始目录输入、压缩开关在正式表单中可修改并标脏，但未持久化/未影响真实连接；V1.4并未确认这些额外覆盖参数，不能假装保存。正式页改为真实值只读说明：PTY=xterm-256color、SFTP首次由远端解析“.”、当前构建压缩none。原独立Mock保留模拟控件；已确认的正式SFTP开关/OSC7偏好/tmux/字体/网络参数不删不改。
- 原“Agent转发尚未启用”文案已与真实认证选项和原会话限时授权一致。新增正式/Mock两项组件测试源码，未执行。仅Dart格式解析/本地SDK字段检查/diff；不是完整点击路径审核结束，未生成/编译/运行。


## 同批安全静态审核：FRB错误链及底层输出日志边界（未统一验证）

- 从db9bce0继续，核实当前正式生成代码的anyhow SSE codec使用Debug，会展示完整source链；原本固定SshError Display/外层中文context不能阻止内层网络/JSON/IO正文出现在返回错误中。202个公开Result函数已在业务源码统一增加新的无source错误边界；签名、成功结果、网络操作及资源owner不改，生成文件未手改。差异较大主要是函数内多一层结果作用域/缩进，不是重写协议或迁移业务模块。
- public_errors优先原生产源码中精确静态中文摘要，另允许已审计的阶段/状态数字、规则/行号及跳板递归摘要；不凭中文前缀、正则猜秘密来信任任意字符串。未知/JSON/IO/worker错误返回明确的未确认摘要，不宣称操作未发生或成功；原错误链、私有上下文不留在新返回错误。传输/远端复制/预览失败快照及大正文编辑IO桥接也改用相同摘要。
- tools/bridge_error_boundaries.py按字符串/字符/嵌套注释和顶层函数词法维护保护与精确摘要清单，排除测试模块/文件；已实际生成并静态核对202项全有边界，非编译或代码生成器验收。后续新增API必须同样包边界；工具只改业务源与自有清单，不动FRB产物。
- Event的ClipboardStore/PtyWrite/Title、Cell和Snapshot Debug不再显示正文/URI；标题trace和未知OSC/DCS/CSI日志去正文，未知DCS逐字节日志取消。终端真实网格/渲染/剪贴板数据不删改。发现russh未知扩展也会写raw log，应用私有Bridge增加log/max_level_off及编译期常量闸门，依赖日志不能绕过1000条固定元数据诊断；Core独立库不强制该全局策略。tracing/直接stderr和panic路径仍须继续审核，不能称全应用脱敏完结。
- 新Bridge4/Core Debug与Trace1/Python词法维护3共8项测试源码，全部未运行。实际仅Rust格式解析、vendor仅输出语法解析、Python AST/源码清单、diff检查；未依赖解析/锁更新/FRB/编译/Analyze/Clippy/运行。最后完整已验证仍0e96be4。下一步优先panic/异常回执与其余Windows源码，Android暂缓。


## 同批安全静态审核续：函数体panic/默认hook及实际Future资源

- 从0310314继续：202个Result入口升级为195个原Future的catch_unwind和7个原同步闭包的catch_unwind，成功/Err仍沿原无source摘要。没有用spawn把API工作脱离请求生命周期，也不把panic记成可重试/成功；只返回固定“操作结果未确认、保留状态并重启”的错误。
- 应用私有Native首次受保护调用安装一次panic hook，原诊断store先初始化；不格式化payload/代码位置、不调用默认stderr hook，仅记录固定CoreWorkerPanicked枚举。诊断锁已持有时只做try_lock，无法入队累计到原dropped计数，不等待锁/不写日志。Flutter诊断标签与失败筛选已接，新枚举待正规生成。panic=abort、栈溢出及函数体之前的FFI/平台异常不在catch的恢复保证内；不能因此称整个进程能从任意panic安全恢复。
- 自有源码维护工具词法升级旧边界，保留原函数体，支持rustfmt简化后的同步单表达式；再次静态清单202项通过，仅词法/格式验证。新增Guard Future真实Drop/同步秘密payload/诊断锁不阻塞3项Rust与迁移旧边界1项Python测试源码，未执行。新futures-util依赖声明/锁、FRB/编译/Analyze/Clippy及全部测试仍留最后统一阶段，Android暂停。


## 同批继续：通用排版加密同步与本机字体映射组合（未统一验证）

- 从316dc81和上次未提交改动继续。config-terminal-preferences-v1新增可选、严格有界的typography，包含全局字号/行高/边距/连字及三个允许内置家族预设。原共享允许清单接云同步与完整备份，本机系统/导入家族名、正文/散列及主机覆盖仍不入云。显式本机家族优先；旧无共享字段保留原本机几何，不读时迁移。
- 原排版修订改Vault私有HMAC覆盖本机与共享原行；全局保存同一SQL比较两源及字体正文，原子发布通用偏好和本机映射。其他排版操作亦检查共享源，其他终端设置保留排版；未知格式/坏数据不默认覆盖。Android无记录默认30000仅修正共享加载入口，不开展Android UI。
- 云合并/完整恢复后的排版load等待原实际写入，再读当前库，避免旧ACK迟到获胜，不重放写入。新增Core1/存储4/云投影1/Dart及组件3共9项测试源码，扩展原Native字体测试，均未执行。遗留错误边界词法工具另补同步旧边界测试分支；Python字节码忽略，非功能验收。
- 实际仅Rust/Dart格式解析、源码错误边界清单、需求表生成和diff检查；未依赖解析/锁更新/FRB生成/编译/Analyze/Clippy/测试。最后完整已验证仍0e96be4。继续其余Windows源码及全量静态审核，Android暂停；可靠单行输入与路径、传输策略/Explorer、旧命令范围Reflow及可选远端指标/进程等未完成，不在检查点等用户验收。


## 同批继续：可选远端资源/进程与原Transport独立通道（未统一验证）

- 从e30e897继续Windows剩余源码。新增原Root共享单槽Inspector、PTY actor只返能力，固定Python隔离脚本读取Linux procfs/根盘statvfs，无任意脚本/路径/信号API，不注入PTY或创建SSH。单次256KiB/固定读取限额、8秒/2秒预算，进程扫描4096/显示512；超限明确不完整，stderr不返回。资源读需Linux/Python3.7+，信号需Python3.9+/pidfd内核，不支持时拒绝，不安装远端依赖。
- 默认无请求。原NativeID/代次分开显式授权资源/进程，前台焦点工作页才每次完成后5秒采样，失焦/隐藏停表、错误停止自动请求。原授权撤销取消在途并拒绝迟到结果；断线重连清空本地启用，不沿用新Root。状态栏独立通知不取终端帧，标签组菜单/底栏进入可滚动面板，数据仅内存，不入日志/备份/同步。关闭面板不停止已明确启用的前台资源采样，有独立撤销入口。
- 进程列表按需、原30秒修订及进程行冻结，显式二次风险确认，只对PID>1有效创建身份发固定SIGTERM；消费后未知结果不重发。远端先开pidfd再复核boot/创建计数，拒绝普通kill回退。回执只称内核接受信号，不称已退出。真正服务器权限与pidfd缺失如实失败，无自动SSH重连。挂起channel-open不被本机deadline遗弃，原单槽保留至ACK/Root；关闭发送未知也保留到Root，Root close等待真实worker退休。
- 新Core3/Bridge2/私有OpenSSH1/Dart7/Native1共14项测试源码，全部未运行。真实信号测试仅针对夹具自行创建的sleep子进程，未访问账号或结束任何实际进程。四API未生成；只格式解析、Python AST、206公共边界源码清单和diff。依赖/锁/FRB/编译/Analyze/Clippy/测试仍最后统一；最后完整已验证0e96be4，Android暂停。
- 继续Windows可靠单行输入/命令联想与路径发送、传输内部并行/通道恢复/安全直传与跨服务器剪切/Explorer、旧命令范围Reflow、全应用异常和点击路径静态审查等，不在本节点等验收。详REMOTE_INSPECTION.md。


## 同批交叉审核补正：字体删除回退与共享预设回执一致（未统一验证）

- 从b05c703复查实际排版合成，发现全局导入字体删除回退JBM后，旧共享Nerd/CJK预设可能在下一次load覆盖回执。现全局实际引用时同SQL更新共享builtin_family=JBM、退休本机正文及全部引用；确认框明确通用预设会参与已有加密同步。仅主机使用此字体时保持共享预设不动，其他几何不变。
- 新增1项Rust测试源码覆盖回执=重读、触发器拒绝共享写时正文/两源全回滚、仅主机引用删除保持Nerd共享预设。未运行；仅格式解析、diff检查，最后统一验证策略不变。Windows其他剩余项继续，Android暂停。


- 资源通道静态复核续：发现close发送入队不能代表对端通道退休；现8秒工作后同一2秒清理预算发送并有限排空至原Close/通道结束，未确认保持单槽到Root取消，避免用户连续重试累积未退休通道。正常完整回复不额外等待。仅格式/diff，未执行测试；仍保留统一阶段的迟到open/close协议故障验收。


- 资源通道新增受控SSH peer源码1项：晚session-open ACK、取消后单槽不释放/不发脚本、原SSH保留及第二个无ACK开通道时Root关闭等待真实worker。明确不是OpenSSH或实际Python执行结果；此项未运行，与前14项合计15项测试源码待统一阶段。主记录首部已更新最新恢复入口，当前未启动验证管道。


## 2026-11-02：文件夹内部并行与逐文件进度（未统一验证）

- 从干净6a1cc64继续。新增TreeTransfer::run_parallel_observed，原顺序接口保留；目录先检查、内部3个文件共用原SFTP与全局Limiter，不新建SSH、不增加顶层任务名额。直接拥有全部文件Future，每文件仅一份合并ACK，无无界队列；暂停停止准入并排空结果，错误只标当前文件。主清单真实偏移/统计及dirty原节点索引持续保存，不伪造完成状态。
- 文件目标活动预留防止显式更名/Windows大小写别名并行写同一目标，前一个真正结束才继续；本地独占创建竞态AlreadyExists归冲突。队列新增可选active_files及独立字节/进度，仅显示当前有界文件，不列成功文件；结束清活动元数据，远端中转沿旧current，不假称中转并行完成。
- 新Core路径1/私有OpenSSH3/Native1/Widget1共6项测试源码未运行；正规生成新DTO、解析新增futures-util直接清单、编译/Analyze/Clippy/测试仍统一最后执行。实际仅Rust/Dart格式解析、206个公共Result源码边界清单、需求表与diff。没有启动构建、没有网络服务测试、Android暂停，最后完整已验证仍0e96be4。
- 继续有限瞬时通道重试/安全直传与跨服剪切/Explorer、可靠单行历史与路径发送、OSC133旧范围Reflow及全量静态审核，不在本检查点等待验收。SFTP session.close目前原依赖仅发送本机停止请求，不能据此当作对端通道退休ACK；后续生命周期审核须区分文件CLOSE真实ACK与通道队列停止，不能扩大成功保证。详TRANSFER_PERFORMANCE最新节。


## 2026-11-02续：原Transport SFTP资源所有权、真实本机收尾及有限恢复（未统一验证）

- 从af0bb4f继续，修复原sftp_opener在timeout/drop直接丢弃russh channel-open的所有权问题。新原Root SftpConnector统一64个未知开通/活动IO名额；晚ACK不继续请求subsystem，已知失败有界关闭，未知持名额至Root。成功名额跟随双工stream到真正读写任务；Root取消socket后等待全部实际stream/开通退休，actor仍不等待协商。
- vendor SFTPSession.close现按请求超时等待读写两个实际owner退出，不把仅排入停止请求当结束，也不冒称SSH对端CLOSE ACK。取消覆盖阻塞write/shutdown，停止后拒绝新请求。新增固定ConnectionClosed分类，畸形协议显式UnexpectedPacket及共享末端分类覆盖迟到请求，不能因请求sender消失把协议错误当瞬时网络故障；不依据字符串内容重试，不打印底层正文。
- background开通最多3次，仅原代次及typed transient/150ms、400ms间隔。文件夹内部发现通道故障停准入/撤销其他流并收尾，失败节点稳定索引与ACK保留；Bridge最多2次更换工作通道，先本机真实IO退休，再只恢复通道故障节点、完整保存检查点，才开新通道续传。成功文件/永久失败不重跑，取消/身份变化/坏检查点/预算耗尽失败，不建立新SSH。中转两端仅开通重试已接，工作中继恢复仍待补。
- 新Core分类1/协议IO4/受控SSH4共9项测试源码未执行；受控peer不是OpenSSH实测。已有所有传输/原协议测试保留，当前仅格式解析/vendor仅输出语法/206错误边界源码清单与diff。未依赖锁/FRB生成/编译/Analyze/Clippy/运行，最后完整已验证仍0e96be4；Android暂停。
- 继续其余Windows剩余编码：安全直传/跨服剪切/中转恢复/Explorer，可靠单行历史与安全路径发送、OSC133旧范围Reflow、全量点击路径/异常静态审核。详SFTP_RECOVERY.md及vendor/HSPTERM-PATCH.md，不在此模块等待验收。


## 2026-11-02续：远端中转内部并行、双端有限恢复与真实故障夹具（未统一验证）

- 从干净c82d2a3继续。RemoteTree文件状态机提取为只拥有单个节点/阶段/原序号路径的FileWork，顺序接口保留并复用相同代码；新并行入口先验证所有父目录，再内部3个文件共用原两端SFTP/全局双向限速/单FIFO名额。一个实际主清单，不复制整树，每个Future由run直接拥有；回调同步合入主清单/增量统计并持久化原Intent/Writing/Ready/Publishing/Published屏障，屏障失败撤销准入并等全部文件收尾，不detach检查点。队列复用active_files显示真实并行文件，暂停/退出清空运行元数据。
- 两端工作通道最多2次恢复，仅typed Timeout/ConnectionClosed及全部错误原因可重试时允许。文件只对Absent/Writing/Ready恢复，Intent创建未知/Publishing替换未知/Published清理未知不自动重放；协议/权限/冲突/坏偏移/普通IO超时及混合CLOSE失败保留原失败。并行故障取消兄弟后保留ACK，未知写边界单列失败；两旧本机IO均真正退休、原双端代次/实际身份复核、只reset明确故障节点且全量检查点保存成功后才开新通道，不新建SSH、不重传成功兄弟。移动rename仍禁止自动重发，未扩大恢复语义。
- 静态复核发现vendor server::run在内部detach，先前新增夹具abort外层并不能制造真实断链。新增保持旧入口行为的run_owned实际服务Future，当前SFTP生命周期/开通所有权及新发布夹具改用它，abort/await对应实际流；错误IO退出，畸形请求日志固定摘要，保留原CRLF。此前9项源码仍未运行，不能误称已经验证故障。现新增分类3/协议发布4/私有OpenSSH3/Native1共11项测试源码，涵盖真实流断链/ACK保留/未知屏障拒重放/检查点优先/同Transport三路并行/父目录失败/暂停与加密重开。全部未执行。
- 实际仅cargo fmt、vendor仅输出语法解析、Dart格式解析（缓存缺flutter_lints警告，不是Analyze）、206公共入口源码清单及diff；未依赖解析/锁更新/FRB/编译/Clippy/测试，最后完整已验证仍0e96be4，磁盘约4.2GiB未清理构建缓存。
- 继续Windows可靠单行输入/实时候选和安全路径发送、OSC133旧范围Reflow、跨服直传/剪切/未知暂存清理、Explorer系统拖放、全量异常与点击路径静态审核；不在本模块暂停等待验收，Android仍暂停。


## 2026-11-02续：OSC133旧范围的有界可验证Reflow（未统一验证）

- 从干净4eff048继续。原完整范围经行身份/可变修订确认后，在实际resize前后逐行映射逻辑UTF-8偏移并比较整段SHA-256/长度；只有逻辑内容一致且端点有确切位置才恢复原ID/退出值和新行证明。软换行不增行、宽字符占位跳过、组合字整体定位，内部signed Anchor兼容高度变更产生的负历史原点。没有通过重复输出/相似文本猜属于哪个命令，不复活已经覆写或改后还原的旧范围。
- 不克隆Grid或全文；最多16Mi单元/64MiB、每扫描250ms软期限（含组合字检查），只在合格范围存在的实际resize触发。超过预算、历史裁剪导致逻辑内容改变、尾部填充边界不明确均安全降级，不删除终端正文/搜索/滚动历史。Alt/RIS/畸形标记/新PTY保留失效，未结束标记不能被resize补完，锁尺寸不重排。冷历史故障在映射发布前后明确检查，不发布不可靠范围。新增sha2直接清单，lock仍待统一解析。
- 新Core8项源码（集成6+映射2）及原真实Native夹具扩展多次resize/原ID/Unicode输出与原SSH代次；全部未运行。实际只Rust/Dart格式解析、206公共边界源码清单和diff，未生成/编译/Analyze/Clippy/测试；没有声称250ms期限或冷历史性能已测，最后完整已验证仍0e96be4。
- Windows剩余继续：可靠普通Shell受控单行输入/历史候选/安全路径发送、直传/跨服务器剪切及未知暂存清理、Explorer、全量异常/点击路径静态审核。仅Windows优先、Android暂缓；不在本模块等待验收，最后统一验证。


## 2026-11-02续：Explorer拖入上传、真实目标路由与批次生命周期（未统一验证）

- 从干净cada108继续。Windows原生OLE IDropTarget/CF_HDROP仅文件名通道，Dart实际DPR/可见区域/目录行命中、高亮与750ms悬停进入、当前目录投放，复用原Rust任务/目录扫描/FIFO。4MiB/4096项/32767 UTF-16名字与双NUL/offset/Unicode/绝对路径容量检查，仅Copy/None，绝不请求删除Explorer本地来源、不读正文、不向终端注入。反向拖到Explorer下载仍未实现，不能把单向接线标完整拖放。
- Native首次接受时固定会话，Drop在可能重入的GetData前后核对owner/zone/drag/alive；hover只有一在途+一最新坐标、Dart拒旧也ACK，防界面阻塞时积压鼠标事件。滚动/几何/目录/代次/对话框改变撤销旧token，Mock/Linux不启用；窗口关闭先停用共享State/撤销注册/拆通道，再释放引擎。main使用正确OLE生命周期并处理GetMessage失败，普通原生窗口行为保持。
- 释放固定原会话/目录/有序名字，正式Model拥有入队批次并纳入退出pending；切换/卸载侧栏及随后浏览别的目录不改目标、不打断已接受批次。断线/关闭/重连停止余项，保留已接受队列，失败报告确认数不自动重发。enqueue_transfer新增可选expected_generation并沿原Connection门控；上传/下载选择器也捕获原代次，退出拒绝新传输。绑定未正规生成，旧API/SO不可用于验收。
- 新Dart/组件9项测试源码+既有真实Native夹具错误代次场景扩展均未运行；只是路由夹具不能当OLE或传输实测。实际仅Dart/Rust格式解析、206公共错误源码清单/diff；C++没有编译/静态语义分析或Win执行，没有FRB/Analyze/Clippy/构建/测试。Microsoft/Flutter官方接口已只读核对，Native释放/坐标/DPI/Explorer人工验收列WINDOWS_EXPLORER_DROP，最后完整已验证仍0e96be4，Android暂停。
- 下一Windows源码入口继续反向Explorer下载、安全直传/跨服剪切和未知暂存清理、可靠单行历史候选/安全路径发送、完整点击路径与异常静态审核。已有OSC133 Reflow及中转并行/恢复不要按旧记录重复实现；最终统一依赖/锁/FRB/编译/Analyze/Clippy/测试仍未开始。


## 2026-11-02续：传输工作异常后的通道持有、FIFO及最后确认屏障（未统一验证）

- 从干净1a9567c继续静态资源审核。此前spawn_blocking异常已会结束busy，但run栈销毁后没有任务级SFTP会话记录可等待；现在Job/CopyJob持有Channels，开通/替换通道均登记Arc，原工作Future捕获Rust unwind后仍明确收尾。再次运行必须先关闭上一轮本机IO；超时保留owner，不开新流覆盖旧目标。原Root/代次和有限重试预算不变，没有自动重连，也不把本机IO完成当SSH peer CLOSE或文件成功证明。
- FIFO名额移到真实blocking worker，直到工作/异常收尾/必要失败状态保存结束才释放；结束清理也不detach。vendor只新增同步local_io_closed读取真实双IO完成位，用于安全退休owner；不轮询、不新增worker。取消已失败且仍收尾的任务、清理已结束行和切换配置库都不能丢owner；普通配置合并不清任务，不额外阻塞无关云同步。已结束但busy仍真的在收尾时，stop必须等原finished屏障，后来的暂停不覆盖已明确取消。
- 本地↔远端并行任务增加最后dirty确认/节点状态持久化屏障，再释放IO/删除任务日志；修复删除最终任务记录失败后旧检查点可能把成功文件当待传的问题。异常状态按原检查点另存Failed，保存失败明确提示，不伪造新空计划。完整副本/部分写入保持，不在异常后自动重跑。
- 新3项Bridge协议/IO源码覆盖panic后实际stream/FIFO保持、收尾超时不开始下一轮、丢弃cleanup Future仍保留owner。既有真实Native并行夹具扩展SQLite DELETE故障、完成文件源被移除/目标后来改变后明确继续仍不重传。全部未运行；Tokio test-util仅新增测试特性声明，未解析lock/生成绑定/编译/Analyze/Clippy/测试。实际仅格式解析/vendor只输出解析/206公共边界源码清单及diff，最后完整已验证仍0e96be4。
- 当前Windows编码及全量静态审核仍未全齐：反向Explorer下载、安全直传/跨服剪切、未知暂存清理、可靠单行输入采集/候选与安全路径发送等继续；Android暂停。不要用本源码检查点称完成或提前执行分模块编译测试。


- 2026-11-02继续：上传/下载选择器与Explorer现在共用Model.submitFileTransfers冻结请求批次、原会话代次、退出pending及部分接受计数。下载先校验全部选中文件名再入第一项，避免后续非法名字造成意外部分批次；文件选择前冻结下载列表，后续焦点/目录变化不改目标。新增3项模型测试源码未运行，仅Dart格式解析/diff；剩余Windows功能和统一验证仍未完成，Android暂停。


## 2026-11-02继续：文件列表列可见性及顺序（未统一验证）

- 从4dbeaa2继续静态点击路径审核，补上正式FilesPanel的“显示与排列列”窗口；编辑候选在应用前不改变列表，取消保留原样，名称列保持可见并可移动位置。表头/对应元数据/总宽度统一按同一可见列顺序绘制，保留按原列ID排序及列宽，窄窗仍横向滚动。列更改也使Explorer旧区域token失效，不改会话/真实文件/剪贴板或终端内容。当前为面板运行期布局，不新增云端设备布局数据。
- 新2项组件测试源码覆盖取消/应用/隐藏、列序回调及表头位置/文件身份；尚未执行，物理拖动验收仍留统一阶段。首次Dart格式解析发现collection-if的逗号位置错误，已修正后格式解析/diff通过；这不是Analyze或构建/测试通过。其余Windows剩余源码继续，不等待模块验收，Android暂停。


## 2026-11-02继续：远端暂存显式清理与未知结果屏障（未统一验证）

- 从323d7ae及未提交清理源码继续：新增核心逐路径lstat/私有类型检查、一次性风险确认、REMOVE前原子意图及ACK后退休；来源/最终目标不删除。缺失只退休引用，元数据不作为身份或旧请求成功证明；未知创建/发布/删除封禁旧任务路径续传，明确新任务使用新随机名字。
- 正式队列独立分页入口保留跨重启已结束任务的暂存引用，普通队列不恢复已完成行。只需手动连接原目标，不要求源SSH；原Vault/实际账户/指纹/代次/任务身份/完整检查点修订绑定确认。读取和删除真实worker持有原任务通道、异常结束屏障及清理FIFO，取消/收尾失败不能遗弃owner。仅结束本机等待保留未知记录、不发网络请求、不标成功。
- 新Core3项（含5个场景）/Bridge codec1/Flutter3项测试源码未运行，私有Native故障夹具待统一阶段补齐和执行；仅Rust/Dart格式解析、212公共Result源码保护及diff，未依赖解析/FRB生成/编译/Analyze/Clippy/测试。Dart格式解析曾发现括号错误并修复；不将其描述为语义或运行验证。最后完整已验证仍0e96be4，Android暂停；继续Windows其余源码，不等待模块验收。


## 2026-11-02继续：手动重连按设置恢复待传项目（未统一验证）

- 从d090612继续：传输加密偏好新增默认关闭的resume_on_reconnect，省略字段的旧调用保持原值，旧记录不授权网络工作。只有本次运行中原标签中断的工作任务成为内存候选，明确暂停/取消撤销；跨启动/同库重开不重建候选。重连前等待旧任务/检查点，回执代次/原Vault/账户/指纹核对后才继续待传节点；完成字节/成功兄弟/失败项/冲突保持。
- 跨服复制复用两端均已手动连接的原nativeID，不代换其他标签、不建SSH。另一端断开待处理，未知移动/暂存删除/创建发布保留原安全拒绝。清理元数据检查也标独立cleaning，修复其在Root断开时可能被误算作复制恢复候选的问题。恢复入队汇总/错误独立于SSH结果，通过Controller可选backend能力和顶部紧凑报告显示，队列重新取快照，不新增空闲poll或传输Toast。
- 新存储1/设置1/Controller2/私有OpenSSH Native1共5项测试源码未运行；旧设置测试新增滚动可见处理。故障分类失败节点仍需用户明确重试，不靠字符串猜测、不将其计为自动恢复成功；详TRANSFER_RECONNECT。实际仅Rust/Dart格式解析、213公共Result源码保护清单及diff；FRB/依赖锁/编译/Analyze/Clippy/所有测试仍留最后统一。最后完整已验证0e96be4，Android暂停；继续安全直传/跨服剪切、反向Explorer、可靠单行历史候选/路径发送及全量静态审核。


## 2026-11-02继续：普通文件反向Explorer虚拟下载（未统一验证，条目仍部分）

- 从42d3239继续：固定0.9.1的MIT super_drag_and_drop/super_clipboard源码声明及官方API/Windows实现只读核对，正式文件行Alt拖出、普通手势仍走原内部拖动。冻结原会话/代次/元数据和128项多选，拒Windows非法/设备/重复名称，不截断或自动重命名。只允许Copy，Native接收方请求内容才下载，不提供指向缓存的CF_HDROP，不误触发本应用上传/PTY。
- 复用原Rust预览票据/FIFO/限速/完整下载与文件CLOSE，明确下载不调用关联程序；完整快照后64KiB分块到原生临时磁盘sink，无整文件读入或FRB正文。源释放与错误在Model原pending内，取消跟踪实际Future、关闭逐块检查，EOF不代表Explorer目的落盘；失败固定摘要、不删来源或接收方部分文件。预览+原生spool占两份磁盘，原依赖注册/COM/异步交付仍待Windows验证。
- 新4项纯适配器测试源码未执行；静态发现并修复Dart字符串乘法、重复sink关闭、取消Future未观察及结束信号晚于Model pending的问题。仅Dart格式解析/diff，未pub依赖/锁/插件注册生成/编译/Analyze/测试；不是Windows已用。目录/链接拖出及HSPTerm队列显示/暂停恢复仍缺，保留原完整下载选择器作为现有功能，不能标系统拖放整条完成。详WINDOWS_EXPLORER_DROP末节。
- Windows其余仍继续：安全直传/跨服剪切、可靠单行采集/候选与路径、反向目录/队列及全量静态审核；最后统一FRB/依赖/编译测试未开始，Android暂停，最后完整已验证0e96be4。


- 暂存清理后续静态资源复核：普通队列手动清理已结束项时，只有仍存在设备日志的复制任务保留隐藏清理owner；已成功删除日志的完整任务真正释放，修复反复清理后不可见CopyJob累积。设备清单读取移到blocking worker，失败不静默丢唯一引用。只格式解析/213源码边界清单/diff，Native循环资源回收仍待统一执行。


- 继续静态生命周期交叉审核：未确认移动的只读检查改为原任务持有的独立ChannelBatch，各检查仅收尾自己的IO，不关闭后来检查的通道；同任务保留所有尚未实际结束的会话。FRB检查由实际blocking worker拥有，取消RPC不遗弃在途读取；既有最新票据/代次/原任务保护不变。新增1项受控双工协议测试源码覆盖独立批次/异常/任务owner，未执行；原Native迟到检查夹具保留待统一回归。实际仅格式解析/213源码边界清单/diff。后续全量审核还需检查预览/编辑异常收尾与目录ChannelLease取消兜底，不能将传输任务owner修复泛称所有SFTP生命周期已验。


- 同批继续修复预览/Explorer共用下载的异常收尾：PreviewJob持有实际SFTP Channels，worker内部监督正常/错误/panic后的本机IO收尾，FIFO许可放在原run Future外，覆盖整个清理尝试。并发取消即便另一调用拿走JoinHandle也等待原finished版本；清理失败不移除job/slot或运行缓存锁，shutdown不预先drain唯一owner，可在Root结束后明确重试。32项准入也统计仍退休中的失败owner，避免无限保留未释放通道。新增私有OpenSSH Native并发cancel/共享FIFO/原源保留/下一完整快照1项测试源码未运行；只有格式解析/213源码边界清单/diff。编辑与目录取消兜底仍需继续，未称所有SFTP收尾已完成或已验。

- 预览收尾同批补正：去掉原run内与外层Channels监督重复的SFTP close等待，文件CLOSE ACK仍由原transfer检查；统一worker外层收尾覆盖取消/错误/unwind，避免一次异常串行耗用两次完整关闭时限。仅格式/diff，最终故障延迟和回归仍待统一验证。

- 暂存清理UI身份静态补正：确认时不再按主机ID重新查找第一个连接；仅保留一次弱引用的原会话/nativeID/代次/票据与路径，标签排序/移动不改确认对象，关闭/重连/迟到检查拒绝，消费后不复用。删除成功只失效对应父目录缓存，可见同目录才独立刷新；刷新失败与已确认删除分离。仅Dart格式解析/diff，原会话双连接重排/关闭和缓存刷新Native专项留统一验证。


## 2026-11-02继续：跨服务器来源删除核心（正式入口未接，未统一验证）

- 新SourceRetirement实际核心状态机：仅整树Complete/Published/完整ACK，固定版本元数据摘要绑定不可变计划；子先父后且兼容追加子树。总数/确认游标/单个Intent为有界任务头，不建百万条删除日志。每次lstat父/最终类型与大小检查后先checkpoint Intent，再一次REMOVE/RMDIR、真实ACK后推进；未知不重发，已完成不删除后来重建的同名来源。明确结束等待仅本机未知记录，不标成功或再次删除。
- 新错误文案区分复制未全确认、来源已部分删除后的停止、未知删除和来源变化，避免沿用“源保留”而误导。sha2只为固定元数据投影，不做文件内容哈希。新增1项核心顺序/绑定及3项受控peer测试源码，均未执行；仅Rust格式解析/213源码边界清单/diff。未依赖锁/FRB/编译/Clippy/测试，正式跨服务器移动入口仍拒绝，不能标完整。
- **当前接续入口**：SOURCE_RETIREMENT.md逐项列出Bridge独立Relocate操作、显式中转/来源风险确认、元数据增量日志/恢复/未知本机结束、源编辑互斥/缓存刷新/队列及真实Native/组件测试。尚需接齐才能计正式功能。原同账户Move不要改成复制删除，安全直传/可靠单行历史与路径/反向Explorer目录和队列等仍未齐；最后统一验证策略不变，Windows优先，Android暂停。


## 2026-11-02继续：跨服务器移动正式接入源码（UNVERIFIED）

- 从5de5a33核心继续，新增Relocate正式操作/可选显式中转许可；同账户仍原rename。完整复制且无跳过后才建来源删除ledger，原FIFO/双端身份代次/编辑互斥保持。来源父目录先规范化，同密钥重叠源目录拒重复任务，暂停来源阶段禁止新编辑；只允许继续，不得改树重扫。队列显示复制/来源确认项数与未知删除入口，确认文案说明不可回滚/同大小不能证明身份。
- 来源Intent/ACK只更新有界加密元数据；恢复/结构屏障完整验证计划。失败重读持久日志，读也失败保留原日志与运行已确认游标，禁止最终泛化save覆盖。新增只读原双端独立通道检查/离线一次票据本机结束3API；未知不重发、不推断缺失成功，结束留唯一审计。清理结束行保留所有仍有设备日志的隐藏owner，修复原只保留Copy遗漏Relocate；缓存更新核原nativeID及代次。
- 新源码测试6项：codec2/重叠路径1/真实私有双OpenSSH2/未知来源UI1；原目标确认测试修改与队列夹具扩展。真实OpenSSH夹具只生成专用临时秘密，移动仅私有payload子树，不含server密钥/vault。所有新测试未执行；仅Rust/Dart格式解析、源码保护清单及diff，未Analyze/Clippy/编译/绑定生成。错误保护216API为词法检查，最后完整已验证仍0e96be4。
- 接续：继续剩余Windows源码，重点编辑/目录异常收尾、安全直传、可靠单行输入采集/候选与路径、Explorer目录及消费队列；全功能源码/静态审核未齐。最后统一依赖锁/FRB/编译测试策略不变，Android暂停，未做Win实机验证。详细入口SOURCE_RETIREMENT.md。


## 2026-11-02继续：编辑器实际通道所有权（源码未验证）

- EditorEntry新增原任务Channels，文本与大正文remote统一使用原代次open/监督收尾；共享FIFO许可在select/action Future外，覆盖正常/取消/unwind后的通道收尾尝试。失败保留文档实际owner，32文档预算仍约束它；后续工作先明确完成旧退休，不建立重叠通道。不是远端CLOSE ACK或故障时必能退休的承诺。
- blocking work在本线程捕获action panic，再等待实际Channels退休；本机状态只在原remote收尾成功后确认。取消/断开文档/关闭同样等待原gate及IO，失败不得删除registry文档、外部租约或草稿；关闭线程错误也恢复可重试状态。停止一个Root遍历取消所有关联文档，不因首个清理失败漏停其他编辑。
- 新2项源码测试覆盖panic摘要/票据释放后明确新工作、取消等待真实blocking worker而不提前清票据；原Native编辑/外部大正文/故障测试保留待统一执行。仅rustfmt/216源码保护清单/diff，未编译或测试。接续目录游标ChannelLease::Drop遗留脱离收尾和错误丢弃；最后统一验证策略不变。


## 2026-11-02继续：目录/搜索游标显式通道退休（未统一验证）

- 删除ChannelLease::Drop中脱离调用方的spawn/忽略close结果。Cursor自己持Channels，State保留已替换/关闭但未退休游标；失败保存reader/原gate，下一次打开先完成旧退休，不打开重叠目录通道。release与打开阶段/分页分别有真实门控，避免尚未登记的open被提前prune；取消RPC仍由原游标保存已建立通道。
- close只处理匹配generation/request的旧游标，不能关闭新游标；close_all处理活动和保留项，所有结果尝试后汇总首错。Root断线监视器仍只负责取消/尽力收尾，失败owner留原State供明确清理；不把后台无调用方当成功，也不把本机IO退休等同peer CLOSE。整个runtime销毁仍依赖原Root的实际stream界限，正常退出必须显式close_all。
- 原阻塞READDIR目录/递归搜索夹具改为run_owned真实peer，扩展丢弃RPC Future的两种路径；新增打开阶段替换/等待真实barrier/不关闭新游标1项源码测试。都未执行。只rustfmt/216源码保护清单/diff；未编译/测试。原普通CRUD缓存remote_sftp生命周期仍需审核，其余Windows源码继续，最后统一验证不变。


## 2026-11-02继续：普通SFTP操作原代次与生命周期（源码未验证）

- api::remote_sftp在首个await前捕获原代次，cache锁排队/旧通道退休/新协商后均复核原Root与关闭状态，不能等待后借新代次；旧/迟到通道明确close成功前不丢唯一cache引用。同代次实际IO已退休不复用；只有通道建立用既有typed有限恢复，不重试任何文件mutation。
- 新建目录/更名/删除3个既有API追加可选expected_generation，旧调用保持None，正式Model全部固定提交时原nativeID/代次。批量选择先冻结，每项前复核，关闭/重连停止余项；请求加入原pending。刷新只失效受影响目录并按原目录/请求epoch复核，不在导航/重连后覆盖新视图；重命名目标取所选文件原父目录，不跟随后来OSC7目录变化。
- 新私有OpenSSH Native测试源码1项：旧代次3类mutation全部拒绝/源目标不变，当前代次明确新操作可完成且原终端保持连接。未运行；新增参数需最终正规FRB生成。仅Rust/Dart格式解析/216源码保护清单/diff，统一依赖/编译测试仍未开始。


## 2026-11-02继续：安全直传准备器（未派发/未统一验证）

- 新ssh-core::direct_transfer::DirectProbe仅准备只读固定命令/验证公共端点与原Active应用Agent epoch及剩余期限、限定响应。固定Python探测系统rsync/ssh、原通道socket及目标rsync；SSH argv禁用户配置/默认密钥/系统known_hosts/外部Agent/代理/复用/askpass，只KnownHostsCommand重新计算原目标SHA256并保持StrictHostKeyChecking，RSA只SHA2。参数base64元数据、无shell subprocess、stderr不回传，超时杀整个本机辅助进程组并wait。
- 新Rust3/Python2项源码测试未执行，仅rustfmt/Python AST解析/diff，无远端执行。**尚无专用原Root exec派发/Agent endpoint/实际直传正文与暂存回执/任务策略UI接线，不能称直传已实现**；正式复制仍原显式许可中继。下一步从DIRECT_TRANSFERS.md继续原Root单槽所有权和任务接入，可靠单行增强/Explorer目录及队列也仍未齐。统一生成/编译测试未开始，Android暂停。


## 2026-11-02继续：原Root安全直传只读派发（源码未验证）

- DirectConnector新增原Transport独立单槽exec，ManagedSession按明确generation返回，原SshConnection关闭等待实际slot；未决OPEN保留到晚ACK/Root结束，操作超时/unwind仍尝试已知channel收尾，未知CLOSE持槽防无限重试。固定probe前后复核原Agent授权epoch/Active，请求原PTY已协商Agentendpoint，绝无任意exec或PTY注入。
- 新私有双OpenSSH测试源码1项覆盖未授权/目标原key及appkey/改指纹/撤销/PTY保留/旧Root关闭。未执行，最终须系统rsync/ssh/python3；只rustfmt/216入口词法清单/diff。DIRECT_TRANSFERS.md更新当前边界：核心只读派发已接，但Bridge实际任务/暂存发布/正文直传与UI策略仍未齐，不能称安全直传完整。继续此入口，其余Windows及最后统一验证仍待做。


- 跨crate静态接口复核补正：Relocate规范化调用的transfer::object_path此前仍pub(crate)，现明确公开只读父目录规范化API并保留最后链接/不预留名称边界，修复Bridge不可见引用。原私有OpenSSH准备测试源码扩展最后符号链接不跟随/根与点段拒绝断言，未执行；只rustfmt/diff。


- 正式设置点击路径静态补正：快捷键页不再展示仅弹“编辑原型”通知的假编辑按钮，也不将未接入的Ctrl+Shift+F/D/M列为现有组合键。Mock入口保留原型；正式页保留已接真实加密自定义命令面板设置及实际终端复制/粘贴/历史浏览、新建入口的只读说明，搜索/分屏/最大化沿现有菜单/面板。未改变真实键盘路由或远端协议。仅Dart格式解析/diff，交互回归留统一阶段。


- DirectConnector追加受控SSH peer测试源码：明确授权后故意延迟OPEN，取消返回但仍占原slot，晚ACK后不得发送exec（实际server计数，不以空stdout冒充没有执行），下一未决OPEN期间Root关闭等待worker。此为协议所有权夹具，不是rsync真实直传；未执行，仅rustfmt/diff。


## 2026-11-03继续：直传正文/策略/任务接线源码（未统一验证）

- 从c35c8f1继续，原DirectConnector新增固定rsync正文到独占暂存：Intent先设备checkpoint，原目标SFTP 0600/EXCL一次随机cap+CLOSE，receiver NOFOLLOW仅核原标记后写原inode，源FD冻结/目标父目录FD/大小权限fsync和成功回执后才Ready；再原发布/冲突及来源删除。不将同指纹不同文件系统误写目标。30秒IO空闲而非1小时总限；未知不重发/改中转。
- 新allow_direct可选API缺省false、Header旧direct默认false/旧relay保持true，避免提升旧许可；正式确认明确SSH/SFTP路径一致、直传优先及独立中转策略，可选仅中转，虚拟根不一致应关闭直传。无中转时先只读预检；原Vault实例跨await固定最终gate核对。task内3文件/原Root单直传槽/每任务真实IO追踪及收尾；未知阻止切库/清理，不与别的任务同Root操作混淆。手动断开不再因停止子任务失败而跳过Root关闭。
- 队列新增direct/relay/mixed实际方式，直传只按整文件回执确认/不伪造速度；新增写命令/IO隔离/codec/选择器/接收器安全及私有Native测试源码，原OpenSSH扩正文/阶段/边界暂停继续。全部未运行；只Rust/Dart格式解析、Python AST、216入口词法清单/diff，最后完整已验证仍0e96be4。DTO/参数需要最终FRB生成，未编译/测试。
- **仍在进行**：直传未知结果后的原远端执行再确认/精确部分续传尚需完善；其他Windows剩余包括可靠Shell命令跟踪/候选与路径注入、Explorer目录及消费队列。Shell输入证明与禁止依赖插件的冲突已通过异步问题请求用户决定是否允许可选主动启用集成；尚无答复，不得按允许处理，继续独立工作。DIRECT_TRANSFERS.md最新节是本模块恢复入口。Android暂停，统一生成编译测试仍放全部源码/静态审核之后。


## 2026-11-03继续：Explorer目录描述符与双向OLE所有权（源码未统一验证）

- 新ssh-core::explorer_manifest从原下载TreeTransfer产生完整虚拟清单，保留原根/节点身份、父先子后/空目录/中文及64位长度；整批128根/32768项，259 UTF16全路径/255分量，失败/跳过/链接/别名/大小写碰撞整批拒绝，不截断/改名。尚未接目录实际provider/缓存租约/正式队列，UI仍诚实拒绝目录，不能计完整。
- 固定super_native_extensions0.9.1最小源码补丁增加明确目录/文件属性、FD_FILESIZE和不截断清单；准备器只核固定归档SHA/安全tar/容量并生成忽略目录下本地fork，保留MIT、散列清单，已有修改拒覆盖，不碰全局pub缓存。pubspec显式override，Windows构建脚本在pub get前准备；手工/clean后也须先准备。当前尚未执行准备器/依赖解析，最终锁/许可审核待统一阶段。
- 跨层发现outgoing插件也初始化DropContext，上游无条件RevokeDragDrop会撤runner接收器。现runner在RegisterPlugins前RAII预留窗口属性，固定补丁检测后跳过注册/销毁hook，空hook析构匹配；原上传仍区域bind才接收，不改内部Flutter拖动或远端正文协议。普通文件UI补CONIN$/CONOUT$/dotless-i设备别名及大写碰撞拒绝。
- 新4项Rust清单/5项Python准备器/2项补丁Windows属性测试源码，原Dart名称夹具扩展；全部未执行。实际只Rust/Dart格式解析、Python AST及diff；无FRB生成、Analyze/Clippy、编译或Windows消息泵测试。详细边界/命令在WINDOWS_EXPLORER_DROP.md。最后完整已验证仍0e96be4。
- 接续从后台原会话扫描/同一目录任务清单、独立缓存及Native注册/实际消费租约接完整目录拖出队列，不提供临时CF_HDROP目录后在DragEnd猜清理。安全直传未知结果/精确续传及其余Windows继续；可靠Shell编辑证明仍等待用户对可选集成的决定，不阻塞独立模块。Android暂停，最后统一依赖/生成/编译测试策略保持。

- 本批已保存源码检查点babde8c（UNVERIFIED）。继续跨层审核修正普通文件拖出复用预览全路径REALPATH导致跟随最终链接：新增固定Purpose::ExplorerCopy的专用reserve_explorer_file_export，正式拖出调用它，父目录规范化/最终lstat及原下载检查；显式打开仍可解析链接。原私有Native预览夹具扩3条路径（链接拖出拒绝、显式打开链接保留、普通复制源及PTY保持），未执行。新增API需最终FRB生成；SFTP v3检查与OPEN并非原子NOFOLLOW，明确保留此协议限制。没有因此宣称目录队列已接。
- 正式虚拟消费再补有界FIFO准入（票据预留前3活动/256总量），处理接收方同时/重复请求，避免128项直接耗尽32个Rust准备票据；共享Rust传输FIFO/带宽保持。等待取消不启动源，活动取消不提前放开实际action；未知IO仍原Rust owner保留，不以Dart计数证明退休。修复cancelled标志吞掉清理失败，仅安静处理类型化本地取消。新增4项Dart测试源码未运行；只Dart/Rust格式解析、217入口词法保护清单/Python AST/diff。公开固定依赖源只读审核散列/成员/容量/MIT/edition吻合，未准备/安装/测试上游。继续目录原任务/缓存消费与其他Windows源码，不按本模块检查点停止验收。


## 2026-11-03继续：Explorer目录真实源任务与消费生命周期（全部源码未验证）

- 正式Alt拖出统一文件/目录：冻结原会话/代次/列表有序项，后台TreeTransfer扫描、完整Windows清单校验后才注册Native描述符；文件/目录类型变化拒绝。扫描增entry_limit，Native早停32768，普通任务仍原1m；不先扫百万行再拒绝。不跟随链接，不改内部移动/终端路径拖动。
- 新storage-sync::export_cache私有持久源缓存：每目录owner锁、共享registry锁、安全路径/marker/权限与reparse检查、未知兄弟拒删除。Drop仅解锁不删部分数据；退出/重开库未完成源任务仍按原加密检查点和偏移继续。缓存正文不进FRB/配置同步/备份，Windows依赖应用私有support目录继承ACL，实际权限仍待实机。
- 新7个Bridge API及transfers::explorer租约：一个根一个普通FIFO任务/原下载限速与3文件内部并行。初始仅扫描，FILECONTENTS才下载整树，真实文件/通道收尾及完整整树后才返回缓存路径。ExportReady不是外部目标成功；可在队列从就绪快照离线拖出，重启也不新建SSH。文件read票据单独ACK，尚有本机读者/实际IO时不释缓存/切库；同库配置恢复的scope旋转不错误剥夺活交付。原代次Native租约不接管重连后源工作，重连恢复暂缓有活交付的源任务。
- 新Dart批次所有权独立于原Widget：构造/在途票据、Native注册/Dispose、实际本机provider/预备workers联合退休；退出先关Root、取消源、等本机读者、再释放。取消是意图，不提前删文件；释放ACK失败保留逐读票据可明确重试。队列提供“结束所有Explorer交付”，解决接收方保留Native对象时不能切库的问题；离线活交付也纳入退出确认。零字节文件及纯空目录不依赖接收方一定请求FILECONTENTS，复制手势仍确认实际源任务。
- 只有Native关闭所有provider且本机读取结束、文件EOF交付充分时，源行标“数据已交付·目标由Explorer确认”。没有外部目标路径/磁盘ACK，不擅自删Explorer部分文件。源暂停/失败保留字节，明确继续/重试原失败文件；冻清单不允许更名/跳过/重扫改变Native身份，需改清单重新发起拖出。SourceReady后的外部本机复制由Explorer控制，队列不伪造外部写入进度或暂停能力。
- 静态性能审核修正逐文件重复加载/解密整树的O(N²)问题：每交付租约共享元数据清单和一次确认后的就绪清单，文件只按原node索引取路径；Dart逐块64KiB→Native磁盘spool。尚未进行性能测量或证明无泄漏。
- 新缓存2项Rust/真实私有OpenSSH Native目录与读租约/离线恢复1项、队列语义组件1项测试源码；原文件协议及IO适配器测试保留。全部未执行。实际仅Rust/Dart格式解析、公共错误边界词法检查/diff；未FRB生成/Analyze/Clippy/编译/测试，依赖缓存缺失警告未消除，最后完整已验证仍0e96be4。
- 仍需统一阶段实际验证：复制大目录、部分失败/断点、Native注册前取消与晚票据、零文件/重复内容请求/慢盘/缓存错误/退出及多进程锁、Windows OLE消息泵。异常中断遗留且无日志引用的源缓存未提供全局清理工具，不能自动删除未知缓存；明确保留为后续收尾项。继续直传再确认/精确续传与其余Windows剩余源码，Shell可选集成决定仍未获回复，Android暂停。
- 本批后续静态生命周期复核补正：把预备元数据/晚begin票据也纳入批次worker屏障，避免结束交付时晚票据泄漏；取消排空实际读取、释放Future串行化、返还ACK失败留票据重试；接收器注册/Dispose乱序合并。新增7个公共API已由源码保护器补边界，现224入口，仅词法检查。所有新DTO和导入transfers/explorer仍待最终正规生成，不能加载旧绑定/SO。
- 源码检查点975ef1b已保存（UNVERIFIED）；后续修正拖出包装器为Stateful持批次，避免目录扫描期间队列刷新重建控件导致配置引用丢失；异步代码冻结原Widget参数，卸载/焦点变化不借新源。源任务名称使用原描述符根名。新增代码仍未编译或运行，Windows完整源码/全量审核尚未结束。


## 2026-11-03继续：直传认证回执/增量恢复源码（UNVERIFIED）

- 原分块设备检查点新增Direct能力/attempt，Debug脱敏；原inode原子xattr保存HMAC回执、排他flock及原rsync进程组。首次标记只截断一次，旧attempt/伪造complete/仅完整长度均不能确认成功；原能力不写xattr。只读查询经原源Root/Agent/目标指纹，有界输出和期限，未知不重放。
- 明确继续先核对：Complete经原目标SFTP确认即可发布，不再依赖来源父目录/正文；Partial只有旧进程组确定消失才保存新attempt并用rsync正常delta恢复，保留部分字节，不使用append或伪造偏移ACK。旧Intent无能力不收养；pgid0/仍活/未知/不支持xattr安全拒绝，实际非秘密回执xattr随最终inode保留。取消映射保留可继续阶段，不自动SSH或新Agent授权。source辅助进程也补原未收割子进程收尾，避免重用PID信号。
- 新Rust2/Python2及原2负控修订/原私有双OpenSSH丢Ready恢复场景源码，全部未执行。仅Rust格式解析/Python AST/源码保护清单/diff；未编译/测试/FRB。真实中途部分delta及目标FS支持仍待统一阶段。DIRECT_TRANSFERS.md最新节为准确接续，覆盖前文尚无恢复源码，不称已验收。
- 继续Windows其余源码/跨层审核，Explorer无日志引用孤立缓存清理仍缺，可靠Shell输入证明待用户可选集成决定（未获允许），不得注入Shell插件。全部剩余编码及统一验证未完成，最后完整已验仍0e96be4；Android暂停。


## 2026-11-03继续：孤立Explorer缓存显式清理源码（UNVERIFIED）

- 新导出v2归属marker+本机加密location绑定随机owner，不进同步/备份；不同位置的物理Vault副本不复用owner。队列加入只读检查/默认取消确认/删除时原scope、日志、运行路径与owner锁再核对；每批最多128、扫描10000、一次票据5分钟/16份。旧v1/其他库/活读取/可恢复日志引用全部保留，关闭弹窗不删除，不触碰远端/Explorer目标。删除失败逐项统计，可重新检查，未实际清理用户磁盘。
- 日志增加只读根元数据投影，避免清理时重建整树；缺正文块仍保护原目标，损坏根拒绝清理，绝不授权恢复。新增Storage缓存2+metadata1、Bridge引用1、Flutter2共6项测试源码（原备份排除扩展），均未运行。只Rust/Dart格式解析/227公共入口源码保护/diff；无FRB/编译/Analyze/测试。新增DTO/API绑定留统一收尾。
- 接续覆盖旧“无日志引用缓存完全没有清理工具”：仅新归属缓存已加显式入口，旧无归属不猜测清理。WINDOWS_EXPLORER_DROP最新节详述限制。继续Windows全量源码核查，可靠Shell输入/历史/路径注入仍待可选集成决策；最后完整已验证0e96be4，Android暂停，统一构建测试尚未开始。

- 直传统一验收源码再补：私有双OpenSSH场景准备错误部分basis后运行真实rsync delta恢复，断言完整字节/attempt递增/不走中转/来源不变；另Python空文件成功回执与pgid0未知不恢复。这里只编制测试未执行，不把受控部分状态等同真实网络中断，也不称测试已通过。仅Rust格式/Python AST/diff。源码检查点f4c8942与c2c93ee已保存，均UNVERIFIED，继续剩余Windows静态审核。


## 2026-11-03继续：Windows标题空白拖动与真实标签状态源码（UNVERIFIED）

- 标题文字、单组标签栏实际剩余空间、多组顶栏空白接既有原生drag/maximize/systemMenu；标签与控制按钮不被覆盖，分屏内部组不加窗口手势。空白仍接受标签追加，溢出区固定32px，实际不足继续横向滚动；组计数小窗省略。正式标签Tooltip取真实连接状态，不再错误显示Mock文案。
- 新3项Widget测试源码未运行；只Dart格式解析/diff，不称Snap/Win32消息行为已验。WINDOWS_WINDOW.md最新节记录边界。继续Windows独立剩余源码；Shell可选集成问题已再次异步提出，尚未得到明确许可，依旧不注入脚本或以OSC自报开启历史采集。统一编译/测试仍在全部编码之后，Android暂停。


## 2026-11-03继续：终端普通路径/行列引用源码（UNVERIFIED）

- Flutter新增有界只读路径显示识别，支持绝对/显式相对/目录路径/带扩展名文件及path:line[:col]，保留编译器末尾冒号原文。原URI/IP/loopback端口、OSC8真实目标优先及宽字符软换行定位保持；不剥标点猜文件、不以裸路径替代非法OSC8。无预探测/PTY输入/本机打开。
- Ctrl+Click/菜单明确定位，行列后缀及单文件名有默认取消选择；行列引用可选择文件或原文字面路径，选区也有独立入口。原源session/id/generation跨确认检查，实际CWD/authority/路径解释和访问仍Rust，不把SFTP浏览器目录当未知Shell CWD，不自动编辑跳行。新增6项测试源码未运行；仅Dart格式解析/diff。TERMINAL_PATHS最新节为接续，更多真实特殊名和TUI场景留统一验证。
- 标题栏源码检查点8639c72已保存UNVERIFIED。Windows全部编码/全量静态审核尚未宣布完成；仍在追踪可靠输入/候选及路径发送的实质需求冲突，用户选择前不开放不可信注入。统一依赖/FRB/编译/测试尚未开始，Android继续暂停。


## 2026-11-03继续：跨语言批量接口源码审核工具（未编译测试）

- tools/bridge_contracts.py直接比对Rust公开函数/唯一Bridge结构与Flutter实际Rust导入调用，覆盖函数/字段名称、非Option必填项、隐式StreamSink；有界词法不执行字符串/插值。修正三元属性名误报，不改正确业务调用。当前实际扫描230函数/72结构/259源码文件，0项发现；不是类型/ABI/生成导入或运行证明。
- 新扫描器6项回归测试源码未运行，Python AST通过；未解析依赖/FRB/Analyze/编译/应用测试。边界和命令见STATIC_REVIEW.md。本次路径源码检查点1e22801、窗口8639c72均已保存UNVERIFIED。继续全量Windows剩余核查，Shell可选集成尚未获答复，不暂停其他独立模块；Android暂停。


## 2026-11-03继续：正式点击路径审核与收尾所有权修复（源码，UNVERIFIED）

- 应用ecc:click-path-audit技能先映射Model sets/resets，再分主机/目录/队列与退出只读交叉审核。三个审查者发现实证问题后编制修复与测试，后续代理额度中断；已逐项检查实际文件并由主线程完成未接完的SFTP浏览默认值，不将代理报错当任务完成。
- 主机choose在离开/保存后按ID重新解析新记录，目标消失不回退旧对象；生成/导入密钥已写入加密草稿后的目录刷新失败使用KeyPreparationRefreshFailure保留KeyDetails，UI接纳成功公钥并清旧secret/passphrase，避免再保存覆盖新密钥。5项新测试源码。
- FilesPanel冻结原Model/session/nativeID/generation/path及导航token/历史快照/Live directoryEpoch，过期reader正常返回不能消费历史；补实际前进按钮，删除/新建目录的旧确认不借重连后代次/后来的目录。旧重命名回调不清新选区，Clipboard ACK后才提示复制。4项新测试源码。canonical别名路径可被Model正常导航，但保守不执行依赖精确目标的旧UI后续，未来可用明确导航回执改善。
- TerminalController关闭后永久禁止交互，但保存原Native ID/订阅至实际关闭确认；失败可明确重试，不复活SSH；native完成与stream退休分阶段，晚create纳入原shutdown并等待，dispose幂等不丢owner。Model立即移除标签后保留退休session，命令面板可显式重试关闭，退出也等待/重试旧owner；不再把失败Future永久缓存或以id==null推断退休。Native保留closing Entry与串行close_state到所有清理成功，常规entry()拒绝关闭中句柄；已确认步骤不重做，Root始终关闭，原Closed错误先报告而不永久阻止明确退休。Controller4/Model2/Native取消销毁与原search gate所有权1项新测试源码。
- 正式SFTP浏览默认值新config-sftp-view-v1：版本/原Vault修订CAS、加密持久化/同步与完整备份白名单及校验；正式面板的目录优先/隐藏文件/紧凑默认实际影响排序/可见行。仅保存ACK发布，失败保留上次确认画面并禁写到重读。默认修订不变时列表局部菜单保持，焦点切换不触发存储/联网；Model持控制器，启动/恢复/退出接生命周期。Core2/云备份白名单1/Flutter4项新测试源码。
- 本批共23项新回归源码，全部未执行。实际仅Rust/Dart格式解析、接口名/字段词法扫描（截至接入2新API为232函数/72结构/263个Dart源，后续新增测试数会变化）、公共错误摘要清单/diff；新JSON API待正规FRB。另4个早期文件仅格式调整，无业务变化。未Analyze/Clippy/编译/运行，最后完整已验仍0e96be4，Android暂停。
- **明确接续未完成项**：Model.load缺整体旧请求发布保护/原库原子主机目录快照；正式设置未保存编辑跨类别/离页保护；队列恢复候选优先原native但实际身份已变时无法选正确同host标签（Native仍能阻止错服写入）；可靠Shell编辑证明/候选/安全路径填入仍待用户选择可选集成方案，未获允许不可注入脚本。继续这些独立编码，全部源码后再统一依赖/FRB/编译测试，不将本节点误标全Windows完成。


## 2026-11-03继续：主机目录一致快照与旧请求发布保护（源码UNVERIFIED）

- Repository::metadata_snapshot在同一SQLite读事务内读取主机/组/草稿，只传元数据与凭据存在标志，草稿秘密不跨FFI。Bridge host_catalog_snapshot在原Vault锁下先完成旧profile迁移再读；NativeHostStore采用可选HostCatalogStore能力，旧小接口/Fake仍兼容。
- Model整体catalog epoch、关闭门与Shortcut scope交叉核对后一次发布；旧load不能覆盖新load或后来的host/draft保存ACK。load原Future纳入pending，退出等待实际读取；不假定三个分离接口属于同一瞬间。快捷键读取失败仍禁用该快捷键，不能因此用默认值覆盖。需要完整DTO/API最终正规生成。
- 新Core1/Flutter5共6项源码（元数据凭据存在、晚旧读/保存/草稿ACK保护、实际原子能力及异库scope拒绝）均未运行；只Rust/Dart格式、公共错误边界/接口名词法扫描与diff，未编译/Analyze/测试。前批源码检查点38a060c已保存UNVERIFIED。
- 下一步仍为设置未保存离开守卫、队列显式正确恢复候选、Shell输入证明决策和全量静态复核；不能据新工具0发现宣称全Windows编码/类型检查完成。统一依赖/FRB/编译/测试仍未启动，Android暂停。


## 2026-11-03继续：设置编辑离开守卫与队列候选代次（源码UNVERIFIED）

- 设置页新增SettingsLeaveRegistry/Scope及轻量编辑器登记，跨类别、外部initialCategory请求、离开设置页/切终端/退出共用同一检查；保存尚在处理时禁止离开，dirty时默认返回编辑或明确放弃未提交表单，不自动覆盖/撤销已ACK配置。登记只含标签/dirty/busy回调，无密码/正文副本。已接显示规则、快捷键、字体、终端设置、SSH默认、文件打开、传输、同步目标八类正式表单；立即保存的主题/SFTP默认仍由Model控制器持实际工作，不新增伪dirty。
- 数值配置记录原表单投影，在保存ACK后才清dirty；终端偏好比较实际表单序列化、无效编辑按dirty处理；同步秘密不被守卫复制。新4项守卫/导航组件及真实显示设置组件1项源码未运行。包装器只增加离开保护，不改原保存/校验/确认流程。
- 队列连接偏好先核原native+generation，原标签已重连换代次时优先使用用户当前聚焦的同host会话，再保留既有候选回退；单端及双端共用。它只是UI候选，不将hostId当认证证明，Native完整地址/用户/指纹及原Root检查保持。3项选择器测试源码未运行；未加入自动SSH或为了重试绕开身份验证。
- 原子主机目录进一步逐条读取有界草稿记录，只检查凭据存在后即释放该草稿秘密，避免列表一次保留全部草稿凭据正文。前批235b2fc已保存，所有新代码仍未编译/运行。实际只有格式解析、233 API/73 Bridge结构/268 Dart源码词法审核0发现及diff，未执行新增回归。
- 仍不能标全Windows源码/验收完成：Shell输入状态证明与禁止依赖集成的冲突已异步提出，未获明确选择，不能暗中注入Shell脚本或仅凭OSC7/133采集/替换命令。其余继续做源码覆盖核对；最后再统一依赖锁/FRB/类型检查/编译/测试，Windows实机单列，Android暂停。


## 2026-11-03继续：通知定位遵循编辑离开保护（源码UNVERIFIED）

- 确认76ba690已提交且恢复时工作区干净；继续审核真实通知查看终端路径，发现其直接model.show/selectTab可绕过主机及设置草稿保护。新增PrototypeAppState.activateTab统一入口，检查关闭门、原标签仍存在、离开确认及确认后的mounted/原标签存活；通知先激活原窗口供用户看到确认，再通过该入口定位，不创建/重连会话。普通标签切换共用入口。
- 新2项Widget源码覆盖通知式定位取消保留设置、明确放弃后选择原标签、等待期间标签关闭不得消费离页；未执行。仅Dart格式解析、233API/73结构/268文件接口词法扫描0项和diff，未生成FRB/编译/Analyze/测试。Android继续暂停，Shell可靠输入证明决策仍待答复，不擅自放开注入。


## 2026-11-03继续：历史开关未保存保护（源码UNVERIFIED）

- 正式历史记录面板新增SettingsLeaveScope守卫：未保存记录开关和真实保存/清空ACK等待均登记，跨类别/离页不能静默丢弃；清空只更新历史修订，不顺便保存开关。新增2项组件源码覆盖清空后仍dirty、保存等待禁止离开及ACK后导航，未运行。管理页纠正“云同步尚未接通”的陈旧说明，仍明确可靠采集/实时联想尚未启用，不虚报完整候选。
- 实际仅Dart格式解析与diff；统一FRB/编译/Analyze/测试继续留最后批次。通知守卫检查点d035c98已保存UNVERIFIED。


## 2026-11-03继续：任务显式选择恢复会话与代次约束（源码UNVERIFIED）

- 队列新增“选择连接继续此任务…”真实选择对话框，单端/双端独立选择原主机已连接标签；仅元数据，不探测/创建SSH。TransferConnectionRef冻结对象/nativeID/代次；确认前监听原会话及任务变化，失效不回退焦点；Model复核，Native新增可选代次参数并在原实际身份检查前拒绝旧选择。源/目标可分别选择，解决一个焦点无法表达双端恢复候选；未知移动意图保持原检查入口。
- 队列control/clear真实请求纳入pending，退出等待原操作和列表读取；closing后不再为ACK发起新列表请求。原完整地址/用户/指纹、Vault、Root及任务状态检查保持，不增加自动SSH或直传许可。
- 新6项Widget/引用源码及原真实OpenSSH单端/双端测试扩展未执行；全部仅格式解析、230个Result源码边界、233API/73结构/270Dart文件词法扫描0项及diff。新参数待正规FRB，旧生成文件保持不手改。历史开关源码检查点c6bd176已保存UNVERIFIED。
- 编码未标100%：可靠Shell输入采集、实时候选/受控填入与SFTP安全注入仍待实质需求冲突选择；统一依赖/FRB/类型检查/编译/测试未开始，Android暂停、Windows实机待验。继续独立源码审阅和覆盖记录纠错，不以陈旧“待做”记录重复开发。


## 2026-11-03继续：覆盖记录纠错与当前恢复入口

- 627e834保存显式恢复选择/代次检查源码，c6bd176保存历史开关保护，d035c98保存通知导航保护，均UNVERIFIED。当前175项需求/验收索引已重新生成，修正已存在源码却仍标待编码的自定义快捷键、主列表拖放/批改、独立云代理、合格历史云投影/完整备份记录；不改变旧运行证据，也不把新源码标成验收通过。
- 新增API签名待正规FRB，缺失的生成导入有diagnostics.dart、host_bulk.dart、transfers/explorer.dart；所有非生成相对导入路径均存在。实际静态检查为Rust/Dart格式解析、公开Result边界清单、API/DTO名称和非Option字段词法扫描0项、Python AST与git diff；不是完整类型/ABI/平台或行为证明。本轮应用/回归测试均未运行，最后完整已验仍0e96be4。
- **未获解决的产品决策**：V1.4同时要求可靠普通Shell编辑/隐藏输入判断与实时历史联想/路径填入，且禁止注入Shell integration。PTY/OSC7/OSC133不足以证明这项状态；之前已提出允许逐主机主动可选集成或接受无法证明时禁用的选择，目前尚无明确答复。保留加密历史基础/管理/同步投影和安全路径复制，不暗中注入脚本、盲清行、抓取回显或把“继续”当批准。统一依赖锁/FRB/Analyze/Clippy/编译/测试尚待，Windows实机单列，Android暂停。恢复先看Git实际状态，不能再按早期覆盖文字重复开发。


## 2026-11-03用户批准可选Shell集成：源码接入中（UNVERIFIED）

- 用户明确选择1，批准逐主机主动集成。V1.4正式追加修订，默认禁止只约束未启用/被动OSC133；不再等待该许可，不将旧冲突当阻塞。新增默认关闭的加密HostRecord/可选HostConfig/DemoHost及正式主机确认→草稿→保存字段，表单epoch/id复查，Rust与UI复制主机均重置false，临时覆盖在Native/UI清除。
- 新固定远端Bash5.1+助手/随机nonce Launch、SSH显式exec启动（tmux附着优先不装内层），不写启动文件；支持范围/风险见SHELL_INTEGRATION。新同VTE私有OSC777通道，完整终止/中止和Alt/RIS失效、脱敏事件，Core单行跟踪/精确提交ACK及受控Plan帧，无裸Enter/猜清行。
- 原SSH actor按实际输入编码跟踪，提交由Weak Entry Native sink写加密历史，实际worker/history_gate随Root退出；不依赖renderer/FRB stream收录，不回传原文。每批最多32条同事务，原Vault/实际目标/主机许可/代次和敏感过滤、关闭/清空规则保持；失败固定HistoryWarning不自动重试。
- 新17项Core/仓库/Actor/Launch/Widget测试源码全部未运行。实际仅Rust/Dart格式、Bash语法、vendor只读语法、233API/73结构/271Dart词法0项与diff；未生成FRB/编译/Analyze/Clippy。最后完整已验仍0e96be4，Android暂停。
- **下步从这里继续，不重复设计/问许可**：现仅支持简单末端输入/ASCII退格，复杂编辑保守失效；助手启动缺Bash/非POSIX入口/dev/fd的预检与失败回退待补；原actor受控应用命令、Native内存候选/历史变更失效、Flutter实时列表/上下/Enter/Tab/鼠标/IME、SFTP插入与空行cd均未接，不能称历史联想/全部Windows已完成。先继续这些源码，最后再统一依赖锁/FRB/编译测试。


## 2026-11-03继续：可选Bash能力预检及失败降级源码

- 2076328已保存上述可选集成/原actor历史sink基础UNVERIFIED。本批仅显式opt-in且不附着tmux时同Root进行固定只读Bash5.1+/dev/fd探测；输出/stderr总4096字节、64消息yield、原连接Budget与通道关闭确认。明确不支持/拒绝exec时原Transport请求普通Shell，未知网络/协议结果不假装成功。
- 新Core只读integration_proof、私有HOME真实OpenSSH测试源码3项（中文实际提交、缺Bash回退保持generation、隐藏输入不收录/不回显）；输出等完整行避免只看到命令回显即通过，隐藏输入在stty已关闭回显且真实输出marker后才发送。均未运行，当前可选集成新增累计20项测试源码；实际仅格式/Bash与Rust语法/接口词法/diff。
- “缺Bash预检未接”的上一条已由本源码覆盖；后续仍是Native内存索引/候选变更失效、原actor受控Plan动作与确切回执、Flutter实时候选及IME/原视图路由、SFTP插入及空行cd。不要恢复等待Shell许可（用户已明确允许），不要标全部Windows完成或提前统一编译，Android暂停。

## 2026-11-03继续：历史候选与同源SFTP受控输入源码接线（UNVERIFIED）

- eec66c0之后本批接入原SSH actor受控动作/有界实际回执；等待在actor之外，填入等A、执行再等实际S。原代次/Proof/实际输入空行/内存许可在派发前复核；确定未发送才Unavailable，未知状态不自动重试/发送Enter。修复PS1零宽后缀判断导致重复Ready及失败回执退休问题。
- Native新增3个API（terminal_suggestions/choose_terminal_suggestion/insert_terminal_paths）、原history_gate与Vault/保存主机缓存、配置journal/导入失效、随机单次候选票据；平台仅合并数字失效事件、不发命令正文。Flutter候选独立16ms合并/单在途/首项与上下/Tab仅填/Enter点击明确执行/Esc，失焦/隐藏/历史查看/TUI/IME撤销；不改原网格绘制和原普通输入。
- SFTP同会话文件/目录/多选拖入、菜单发送/空行cd、当前目录工具栏和路径栏菜单正式接controlledInput；冻结原源代次/文件名快照，POSIX引用。仅确定未发送时安全复制降级，未知不重发，不触发上传下载、不转投其他终端。原OSC7相对路径/Phase2真实入口保留。
- 新增15项Core/真实隔离OpenSSH/Flutter候选及IME/源路径/真实Native测试**源码均未运行**。实际执行：cargo fmt、显式13个Dart format（包缓存已清，flutter_lints include未解析，不是Analyze）、bash -n、API/DTO词法扫描236函数/74结构/277个Dart源0项、diff检查；最终以本批末检查为准。旧最后完整已验证仍0e96be4，所有新增生成/编译/类型/运行/性能验证均未开始。
- REQUIREMENTS_COVERAGE生成器同步纠正候选/实际采集/路径发送及原历史搜索等旧“未接”说明，175条索引含Android和验收，不能换算成已验百分比。SHELL_INTEGRATION记支持范围和验收命令来源，不再恢复用户已解除的许可冲突。
- **继续入口**：先完成Windows全范围静态交叉审核，重点FFI/原生日志边界和真实点击路径、候选异步取消/权限及Shell兼容；再按用户策略统一依赖锁/准备本机扩展fork/正式FRB/Analyze/Clippy/构建/测试与修复。不要手改生成绑定或重复做已有模块。Android暂停，Windows实机明确待验；简单Bash末端输入/ASCII退格之外安全退化仍是支持边界，不能标全部Windows已完成。

## 2026-11-03继续：真实入口脱敏与历史清空竞争静态修复（UNVERIFIED）

- eaeca66已保存候选/受控动作/同源路径和15项新增测试源码。继续审阅发现旧main.dart原生加载异常会debugPrint正文，两个真实入口默认Flutter异常/错误Widget也可能格式化含敏感内容的对象；新增固定提示/root handlers与4类上限计数，正式诊断按原明确刷新读取/ACK清空，不记录异常对象/栈或新空闲轮询。新FRB initializer只提前原固定panic边界，不装packet日志；尚未生成所以不能声称已运行。旧验收入口关闭失败保留owner/取消退出，正式工作台退出流程未改。
- 修复清空/关闭后再开启与原actor已接受但等待SQL批次竞争：捕获原epoch，实际持Vault写入时复核；清空/开关真实变化及导入/同步退休同时推进epoch，拒绝旧批次回灌。同值开关不丢旧批次。助手补拒绝allexport和先耗尽有界包再拒绝失效Ready；管理页/COMMAND_HISTORY同步真实源码边界。
- 新增3项Flutter异常隐私/不可变计数/正式诊断刷新清空测试源码，未运行。本批实际只格式解析/Bash语法/本机SDK接口源码核对/API词法与diff，后续最终末检查为准；不依赖未生成绑定作真值，不编译/Analyze/Clippy/运行。继续所有Windows剩余源码/静态审阅，最后统一验证；Android暂停，Windows实机未验。
- 本批续补2项未运行场景源码：真实Flutter拖放拒绝异会话/旧代次并保留View身份、隔离OpenSSH的allexport降级及未创建私有环境变量。累计相对此前已提交20项可选集成基础测试，本轮新增20项测试源码（首批15、异常3、续补2），不是40项通过。最新恢复仍先Windows静态审核→最终正规生成/统一验证，不将无TODO扫描或词法0项当全功能完成。

## 2026-11-03继续：单主机清空不误丢其他主机在途历史（源码）

- 656b410保存真实入口脱敏/有界诊断及清空竞争首轮修复，UNVERIFIED。继续交叉审核将采集epoch细化到每个原Entry：清空某一主机只退休该主机的等待批次，避免丢弃其他主机已经接受的待保存命令；全局开关/清空/导入仍退休所有原owner。候选依旧以全局配置版本失效，不以此改变SSH/焦点。
- 新增1项原Native Entry归属/清空隔离测试源码，未运行。下步继续Windows源码漏项与跨层所有权复查，最后统一生成绑定/类型检查/构建/测试；源文件存在、词法0项与无TODO均不是完整功能通过。

## 2026-11-03集中收尾开始：真实依赖解析与正规FRB生成

- b42cb1b保存单主机清空/原owner隔离源码。按用户先编码后统一检查的策略，现进入集中生成/静态类型及构建测试阶段，后续发现缺陷持续修正，不再以词法扫描0项作为完成依据。
- 已真实执行固定原生扩展fork准备和Flutter pub get，新增16依赖、两锁文件真实解析更新中。FRB2.13.0正式生成正在推进，内部cargo expand发现此前纯源码审核无法确认的类型错误，已逐项修复EventListener方法约束、Drive分页Option<String>、并行cursor:usize及工具链弃用警告等；尚未称生成/编译通过。见UNIFIED_VALIDATION.md，不手改绑定。
- 所有本轮新运行测试仍未开始；最后全量已验仍0e96be4。恢复先看Git/生成命令结果，沿集中FRB→全量Analyze/Cargo/Clippy→统一测试/构建继续，不恢复逐模块验证或等待用户验收。Android暂停；Windows实机单列。当前磁盘约3GiB、单job/关闭incremental，不清理用户文件。


## 2026-11-04：全量Flutter Analyze与Rust全目标检查通过，统一测试进行中

- 正式FRB已生成，私有Default缓存/关闭状态补ignore以免暴露为调用API；纯词法无法发现的可见性与接口交叉类型均按实际工具修正。Flutter Analyze从289项收敛为0项；Rust workspace/all-targets/locked已通过（28.14s，1个无用测试常量随后删去）。这些是类型/静态检查，不是Windows实测或全功能验收。
- 已执行Python工具10项+直传/准备器协议12项共22通过。严格Clippy统一收尾进行中，后续全量Rust/Flutter/Native/GTK测试及构建尚未运行；见UNIFIED_VALIDATION.md。当前全部修改是本线程在b42cb1b之后的集中生成/检查修正，不清理/覆盖未知用户文件，提交前复核。

- 本次严格Clippy（workspace/all-targets/locked/-D warnings）已通过33.95s，Flutter Analyze仍为0项；Native debug共享库统一构建启动中。依赖/绑定现在已正规更新，旧“新增绑定完全未生成”仅是历史节点，勿重复手工造绑定。原生Bridge不再生成无使用者的staticlib，保留cdylib+测试rlib以节约磁盘；未删除已有用户构建物。

- fe79407已保存正式生成/锁更新及全量静态修正。Ubuntu debug Native库实际构建通过1m32s，统一Rust workspace测试已启动（单job、--test-threads=1）。不要在Flutter测试中加载旧库；当前应使用已匹配新绑定的target/debug/libhspterm_frb_bridge.so。Codex仅既有隔离无凭据场景，无真实付费任务。

## 2026-11-04统一运行首轮发现真实缺陷与磁盘恢复

- Native debug库已构建；Flutter统一首轮109项通过后中止，包含隔离真实Codex TUI通过，未使用真实账号。实际失败详UNIFIED_VALIDATION：Explorer离线重租、重复FRB初始化、字体关闭读取自等待、队列行高、Windows模拟全局覆盖清理；尚未全量通过。Rust所有测试已编译并开始Bridge测试，因磁盘满停止，未完成汇总。
- 已验证本次cargo/Flutter测试PID归属后停止原操作；只移除本轮25个新且未映射ELF的DWARF段，保留执行代码/符号，回收1278.7MiB至约1.2GiB；没有清理用户文件或旧构建。不要盲目重跑占满磁盘的构建；后续限制链接峰值并保存日志状态。
- 新修正未提交：backend共享初始化Future、typography.load关闭早拒、队列最小高度、窗口模拟try/finally，export_cache新目录创建0700（不能放宽现有安全检查）。Flutter定向失败回归启动；export_cache需实际新Native库与Rust回归后再全量测试。恢复先看Git和/tmp/hspterm-unified-*.log，未通过不标全部Windows完成。
- 首轮失败的20项Flutter定向回归已通过；新Native库以本包dev debug=0/strip=debuginfo构建通过37.68s，磁盘恢复约2GiB。现已重启统一Rust（四个本项目包test debug=0/strip=debuginfo，单job/test-thread）与完整Flutter（单并发）测试，日志分别/tmp/hspterm-unified-rust-tests-small.log及/tmp/hspterm-unified-flutter-tests-2.log；尚未出完整结果，恢复先确认这两个在途命令，不启动重复runner。
- 完整Flutter第二轮Explorer真实快照离线重租已通过（新0700缓存代码实际被执行），后续初始化/字体关闭/来源删除场景继续通过；完整结果仍在途。原Native生命周期测试追加并发4次+重复初始化以保护本次共享Future修复。完整Rust小调试产物构建仍在途，源/产物/测试三者不能混淆。

## 2026-11-04集中运行续修：关闭确认、Readline与Explorer恢复

- 第二轮完整Rust已跑出Bridge72通过/3失败、SSH单元78通过、OpenSSH121通过/5失败及各SFTP专项通过；storage-sync213项仍在运行，不能称整个workspace通过。第二轮Flutter在199项附近暴露后续失败/假时钟收尾挂起，已停止对应本线程runner并保留日志，未跳过用例。
- 已定位并修改：Drive取消后释放已退休操作的凭据permit（当前Rust已验）；目录并发最后释放者再次清除retired游标；tmux测试夹具补协议要求的末尾换行，不放宽解析器；测试panic仅报告源码位置，生产仍无敏感payload输出。目录/tmux修正待新Bridge测试。
- Explorer原生通道仅在在途时保留排序Future，新视图重新安装消息handler，避免静态已完成Future/已清空handler跨视图与测试生命周期；Windows测试在回调内还原platform。相关8项交互通过；连接状态3项通过。测试须正确排空假时钟和真实微任务，保留关闭完成断言。
- 受控路径动作立即退休旧候选，flushInput等待期间新增的按键也必须排空；新增顺序回归及候选/IME/键盘共5项通过。暂存确认遮挡期间不继续无限进度动画（仍禁止重复动作），3项通过。Mock远端拖动按稳定ID移除源项，原型/布局23项通过。
- 真正协议缺陷：russh本端CLOSE删除加密参数后，原接收guard误丢对端CLOSE确认，导致有界名额永久保留。双端现在只允许已有本地receiver且已移除参数的关闭确认；未确认OPEN和未知ID仍拒绝。实际迟到OPEN/取消/Root关闭及SFTP所有权6项通过。SFTP明确拒绝先返回已知错误，同时worker继续保留清理名额，不能将拒绝变成可重试超时。
- Readline多字节位置按原locale比较、wire长度按字节；bind-x重绘缓存PS1的重复R只忽略，不重置输入或恢复已退休proof。真实隔离OpenSSH可选集成7项全通过（中文、Tab不执行、显式执行仅一次、实际输入不符拒绝、隐藏输入、Bash缺失及allexport降级）。新增重复R单测待统一term-core运行。
- 本轮Flutter Analyze再次0项（4.3s）。新Native库正在重建；随后重跑完整Flutter、Bridge/term-core及Clippy与构建。旧完整已验仍0e96be4，不以局部通过替代Windows全部完成。日志见/tmp/hspterm-*-recovery-4.log、/tmp/hspterm-suggestions-regression-7.log。Android暂停，Windows实机待验。

- 续修后Bridge全量75/0（114.05s）、term-core全量42/0（6.16s）均通过，包含目录取消释放、Drive worker退休、tmux真实身份夹具和缓存R重放保护。新Native debug库已构建通过52.38s。当前完整Flutter第三轮与修正后126项OpenSSH、原storage-sync213项仍在运行；另启动真实release Native构建，不复用旧release库。新增受控填入/执行的中文+组合字符断言由本轮126项覆盖，完整结果尚待收敛。

## 2026-11-04续修检查点：并发回执与同步停用（集中验收未完成）

- 19567d8后扩大OpenSSH126项回归为125通过/1失败：真实检查在错误操作后返回Busy，已复现为worker先发回执后释放准入permit的竞争。检查和直传现在先释放已完成IO的permit再发送回执；检查两项真实回归和SSH单元78项通过。没有提前释放仍未知或在途的通道。
- storage-sync完整213项实际结果212通过/1失败（1039.22s）：未知主机字段已被更早的严格解码拒绝，但排序API错误分类与原合同不同。新增From映射保留OrderingError::Format，原数据/凭据不改，排序4项回归通过。完整原始失败不擦除。
- Flutter假时钟与真实stream/compute isolate需共同排空：新增测试专用support/terminal_cleanup.dart，必须断言真正完成/失败，仍等待Native关闭；修复应用快捷键、远端检查、候选及同步控制器的测试调度。21项交互回归通过，显示设置滚动后等待布局4项通过。文件移动测试更新为现有明确跨服中转/来源删除风险按钮，未修改正式许可。
- 同步实质修正：停用目标立即取消去抖/在途操作并推进编辑代次；定时回调和开始自动同步前再次核对授权，预留操作迟到也不得prepare HTTP。同步控制器/归档/真实加密设置18项通过（含新预留期间停用测试）。归档确认期间停止背后进度动画，操作仍禁用且原owner/token校验保留。Native设置测试统一走正式initializeRust，不依赖隐含动态库搜索路径。
- 严格全workspace/all-target Clippy再次通过（38.53s）；Bridge开发profile固定为已验证debug=0/strip=debuginfo，仅减少生成桥接层调试符号，其他core保留原诊断/发布配置不变。需在所有后续源码修正后再做最终静态检查。
- Native release构建通过6m50s；正式工作台Ubuntu Flutter release构建通过，包内Rust库与对应target/release散列一致。该包早于最新同步/归档Dart修正，最后必须重建，不能当最终包。release GTK实际启动/退出、无启动联网历史或配置库、预览run清理通过；短采样RSS339.7MiB，CPU焦点14.0%/失焦5.4%；第二次线程采样RSS349.5→356.5MiB，CPU11.4%/5.6%，主要为UI/raster/llvmpipe。尚非帧时序、长期泄漏或Windows性能通过证据。
- 构建低空间期间只清理本次release插件生成的已完成中间目录（Git忽略、mtime晚于本轮日志birthtime、无进程映射），最终bundle及旧文件保留，回收约400MiB。恢复时当前约6GiB余量，不重复清理用户文件。
- Flutter完整第三轮前52文件214项通过后，按实际中断/已通过日志恢复执行；后续分文件首批80个文件的状态写/tmp/hspterm-flutter-file-results-6.json，最后live_workbench日志已通过且无残留进程，已补记恢复结果；其中设置库/显示设置/文件菜单三项原失败已独立通过。当前剩46文件以/tmp/hspterm_flutter_remaining_runner7.py运行，结果/tmp/hspterm-flutter-file-results-7.json，每文件真实进程idle120秒/总900秒看门狗，超时记失败，不跳过当通过。旧未知exec session不重用。
- 尚未收敛：真实Native命令区间在23→65宽度变化后消失，已确认本地重排阶段仍有效，实际Bash重绘后才退休；新增实际SSH流定位，需确认该范围是否真被重绘覆盖，不能放宽proof来强行通过。纯核心81组前后长提示符、中文/组合字及23/65/17重排已通过。command_ranges_bridge_test.dart当前有临时仅数字探针，完成定位后必须移除。新openssh_ranges.rs仍是诊断回归，未宣称通过。
- 下一步继续46文件和失败修正→最终Analyze/Clippy/构建及GTK回归。Android暂停；Windows真实编译/输入/OLE/DPAPI等仍待目标平台，不把Ubuntu结果冒充Win实测。不宣称全Windows完成。

### 本次恢复与已收敛问题（2026-11-04）

- 旧工具session已失效且无测试进程；先按日志恢复，80文件记录最后live_workbench实际All tests passed，补记为恢复通过。尚余46文件由runner7继续（/tmp/hspterm-flutter-file-results-7.json），不重跑已通过文件。原三项失败已在独立回归修正，不能直接读取旧JSON就说仍失败。
- OSC133问题已定位为Bash的真实重绘改写旧输出区域：本地reflow后proof有效，后续SSH字节后失效，按旧坐标实际导出已不同于原命令输出。保留生产校验；Native正向夹具以阻塞read保持远端静止（其后仍测试断线、手动重连），独立真实SSH同时覆盖静止重排与Bash覆盖拒绝。Native1项通过5秒、实际SSH2项通过2.09秒；临时数字探针已删除。纯核心额外81组/243次缩放通过。没有改写远端数据或放松row proof。
- 远端未知RENAME恢复测试原先试图在真实元数据通道仍忙时换库，与已实现安全屏障冲突；现在验证换库明确拒绝、原检查正常完成，实际IO退休后才重开/加载任务。原来源重建保护、未知动作不得重发及旧票据失效断言保留；Native回归1项17秒通过。
- 可选Shell联想的Native夹具用合法newHostId和实际组名，原“fixture”ID被正式校验正确拒绝，未放宽生产校验；真实加密历史/单次候选/路径同源1项5秒通过。
- 当前最新Flutter Analyze 0项（8.3秒）；21项终端/菜单/输入交互及18项同步、4项显示设置已独立通过。Ubuntu正式debug工作台构建进行中；release检查点仍须在最终Dart修正后重建。剩余文件测试、完整GTK及最终资源回归尚未完成，Windows实机/Android暂缓边界不变。

### 单文件回归收齐、整套复核启动（2026-11-04）

- 分文件续跑46项记录41通过/2失败/3看门狗超时；这5个原问题均已独立修正并实测：remote_move_resolution（17秒）、shell_suggestions（5秒）、terminal_commands/paste（合并14项通过）和terminal_shutdown（4项通过）。不能把原JSON直接改成假“首轮全过”。全部142个Flutter测试文件现已有运行及修复后通过证据；为核对全套调度，额外完整flutter test单并发复核正在运行，日志/tmp/hspterm-unified-flutter-final-23.log，尚未宣称整轮全过。
- 新增SSH回归文件原放tests根目录被Cargo额外当独立binary，导致最终workspace21轮编译失败（无测试执行）。已按现有项目结构移入tests/openssh_ranges/mod.rs，父openssh模块仍正常引用；workspace完整22轮正在运行，日志/tmp/hspterm-unified-rust-final-22.log。不得忽略新增测试目标编译错误。
- 正式Ubuntu debug工作台构建成功；实际GTK启动、Native加载、无启动配置库/历史、预览缓存退出清理/正常退出通过。短采样debug RSS448.3MiB，失焦376.7MiB，CPU17.6%/7.8%；仍只是短软件图形栈采样，不等同泄漏证明或目标平台指标。
- 29个适用GTK集成文件正在按独立桌面/真实Native顺序执行，状态/tmp/hspterm-gtk-final-22/results.json；file_preview专用隔离MIME receipt，其他使用external_editor_gtk私有XDG/Xvfb。Windows DPAPI文件明确记deferred、不在Linux伪报通过。看门狗idle240秒/总1200秒记失败并继续，需后续修正，不能跳过错误。执行器/tmp/hspterm_gtk_runner22.py，日志/tmp/hspterm-gtk-runner-22.log。

### Windows Rust交叉审核收敛（2026-11-04）

- 最小MinGW工具链实际安装完成（6新增、0升级/删除）；Windows GNU全workspace/all-targets check通过2m36s。修正4处DirBuilder仅Unix才需mut、1处仅Unix父目录fsync才需File导入，未改权限或业务行为；Windows严格Clippy0警告通过41.50s，Linux全目标严格Clippy0警告通过49.62s。命令/边界写PLATFORM_VALIDATION.md，不等同Windows Flutter/C++/MSVC构建运行。
- 完整Flutter最终23轮和Rust22轮仍在途；GTK已有一个状态栏等待超时和一个真实外部编辑流程失败，需要继续修正。为定位状态栏，同一Linux build目录的GTK调度器被自有协调器暂缓推进，当前app退出后才顺序重试，无并行GUI构建；/tmp/hspterm-gtk-status-coordinator-28.log及/tmp/hspterm_gtk_status_retry28.py负责finally恢复SIGCONT。若会话/工具中断，先检查602864（必须核对argv为hspterm_gtk_runner22.py）状态T及协调器是否仍运行，再恢复该自有调度器，不能误停其他程序。

### 全量核心验证通过，桌面交互续修（2026-11-04）

- Rust完整workspace第22轮：647项通过、0失败、0忽略，28个测试/文档测试套件；其中真实OpenSSH128项、storage-sync213项（1091.78秒）。日志 `/tmp/hspterm-unified-rust-final-22.log`。Flutter完整第23轮：502项全部通过，20分07秒，日志 `/tmp/hspterm-unified-flutter-final-23.log`。两者均为完整运行，取代旧局部证据；不等于Windows实机通过。
- GTK第22轮29个适用文件：24通过/5失败，DPAPI另1个明确延期。正在依次重测失败文件，日志 `/tmp/hspterm-gtk-retry-30/`。状态栏与终端偏好夹具挂载正式App后会由真实TOFU弹窗取代原自动同意回调，现明确点击本地合成服务器的“信任并保存”，不跳过生产安全确认。状态栏重测已通过。
- 产品修正：正式WorkbenchApp原先只将初始PaletteBinding传给应用级按键路由，保存新键位未刷新。现仅在模型绑定身份变化后重建该配置，保留原Navigator/路由Key与按键释放所有权，不因每个任务事件重建。新增正式App/原Navigator/F8生效/禁用回归，5项快捷键测试通过；Analyze 0问题（4.6秒）。路由专用测试隔离Native缓存，缓存实际生命周期仍由原Native/GTK测试覆盖。
- 其余GTK失败续修：palette与排版保存滚动后等待布局，live_workbench两处旧确认文字改为正式明确中转风险文字；均待本次GTK回归，不将尚未重跑宣称已过。正式debug/release工作台必须在最后GUI测试后重建，当前debug bundle为集成测试入口。Android继续暂缓。

### Kitty修饰键所有权修正（2026-11-04）

- 实际GTK快捷键第30轮已能打开面板，但捕获到Ctrl/Shift按下后缺少释放：它们在组合键尚未形成时合法发给SSH，随后本地面板拿走焦点。现在只登记实际转发的修饰键，真实释放按原控制器/nativeID/代次返回；全局和终端事件去重，不将旧代次释放注入重连后或另一个标签。F8与面板Enter本体/释放仍留本机，不缓冲或吞掉原始修饰键按下。
- 路由/原终端/候选回归22项通过；新增切换终端与代次变化两项后快捷键文件7项通过。真实Kitty GTK第33轮通过（23秒），按确切协议字节断言原修饰键按下与释放配对，F8和晚到Enter释放均未流入远端；日志 `/tmp/hspterm-gtk-key-regression-33/palette_shortcut_test.log`。
- 第30轮状态栏、终端偏好、字体排版均通过。大型真实工作台流程已通过实际上传/重扫/重命名、4096目录、Mousepad保存及大于16MiB原始字节回传、GBK/CRLF、复制移动和递归搜索；最后预览设置保存点击发生在滚动布局完成前，已补等待，整场第36轮待重跑。没有改业务成功或风险确认规则。
- 完整GTK首轮生成的30个已完成app.dill（明确生成于该轮起止时间、Git忽略、无进程映射）已清理，回收2.335GB，保留当前构建、旧缓存、源码及所有最终bundle。
- 下一步：第33轮真实Codex/SSH输入回归→第36轮完整工作台→扩展release性能基准→最后重建正式debug/release入口及启动退出检查。全过程顺序使用同一个Linux GUI构建目录，恢复时先核对 `/tmp/hspterm-gtk-key-regression-33.log`、`/tmp/hspterm-gtk-workbench-retry-36.log`、`/tmp/hspterm-build-benchmark-34.log`，不要并发构建或交付测试入口。

### 安全扫描与最终复核新发现（2026-11-04，继续收尾）

- GTK29个Ubuntu适用文件均已有通过证据：第22轮24个，第30轮状态栏/偏好/字体3个，第33轮Kitty快捷键1个，第36轮大型真实工作台1个；DPAPI仅Windows另列，不计Ubuntu通过。第33轮Codex/SSH也再次通过。工作台完整场景已实测原预览/传输设置最终保存，合成Mousepad/SSH文件操作并非Mock。
- 新增上游补丁测试：根包vte56项通过；alacritty独立锁/本地vte补丁/hspterm-history特性下132单元+45参考记录+1文档=178项通过。原根命令不能运行有dev依赖的排除workspace包，现使用其独立manifest；offline缺旧锁依赖后正常下载，未改锁。
- 完整Flutter第37轮在途，发现tmux取消状态事件与connect Future迟到回执的文案竞争（中文取消被AnyhowException包装覆盖）。生产report现对FRB AnyhowException使用已审计message，与状态详情一致；新增两种顺序及真实tmux3项共5项回归通过（28秒）。不放宽断线/旧票据断言。原完整502通过与新一轮失败分别保留。
- Cargo audit按2026-11-03数据库发现crypto-bigint0.7.5和ctutils0.4.3分别命中RUSTSEC-2026-0387/0385；已查官方公告。最低补丁0.7.6也被撤回，因此继续选择同0.7系列非撤回0.7.10，ctutils升至同0.4系列0.4.8，无全依赖升级；最终audit及SSH受影响验证待收齐。该图仅经russh进入ssh-core/bridge，不进入storage-sync自身。旧647测试不是新锁的回归证据。
- 为隔离上述变更，**自有构建调度器650330（argv须为hspterm_build_and_benchmark34.py）暂SIGSTOP**，已启动release benchmark编译子任务允许完成，但不自动开始后续debug/正式包。恢复时先检查状态T、子编译完成和最终锁，再安排新锁Native构建/SSH回归，最后SIGCONT或更换已确认的自有调度器，不能遗忘暂停或误操作用户程序。完整Flutter37使用之前已构建Native；新锁Native/TUI验证单列，不冒称同一轮。
- Android暂缓；Windows MSVC/C++/真实输入、系统功能及真实云账号仍缺当前环境，边界不变。

### 真实工作流与输入竞态复核（2026-11-04）

- 构建调度器650330已SIGCONT，**不再暂停**；其benchmark release编译264.3秒、扩展19场景实际运行50.3秒成功；新锁正式debug57秒通过，正式release继续编译。无需再恢复该PID或重复启动旧调度器。
- 扩展基准覆盖实际Vim/tmux/htop、5万中文/组合字符行、滚动100次、Reflow、5次显式重连、5万正则与标记、负载输入、原生窗口变化、实际PTY与关闭：5.604秒空闲0桥接帧/0渲染帧、CPU0.178%；负载输入20次中位32ms/P95 54ms/最大55ms。该基准Native为安全升级前编译，记录保留为对照 `validation/windows-unified-2026-11-04/performance-before-security-patch.json`；最终新锁基准另跑，不将旧图当新图。关闭后RSS未立即下降不直接判泄漏，图形栈/分配器保留与持续增长区别列明。
- Flutter37第二个失败为Shell候选夹具在受控填入后按Enter，仅等待shellInputChanges增加就立即打前缀；重复5次重现1失败，阶段诊断确认是第二个前缀，5个输入事件。S提交回执也会增加此计数，不能当新Readline prompt。夹具现等待实际新revision的合成提示符显示，保留全部候选/清空/原会话/只填入/一次执行及错误代次断言；修后连续5次通过（5–6秒/次）。生产proof未放宽，也不靠屏幕推断真实用户输入。
- 当前完整Flutter37仍用于收集其余缺陷（原两项失败保留），最后同新锁库/固定源码全量复核将由 `/tmp/hspterm_final_delivery53.py` 执行，日志 `/tmp/hspterm-final-delivery-53.log` 和逐步JSON；等待37/34/48三个已有任务真正退出后才推进，校验安全4步和Shell5次均通过。顺序：新锁release性能→Kitty/Codex/SSH真实GTK→重建正式debug/release→全量Flutter→Analyze→双模式正常启动退出。先检查其状态，不重复执行，也不交付benchmark/integration_test入口。

### 最终固定源码/新锁回归已启动（2026-11-04）

- 98fb042为安全补丁与Readline夹具修正检查点。新锁影响范围Bridge75、SSH255全过；Linux严格Clippy56秒、Windows GNU严格Clippy53.5秒全目标0警告通过。配置/终端自身依赖图不变，之前完整workspace647项及VTE56/alacritty178项证据保留，不重复虚加总。
- Flutter第37轮真实结束：503通过/2失败，19分44秒。两个失败均已修并有独立回归，失败原记录不删。新固定源码/新Native库的完整第53轮已运行，日志 `/tmp/hspterm-final-flutter-tests-53.log`，未结束不可提前写507全过。第53轮上游新锁性能、Kitty精确按键归属、实际Codex正常/备用屏幕及原SSH/Vim/tmux/htop GTK均通过；SSH GTK20次Native生命周期RSS差值−1,314,816字节。
- 第53轮正式debug/release工作台均重建通过（5.2秒/6.4秒，缓存有效），入口 `lib/workbench_main.dart`；不再是集成测试/性能入口。最后完整Flutter、Analyze和两模式正式正常关闭smoke仍由53号执行器顺序完成，状态 `/tmp/hspterm-final-delivery-53.json`，不得启动重叠GUI构建。
- 新锁19场景release性能基准49.2秒通过，原始聚合数据 `validation/windows-unified-2026-11-04/performance-after-security-patch.json`。5.603秒空闲0桥接帧/0渲染帧、CPU0.178%；5万Unicode行1.716秒；负载输入20样本中位30ms/P95 46ms/最大53ms。普通命令往返回显中位53ms/P95 78ms。软件图形栈高输出raster P95约90ms、负载约47ms，不能宣称60fps实测通过；后续Windows GPU/字体/IME与长时资源验证仍单列。峰值和退出后RSS不独立等于泄漏，实际租约/历史清理及重复生命周期分别验证。

### 2026-11-04再次恢复：53号进程已退出，按458项继续

- 用户继续时当前UTC08:48，53号及Flutter进程均已不存在；日志最后UTC04:50的editor_bridge第四用例开始处中断，无异常结尾。已确认Git仍25b4da2、工作区干净，未重新覆盖任何源码。该轮458通过/0失败属于未完成运行，不能记整轮通过或推断用例超时。
- 已按已加载文件和后继用例记录恢复，最后editor_bridge未确认完成，必须重跑该文件；其他尚未加载文件继续。清单 `/tmp/hspterm-flutter-recovery-56.json`；此前构建/新锁GTK/性能证据保留，不能盲重启53号所有构建和已通过文件。之后补Analyze/正式双模式smoke及产物散列，最终归档续跑结果。

### 最终收齐（2026-11-04）

- 最后20文件52项全部通过；按已完整文件455项去重，共507项、143文件。editor_bridge全5项重新验证成功，未用中断前3项重复虚增数量。第57轮最终Analyze仅发现测试夹具一条if缺花括号的info，修正后Analyze0项、Dart305文件格式0变更、Rust格式及正式双模式smoke全通过。
- 新锁性能/GTK/构建、补丁影响范围330项和全部静态结果已归档。正式debug/release正常退出、预览run0残留、库散列匹配；代码与记录即将创建最终收尾提交。当前环境仍无Windows exe/zip，构建方案保留，不用Linux bundle冒充。
- 只清理本轮已完成GTK的中间app.dill和本轮独立上游测试target（生成时间/Git忽略/任务完成已核对），最近回收358,861,306字节；未清理用户未知缓存、源码或最终包。当前约1.2GiB余量。

### GitHub Windows自动构建接入（2026-11-04，用户已授权上传并触发）

- 远端私有仓库hspmanbu/hspterm原main仅f339db5初始化README；已以正常无关历史合并保留该提交及原简介，本地完整历史未改写，不使用force push。origin为无嵌入凭据的HTTPS地址。
- 新增.github/workflows/windows-build.yml：main源码push及手动触发；Windows Server2022 x64/VS2022、固定Flutter3.47.7/Rust1.99.1、FRB2.13.0/cargo-expand1.0.127；依赖工具缓存、90分钟限时/同分支单任务；checkout不保留凭据，作业仅contents读取权限；完整程序目录作为14天Artifact，不上传Vault或用户配置。
- Windows CMake与脚本统一显式MSVC target/target-dir，避免重复构建及DLL源不一致；打包增加来自已安装VS的x64 CRT DLL，避免目标用户必须安装VS。新增实际窗口启动/正常关闭检查，不能当Windows11键盘/IME/OLE/DPAPI验收。
- 已用actionlint1.7.12实际验证工作流0项（修复job env非法runner上下文）；固定所有Actions到官方tag对应commit。历史3692个文本blob检查未发现GitHub/云API Token及本项目私钥；仅vendor/russh两个上游公开测试向量含私钥正文，许可证/补丁说明保留；无敏感形状配置文件、无>=95MiB blob。
- 当前尚未push或取得Windows构建结果；下一步正常推送main，读取Actions run并修复真实编译/启动错误，记录run URL及Artifacts。不要把这段源码检查当云端构建通过。

### GitHub源码已发布、Windows首次云构建运行中（2026-11-04）

- Git smart HTTP四次返回GitHub服务端500（含HTTP/1.1、非分块及不带workflow的源码提交），远端main均未变化；本地fsck仅存在正常dangling对象，无对象损坏。改走Git Data API分批上传当前源码，98个二进制/大blob逐项SHA校验、15批树对象，最终树5df5ed9811ba1b6eaba89f87ecf7a7dd772edb8f与本地2bd78bb完全相同，随后非force/原head租约更新main。
- GitHub当前源码快照25ca3a8b85b4fc8d13d5c4f5a5769afaf6496001，父提交仍为远端原f339db5。完整本地开发历史保留在development-history分支（2bd78bb含与原仓库初始化历史的合并）；本地main现追踪origin/main的源码快照，文件内容完全一致，没有重写/删除旧历史。远端目前未上传此前所有开发提交，不能把本地旧hash链接当GitHub已存在提交。
- push事件已自动触发Windows x64 build，run41811094676： https://github.com/hspmanbu/hspterm/actions/runs/41811094676 ，job126510236025。截至本记录，checkout/Python/Flutter/Rust MSVC/缓存准备通过，正在首次安装固定桥接工具；尚未完成编译或产生可宣称通过的Windows包。
- GitHub连接器可查询作业/日志/Artifacts，但不提供本次push run列表和批量大文件上传接口；这两项使用本机现有Git凭据在内存调用GitHub API，不写入/打印令牌。/tmp/hspterm_github_ci.py可读取run/手动dispatch；/tmp/hspterm-github-import-state.json仅保存对象SHA/状态不含认证。已经发布，不能盲重跑旧import脚本覆盖新main。
- 接续：优先读取上述run/job状态及首次Windows编译失败日志，自主修复普通编译/打包/启动问题；最终Artifact名HSPTerm-windows-x64，下载解压即完整Release目录。仍不将Windows Server2022基础启动视为Windows11键盘/IME/OLE/DPAPI验收。

### 首次Windows Actions失败与修正（2026-11-04）

- run41811094676已实际结束失败；Python/Flutter/Rust MSVC/两桥接工具及Windows/VS doctor均通过。失败发生在正规FRB生成的compute_mod_from_rust_path：显式相对rust_output变为普通D:\a路径，而规范crate-root是\\?\D:\a，strip_prefix报prefix not found；尚未编译C++或产生程序包。不是Android doctor的Java/许可证提示导致。
- 已核对FRB2.13.0原始rust_path_parser.rs：省略rust_output时从已经规范化的crate-root生成同一src/frb_generated.rs，避免两种Windows路径前缀混用。现使用该默认值，不跳过生成、不改生成文件、不升级FRB。
- 加入Bash内嵌rcfile的text/eol=lf属性；用core.autocrlf=true实际检出过滤模拟，普通Rust文本转换CRLF的同时Bash正文仍与Git blob逐字节一致，bash -n通过。避免Windows客户端将CRLF载入远端Bash。
- Rust缓存改独立restore/save，失败时也保存已编译工具和依赖，避免后续修复反复冷编译；workflow增加.gitattributes触发。准备提交并运行第二轮，首轮真实失败保留。

### Windows第二轮云构建已触发（2026-11-04）

- 修正已发布为1aef4b9c6bc93db5f0019f47c19fec618e6c040a；远端树9b9192f4c38a624a3d363b940a48b7d957446921与本地修正6c4e17c完全一致，父提交411f60c保留。小文档提交可正常Git push，含workflow的push仍500，故使用Git Data API与连接器非force租约发布；本地修正历史额外保留在ci-attempt-6c4e17c/ci-local-fix。
- 第二轮run41813471598/job126518251196： https://github.com/hspmanbu/hspterm/actions/runs/41813471598 ，已实际启动，待工具安装、正规生成/编译/分析/基础窗口启动结果。当前无可宣称成功的Windows可分发包；后续恢复直接查询本run，不重复导入源码或触发重复runner。

### 内存修正已发布并触发Windows构建（2026-11-04）

- 本次修正已发布df2fd9ef93ecf65efc4840cb3e879ec0d94e67aa，树773d00e33f0954b484167f0b26f4a503d192b591与本地ebe0aaa完全一致；API保留原父提交0b9b170并以预期head非force更新。本地额外历史在settings-memory-local-ebe0aaa，main跟踪远端且工作区内容一致。
- 新Windows run41820174611已实际运行： https://github.com/hspmanbu/hspterm/actions/runs/41820174611 。等待正式生成/构建/Analyze/19组件测试/启动退出；成功程序包仍叫HSPTerm-windows-x64，新增windows-startup-memory为锁库首屏三个工作集/专用字节样本。尚未宣称本次Windows构建通过或用户Win11设置页实际降幅；恢复先查看该run，不重复构建旧源码。

### 七项反馈修正已发布并触发Windows构建（2026-11-04）

- 源码已发布165ae67579eae165968bd84331263cd6a7f1d433，树4c248f1b76426edc8adde22e12a15780f353e629与本地f4cd1a7精确一致；18个PNG blob逐项Git SHA验证。保持原4e32c28父提交、预期head非force发布。完整本地源码提交仍在windows-feedback-local-f4cd1a7，main与远端同源码。
- 新Windows run41849076983已实际启动： https://github.com/hspmanbu/hspterm/actions/runs/41849076983 。作业增加当前View ID/IME逻辑、目录大小和路径保护组件测试；等待MSVC构建/Analyze/组件/基础窗口启动结果。成功主包仍HSPTerm-windows-x64；Windows11实际文字/中文IME仍须用户复测，尚未冒称通过。
- 本轮103组件、7个不同GTK、九分类两尺寸18图、最终Analyze0项/格式0变更/actionlint，正式debug/release最终构建和真实窗口启动/退出0及预览run0均已归档validation/windows-feedback-2026-11-04。补修加密页间距后的最后GTK/两模式构建也真实通过。没有在途本机编译或未完成的本机测试。
- 仅移除了本轮已完成测试且Git忽略、时间/入口已核对的10份app.dill中间输出，保留正式debug/release包、源码和未知缓存；硬链/保留块可能影响实际磁盘释放，不把逻辑文件字节数冒充实际可用空间。
- 恢复直接查看新run，勿重跑旧Git导入脚本或还原旧分类未保存弹窗；第3项仍必须逐主机主动启用，不删除输入安全保护。
