# SSH 网络配置与验证

需求基线：V1.4 §3.1/§3.2。一终端一个Transport；代理改变TCP路由，不改变目标地址、TOFU键、认证用户、PTY/SFTP上下文；任何失败均不直连回退、不自动重连。

## 单代理核心

ssh-core::ConnectConfig.proxy 可显式配置一个 HTTP CONNECT 或 SOCKS5 TCP 代理，无代理时保持原连接流程。TCP→代理协商→SSH握手→认证→PTY共用总连接Budget，代理协商单列Stage::Proxy，可取消；交互式host key确认仍暂停计时。代理未完成前不发送SSH认证。

- HTTP/1.0/1.1 CONNECT使用显式目标端口，IPv6使用方括号。可选Basic只发Proxy-Authorization；不协商其他认证、不自动重试。接受2xx切隧道，有限1xx中间响应；每个响应头限16KiB、最多5份响应。只读到头结束，保留同包SSH banner。拒绝无效状态/头字段/截断，错误仅静态文本或状态数字，不带代理响应。
- SOCKS5只提供所选认证方法：无认证或RFC1929用户名密码，配置密码时拒绝降级。域名在代理端解析；支持IPv4/IPv6/域名目标及三类返回绑定地址。只消耗协议精确长度，保留后续SSH字节。用户名/密码分别1..255 UTF-8字节。
- 端点为ASCII域名或IP，IPv6可加方括号，域名/IPv4不能用方括号。没有URL、路径、内嵌端口/用户信息；端口非0。HTTP用户名非空且无冒号，凭据无控制字符，总长有界。当前不做IDNA转换，不声称支持任意国际域名或HTTP TLS代理。
- 认证值及HTTP请求/响应缓冲使用Zeroizing，配置/凭据Debug脱敏。HTTP Basic、SOCKS密码在到代理的TCP链路无加密，SSH的后续加密不保护代理认证；只应对可信代理/网络使用。HTTP Basic以UTF-8编码，不尝试其他字符集，不对407自动重发。

