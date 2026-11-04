# HSPTerm 开发恢复进度

## 当前阶段与执行方式

- 工作目录/opt/hspterm；V1.4及后续明确修订为唯一基线。一终端标签对应独立SSH/PTY/SFTP，SplitTree只组织TabGroup布局。
- 持续完成全部Windows/Android功能，不在阶段/UI验收边界停下。按依赖批量静态编码与跨层审核，再集中编译、修复、测试；不每个小改动反复全量构建。没有平台设备只阻塞对应实机验证。
- 新会话先读AGENTS、完整V1.4、本文和REQUIREMENTS_COVERAGE，检查Git/近期提交/未提交diff与在途日志。保留未知修改，不盲重跑一次性脚本。
- 当前Windows真实业务整合已完成SSH路由/转发/网络默认、受控Config导入和本批显示增强。其他完整功能仍有大量未实现，不是可最终交付的完整应用；Android专用业务与Windows原生也仍待开发。

## 最近稳定节点

- 909b002：明确手动重连后的可选L/R/D恢复与局部失败、加密规则草稿/CAS墓碑/原子提交、终端链接确认临时回环转发；289 Rust/186 Flutter/GTK/NDK/双模式包。
- 093ab2a：加密全局SSH时限/心跳默认与主机继承/覆盖，独立真实ACK响应超时及0关闭；294 Rust/188 Flutter/真实ACK停流重连/GTK/NDK/双模式包。旧主机false/None保留旧策略，不热改Transport，不自动重连。
- c21a9fb：用户显式UTF-8文件或文本→有界OpenSSH Config解析/逐项预览与警告确认→原子正式元数据导入。首值/Host通配否定/单跳依赖，旧Vault/同名拒绝；不执行Match/ProxyCommand、不展开Include、不读IdentityFile秘密；缺凭据须明确配置后连接。300 Rust/192 Flutter/GTK及正式包见OPENSSH_IMPORT。
- 本批显示增强的最终提交号用git log核对；以下为已执行结果，不将Agent静态源码计入功能。

## 本批显示增强：实现与验证

- term-core::decorations只读Snapshot，Bridge仅派生RenderFrame颜色/下划线；原始SSH、终端缓冲、搜索、复制和导出不变。变化的可见行计算；远端ANSI/DIM/反色优先，明确force另处理；备用屏幕默认停用。
- 加密DisplaySettings全局/主机覆盖、修订墓碑/CAS、旧Vault作用域拒绝；主机复制草稿/丢弃/删除同事务。连接准备在Vault门控内绑定策略，避免迟到旧准备覆盖新Save；previous→display锁序，无锁跨SSH await，不重连、不触发隐藏取帧。
- 正式设置页支持关键词/正则、前景/背景/下划线、规则启停/编辑/删除/顺序/匹配测试/受限JSON预导入；窄窗操作菜单。同词只读完整单行选区，当前可见区精确匹配/大小写、宽字符/组合文字映射、隐藏文本拒绝；缓存按Controller/帧计数/选区，不随光标闪烁重算。
- 规则最多32、源模式512字节、编译/状态各64KiB、单行8KiB/帧文本128KiB/16Ki绘制单元/每行每规则128匹配；每帧8ms预算在有界匹配边界检查，非硬实时抢占。超限只跳过装饰，不丢字节。测试样例按行，文本/次数/时间超限明确报错，不给虚假计数。
- 完整预算快照Rust308项/Flutter198项（4:47）通过；随后仅测试样例语义小修，Core6与Flutter/真实SSH6项13秒补验通过，未把预计309称全量。Clippy all-targets拒绝警告、Analyze、格式、NDK/API26 aarch64共享核心check均通过。
- Native验证真实SSH/ANSI优先与强制、原始导出逐字不变、无SSH输出更新、隐藏无帧、原代次/旧Vault拒绝与按行样例。GTK真实设置/主机继承/SSH绘制16秒通过；三张display-{settings,host-inheritance,terminal}.png已查看，仅fixture$合成提示符。
- 合成160x60、100次release引擎基准：关键词/正则/32规则/语义括号p95为0.153710/0.179828/0.230223/0.443886ms；常规前后原始TSV保留。重复扫描型正则32规则从32.174ms降至8.007ms，超限帧跳过装饰；数据display-regex-stress.json，复现examples/decorations_{bench,stress}.rs。不是Flutter整帧/输入延迟或泄漏结论。
- 样例小修后的正式debug/release重建，SO与target同模式匹配：debug7739a31dc5f37fd6622d18797e992561457559cb72d2449e3c6860a4b472636d；release fe7007cce49c654af5084c1ca5e75af8b1f59271d016043cf03ff258a9d47d44。release独立启动/resize/退出0，无历史/工作副本/preview残留；最新debug/release独立启动、resize及退出均0，无历史/工作副本/preview残留。
- 选区修复后最新release5秒样本RSS345436160/聚焦CPU7.60%，失焦345776128/5.20%；debug511193088/37.40%，失焦512860160/5.20%（display-selection-startup-*.json）。此前release335028224/10.40%、失焦335364096/5.00%样本也保留。此前预算快照debug517070848/39.80%，失焦518733824/5.20%；短样本有波动，不认定长期无泄漏/性能已全部优化，失焦开销仍待定位。
- 后续发现并修复纯显示完整刷新误清真实选区：仅内容/视口/几何/映射及选中文字不变时保留，实际内容、缩放、TUI/鼠标模式变化仍失效。新增2项选择回归、原键盘/可见性/Native与真实Codex合成provider共24项29秒通过，20次Native生命周期RSS差761856字节仅短样本。选区后正式双模式/匹配SO/双模式独立启动均通过（.local/display-selection-*）；不是未运行的预计200全量。
- 日志.local/display-final-*全量与构建管道已正常0结束；.local/display-sample-fix-*小修专项/NDK/双模式/哈希/release启动管道也已0结束。所有显示批次管道已结束，旧session94556/3518/68871/19841均不要重复等待。早期失败保留且未算通过。

