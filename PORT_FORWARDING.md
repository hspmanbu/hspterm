# SSH 端口转发开发记录

V1.4 §3.1要求本地-L/远端-R/动态-D可视化转发，复用对应终端Transport，显式手动重连，不自动新建SSH。当前共享核心、加密规则、运行推送、手动重连恢复、本机加密编辑草稿和终端链接确认临时转发已接入；本批专项与两项GTK通过，完整回归/正式包状态以PROGRESS最新记录为准。历史节点计数仅供溯源。Android正式布局与目标平台验收仍需完成，不把Ubuntu当设备验收。

## 已验证的TCP通道基础

ssh-core::TcpConnector从原SshConnection/ManagedSession获取，后者actor只返回同代次能力，不等待通道协商。所有clone和重复获取共享64个在途+活动通道名额，目标域名由SSH服务器解析；地址/端口/超时在网络前验证，无本机直连或Shell回退。旧连接断开/销毁后，旧能力无法在重连后操作新会话。

TcpChannel提供有界异步字节流，保留半关闭语义、独立操作取消和原Transport取消。操作取消唤醒I/O，持有者应丢弃流以关闭通道；后续转发runner负责停止时丢弃全部流。没有新的SSH认证/PTY或SFTP配置。

russh0.64.1直接丢弃channel_open_direct_tcpip future可能让迟到确认缺少CloseOnDrop。当前有界worker持续消费原请求，超时/调用方取消或abort后若收到确认，已关闭receiver会丢弃真正的ChannelStream并发CHANNEL_CLOSE、释放名额。原SSH关闭时worker同取消退出；永不确认的恶意peer最多占用本连接64个名额，不启动无界后台任务/轮询。

实际验证5项：256KiB+37二进制往返且PTY/SFTP仍可运行；单通道取消不取消SSH；断线/明确重连后旧能力拒绝；64名额跨clone/再次获取共享，等待可超时/取消，丢弃后释放；服务器拒绝无本机直连回退。另用受控真实SSH peer精确延迟确认，验证timeout/cancel/abort三种迟到通道都关闭且原SSH保持。前4项实际OpenSSH，最后受控peer明确不计OpenSSH或应用端到端。

重现：`cargo test -p hspterm-ssh-core --test openssh openssh_forward --locked -- --test-threads=1`。完整core122项、Clippy、NDK及匹配Native见PROGRESS。源码src/tcp_channel.rs与session.rs，测试openssh_forward/{mod,late}.rs；该初始节点未修改协议依赖；后续消费窗口补丁见下文与vendor说明。

## 当前尚待实现

明确手动重连后的按配置恢复、localhost链接确认临时转发及规则编辑完整草稿仍待完成。R核心/加密规则/FRB管理和正式手动UI已经接入（见后文）；原型菜单仍明确不联网，不当业务完成。正式GUI包以PROGRESS为准。

## 本地-L监听核心

forwarding::LocalForward在已获取TcpConnector上明确绑定SocketAddr，调用方应默认loopback，端口0由OS分配。先验证目标/超时，再真实bind，端口占用立即返回错误；不后台探测目标，成功bind仅表示监听建立。目标域名由SSH服务器解析。每监听至多64个待协商/转发任务，所有监听仍共用原Transport的64 TCP通道上限；SSH层背压和copy_bidirectional的有界缓冲处理双向数据及半关闭，没有字节内容穿Flutter桥接。

watch状态仅在accept/任务结束/停止时更新，含accepted/active（含正在协商）/failed/最近脱敏错误/stopped；没有空闲轮询。拒绝或IO错误如实计数，不误记目标连接成功。stop等待本监听socket与全部子socket/stream所有者释放，可重复调用；只取消本转发，不停兄弟转发/SSH/SFTP。Drop安全取消而不能同步等待，正式管理器退出须显式await stop。原SSH断开会关闭对应监听和通道，原能力不会追随新连接，不自动恢复。迟到SSH确认仍按上一节有界收尾，不能撤回已发出的远端TCP连接请求。

新增4项真实OpenSSH验证：128KiB+23准确往返/EOF半关闭/PTY并行；停A后B继续回显，断开SSH关闭B监听，重连旧能力拒绝；服务器拒绝被统计且SSH仍在线；无效目标/端口/超时先于监听发布，端口占用返回真实IO失败。9项转发专项10.37秒与完整ssh-core126项通过，Clippy/匹配Native通过，NDK/Native最终见PROGRESS。这是早期Rust监听节点；后续FRB/加密规则/手动管理已接（见末节），Mock不当真实业务。

