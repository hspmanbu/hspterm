# HSPTerm 开发恢复进度

## 当前状态

- 工作目录`/opt/hspterm`；V1.4及后续明确修订为唯一产品基线。一个标签一独立SSH/PTY/SFTP；布局不拥有连接。
- 连续开发全部Windows/Android功能，不按阶段等待验收。用户偏好成批静态编码和跨层审查，再集中编译/修正/回归；未验证源码不得称完成。缺实机只阻塞相应验证。
- Phase1/2 Ubuntu基础验收及Phase3A修订原型已完成；正式业务仍有大量待办，不能称完整交付。完整175条覆盖见REQUIREMENTS_COVERAGE。
- 恢复先读AGENTS、完整V1.4、本文/覆盖及Git状态和近期diff，核实在途日志，不清理未知修改、不重跑一次性脚本。旧过程和各节点证据见docs/history/PROGRESS_2026-10-27_OSC8.md及其引用。

## 最近稳定提交

- `909b002`明确重连转发恢复/加密规则草稿CAS/临时回环链接；`093ab2a`全局SSH默认和独立ACK心跳；`c21a9fb`受控OpenSSH导入；`c04531b`有界显示增强及真实选区保留。
- `3d2e024`ring RSA签名/应用内Agent核心/发送ACK额度竞态；`66eca8b`正式Agent主机/票据/确认撤销/独立推送；`5179749`RSA主机验签/重协商保护/有界PEM导入。
- `bf00066`原Transport身份回执/代次与跨库主机指纹确认保护；`115c24e`真实未读PTY阻塞SFTP复现和消费窗口修复。
- `a46da7e`正式主机单次临时地址/端口/用户/一种认证覆盖，原Vault/主机/跳板元数据前后复核；不改保存凭据、不回退。断线重新确认新秘密，临时Root排除未来历史收集。详TEMPORARY_CONNECTIONS；Rust30/全Flutter213/GTK通过，三张PNG及正式双模式包已验。
- 本批OSC8稳定提交号以git log核实；代码/测试/包如下。

## 本批完成：OSC8及滚动溢出修复

- 原Hyperlink共享属性→Snapshot→有界每变化行物理列span→Controller→既有hover/Ctrl+Click/本地菜单/原会话确认/临时回环转发；文字/宽字/组合字/选择/搜索/导出不改。普通及OSC8 URL统一拒绝C1/双向控制，显式不安全目标不回退激活伪装标签。
- URI/id保留前4096/1024 UTF8字节；桥接64K单元/2048段/256KiB预算，超限只屏蔽链接。冷历史/重排沿用原加密单元，不同步/备份。当前只激活HTTP(S)，远端file URI及Android长按仍待补。详OSC8_LINKS。
- 新冷历史测试真实复现Grid.display_offset+i32::MAX溢出，已饱和运算修复；另复现旧VTE把40分号目标截为前14段，已保留URI尾分号、完整ST/BEL、取消专用discard及分配前UTF8/长度检查；无部分目标/旧目标继承，不改OSC7/133或OSC52预算。
- 首轮workspace到新冷历史测试失败（exit101），此前Bridge32/SSH185/存储80及term已有项通过，不能写成该命令全量成功。修复后**完整term-core58、VTE56、frame3通过**。最终Native/真实Codex输入8项27秒通过，20次Native生命周期RSS差425984B仅短样本。日志.local/osc8-final-*、osc8-protocol-native-final.log。
- 新解析补丁前**全Flutter217项5:37通过**；新补丁后Native/输入专项8项、最后普通/OSC8 URL组件5项通过。最终真实GTK hover/点击9秒、原OSC8回环链接→确认/取消/转发/失败局部清理13秒通过（osc8-last-{gtk,forward-gtk}.log）；假浏览器只记URL，实际转发用本机回显，不访问外网。真实Codex仍隔离HOME/CODEX_HOME和本机合成provider，不用真实账号/付费服务。
- 同一次Flutter命令第二GTK runner曾未启动，已改逐文件独立私有桌面；新增取帧曾因无View而hidden超时，夹具明确设可见取帧后再隐藏，未改变产品隐藏零帧规则。失败日志保留；不把这些先前失败隐去。最后Analyze/all-target Clippy拒绝警告/NDK25/API26共享核心check通过，不是APK/实机。
- 正式debug/release已重建workbench_main并各自实际窗口启动/resize/正常关闭退出0，无历史/编辑工作副本/preview残留。SO同模式匹配：debug`03ea098768d573ecd8615aa15fb6486e54a3793350522bf62deb1e31e8514443`；release`f42f6b8fcdacf2585ecf0596d471d4cd3d84b798be2a9c61b87d595dc77c5d5c`。72736管道已退出0，不再等待。
- 原始短样本validation/phase3b/osc8-startup-*.json：release RSS341303296B/5秒聚焦CPU13.20%，失焦341643264/6.20%；debug504246272/48.40%，失焦509276160/6.20%。失焦开销仍待定位，不能从短样本宣称优化或长期无泄漏。前批数据均保留。

