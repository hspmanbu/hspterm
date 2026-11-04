# 原 SSH 内的 SFTP 恢复（2026-11-02 静态源码，未统一验证）

本批不重建SSH，不读凭据，不跨终端/代次重试；首次认证/host key逻辑不变。后台文件任务使用ManagedSession::open_sftp_with_retry，原generation随OpenSftp命令入actor；不得在重试时从当前连接重新采样代次。每次开通至多三次尝试，只有SFTP开通超时/明确的SFTP Timeout或ConnectionClosed参与，分别150/400ms间隔。权限/不支持/协议损坏/Root断开/容量不足立即失败，取消立即停止后续尝试。远端中转两端开通也使用此机制，传输中的中转恢复仍待后续。

本地↔远端文件夹并行流发现通道故障时，停止本次内部准入、撤销同通道其他文件流、排空所有真实Future，返回故障节点的稳定索引。其他文件的已确认字节/成功状态不清；取消的兄弟保留Pending及原偏移。目录操作瞬时失败在尚无文件流时即退出，避免把整棵后代误标成永久失败。

Bridge每次任务运行至多再恢复两个工作通道。先确认原连接身份与代次，再等待旧SFTP的本机IO实际退出；只将这次通道故障节点恢复Pending，保留目标策略/已确认偏移及其他失败和成功节点。完整保存检查点后才开新通道并继续。旧IO收尾不明、检查点失败、取消、身份变化或预算用尽都停止，不盲重连或无限重试。每次新开通内部仍有三次上限，因此单运行最坏最多九次开通请求；跨启动仍仅用户明确继续。

## 资源所有权

SftpConnector归原SshConnection，所有clone共享64个开通/活动流名额。未知SSH channel-open不能被本机超时或RPC drop丢弃，实际worker等待原ACK或Root取消；已知channel失败有限关闭排空，未知保持名额至Root。开通成功后名额跟随真正的双工Stream进入SFTP读写线程，不归API Future或Session包装对象；接收者消失会主动关闭。

Root退出先取消原socket，再等待全部SFTP实际Stream/迟到open名额退休。原PTy actor只交付开通Future，不等待协商；不会被SFTP服务器拖住终端IO。固定sftp subsystem、VERSION前不接受/丢弃不合法预发送正文，不添加任意exec。上限失败明确可见，不自动释放仍未知的通道名额。

vendor的close现在证明本机读写owner已退休，明确不称远端SSH ChannelClose ACK；配置的请求超时也约束close等待。真实文件CLOSE成功响应、文件大小与字节确认仍由原stream primitives决定。错误分类由固定类型传递：本地磁盘错误、权限STATUS和畸形协议不可凭相似文字重试；末端协议失败缓存防晚请求被错误降级成EOF。

## 测试源码及统一验证

新增9项未运行源码：Core分类1；独立IO/协议4（延迟本机shutdown/超时不冒称完成/畸形协议在迟到请求仍拒绝/确认偏移后注入通道断开并换通道完整恢复）；受控SSH peer4（64未知open的真实边界、晚ACK不请求subsystem、最多两次重试及原代次拒绝、明确拒绝不重试与取消）。SSH peer不是OpenSSH实测。只对自有duplex/私有loopback处理，不触碰外部账号、用户服务器或进程。

实际仅Rust格式及vendor语法解析、公共Result边界源码清单/diff；未解析依赖、生成FRB、编译/Clippy/Analyze或运行测试。统一阶段必须执行全部原SFTP预算/目录/编辑/发布/传输以及新增故障回归，Windows实机仍另记。Android暂缓，不因共享核心修改宣称Android验收。


## 远端中转：并行及安全恢复（新增源码，未执行）

`RemoteTree::run_parallel_observed`由正式remote_transfers以3文件调用，原`run`保留。FileWork只持单节点及原staging index的确切源/目标/暂存路径；一份共享主清单，短同步互斥仅在回调期间使用，不跨await。目录先验证，文件Future协作并行且归run直接拥有。Intent→Writing→Ready→Publishing→Published的每个持久屏障仍同步完成后才继续请求；失败时停准入/取消兄弟并排空CLOSE/ACK，没有异步丢弃的检查点。队列active_files复用本地任务DTO，不显示成功文件列表。

