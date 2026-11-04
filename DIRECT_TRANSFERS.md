# 安全服务器间直传（源码编制中，未验证）

V1.4要求优先安全rsync/scp，不能通过复制私钥、读取服务器已有凭据/系统Agent、关闭host key检查来凑出“直传”。正式任务新增显式策略、原Root探测、rsync正文暂存与原SFTP发布的源码；尚未统一生成/编译/运行，不能按可用或验收完成交付。

`ssh-core::direct_transfer::DirectProbe`新增只读探测命令编制及严格响应解析：目标必须来自原目标SSH身份回执，源应用Agent必须是用户明确授权的原epoch、仍Active且有足够剩余期限。没有授权不能自动新建授权、读系统Agent或上传密钥。实际派发前后还必须再次核对原双端代次和Agent；探测结果不是写入能力或长期授权。

固定Python代码只做系统路径工具/原通道Agent socket检查、源rsync参数支持和经SSH固定远端rsync版本命令。参数仅公共端点元数据的base64 JSON，不把用户名/地址拼成Shell命令；subprocess用argv且不启shell。环境排除用户PATH、askpass、预加载库及rsync/SSH变量；SSH `-F /dev/null`、无默认Identity/Certificate/PKCS11/系统known_hosts/代理/复用连接，只有当前通道获授权的SSH_AUTH_SOCK。全进程组限时结束并wait，stdout只固定枚举，远端stderr不回传。

KnownHostsCommand在源端只验证目标原SHA256指纹，重新计算所见公开key blob摘要再输出固定HostKeyAlias的known-host行；ORDER阶段不输出任何信任。StrictHostKeyChecking保持yes，禁DNS信任/自动更新/本机host文件写入；RSA只允许SHA2协商，绝不启SHA1。此方案不需要把目标完整公开key另存远端临时文件。