## 下一批直接入口（不等待验收）

1. 优先补真实RSA私钥认证及应用内限时Agent转发。当前workspace russh只有ring且关闭默认features，未启用rsa；RSA可解码不等于能签名认证，覆盖清单已改为部分。开启对应能力时核对Cargo锁/新依赖与许可，不升级其他稳定依赖；补真实RSA OpenSSH认证。
2. agent_protocol.rs和agent_signer.rs是未注册、未编译的静态准备：有界帧只准列表/签名，真实库签名与单blocking任务/有界队列、Root子授权/限时撤销、关闭等待crypto的源码及验签测试。不能当已可用Agent；还需原Transport端点、消费驱动入站流控、显式限时同意/选密钥及指纹、FRB/UI、真实两台隔离OpenSSH测试。Windows不读外部系统Agent，不盲注入SSH_AUTH_SOCK。
3. RFC9987和OpenSSH PROTOCOL.agent已核对：RSA flags是2/4位集合，新标准agent-forward版本0/agent-req/agent-connect协商须兼容旧OpenSSH别名；Agent默认拒绝未授权入站，目标与跳板路由独立，不破坏现有7类拒绝测试。新Root不自动继承旧授权，撤销不关闭SSH。
4. 网络其余：可选tmux附着/单控制端/尺寸锁、单次临时连接覆盖、完整按配置继续未完成任务。已完成跳板/唯一代理/TOFU/转发/全局默认不重做。
5. 可靠OSC133 C/D历史锚点及裁剪/Reflow、命令导航/输出复制；可靠普通Shell输入跟踪→十项路径联动/加密合格单行历史与联想。OSC7/133不能单独证明安全输入，禁止盲清行/TUI注入；已接选区定位/CWD跟随不重做。
6. 按175项覆盖清单连续补全：字体/OSC8/通知/命令面板、完整主机批改与排序、文件内并行/直传/跨服务器剪切/暂存清理与编辑保护、配置同步/备份/DPAPI/Keystore、Windows原生与完整Android/SAF/IME/触控/扩展键盘/前台服务。显示规则同步未接，Android专用显示设置入口未接；不把共享UI当平台完成。

## 安全、恢复与构建