## 动态-D SOCKS5 CONNECT核心

LocalForward::socks5复用相同有界监听/runner/统计/停止，私有Mode只区分固定目的地与按请求目的地，不复制监听实现。按[RFC1928](https://www.rfc-editor.org/rfc/rfc1928.html)的TCP请求格式及[OpenSSH动态转发实现](https://github.com/openssh/openssh-portable/blob/master/channels.c)核对，提供SSH-D常用的无认证CONNECT子集，不声称完整SOCKS服务器/GSSAPI/BIND/UDP/SOCKS4。绑定由调用者明确指定，应用默认应为loopback；独立于SSH外层HTTP/SOCKS代理，不复用其代理认证秘密。

握手仅精确读取所需字段，方法/地址最多各255字节，支持IPv4/IPv6/ASCII域名，目标域名由SSH服务器解析；不多读同包应用字节。无匹配无认证方法返回FF，不接受不支持的BIND/UDP或畸形/非零保留字段/无效地址端口；错误均静态文本，不回显请求内容。只有目标direct-tcpip确认后回复成功，SSH拒绝返回明确失败，绝无本地TCP回退。SSH不提供远端出站socket绑定信息，回复未指定地址/端口，不编造实际绑定。

握手与等待通道名额/目标打开共用每连接的open_timeout预算，最后小回复写入另限min(open_timeout,1秒)，转发数据本身不套握手deadline。慢客户端超时释放局部任务，不占满无限worker；明确停止立即中止未完成握手，不等待30秒deadline，SSH与其他转发不受影响。仍遵循迟到通道有界清理。

2项解析单测覆盖IPv4/IPv6/域名/合并包负载保留、无认证方法与13种畸形/不支持/截断输入、错误脱敏；5项新增真实OpenSSH覆盖IPv4/域名128KiB+17合并包及半关闭、IPv6目标经IPv4 SSH、SSH禁止转发的失败回复/无回退、慢客户端与UDP拒绝、30秒未完成握手在停止后1秒内关闭。14项转发专项15.30秒与完整core133通过；最终workspace/NDK/Native/GUI包状态以PROGRESS为准。后续FRB/配置与可视化手动D管理已接（见末节），运行事件推送已接，恢复仍待完成。

## 远端-R后续实现边界

-R须在原目标Client独立维护有界入站路由，跳板Client不能共享该路由。未知/未启用/已停止的forwarded-tcpip默认拒绝，本机目标TCP连接必须在PTY actor外执行。tcpip_forward/cancel全局请求若调用方超时/abort，不能丢弃迟到ACK：尤其请求端口0时须捕获真实端口，迟到成功后在同一Transport明确清理。取消ACK丢失不能谎报远端监听已关闭，应保留可重试/未知状态；SSH销毁才使该代次路由完全失效。不凭焦点或后来重连的同地址路由把旧入站连接导入新会话。

## 慢消费/共享PTY流控修复（真实复现后实现）

在客户完全不读取转发TCP数据时，原russh0.64.1会await有界ChannelRef.send(Data)，共享client分发循环被堵，独立PTY marker超过2秒不出现；不是Flutter重绘问题。16MiB持续输出夹具已复现并先清理后报错，日志ssh-forward-backpressure-before.log保留。

固定版本本地补丁vendor/russh（见HSPTERM_PATCH.md与Apache许可证）新增显式channel_open_direct_tcpip_flow_controlled，仅TcpConnector调用。协商窗口内的接收FIFO按字节有界、64KiB合并块且最多128项，不await慢消费者；实际读取字节后才经既有priority路径发送合并窗口credit，同一channel最多一个排队通知加正在处理的通知。溢出/poison向读取者明确返回IO错误，不把截断当正常EOF。Data/EOF/CLOSE顺序、读取者丢弃、迟到打开收尾和rekey仍由原Transport约束。默认PTY/SFTP/跳板/服务端调用不改队列策略。没有扩大队列或无界payload，也不临时写磁盘转发正文。

精确生产队列源在receive_window.rs对真实russh ChannelMsg执行4项边界/一字节包合并/消费credit/FIFO/EOF/Close/wake/丢读者测试；不是复制实现。真实慢读PTY测试修复后通过（原3.53秒失败→1.53秒整个测试通过，不当输入延迟精确测量），8MiB+17二进制经4093字节碎片读取/多轮窗口补充完全一致；17项转发专项18.91秒通过。完整workspace/Native/Codex/NDK与最终包仍以PROGRESS最终记录为准。后续-R的入站forwarded-tcpip同样必须启用消费驱动窗口，不能假定只改出站direct-tcpip就覆盖入站。

## 未请求的服务器入站通道

受控真实SSH peer的七类入站测试先复现默认接受，再由HSPTerm Client逐项明确拒绝（AdministrativelyProhibited），原PTY连接保持。forwarded-tcpip只有后续显式-R规则可放行，Agent/X11/其他入站仍禁用；不因russh默认回调接受就视为用户授权。测试openssh_forward/incoming.rs，完整core141与Clippy通过，未把受控peer计成OpenSSH。

## 远端-R核心（当前回归状态见PROGRESS）

`RemoteConnector::listen`先同步验证/预留并返回唯一拥有者`RemoteForward`，不在调用栈等待全局请求。`wait_started()`独立等待同一次请求结果，取消等待不会丢失请求；Drop拥有者只撤销本规则。每个实际目标Client独立Router，跳板Client另建Router，ManagedSession仅按原代次返回能力，协商/本机TCP连接/转发均在PTY actor外执行。每Transport最多32条启动中/活动/未知清理规则及64条共享入站流，每规则inbox16，流计入目标连接协商与全部活动期。未知/已停止/地址端口不匹配、歧义localhost、容量耗尽均拒绝，不探测本机目标或共享焦点会话。

请求遵循[RFC4254 §7](https://www.rfc-editor.org/rfc/rfc4254#section-7)；规则明确指定SocketAddr（拒绝IPv6 scope/flowinfo），本机目的地支持IP/受限ASCII域名，明确入站时才本机解析。端口0的ACK必须提供有效分配端口；状态只报告“请求地址+分配端口”，不能从ACK推断GatewayPorts实际对外绑定范围。错误分配与其他已预留规则重叠时禁用新规则并保留未知状态，不猜端口或取消其他规则。

启动超时/owner Drop/等待Future abort后，保留原tcpip_forward Future直到结果或原Transport销毁；迟到分配后明确取消同一Transport的原端口，绝不激活迟到监听。启动结果一经确定不被后续清理改写成成功。停止立即禁止路由并释放本机socket/stream所有者；只有cancel-tcpip-forward成功ACK才记Stopped。停止超时为CleanupPending，继续消费原ACK，不重复发送；明确拒绝为CleanupDenied，再次stop才允许用户显式重试，不能自动重连SSH。停止Future abort后可再次等待原操作，旧已停止句柄不能取消后来重建的同端口监听。Disconnected仅表示原Transport结束，不谎称收到远端关闭确认。

vendor/russh新增默认false的`Handler::flow_control_forwarded_tcpip`，仅HSPTerm Client明确启用；入站Channel与其PendingChannelOpen使用同一消费驱动有界FIFO/credit。已有默认客户端行为、PTY/SFTP/跳板出站API仍保持。慢本机目标测试关闭opt-in时3.57秒失败，启用后通过；不把整项测试耗时当精确输入延迟。真实OpenSSH8MiB+17多窗口二进制、半关闭、PTY/SFTP同时运行；受控peer精确延迟启动/取消ACK与拒绝/错误分配验证不是OpenSSH运行结果。

R核心后已接加密规则、FRB registry/退出收尾与可视化手动管理；运行事件推送已接，明确重连恢复仍待完成，原型菜单继续明确模拟。具体计数/包版本见PROGRESS。

## 加密规则仓库

storage-sync::forwarding_rules保存每正式主机独立的版本化文档，最多32条规则、读取前128KiB字节界限；L/R固定目标与D按请求目标分开，默认loopback，可显式选择恢复策略。规则ID稳定且副本独立，L与D共享本机固定监听冲突域，R是远端域；禁用/端口0不伪占固定端口。没有socket/名称解析/SSH凭据读取/自动启动或运行状态持久化。格式/版本/容量错误不覆盖原记录。

复制主机将新规则ID的配置与新凭据草稿/catalog同事务写入；正式保存前不能作为正式配置读取。普通草稿自动保存和恢复保持规则；丢弃新副本清关联配置，丢弃现有主机编辑草稿保留正式规则。删除主机同事务删除规则，写/复制/删除故障全部回滚，运行会话不被暗断。同步尚未实现，未来必须按正式catalog.hosts筛配置，复制草稿的规则记录不能入同步/配置备份。

5项新增专项与完整storage-sync65项通过，具体当前Native/FRB/GUI状态见PROGRESS；不把仓库能力当作可视化转发交付。

## 配置桥接

FRB forwarding_rules/save_forwarding_rules提供结构化RuleConfig，读取元数据、显式整组保存并返回已分配稳定ID。端口先用u32接收再检查u16范围，监听地址要求明确IP，未知类型/缺半个目标/动态错误目标/字段不合法/重复ID/容量超限均拒绝，原记录保持。保存不改变原连接或启动监听。正式HostConfig与独立规则文档分开，主机基本编辑不覆盖规则。

官方生成器2.13.0与匹配Native后，新真实Dart→FRB→加密仓库测试覆盖L/R/D、规则ID、无效保存保留、重开/副本草稿正式保存/普通主机编辑/删除隔离，真实回环监听收到请求0；密文不含标签或密码。完整Rust281、Flutter169、Clippy/Analyze/NDK通过，详情以PROGRESS最新记录为准。配置接口本身不启动监听；另有原会话运行API及手动管理页，见后文。

## 原终端运行期管理与FRB

Entry持独立ForwardingRegistry，start_forwarding需原NativeID/代次和已保存且启用的规则ID。实际目标地址/端口/用户与保存主机不符则拒绝，配置在原Vault锁内捕获，网络能力获取/协议IO不持配置锁或管理gate；目标明确且原会话有效才构造L/R/D，绝无新SSH或直连降级。API只回小状态，实际数据流始终在Rust。

实例拥有不随配置改动的副本与唯一token，原代次/跨标签stop不能误中后来实例。删除主机不暗停已有转发，但无法据删掉的配置新启动。断开期间计数RAII关闭准入，多个关闭/abort不能提前重开；销毁永久关闭，迟到准备也拒绝。所有转发在Root关闭前并行停止，R取消超时/拒绝不伪造Stopped；Root关闭后对应代次才退休，本机清理异常等待原文档/搜索/任务释放后再报告。

2项RAII单测与真实Native端到端验证L/R/D各65KiB+17、PTY并行、重复启动拒绝、跨标签token隔离/标签关闭监听释放、保存配置不改变实例、断开与手动重连后旧token失效/无隐式重建、删除主机后原转发继续/能停止、退出关闭剩余R监听。停止不需要Vault或凭据。完整当前结果以PROGRESS为准；可视化手动入口已接；变化推送已接，按配置重连恢复仍待接入。

## 正式手动管理界面

已保存主机的「进阶→端口转发配置」可离线管理规则；当前标签组菜单「当前终端端口转发」固定到所选原终端。脏主机须先正式保存，原型明确提示不联网。多连接时需明确选择，选择保存原NativeID/代次，后来切焦点/移动标签不更换目标。

表单实际加密保存L/R/D，绑定默认127.0.0.1、端口0自动分配；字段校验和读取失败保护、启停/编辑/删除确认均可操作。保存/删除规则不停止既有实例，运行实例另列实际端口和状态，可在主机删除/配置不可读后停止。非回环监听启动明确确认；R实际绑定范围由服务器策略决定，D仅无认证SOCKS5 CONNECT。关闭面板不关监听，断开/关闭标签/退出才沿原Root清理。

连接生命周期变更自动禁用旧操作并标记原连接已断开，100次普通通知不额外查询；运行元数据已接任务驱动推送，明确重连恢复仍待接，恢复开关未在UI启用。规则弹窗尚未接完整加密未保存草稿，不计该子项完成。

验证：6项组件（含读失败/旧代次/删除后停止/字段/480×360和1.6倍文字）与GTK真实表单/L/R/D TCP回显/停止/主机入口/原会话身份通过。截图validation/phase3b/hspterm-forwarding-{config,running,host-settings}.png；完整Rust283/Flutter176、Analyze/Clippy、NDK与正式debug/release及启动数据见PROGRESS。

Ubuntu运行：在ui_flutter中执行`/opt/flutter/bin/flutter run -d linux -t lib/workbench_main.dart`。回归：`flutter test test/forwarding_dialog_test.dart test/forwarding_rules_bridge_test.dart test/forwarding_runtime_bridge_test.dart`；实际GTK用`python3 benchmark/external_editor_gtk.py flutter test integration_test/forwarding_test.dart -d linux --reporter expanded`。Windows/Android实机没有执行，不把Ubuntu结果当设备验收。

## 运行元数据任务驱动推送

每实例仅持原状态watch receiver的观察任务，通过Weak注册表上报修订，不持SSH能力/运行拥有者，不延长会话生命周期；状态结束或发送方关闭即退出。watch_events采用首个变更起100ms固定合并窗口，连续变更不重置deadline，空闲不启动周期计时。只发送代次与forwardings触发，不发送TCP字节/终端帧。Flutter按原代次通知独立forwardingChanges，面板合并在途读取、丢弃旧源响应；不经全局模型重绘，隐藏终端不拉帧。界面已移除过渡查询定时器，保留明确刷新入口。

新增Rust观察者空闲/停止/Weak释放测试、Controller跨代次和零帧测试、100次在途通知合并/关闭注销测试；真实Native验证隐藏零帧和空闲零周期通知，GTK验证面板外停止R后自动显示已停止。完整结果以PROGRESS为准。

## 明确手动重连恢复

connect_terminal仅在原有成功认证目标存在时捕获恢复配置；首次连接不启动任何规则。成功后核对原保存主机ID、实际地址/端口/用户及主机指纹，目标身份变化则报告未恢复。仅enabled且restore_on_reconnect的规则在新代次各尝试一次，使用新Transport能力，未建立新的SSH。局部bind失败以独立失败元数据返回，无监听地址，不把SSH标为失败，也不中断兄弟规则；R仍沿原异步状态/迟到ACK清理。手动重试成功替换对应失败记录。用户在Connected发布时并发手动启动同规则，恢复会复用原实例而不复制。

恢复开关默认false，规则编辑明确可选；非回环监听的持久恢复需单独确认风险。停止与恢复开关独立：明确重连时按保存策略恢复，当前停止不暗中改配置。Native测试覆盖L/R/D、禁用/不恢复、端口占用与重试、改变目标身份保护；GTK通过真实重新连接按钮及三类TCP回显。

## 本机加密规则草稿

forwarding_drafts按正式主机ID保存不完整字段，64KiB上限，非法端口文本可恢复但不能正式提交。只在本机加密，不入同步/配置备份，不复制到主机副本；删除主机同事务删除。修订号及空正文墓碑禁止旧写入复活已丢弃/提交内容；原规则快照、当前配置和草稿修订共同检查，正式保存与草稿退休同事务。其他进程改动/删除原规则不能被恢复草稿覆盖；未知版本/容量/存储失败保留原数据。

编辑器300ms合并自动保存，焦点/选区改变不产生草稿；恢复/丢弃需明确选择，关闭可保留草稿或明确丢弃，退出等待在途写入，失败阻止关闭。正式配置仍必须点保存。编辑弹窗打开不属于持续忙碌IO，避免底层不确定进度动画空转。当前独立规则编辑仅面向已保存主机；整个主机管理/跨平台配置流程不据此计全部完成。

## 终端链接与临时回环转发

只本机扫描可见真实网格，支持Unicode/宽字符位置映射及WRAPLINE软换行，最多16行/4096格/16384 UTF-16单位；窗口外截断的软换行不激活，隐藏SGR文本不通过提示泄漏。悬停仅完整文本，不解析DNS/探测/取网页；Ctrl+Click或菜单才进入动作，远端鼠标捕获优先，Shift显式覆盖保留。仅允许http/https，拒绝URL凭据/控制字符/无效端口；普通IP/host:port可复制地址，不猜浏览器协议。OSC8显式超链接和Android长按完整适配仍待整体链接模块补齐。

回环URL或host:port需确认原终端，Native再次限制localhost/明确loopback IP和1..65535端口，仅在本机127.0.0.1随机端口建立L；不读写已保存配置、不探测目标、不自动恢复。源ID/代次和标签归属在异步边界复查；浏览器拒绝启动只清理本次新监听，兄弟监听继续。HTTPS保留协议，由浏览器正常验证证书，不降低TLS。普通网页在保留的断线历史中仍可明确打开，不为此重建SSH。临时实例可在原会话转发面板停止，Root退出统一释放。

GTK使用注入的记录型浏览器适配器，不访问外部网页；真实原SSH TCP数据、确认前零连接、取消、打开失败收尾、断线后迟到确认不执行和普通链接不重连均验证。此结果不是实际系统浏览器/Windows/Android实机测试。