官方依据：[OpenSSH ssh_config](https://man.openbsd.org/OpenBSD-current/man/ssh_config)中KnownHostsCommand/TOKENS与身份、配置选项；[rsync官方手册](https://www.samba.org/ftp/rsync/rsync.1)中protected arguments。具体源端OpenSSH版本/参数兼容仍需最终真实私有服务器验证，不把文档审阅当运行证据。

当前已新增**准备/解析及原Root只读派发源码**，尚未接入任务文件暂存与发布、UI策略/队列或续传。下一步必须继续这些接线，不能让尚未取得派发/完整传输回执的probe冒充复制成功；未知写入不得自动转中继或重发。来源删除仍只在既有完整目标确认后独立进行。

新增Rust3项及Python2项测试源码（原授权epoch/期限、端点与Shell隔离、限定响应、指纹重算/ORDER/不匹配、SSH argv/配置/算法），均未执行。只做Rust格式及Python AST语法解析/diff；未执行任何远端命令、真实Agent或测试账号操作。


## 原Root只读派发源码续接（未编译运行）

DirectConnector属于SshConnection的原Root，单槽独立于PTY和资源检查；ManagedSession必须传确切generation取得它。原PTY未配置/获准应用Agent endpoint时拒绝派发，派发前后复核原授权epoch/Active，专用通道请求与PTY同一已协商Agent协议。兼容OpenSSH连接级重复请求的Failure，同时固定脚本要求该会话有socket；不把服务器已有用户SSH配置作为认证来源。源服务器掌握自己环境，与既有应用Agent明确授权的风险边界相同。

未决OPEN跟随原槽直到晚回执或Root结束，操作有期限且捕获unwind后仍收尾已知通道；CLOSE未知保留唯一槽到Root关闭，防重复探测无限堆积。原Root关闭显式等待此槽，无Transport重连/PTY输入。关闭exec不证明远端进程已经退出，更不授予后续写入或来源删除权限。

新增私有双OpenSSH源码测试1项：未授权拒绝→原应用目标密钥授权→确切目标指纹/工具可用→改变指纹拒绝→撤销拒绝→PTY仍可输入→旧Root关闭后能力失效。最终验证须系统ssh/rsync/python3；缺工具不能算该测试通过。没有执行真实Agent或这项测试，Bridge任务/实际文件直传接线继续待做。


- DirectConnector追加受控SSH peer测试源码：明确授权后故意延迟OPEN，取消返回但仍占原slot，晚ACK后不得发送exec（实际server计数，不以空stdout冒充没有执行），下一未决OPEN期间Root关闭等待worker。此为协议所有权夹具，不是rsync真实直传；未执行，仅rustfmt/diff。


## 2026-11-03 正文与任务接线源码（UNVERIFIED）

- enqueue_remote_copy/move追加可选allow_direct，缺省false防止旧客户端/设备日志被追溯提升为exec权限；新正式确认入口明确优先直传及SSH/SFTP路径一致条件，可独立关闭直传或中转。自定义SFTP虚拟根与Shell路径不一致必须仅中转；不无条件推断两种路径命名空间一致。旧relay_permitted缺省true只保持此前已经明确授权的中继，direct_permitted缺省false；新策略随设备日志持久化。
- 仅原实际目标回执地址/端口/指纹/用户、原两端代次、原应用Agent有效授权可以探测。无中转许可时先只读预检再入队；准备跨await前固定Vault实例，最终在传输gate内核对，切库拒绝旧请求。需要跳板/客户端代理而源端不可直达或缺Python/rsync/procfs时，仅明确许可才回退中继；不复制密钥、不读系统Agent/远端默认凭据。
- 每文件先持久化既有Intent，原目标SFTP CREATE_EXCL/0600建立32字节一次随机cap并确认文件CLOSE；rsync接收器只能以NOFOLLOW打开这个已有标记，恒时核对cap后截断，不能在同地址但不同文件系统上创建另一个目标。源FD冻结普通文件/预期大小；目标继承父目录FD，原inode/0600/完整大小及fsync复核后才退出成功。只有实际rsync回执+目标SFTP属性确认才发布Ready，再复用原冲突/发布/私有暂存清理和跨服来源删除。
- rsync固定argv/受保护参数、私有随机basename，正文不经FRB/本机磁盘；原应用Agent向原源Root专用通道转发。Source/Receiver只运行固定代码，不收任意命令。已确认文件不重传，未发布不当完成；探测前可降级、明确允许且尚未写入的单文件可中转，已经发出的未知直传绝不自动重发/改中转。原子覆盖不支持且未允许中继时保留已确认暂存并报错，不违反用户策略。
- 单任务仍3个文件准入，原源Root的直传槽串行；不同Root与中继保持原并发/FIFO。每个任务单独记录自己的真实exec操作，避免其他任务同Root的探测误伤本任务收尾。取消/未知CLOSE仍保留任务owner、检查点和Vault门控；Root断开即使子任务停止报错也必须继续关闭Root，才能解除旧实际IO。大文件没有任意1小时总期限：rsync使用与既有SFTP量级一致的30秒IO空闲期限，SSH单独有连接/存活检查；关闭SSH通道不保证远端进程已退出，仍作为未知结果处理。
- 队列区分direct/relay/mixed；直传仅按完整文件回执确认字节，禁止用瞬间ACK跳跃伪造实时速度/ETA。本机不能准确限制服务器直传带宽。实际文件中途暂停/断线可能保留Intent未知，当前不盲用部分文件续写；应先结束旧Root、显式核对/清理旧暂存并新建任务，已成功兄弟不因重试重复传。**直传中断后的精确分块续传/远端执行结果再确认仍待后续完善，不能将其等同既有SFTP续传已验。**
- 新测试源码：写命令/限定回复、每任务真实收尾隔离、无中转策略codec与旧字段默认、仅直传选择器、接收端错误cap/权限/链接/缺失不截断不创建、真实私有Native直传复制/移动/撤销及明确仅中转；扩展原真实OpenSSH测试为正文完整性、阶段顺序、边界暂停/明确继续。均未执行；原5项准备器测试和受控晚ACK测试也未执行。
- 仅执行Rust/Dart格式解析、Python AST及错误边界源码清单/diff。新增DTO和API参数须最终正规FRB生成；依赖/锁/编译/Analyze/Clippy/测试尚未启动，实际工具参数和proc FD兼容仍留统一验证，Windows实机未验。


## 2026-11-03 中断回执核对及 rsync 增量恢复续接（源码，UNVERIFIED）

本节覆盖前述“未知结果再确认/部分续传尚缺”的旧状态，但不代表已运行验证。新设备检查点 `StagingPhase::Direct` 保存随机32字节能力及单调 attempt，仍使用原本机加密分块日志，不进入配置同步/备份，Debug仅显示阶段名称。每次远端尝试前先保存；旧无能力的Intent不能倒推或收养。

原目标接收器持原 staging inode 的排他 flock，以有界原子 `user.hspterm.direct.v1` xattr 保存设备/inode/预期大小/attempt/进程组/writing或complete及HMAC-SHA256标签。标签使用设备检查点能力作密钥，xattr不含原始能力或可重用秘密。首次先XATTR_CREATE+fsync认领，才允许截断一次原32字节标记；恢复只接受上次认证attempt，保持部分字节，XATTR_REPLACE+fsync记录新尝试，再启动独立rsync进程组。成功须rsync退出0、原inode/0600/完整大小及fsync，才发布complete；不据文件长度推断成功。

明确继续原任务时，经原源Root/有效应用Agent和固定目标指纹运行只读核对；固定响应最大4096字节/7秒，外层原Root仍有实际通道所有权。flock占用、旧进程组仍存在/权限不足/pgid未知均不能重发。已完成回执只经原目标SFTP大小/类型复核进入Ready，无须重新读取来源正文或来源父目录。partial确认旧进程组已消失后，先落下一attempt，再运行rsync正常delta恢复；`--ignore-times`防同大小mtime快跳过，**不使用--append，不把部分文件大小当连续已确认偏移**。成功兄弟和发布/来源删除语义不变。暂停保留Direct，取消实际操作仍按原owned IO收尾；需要新Root/授权时仍必须用户明确操作。

限制：接收Linux文件系统必须支持user xattr；不支持不假报成功，也不在已产生Direct意图后盲改中继。创建cap/首次claim中断可能仍无法确认；启动子进程与持久pgid之间崩溃留下pgid0时保守拒绝自动恢复。PID复用或僵尸可导致保守Busy，不向未知进程发送终止信号；明确风险清理沿原暂存入口。完整回执是小型非秘密inode元数据，随最终rename保留，未添加自动移除xattr的步骤；不保存源mtime/权限。信任边界仍包括用户授权的远端账户，同账户恶意进程不被视作隔离沙箱。旧不带能力的日志不能升级为新收据。

新增Rust回执解码/Direct日志约束2项、Python控制接收器2项（另原2项负面控制修订）、私有双OpenSSH丢Ready本机检查点后不重读来源正文的恢复场景源码。**均未运行**；真实网络中途断开后部分delta恢复/忙进程/零字节/xattr不支持/跨启动与Agent再授权仍需统一验证。实际仅rustfmt、Python AST、源码错误保护清单与diff，未编译/测试/生成绑定。

实现依据：[rsync官方手册](https://download.samba.org/pub/rsync/rsync.html)、[Linux flock](https://man7.org/linux/man-pages/man2/flock.2.html)、[xattr](https://man7.org/linux/man-pages/man7/xattr.7.html)、[kill](https://man7.org/linux/man-pages/man2/kill.2.html)。文档审阅不等于目标环境运行证据。

- 续增统一阶段测试源码：原私有双OpenSSH夹具加入确定性错误部分basis，使用原固定receiver+受控失败工具仅准备认证写入回执，再让真实rsync/SSH增量恢复并检查完整字节/attempt2/无中转/来源保留；这不是实际网络中断测试。Python再加空文件真实成功回执与认证pgid0未知窗口拒绝恢复。均未执行；实际网络中途断开和长时并发仍须统一阶段验证。