- 保存/删除配置不改原SSH生命周期，标签/分屏移动不重建连接；所有能力绑定原nativeID/代次/实际目标。未知移动/取消ACK不推断成功、不盲重发。锁序/关闭细节见AGENTS和领域说明。
- 同步/备份未来只取正式配置及允许历史，不取草稿/布局/设备任务/滚动历史/预览/编辑正文/临时凭据/运行端口；复制草稿的转发与显示记录也不能只按前缀扫描入云。
- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；CARGO_INCREMENTAL=0、CARGO_BUILD_JOBS=2，同一时间一个重构建/测试管道。FRB2.13.0正规生成后cargo fmt，不手改绑定；新接口先生成匹配Native再Flutter。
- cargo test --workspace --locked -- --test-threads=1；cargo clippy --workspace --all-targets --locked -- -D warnings；Flutter analyze/test。无代码变化不重复长全量；纯规则测试语义小修已按影响补Core/Native专项。
- main.dart保留Phase2真实SSH，prototype_main.dart独立Mock，workbench_main.dart正式。GTK集成测试后重建正式入口，不能交付测试runner。NDK25.2/API26可check，不是APK/设备通过；Windows/Android实机待验但其业务编码仍须继续。
- .local/integrate_display.py与fix_display_rule_samples.py均已执行一次，不能重跑；恢复先检查实际文件/日志。历史归档PROGRESS_2026-10-26_DECORATIONS及NETWORK_DEFAULTS/FORWARDING系列，档内在途文字被本文替代。

## 下一批静态推进中（c04531b之后）

已核对RFC9987实际正文，纠正早期记录：扩展agent-forward的值是字符串"0"，标准入站通道名是agent-connect（不是agent），会话请求agent-req；只有明确通告支持才用标准请求名，否则兼容旧OpenSSH别名。来源https://www.rfc-editor.org/rfc/rfc9987.html §7，后续不得沿用归档中的旧误记。

agent_forward.rs新增原Client的授权路由/原Root子权限/epoch防迟到确认、最多4入站流与跟踪任务、授权与签名单独有界Worker、撤销不关闭SSH/退出等待crypto的静态源码；仍未注册/未编译，所需SshError变体/Transport前Shell请求/标准协商与消费窗口/ManagedSession、FRB与UI都还未接。Agent默认未授权拒绝保持现有代码不变。Signer静态代码已改为RSA2048–4096位与SHA2，仅ring；不启用RustCrypto rsa。2026-10-27继续批量编码中，以下更新取代早期未注册描述。下一步成批补这些接口和测试，再集中生成/构建；不能把静态文件视为已经可用或宣称测试通过。


2026-10-27本批静态接入（尚未编译验证）：新增vendor ring RSA签名适配/常数时间CRT准备/缓存，明确SHA2与2048–4096位；无需引入RustCrypto rsa（RUSTSEC-2023-0071截至本日无补丁）。Agent协议/有界单签名worker/原Transport路由已注册，默认关闭，PTY前申请socket、单独限时同意，标准RFC9987与旧别名，4流消费驱动接收窗口。ManagedSession正在补断线/关闭等待所有者；真实RSA及双OpenSSH Agent测试源码已编制。正式主机配置/FRB/UI同意尚未接，不能称完整可用。一次性.local/integrate_agent_transport.py已执行，不可重跑。下一步集中构建修正，保留原错误日志。


本批运行节点（2026-10-27）：RSA真实OpenSSH登录SHA256/512、PTY/SFTP、1024拒绝/错口令、4096及错误CRT；Agent真实两个sshd转发认证、撤销/到期/新Root、flags2/4/6独立openssl验签、标准受控peer/双别名/4流限制均已通过。核心整套171项曾通过（.local/agent-full-core-3.log），Clippy/NDK亦通过；随后压力重复发现不能凭单次通过认定稳定：Agent撤销后PTY输入偶发停住，已定位为已有WindowSizeRef绝对ACK更新恢复了排队预留额度，超发进入全局pending-data门控。现仅消费驱动通道改增量grant，默认PTY/SFTP不改；修复后压力前三次已通过，剩余重复与完整回归正在执行，不先标最终通过。新增send_window.rs直接源码回归，临时诊断正文代码已撤除，失败日志保留不提交。SSH_AGENT.md说明当前Rust核心/格式/位数/平台边界。正式AgentRegistry和.local/integrate_agent_api.py为静态编制，脚本尚未执行，agents.rs尚未注册，尚无FRB/UI能力；不得重复执行/误记已完成。