工作通道故障仅原两端实际身份及generation继续有效时最多恢复2次；两旧SFTP本机IO都退休之后，保存完整原计划、只reset分类器给出的稳定节点，再开同Root通道。每次开通自身仍最多3次，不建立新SSH。成功节点、原随机staging_id、阶段、明确冲突决定及确认偏移不重置。只有typed通道原因且所有CLOSE原因同属瞬时错误才接受，权限/坏包/普通本地IO超时/取消/无效偏移不能因一个后续通道错误被覆盖。

文件允许自动恢复的阶段仅Absent（无写意图）、Writing（已确认私有OPEN，可偏移继续）、Ready（完整私有副本）。Intent、Publishing、Published分别涉及未知创建/替换/清理，不因大小相同推断成功或自动重发。并行兄弟被取消且位于这些未知边界时单独标失败，不能在自动恢复循环中再次修改。对用户明确暂停保留原既定手动继续行为；这不是自动处理未知发布的功能，也不是跨服务器剪切/来源删除实现。

11项新增测试源：分类3、受控协议发布4、私有OpenSSH3、Native1；全部留最终统一阶段。静态检查发现旧vendor `server::run`实际另起后台任务，外层JoinHandle不是服务生命周期，已新增兼容的`run_owned`并修正本轮/上一轮新夹具，使断链注入与await对应真实服务Future；不把未执行夹具描述成故障通过。旧API仍保留，生产客户端没有增加服务端任务。


## 任务级通道owner与异常收尾（新增源码，未运行）

frb-bridge::transfer_channels由Job/CopyJob持有，原blocking run只借用。每个初始/替换SFTP都登记Arc；最多原本的3/6个阶段会话，不复制正文或新建Root。supervise在原Future的Rust unwind/正常错误后关闭全部实际会话，未获双本机IO完成确认的引用保留；下一轮先收尾旧引用，失败不开始新写入。关闭Future被丢弃也不能先删除记录。只在确认完成后移除owner，取消/清理UI行/切换Vault均不能丢未退休记录，普通配置同步不清任务。

FIFO permit归真实blocking worker，包含收尾和失败检查点。panic仍表示结果未确认，不是可自动重试故障；不能恢复abort、OOM、栈溢出或原生异常。vendor local_io_closed只读原Completion两位，不证明peer ACK或文件CLOSE。任务结束busy/finished屏障覆盖真实cleanup，取消优先于后来的暂停请求。

另补本地任务最后dirty块屏障，删除任务记录失败时已经成功的节点也在原检查点，不依赖250ms周期恰好执行。3项新Bridge协议夹具及原Native的SQLite删除故障/成功文件不重传扩展源码均未执行；没有新的编译/测试通过结论。


## 2026-11-02继续：普通SFTP操作原代次与生命周期（源码未验证）

- api::remote_sftp在首个await前捕获原代次，cache锁排队/旧通道退休/新协商后均复核原Root与关闭状态，不能等待后借新代次；旧/迟到通道明确close成功前不丢唯一cache引用。同代次实际IO已退休不复用；只有通道建立用既有typed有限恢复，不重试任何文件mutation。
- 新建目录/更名/删除3个既有API追加可选expected_generation，旧调用保持None，正式Model全部固定提交时原nativeID/代次。批量选择先冻结，每项前复核，关闭/重连停止余项；请求加入原pending。刷新只失效受影响目录并按原目录/请求epoch复核，不在导航/重连后覆盖新视图；重命名目标取所选文件原父目录，不跟随后来OSC7目录变化。
- 新私有OpenSSH Native测试源码1项：旧代次3类mutation全部拒绝/源目标不变，当前代次明确新操作可完成且原终端保持连接。未运行；新增参数需最终正规FRB生成。仅Rust/Dart格式解析/216源码保护清单/diff，统一依赖/编译测试仍未开始。