## 下一批入口与未完成项

1. 网络：可选tmux寻找/明确附着/单控制端与只读观看/控制端尺寸锁、按配置明确重连恢复及完整未完成任务恢复。已实现代理/跳板/转发/心跳/Agent/临时覆盖不重做。当前tmux3.4，已查官方手册read-only/ignore-size；尚未写tmux新代码，不把讨论当实现。
2. 终端：可靠OSC133 C/D保留历史范围及导航/复制；可验证普通Shell本地输入追踪、合格单行历史加密/关闭/清空及同步候选、十项安全路径发送；现有OSC7跟随/选区定位已接。OSC7/133不能单独证明可安全编辑，禁止盲Ctrl+U/Backspace/TUI注入。字体/通知/OSC8远端file URI/更多path:line/命令面板等保留范围。
3. 文件：文件内并行、直传、跨服务器剪切、暂存安全清理/编辑保护、完整任务恢复；主机高级批改/排序。现有真实传输/移动/编辑/书签/文件搜索勿重复。
4. 安全配置：完整加密备份/原子合并恢复、WebDAV/Drive端到端同步/冲突、DPAPI/Keystore；仅正式catalog/独立凭据/允许设置/书签/合格历史，排除草稿/布局/设备任务/正文/滚动历史/临时秘密/Agent授权票据。凭据恢复须在原Vault临界区撤销关联Agent。
5. Windows原生窗口/Explorer拖放；Android独立全屏UI/SAF/IME/触控/扩展键盘/前台服务及APK。Ubuntu不是目标设备验收；物理Windows/Android按用户边界暂不做，其他编码/交叉检查继续。

## 可复现执行与恢复

- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；导出CARGO_INCREMENTAL=0、CARGO_BUILD_JOBS=2；同一时间仅一个重构建管道。磁盘曾仅余0.5GiB，用cargo clean --profile dev -p hspterm-ssh-core只清已完成的构建缓存，当前约0.9GiB；勿删用户文件/历史性能基线。
- FRB2.13正规生成后cargo fmt，不手改生成文件。正式入口ui_flutter/lib/workbench_main.dart；Phase2 lib/main.dart及独立Mock prototype_main.dart保留。GTK会覆盖debug runner，交付前重建正式入口。
- 运行：cd ui_flutter && flutter run -d linux --release -t lib/workbench_main.dart。GTK使用benchmark/external_editor_gtk.py，每个测试文件单独私有桌面调用；双包独立启动见benchmark/workbench_smoke.py。
- 旧integrate_agent_*、integrate_temporary_*及其他一次性脚本已执行，不可重跑。connection-receipt-static/session-flow旧副本不可覆盖正式源码。

## 在途静态批次：可选tmux（未接入/未验证）

- 新crates/ssh-core/src/tmux.rs：专用消费窗口exec/完整ACK+ExitStatus+Close/总stdout+stderr64KiB、最多256项、服务器PID+ID+创建时间、Base64名称和UI控制字符转义；未选择不附着。只读-r含ignore-size，控制接管-d须明确风险确认，新建不用-A，不复用用户自定义命令或向PTY注入。
- 类型化Policy/Request/Choice、原连接取消/关闭等待、用户选择不消耗网络Budget、服务器内条件核对后附着及3项测试源码已编制。**尚未mod注册/Stage与SshError接入/认证-PTY流程接入/FRB/加密主机/正式UI/真实隔离测试，尚未编译，不能称tmux已支持。**
- 下一步成批完成上述接入及每连接尺寸/只读状态；控制接管会分离其他客户端（含观看端），UI须明确告知。测试只能使用明确隔离的TMUX_TMPDIR/socket并在任何tmux操作前核对，不能触及用户默认tmux服务。官方3.4手册已核实-r等价read-only,ignore-size及-d行为。d8b830e仍是正式已验证包。