2026-10-27稳定Rust节点：窗口增量grant修复后5次真实慢消费/撤销重复均通过，完整SSH核心172项通过（.local/agent-credit-full-core.log，含91真实/受控SSH、46单测及窗口/SFTP协议）；随后增加私钥bcrypt rounds1–256预检和base64中间缓冲清零，最终46单测+4 RSA+6 Agent共56专项通过，Clippy all-targets/NDK共享核心再次通过且无警告（.local/agent-key-final-*）。不将预计173称新全量。Root子授权/epoch、撤销不能提升未申请端点、Vault可同步invalidate的能力已具备；真实Native/GTK授权尚未验。现有Flutter bundle仍是c04531b显示批次，不能当已打包Agent。准备提交Rust稳定模块，随后执行一次性API静态接入及Dart/FRB生成/集中验证。未注册agents.rs、新agent_dialog.dart和.local/integrate_agent_api.py保留；该脚本尚未执行。没有进入阶段验收暂停。


最新HEAD 3d2e024已提交上述Rust稳定模块。继续正式Agent批次静态编码中：.local/integrate_agent_api.py和integrate_agent_ui.py均已执行一次，不可重跑。HostRecord/HostConfig默认关闭选项已静态接入；agents.rs已注册，Entry原代次/目标/Vault绑定、票据准备/最终凭据标签复核/同步epoch撤销与100ms状态推送、主机认证开关、原终端菜单/风险勾选确认/撤销UI和4项组件测试源码已编制，尚未生成FRB/编译/验证。静态审查重点：Vault→registry→core锁序、原实际目标/120秒一次性票据、不同库不可授权、修改/删除密钥来源撤销、关闭等待crypto。下一步补真实Native/GTK测试源码，再集中正规FRB生成、格式/编译/修复/测试/正式双模式包。当前不得声称UI已完成或把旧bundle视作本批。

正式Agent集中验证进展：正规FRB2.13生成与debug Native编译已通过；4组件与2真实Native/OpenSSH测试曾通过（26秒），覆盖一次性/取消/原代次/同库重开撤销/明确重连/源密钥更改删除、隐藏推送零帧和默认拒绝。后续静态审核修复生命周期监听随SSH每帧查询密钥列表的问题，新增100次绘制通知无RPC检查、重复密钥与17项选择拒绝；2项Rust owned-operation/切库读写门控与旧JSON默认关闭测试已通过。新的本机任务门控跟随blocking私钥工作，关闭等待；等待全局切库门控也先计入原Entry名额，避免关闭漏等引用。Clippy只发现API末尾测试模块顺序，已移至末尾；未跳过检查。当前集中构建/专项管道还需继续，GTK与正式双模式包未执行，旧失败日志保留。.local/agent-ui-*为本批；两个integrate_agent脚本均已执行不可重跑。

GTK真实交互已20秒通过（.local/agent-ui-gtk-2.log），生成/tmp/hspterm-agent-{host-option,consent,active}.png。查看截图发现背景包含系统last-login来源及主机提示符，尚未复制/提交这些PNG；已在隔离sshd禁用PrintLastLog，截图夹具增加远端标准CSI3J清理及不含旧提示符的断言，需回归后重取，不做图片涂改。完整Rust/Flutter/Clippy/NDK/正式debug与release/双启动管道正在session35357执行，日志.local/agent-ui-{full-*,final-*}；同一时间不启动第二个重管道。新增crypto worker panic失败标记/显式收尾报错已编码并包含在该管道源码快照中，不再将异常误标到期。待整套完成后再运行更新过的GTK截图夹具，最后须重新构建正式入口避免交付测试runner。

下一独立任务静态准备：vendor/russh/src/keys/verify_ring.rs尚未注册/编译，只是ring RSA SHA2公开签名验证源码；默认协商/call site/真实RSA host-key测试均未接，不得当已支持RSA host-key。计划在Agent正式模块稳定提交后直接接入并验证；仍不引入RustCrypto rsa。此文件应暂不混入Agent已验证提交。
