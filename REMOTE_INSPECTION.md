# 可选远端资源与进程（静态源码，未统一验证）

Windows工作台底栏点击或终端标签组菜单→远端资源与进程。初始不请求网络；本终端本次SSH代次分别授权资源/进程能力，关闭面板不撤销已启用的资源采样。显式撤销立即停止本机调度并撤销原Native能力；断线/重连清空本机授权，绝不继承至新Root。独立Mock只说明不探测。

资源仅当前前台焦点终端且工作页可见时，每次完成后五秒再采一份，不追赶错过的周期；隐藏/失焦/退出停表，已有一次请求可以结束。失败停止自动采样，明确手动重试或重新授权；无资源监听、无授权时没有定时网络请求。独立状态通知不拉终端帧、不写PTY、不经全工作台普通状态通知。

## 远端边界

- 固定应用自有Python脚本经独立flow-controlled SSH exec运行，不安装文件、Agent或Shell插件，不开新的SSH。资源需要Linux procfs与Python 3.7+，其他服务明确不可用；没有远端程序依赖安装或系统配置修改。Python使用-I/-S隔离模式，不读取用户模块、环境、命令行参数或应用文件。
- CPU读取/proc/stat前八计数，避免guest双计；总量/idle差值产生使用率。内存使用MemAvailable，磁盘当前命名空间的根目录statvfs可用空间，网络汇总非lo接口（包括虚拟桥可能重复计数），不是网卡精确物理吞吐或完整磁盘仪表盘。相邻样本间隔1–30秒、同boot-ID且计数有效才算CPU/网络速率；首样本/归零/旧样本显示未知。
- 单次最多256KiB stdout+stderr；固定文件每份有界读取，进程扫描4096/显示512行，达到上限明确“不完整”，不可读/消失条目单独计数。只读PID/短名称/状态/UID/RSS/创建计数/CPU累计，不读cmdline、environ或凭据。所有结果仅运行内存，不记录/同步/备份。
- 所有Inspector clone共用同一原Transport单槽。PTY actor只交付能力，不等远端exec。八秒工作/至多两秒关闭预算；本地超时/丢RPC不丢弃russh在途channel-open，保留唯一worker等原ACK或Root取消。关闭发送未知也保留单槽到Root结束，不能手动重试积累无限清理worker。Root取消后等待真实槽退休再完成close。成功必须完整exec-accept、exit-status 0和输出结束，stderr不发布。

## 进程操作

进程列表仅明确读取，不周期刷新。Native保留原代次/原授权修订下30秒列表；UI对原冻结行单独确认风险，取消不发送。信号只允许原列表的PID>1且有效创建计数，消费列表后才网络请求，拒绝任意PID/伪造修订/重发。无sudo或SIGKILL。

远端必须有Python3.9+的os.pidfd_open与signal.pidfd_send_signal及相应Linux内核能力。脚本固定SIGTERM，检查boot-ID与/proc创建计数后，对已打开的pidfd发送，避免校验后PID复用误杀；不可用就失败，不回退普通kill。进程在列出与打开之间已变化时保守拒绝；不把进程名称当身份。内核接受信号只代表信号已发送，不代表进程已退出。丢回执可能已发送，UI保留明确未知说明，必须刷新/重新确认，不自动重试。

原生四个业务API都沿公共无source错误/panic边界；原代次/连接状态在能力获取前后、结果发布前复核。仅功能页启用，不是主机后台在线探测。会话关闭/应用退出先撤销并等实际RPC，最终Root负责等待所有原通道worker；布局移动、分屏与焦点切换不建立连接。

## 待统一运行

- Core3项：固定参数域/注入拒绝、数据完整性/重复进程/Bidi拒绝、不可能资源值。Bridge2项：默认拒绝/分别授权/原代次/撤销/永久关闭、列表过期/原行/一次性消费。
- 私有OpenSSH1项：真实资源、只对本测试自行创建的sleep进程测试错误创建计数不发送/正确SIGTERM、终端原PTY仍可用/已取消请求/原Root退休。仅该夹具允许结束其自有进程，不向用户进程发信号。
- Dart7项：速率/旧样本/归零；无启动请求及失焦停表；撤销后迟到结果；未知信号不重放及重连失效；小窗大缩放可滚动；独立确认取消与成功语义。Native1项：真实SSH默认拒绝/分别授权/非法PID与未确认拒绝/原代次/撤销/隐藏零帧。全部未运行。
- 统一正规生成FRB四API、依赖锁/编译/Analyze/Clippy及完整测试后再判定。当前仅Rust/Dart格式解析/Python AST/源码清单/diff，无Windows实测，不作功能成功声明。

参考：[Linux procfs字段](https://docs.kernel.org/filesystems/proc.html)、[Python pidfd_open](https://docs.python.org/3/library/os.html#os.pidfd_open)、[Python pidfd_send_signal](https://docs.python.org/3/library/signal.html#signal.pidfd_send_signal)。


通道退休静态复核补正：CLOSE发送入队不等于对端已退休通道；失败/取消/超量时，在同一两秒清理预算内发送CLOSE并有限排空至原通道Close/接收端结束（最多再256KiB丢弃正文，不发布）。未得到退休则保留唯一槽到Root取消，不能连续重试累积服务器未关闭通道。正常完整结果已看到Close时不再次等待。未执行协议夹具或运行验证。


新增独立受控SSH peer测试源码1项（不是OpenSSH）：延迟inspection session-open确认，本地取消后仍占唯一槽，晚确认仅关闭不发探测脚本，原SSH不受影响；第二个open保持不回ACK时，Root close仍等待并退休真实worker。此测试未运行，不据此宣称迟到ACK/关闭异常验收通过；含此前14项共15项测试源码待统一执行。