tmux静态批次继续：已mod注册、Stage/安全错误类型、ConnectConfig默认None、认证后专用发现/原Root取消或Handle结束的明确选择、PTY exec与普通Shell二选一、新连接回执tmux状态/初始尺寸锁已编码。普通连接接口保留，跳板/代理凭据在认证完成后选择等待前释放。尚未编译/真实验证，FRB/主机开关/正式选择器及隔离服务器测试仍待接；当前d8b830e正式包不含这些修改。

下一次恢复特别注意：tmux.rs已注册到正式源码但整个新批次尚未编译；不要交付未验证包。新ConnectConfig.tmux默认None，新的ConnectionReceipt.tmux带实际启动模式和初始尺寸锁。接下来优先完成FRB/主机配置和正式选择器、真实独立TMUX_TMPDIR验收代码，统一生成/编译/修正。发现列表使用base64/tr承载名称，不把任何会话名称当命令；版本/列表不可用明确报告，只有用户明确选择Shell才启动普通Shell，不自动降级。

tmux正式静态链路继续：加密HostRecord/HostConfig与主机终端页开关、Route一次快照、原Attempt Registry/元数据读取及一次回答、Vault切换/取消/关闭失效、watch独立事件、Controller默认取消/重复token去重、原Controller生命周期绑定选择弹窗及共享确认队列已编码。专用列表名称Base64/控制字符转义，初始PTY尺寸在Prompt显示，接管风险明确勾选，普通Shell需明确选择。尚未正规生成FRB或编译/运行；真实隔离端到端及回归测试还未编制。接下来先静态审查lib::connect与Dialog生命周期/来源作用域并补测试，再统一生成构建。勿把当前源码或过期稳定SO混用。

tmux批次新增两项真实Rust OpenSSH测试源码：先证明独立TMUX_TMPDIR及无继承TMUX再做任何tmux动作，所有本机建/查/清理都明确-S私有socket；控制/只读输入、观看尺寸不参与、显式接管、取消/无风险确认不回退、等待3秒不消耗2秒网络Budget。尚未编译或运行。列表名称改为直接Base64编码再只移除协议自带的一个换行，避免Shell命令替换丢掉真实尾换行；静态复查修正了core Policy发送端正常关闭不能使原connect Future误报失败的问题。剩余：核心/存储/票据/组件/Native/GTK测试代码及实际tmux状态/重连尺寸锁验收，再统一生成检查。

tmux静态生命周期审查：Controller新增独立closingChanges信号，专用于源绑定弹窗退出，不在dispose中触发整棵终端重绘；选择窗监听原id/代次/Connecting及关闭信号，精确移除自身Route，不误关后来弹窗。主机Metadata开关/UI/票据都已接入源码，但生成绑定/实际编译和本批全部测试仍未执行。后续必须补关闭中选择窗、重复事件、切Vault/迟到回答/普通入口保留和ManagedSession锁尺寸等测试，不能把上一稳定包测试当本批通过。

tmux初始状态已接原回执→Registry→独立tmuxState事件，Controller按原代次显示只读/控制，非渲染帧轮询；工作台状态标签明确模式，普通Shell保留原标签。选择弹窗改为只依赖原TerminalController并在Phase2 main.dart亦安装入口，不把主机开关打开后的Phase2入口变成静默取消。尚未生成/编译验证。补独立关闭信号、提示可能先于状态事件的原生验证及同步、迟到回答只取消且不把旧错误写到新代次的静态保护。按配置无提示恢复先前tmux仍待实现，本批当前为明确连接/手动重连逐次选择，不能标完整3.2恢复条目完成。

tmux静态批次已补：Bridge原Scope/一次回答/旧Owner不清新请求/Vault重开及错误密码测试，存储旧字段兼容/加密开关测试，Flutter名称/控制风险/关闭源/重复与迟到事件4项，Native真实锁定与解除/原SFTP/手动重选/切库取消2项，GTK真实确认和2张合成截图测试源码。测试夹具唯一私有socket、先证明远端环境，base64还原仅移除tmux输出协议的一个LF；初始化失败也关闭已建私有tmux服务。均尚未编译/运行。下一操作是最终静态差异审查、正规FRB生成、集中编译和全部修正，禁止用d8b830e旧SO跑新绑定。