协议依据：[RFC9110 CONNECT](https://www.rfc-editor.org/rfc/rfc9110.html#name-connect)、[RFC1928](https://www.rfc-editor.org/rfc/rfc1928.html)、[RFC1929](https://www.rfc-editor.org/rfc/rfc1929.html)、[RFC7617](https://www.rfc-editor.org/rfc/rfc7617.html)。

## 已执行测试与当前边界

协议单测覆盖粘包banner、IPv6、UTF-8凭据字节数、认证降级/失败、拒绝状态、畸形/超长/截断头、有限中间响应和错误脱敏。openssh_proxy在独立一次性回环代理后运行真实sshd：代理端映射.invalid目标（客户端不能解析）、原目标TOFU、PTY输出及resize、SFTP正文往返、变化密钥阻止；超时/取消关闭TCP且未发SSH握手；可直连的目标被代理403拒绝时仍失败。

核心及主机配置持久化/FRB/正式网络UI均已接并通过Ubuntu测试，最终结果看PROGRESS和.local/ssh-proxy-*。一级跳板正式接入见末节；端口转发、内部Agent、tmux及云同步独立代理仍未实现。本文件不把核心协议测试计作应用端到端或Windows/Android实机验收。

## 加密配置与正式界面

HostRecord.proxy为可选字段，旧记录默认无代理。ssh_proxy::ProxySettings只含协议、地址、端口和认证开关；用户名/密码另存加密host-ID归属记录，不复用SSH密码/私钥。HostDraft可包含本机加密的待提交代理凭据；不完整草稿可恢复，但不能连接或绕过正式保存。复制主机把秘密复制到新host-ID草稿，显式保存后建立独立加密记录；原主机修改/删除不改副本。关闭代理或认证时，保存事务删除其代理凭据；重新开启不能凭空复活旧值。事务失败保留原配置、原秘密与待恢复草稿。

FRB HostProxyConfig仅返回非秘密元数据和credential_set存在标记；ProxyAuthenticationInput为单向输入。Rust存储/协议持有秘密的结构均不实现可泄露内容的Debug并在drop零化；Flutter/FRB传输使用普通字符串，不能承诺所有临时副本都可零化，保存/切换后清空表单。主机网络页允许无代理/HTTP CONNECT/SOCKS5选择、地址/端口、独立认证输入；已保存用户名和密码均不回填。保留已有认证时留两项未编辑；替换时同时提供。HTTP密码可空，SOCKS密码不可空，长度以UTF-8字节计。字段无效时返回网络分类并聚焦，无需重复点击保存。

保存只更改未来明确连接/重连使用的配置，不改已建Transport、不自动网络测试；SFTP仍复用原Transport。正式页不把未接入的跳板选择框伪装成可用网络功能；Mock页仍只用内存，保留明确标识。云同步代理是另一独立设置，不与此SSH代理绑定。

## 可复现验证

在根目录export PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH及CARGO_INCREMENTAL=0。协议/core命令：

```
cargo test -p hspterm-ssh-core --locked -- --test-threads=1
cargo test -p hspterm-storage-sync --lib --locked
cargo test --workspace --locked -- --test-threads=1
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build -p hspterm-frb-bridge --locked
```

ui_flutter内运行flutter analyze、flutter test --reporter expanded。新增host_proxy_form_test覆盖字段验证/网络分类单击保存/禁止秘密回填；ssh_proxy_bridge_test使用合成一次性代理和真实sshd，覆盖加密草稿提升/重开、两协议SSH/PTY/SFTP/复制/手动重连与布局身份不变。夹具须显式开启无视图controller的可见性才拉取画面；不可把隐藏终端不拉帧误报为代理丢数据。

GTK使用`python3 benchmark/external_editor_gtk.py flutter test integration_test/ssh_proxy_test.dart -d linux --reporter expanded`，只在私有Xvfb/D-Bus与合成回环目标中执行。测试实际打开网络分类、重新填写认证、点击一次保存，再手动重连确认远端SSH；截图写到/tmp/hspterm-ssh-proxy-settings.png与/tmp/hspterm-ssh-proxy-workbench.png。最终通过情况/正式包版本以PROGRESS为准，不以本文命令清单冒充已执行。

Windows/Android后续验收：在受控HTTP/SOCKS代理后分别测试域名/IP/IPv6、无认证及密码认证、代理拒绝/停机/慢响应、可信密钥变化、取消确认和手动重连。观察SFTP与PTY共享同一代理连接，切标签/分屏不重连；修改代理只对下次连接生效。验证目标平台密码输入/IME与文件路径；Ubuntu结果不代表目标设备通过。

同步/备份后续接入必须把正式host-proxy-credential-*作为独立敏感配置集合，与所属主机按稳定ID保护、端到端加密；不能遗漏代理认证或上传明文。draft-*中的proxy_credential仍是本机草稿，不进入云同步。当前尚无完整同步/备份业务，不能因已加密保存就计作同步完成。

## 主机级时限与心跳控件

主机网络页接通现有加密字段：总连接超时1..3600秒，心跳间隔0..86400秒（0关闭），连续无响应阈值1..100。字段从Rust元数据载入、随草稿/副本/重开保留，正式保存后仅下一次明确连接/重连生效；已建Transport不被配置编辑替换。核心仍共用原总Budget及russh keepalive策略，不自动重连。此处未实现全局默认覆盖或独立于间隔的响应超时，不能把§3.2所有配置计作完成。

host_network_settings_test在标准窗口及640x480逻辑像素/1.5缩放下验证输入、边界、草稿快照与副本、单次保存/错误聚焦。小窗口时限字段竖排，主机页底部操作栏按可用宽度分两行，避免原横排32像素溢出；功能及确认规则不变。主机保存按钮统一调用原save()，保持准备/保存期导航保护。

ssh_network_settings_bridge_test通过真实FRB核对加密库重开：保存1秒预算，在不回应的回环SOCKS代理阶段超时，标签保留；改8秒后实际收到新代理请求再取消。另一真实OpenSSH试验中，仅合成代理在建立隧道后暂停全部转发；1秒心跳/1次阈值触发断线，画面/原ID及代次保留，不自动重连。恢复代理并明确重连、保存0间隔后，同一4秒停流窗口不因心跳断开，仍可手动断开。真实时钟跨FFI，此4秒为关闭心跳对照观测窗口，不作长期网络存活或资源无泄漏证明。最终通过情况及构建版本见PROGRESS。

## 明确握手测试核心

ManagedSession.test_connection与connect共用单actor、忙状态、取消及代次规则，使用SshConnection.test_connection的TCP/代理/SSH握手/TOFU链路；目标认证不是输入参数，不打开PTY/SFTP。成功回Idle（从未实际登录）或Disconnected（保留旧屏幕）；失败为Failed，原画面/历史/修订不变。实际连接进行中或已连接时Busy，不触碰原Transport。确认等待沿同一Budget暂停规则。

探测Future退出时drop_guard只取消本次子token，包括调用方abort，不能误取消后来的请求；shutdown等待actor退出。OpenSSH首轮测试包括不存在的认证用户名握手仍可成功、禁止输入/SFTP、在线Busy、保留旧历史及变化密钥、确认时取消/丢弃/关闭。FRB/主机页现已完成下节列出的Ubuntu验收，最终代码/测试与包版本以PROGRESS为准。

## 正式主机探测入口（Ubuntu已验）

FRB test_host_connection从加密正式主机读取路由/总时限，只在需要代理认证时读取独立代理秘密，不读取目标SSH密码/私钥。connections::configuration同时服务正式连接，避免测试与连接采用两套代理规则；原目标TOFU策略共用。UI传入预期地址/端口/用户名与保存host-ID，Native网络边界再次核对，配置已变更则拒绝而不猜测新目标。

主机页“测试连接”只测试已明确保存的配置。未保存编辑/新草稿需先点击保存，不因测试自动变成正式主机；不后台探测。弹窗显示捕获的原目标、进度和结果，明确握手通过不等于目标账号认证通过。HostConnectionTest使用独立隐藏Controller收host-key事件，不加入TerminalTab/最近连接，不初始化SFTP，不拉帧；原可见会话继续运行。取消/成功都等待原Native句柄及FRB流释放，App退出先取消并等待。取消能力绑定原操作Future，旧Dialog卸载不会取消后来测试；明确取消属正常结束，不写全局错误，原Future仍向调用方返回取消结果。

最终8项专项验证两项真实Native/TOFU与停流代理取消/应用退出、4项按钮/弹窗交互及合法长目标滚动、2项创建中取消及隐藏零帧/一次释放。完整Rust223/Flutter162、真实GTK信任/范围/取消及正式双模式构建/独立启动均通过，见PROGRESS。真实GTK入口为integration_test/connection_test_test.dart；使用一次性sshd与不存在用户/无效合成密码，只有“信任并保存”会写加密指纹，不做目标认证。没有读取Codex或其他账号凭据。

## 一级跳板核心（接入中）

ConnectConfig.jump可选JumpHost，JumpHost只有地址/端口/用户/独立认证/独立host-key策略，不含递归跳板或第二代理。链路为当前连接唯一代理（如配置）→跳板SSH握手/认证→direct-tcpip目标地址端口→目标SSH握手/认证/PTY；不运行跳板Shell、远端ssh命令、Agent转发或本地ssh进程。目标PTY/SFTP仍共享目标Transport。

握手、两端认证、转发通道、唯一外层代理及PTY共用同一总Budget/确认暂停和取消根。跳板错误带独立前缀，取消仍为Cancelled；目标主机密钥及认证失败保持目标分类，不直连、不换认证。JumpStream由目标russh任务持有跳板Handle及ChannelStream，取消同时唤醒外层TCP与嵌套通道，目标退出/失败不得留下跳板连接。

6项真实OpenSSH/协议专项及2项单元首轮通过，完整回归/Native/NDK见PROGRESS。外层代理试验用只有合成代理能解析的虚拟跳板域名，确认CONNECT/SOCKS目标是跳板，非最终目标。超时试验在代理阶段真实等待1秒，再跳板认证、目标停流，以3秒总预算返回目标Handshake超时，不给各跳重新计时；abort探测后目标forwarded socket收EOF且actor关闭。

本节为核心节点，当前正式加密引用/FRB/界面接入见末节。最多一层、删除/改变跳板不能悄悄改直连，TOFU界面显示实际待确认跳板/目标身份；目标握手测试需认证跳板但不读取或使用目标凭据。规范依据：[RFC4254 §7.2](https://www.rfc-editor.org/rfc/rfc4254.html#section-7.2)、[russh0.64.1 Handle](https://docs.rs/russh/0.64.1/russh/client/struct.Handle.html#method.channel_open_direct_tcpip)。

## 一级跳板的加密主机引用
HostRecord.jump_host_id为可选稳定主机ID，默认None。只可引用已正式保存且无跳板的主机；拒绝自身/未保存草稿/两级跳板，反向修改也检查依赖。唯一代理可来自目标或所选跳板，两者都配置则明确拒绝，不静默忽略任何一个。跳板被删除不级联断开/删除目标或改成直连，保留引用，未来保存/连接须明确修正。目标副本保留对同一保存跳板的引用，自身凭据仍独立。草稿可不完整、仍不能连接。存储60项含5项新增行为测试通过；正式路由/指纹/UI当前仍在接入，见PROGRESS。

## 正式跳板路由与双端信任

主机网络页从已正式保存、无跳板的主机中选择最多一级跳板；自身与两级引用不可选，失效引用显式显示且不能保存/连接，只有用户明确选择“无跳板机”才清除。切换/保存/移动标签不联网、不替换已连接Transport。跳板采用所选保存主机的独立认证，目标自身认证保持；目标没有代理时继承所选跳板代理，两端各有代理则拒绝。总时限/心跳采用当前目标连接设置。复制目标保留对同一保存跳板的明确引用，不隐式创建跳板副本。

connections::Route在同一Vault锁下捕获原目标、跳板认证及唯一代理，prepare生成两端各自的HostKeyPolicy。手动测试仅加载跳板认证，不读取目标密码/私钥，不开PTY/SFTP；预期目标端点/用户名/跳板引用均在Native边界复核。

跳板本身仍使用按其端点的原TOFU键；经跳板的目标使用版本化长度前缀tuple（跳板地址/端口/用户名、目标地址/端口）散列后的独立加密键。直接访问的旧trust键不变，不把来自不同内网/跳板的同地址目标混为同一信任。域名大小写规范化，用户名保持大小写。不从远端提供的字符串、当前焦点或后改主机记录推断信任归属。

每个Entry只允许一个准备/连接/探测尝试，至多两个待验证槽。HostKeyPolicy::ConfirmTagged携带应用生成opaque标签；请求须同时匹配原槽、原端点及仍存活的回应端。取消/退出立即撤销槽，旧确认不能写进后来的路由；Vault→验证槽的锁顺序固定，无锁跨网络await。Attempt退出会取消仍在Connecting的本次actor，已Connected不受影响。桥接事件分别为jumpHostKey/hostKey；App显示实际待验证端点及跳板/目标角色，即使二者端点相同也不靠地址猜角色。确认UI异常finally明确拒绝并报告，不能让安全确认暂停预算后永久挂起。

真实Native夹具为三台独立OpenSSH、唯一外层合成SOCKS代理：直连已信任仍需跳板路线独立目标确认；两端加密指纹重用；不存在目标用户探测可通过但登录失败；修正目标认证后明确重连、真实PTY/中文路径SFTP；变更至另一跳板只在明确重连生效且重新确认目标；删除跳板不影响原在线Transport但下次连接拒绝、不直连。选择器专项覆盖自身/嵌套过滤、缺失引用显式修正和双代理拒绝。

GTK真实信任/选择器/单击保存/原会话身份检查通过；不是Mock数据网络动作。重现：ui_flutter内 `python3 benchmark/external_editor_gtk.py flutter test integration_test/ssh_jump_test.dart -d linux --reporter expanded`。截图validation/phase3b/ssh-jump-{tofu,settings,workbench}.png，均已查看。完整回归、最终构建与最新状态以PROGRESS为准；Ubuntu和NDK check不等于Windows/Android实机验收。

## 2026-10-26 全局网络默认与独立心跳

全局连接时限/心跳间隔/ACK响应时限/连续失败阈值已接加密配置、正式设置及主机继承选项。默认30/30/10秒、失败3次；间隔0完全关闭。旧主机保留明确参数与旧心跳策略，新建UI主机默认继承。读取损坏或未来版本拒绝覆盖；修改只影响下一次明确连接，不热改原Transport。独立监视器仅等待真实全局请求ACK，PTY输出不能代替回应；有界失败后结束原连接，不自动重连，关闭等待任务退出。

集中验证：Rust294、Flutter188通过；all-target Clippy拒绝警告、Analyze、格式、NDK/API26 aarch64共享核心check通过。真实OpenSSH/合成代理验证ACK保持在线、2000行PTY、停流超时、修改默认不热生效、手动重连读取0关闭；实际GTK设置/主机保存14秒通过。截图validation/phase3b/ssh-network-{defaults,host-policy}.png已查看，无可见溢出。重现GTK：`python3 benchmark/external_editor_gtk.py flutter test integration_test/ssh_defaults_test.dart -d linux --reporter expanded`（ui_flutter目录）。旧代理表单测试需真实滚动到下方控件，修正后8项通过。

正式workbench_main debug/release构建、同模式SO SHA256匹配及独立GTK启动/缩放/关闭0通过，无历史/工作副本/preview残留。5秒启动样本debug RSS516710400字节/聚焦CPU37.00%，失焦518504448/5.00%；release338276352/9.00%，失焦338616320/5.20%。原始JSON为validation/phase3b/ssh-network-defaults-startup-{debug,release}.json；短样本不证明长期泄漏与否，也不宣称失焦开销已消除。Windows/Android实机及完整应用仍未完成，NDK检查不是APK验证。
