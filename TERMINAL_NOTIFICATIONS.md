# 终端通知（Windows优先，静态源码检查点）

本批尚未解析新依赖、更新锁、生成桥接、编译或运行测试。下列是源码行为及待执行验收，不是通知送达报告。Android暂缓。

`term-core::notifications`统一消费BEL、OSC9文本、OSC777的`notify;title;body`以及显式配置的本地输出规则。OSC9数字子命令（如进度9;4）不当作通知；正文中的字面分号保留，严格UTF-8及长度限制，畸形/未知子命令不执行也不打印其内容。新Event的Debug不带正文。通知不回复PTY、不执行命令、不打开URL、不读网页、不改变真实网格/历史/复制/导出。

配置向后兼容加入原`config-terminal-preferences-v1.notifications`；旧记录缺字段使用默认。沿原Vault实例/修订/事务CAS、预编译后发布、备份/同步候选验证，不另存明文设置。默认开启终端信号但仅后台提示，当前焦点提示、桌面提示、远端正文预览、匹配规则及静默均须显式开启或配置。正文预览关闭时Rust就删除标题/正文，不把完整输出传到Flutter再隐藏。

每终端最多每250ms一条、16条待处理；16项散列在5秒内去重，最近列表不存正文。规则最多16条、每条256 UTF-8字节，关键词或Rust正则、逐条大小写。正则程序256KiB/DFA64KiB/嵌套32上限。普通屏幕明确启用规则才分配4KiB片段缓冲，在CR/LF结束时匹配；跨SSH读取与自动换行保留，超长片段及备用屏幕不匹配。规则针对显示字符流片段，不声称重建任意CSI覆盖编辑后的完整逻辑行，也不扫描历史。通知正文再裁到128/512字符、剔除控制和Bidi格式字符；原终端字符不裁。

静默0关闭，否则5–86400秒。每个输出批次重设一个单次deadline，SSH actor与同步输出共用最近deadline，无输出且功能未启用时无定时器。触发一次后撤下，下一批输出才重新计时，断线取消；新PTY先冲刷旧同步输出再清旧通知，避免跨代次归属。

Bridge只使用既有结构化事件流，新通知和策略事件均绑定原代次及进程内策略ID。设置更改/恢复会退休旧策略；旧排队事件、Flutter迟到投递、通知点击都须复核。Controller.notices独立通知器不请求终端帧，不经整个工作台绘制链。Hub持有应用生命周期和真实会话订阅，不因不可见窗格卸载停止消费；关闭标签、重连及分组移动不会把通知交给另一个会话。应用内最多250ms一条，Windows桌面每秒一条、最多16个短期候选，使用单个OS通知槽。

Windows投递使用固定`flutter_local_notifications_windows: 3.1.1`（BSD-3-Clause）。本应用首次合格且已开启的后台桌面通知才初始化通知身份；Flutter生成的Windows插件registrant可能提前载入DLL，这不等于注册本应用通知身份。Linux仅应用内提示，不构造FFI插件，不将“Unsupported”当作桌面投递成功。失败固定中文提示，不输出Native/远端正文。单实例初始化Future保留结果/失败，避免通知风暴重复分配Native对象；初始化失败后可重启应用再尝试。

通知点击的payload仅本次进程随机nonce及原会话数字身份，不保存地址、路径、命令、密码。只定位仍存在、原代次/策略有效的标签，明确点击才请求已有窗口恢复/激活；Windows拒绝前台激活则明确告知，不修改系统前台锁规则。应用关闭后不会根据旧通知恢复SSH。无系统托盘或额外主窗口。退出先停候选并等真正投递Future，取消退出可恢复，不以取消Dart Future冒充已释放。未打包Windows不能保证撤回已展示的通知，本模块不承诺取消OS通知中心历史。

SFTP成功、失败及传输任务均无此通知类型/订阅通路，仍仅应用内队列状态。

待统一执行：

1. 依赖解析/锁更新、FRB正规生成、完整Rust/Flutter编译/Analyze/Clippy/原回归。
2. Core引擎3项及`crates/term-core/tests/notifications.rs`2项：预算/去重/隐私、静默单次/重置/断线、规则边界、分字节Unicode/分号/进度隔离、自动换行/备用屏幕/超长片段。
3. 存储旧JSON默认/原加密仓库往返1项；`test/terminal_notifications_test.dart`5项模型/原策略及代次/前后台/迟到投递与退出等待/设置草稿。
4. `test/terminal_notifications_bridge_test.dart`1项私有真实OpenSSH：隐藏时OSC和实际5秒静默，不拉帧、SFTP无通知，明确关闭后通知停止且原SSH身份保持。只发合成输出，不用账号或OS通知接口。
5. Windows11安装VS桌面C++/ATL/WinRT并运行`tools/build_windows.ps1`，确认通知DLL打包。手动开启桌面通知，失焦窗口发送合成BEL/OSC9/777、去重/规则/静默、关正文预览/系统勿扰/关闭开关、拖动标签及点击定位、最小化恢复/拒绝激活、退出中在途工作、旧进程通知不重连。Windows实际投递/系统策略/点击回调尚未验证，Ubuntu结果不能代替。

实现参考：[iTerm2通知序列](https://iterm2.com/documentation-escape-codes.html)、[Contour序列索引](https://contour-terminal.org/vt-sequence/)、[插件维护者文档](https://pub.dev/packages/flutter_local_notifications_windows)、[Windows前台激活限制](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)。本批只读检查了固定版本公开包源/API，没有在Windows注册通知身份或访问任何用户账号。