tmux静态批次主体完成：核心3项/真实OpenSSH2项、Bridge作用域1项、存储兼容1项、Flutter4项、Native2项、GTK1项测试源码。已复查元数据通道关闭竞态、初始/增量运行模式事件、异步状态先后及旧回答错误不得污染新代次、Source关闭精确移除弹窗、原Phase2入口复用选择器、测试环境必须先真实核对私有TMUX命名空间。下一步集中FRB生成和编译/运行修正；尚未执行任何本批编译或测试。无需重跑OSC8旧管道72736（已0结束），d8b830e仍是上一稳定提交。

tmux首次集中结果：FRB正规生成及Analyze已通过（7处新增curly格式已修）；Rust核心3项/存储加密兼容1项/Bridge原作用域1项通过。真实OpenSSH测试首次编译发现夹具resize误用了4参数（核心接口仅列/行2参数），已按原接口修正；未进入真实tmux断言，不能标通过。继续原管道从openssh专项开始，不重跑已通过的独立单测。

本轮恢复已确认29616管道实际完成：openssh-3两项、Flutter/Native专项10项23秒、GTK一项11秒通过；预检/实际输入与resize及服务器只读标记均验证，截图已查看并保存validation/phase3b/tmux-{consent,active}.png。原始20次Native生命周期RSS差716800B仅短样本。首次全量Rust因openssh_tmux.rs被Cargo额外发现为独立目标而编译失败，改用既有子目录mod.rs结构后继续，不删断言。仅清理已结束的dev构建缓存释放磁盘至2.2GiB，无源码/用户文件/性能基线删除。当前94601统一管道执行workspace-2→all-target Clippy→Native→Analyze→全Flutter；必须读取日志确认结果，尚不能标全量通过。TMUX.md及覆盖/AGENTS已更新，按配置重连恢复仍明确待做。

94601实际结果：完整workspace所有测试通过（Bridge33/Core51+真实OpenSSH104及SFTP/窗口等、存储81、终端核心与集成共58；总数待汇总，以日志逐项为准）。随后Clippy发现is_multiple_of、两处可折叠if和测试模块后定义项，已按提示修正，无allow放宽。新增Native测试真实复现等待tmux选择期间已resize本地后成功连接仍回退旧PTY尺寸（tmux-resize-before日志）；Controller已在每次进入Connected时补发一次最新布局，保留Rust尺寸锁、去重重复状态，不作周期查询。首次修复后达到132×36客户端，但夹具误以tmux window_height含状态栏，实际132×35，已修正该物理含义断言；仍需全量实际验证，不能写该次命令通过。新增重复Connected/空闲不resize和新代次再同步测试。6840当前正规生成→Clippy3→Native→Analyze→全Flutter，不重跑已结束94601或旧管道。

本批最新事实：完整workspace为362项通过；Clippy3与Analyze最终通过。新增尺寸Native先真实失败、修复后夹具行数需扣tmux状态栏，最终tmux_choice+tmux_bridge共8项24秒通过。第一次全Flutter新增Fake时钟测试挂起，主动终止该自有测试进程并保留tmux-flutter-full-first日志，不能记全量通过；改为普通有超时真实时钟测试后当前81568重跑全Flutter2→NDKcheck→独立GTK→正式debug/release及独立启动。磁盘曾0余量，已只清理已完成Rust测试可执行缓存18个/948275120B，保留Native SO/源码/数据，约1.5GiB可用，日志尚无ENOSPC断言失败。按配置tmux恢复仍未做。
下一独立静态批次草稿暂存.local/command_history.rs（尚未入mod/编译，不能当已实现）：加密有界仓库、原主机ID/原Vault内存匹配、保守敏感过滤、主机/全局清除epoch及过期设备载荷抑制、CAS原子保存和9项测试源码。此基础绝不主动采集输入；可靠Shell输入证明/实时联想UI/同步网络尚未接。完成本批稳定提交后再提升草稿到正式模块集中验证；不要用一次性脚本覆盖已有正式源码。
