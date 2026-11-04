# Google Drive 接入（当前静态源码，未统一验证）

当前已编写桌面授权、设备本机加密账号及正式设置入口。Drive对象层已有独立Rust源码，**正式目标选择/运行驱动尚未接入**，授权成功不表示配置上传或同步成功。Android开发暂缓，不能使用桌面回环授权代替Android原生授权。

## 授权与存储

`storage-sync::cloud_sync::drive_oauth` 仅使用用户注册的桌面OAuth客户端。外部系统浏览器、S256 PKCE、一次性随机state、固定IPv4回环随机端口和精确Host/路径校验，最多16KiB回调头/64个连接/每连接2秒/总操作5分钟。不读取既有Cookie、Codex凭据或其他应用账号。

仅请求 `drive.appdata`；不请求邮箱/用户资料。UI不能确认邮箱身份，由系统浏览器中的Google账号选择/同意页提供确认。未知/扩大权限响应拒绝保存。首次授权要求收到离线刷新令牌，缺失不伪造已登录。访问令牌只保留于原Rust操作内存，没有启动刷新或空闲轮询。

`local-google-drive-account-v1`保存独立刷新令牌和可选client secret，使用原Vault AES-GCM，不参加备份或配置同步。View只有scope、修订、公开client ID及本机随机authorization ID。原账号快照和已保存独立同步代理/秘密在最终SQL同事务比较；旧浏览器不能覆盖重新保存/切库后的账号。

WebDAV与OAuth复用相同HTTPS/TLS/禁重定向/无环境代理/无自动重试的HTTP客户端策略。授权始终固定原已保存独立代理；未保存的表单不影响在途操作，失败不回退直连。客户端秘密、状态、verifier、原响应和受控令牌缓冲使用清零所有者；Flutter字符串和HTTP库内部副本无法承诺全程擦除。

## 生命周期和明确动作

原票据先reserve，再绑定listener/返回验证过的系统浏览器URL，finish等待原回调并在SQL ACK后返回元数据。全局一个名额，原RPC门控租约进入阻塞worker；取消/切库/退出等待实际结束。错误消息为固定中文，不带响应正文/令牌。7个新增API源码尚未生成，不能运行旧绑定。

“仅移除本机授权”不请求Google撤销。“撤销Google授权”需要单独确认，Google确认后才尝试删除原本机账号；超时/取消保留原本机凭据并明确未知。成功撤销可能影响同一OAuth客户端的其他有效令牌。远端撤销和本机删除不能原子提交，后者失败需重新读取状态；16项固定结果码仅进程内保留，防退役竞态丢掉未知结果。

完整备份恢复会更换Vault运行身份：取消旧授权，真实后台工作退役后重新读取账号/重建同步监视器，没有启动HTTP。普通云合并保留运行scope，不走该广泛失效路径。

## 静态审核与待验证

新OAuth5、账号3、Bridge授权2、同步退役1、Flutter7，共18项测试源码尚未执行；覆盖RFC7636向量、浏览器URL、回调攻击边界、本机加密/旧来源/最终代理CAS、真实租约等待、启动无网络、错误浏览器、晚reserve、原回调取消和明确移除/撤销。原备份及云白名单测试增加账号排除。仅格式化解析/diff检查，不等于Analyze或编译通过。

统一阶段先解析依赖/更新锁、正规FRB生成，再编译/Analyze/完整测试。需要补受控HTTPS OAuth服务器夹具（不能用模拟方法称Google实测）、真正浏览器回调/拒绝/关闭、代理中断及真实Google项目验收。后者需要用户自有桌面client和明确账号授权；当前未获取，不访问真实账号。

后续Drive传输需明确appDataFolder对象ID，不能把同名文件当唯一对象。分页不完整/重名须可处理，不能静默选第一个。条件写入必须真实有效，缺强版本证明失败保留两端，不做无条件覆盖。

## 官方依据（2026-10-30读取）

- [Google桌面OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)：PKCE、外部授权及桌面回环；DPoP当前可选，本实现未请求令牌绑定设备密钥。
- [应用数据目录](https://developers.google.com/workspace/drive/api/guides/appdata)：最小应用数据权限与目录边界。
- [预生成文件ID](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/generateIds)和[上传](https://developers.google.com/workspace/drive/api/guides/manage-uploads)：appDataFolder ID及明确409冲突，不凭文件名防重复。
- [RFC8252](https://www.rfc-editor.org/rfc/rfc8252)和[RFC7636](https://www.rfc-editor.org/rfc/rfc7636)：原生应用/PKCE安全边界。


## 同批继续：Drive 文件层（仍未接正式目标）

新增drive_files固定Google API origin/appDataFolder、至多32页/512对象/单响应256KiB的完整发现；同一集合多个ID保留全部供明确选择，缺页/重复token/不完整搜索/未来格式不作空成功。只查询本应用元数据，不读其他个人文件。

预生成ID为Rust内不可序列化能力，明确create才上传单个完整加密文档（multipart metadata+ciphertext），不先创建空正文占位。ID防重复依据官方generateIds/appDataFolder及409约定，不凭名称假设唯一。已保存对象404不当Missing，也不创建新ID或替代对象。

读取先校验原ID/集合/类型/应用元数据和强ETag，条件读取媒体并检查字节数，竞态重读至多三次；更新再次用原ETag复核对象与集合，最终只带If-Match PATCH。创建/更新都要求强新ETag及完整相同对象ID回执才构造ACK，超时/取消/缺etag/错ID/响应中断明确未知，不更新本机基线或盲重发。没有无条件覆盖、DELETE、启动请求或定时刷新。

**条件请求的Google实际支持仍未验证。** 当前官方v3文档没有足够明确地承诺所有媒体写入/元数据ETag组合语义；源码选择严格失败，不用version字符串伪造ETag。统一阶段须在明确授权的私有测试对象验证陈旧If-Match真正返回412、元数据与媒体版本对应、上传响应etag和ID；缺能力时需要调整传输设计，不能将模拟HTTP夹具当Google服务保证。此项影响Drive可用性，不能标完成。

新增6项Rust测试源码，覆盖完整分页/重名、不完整及未知格式、已存404与媒体If-Match、对象复核与PATCH、预生成创建/缺etag未知、路径/跨集合边界，全部未运行。仅格式解析/diff。真实OAuth账号未访问；正式目标扩展、账号/刷新令牌轮换CAS、驱动与审阅/取消UI接入仍是下一开发入口。

同批静态审查把外观/归档的回执丢失文案改成“重新读取当前状态”，避免SQL可能已提交却写成“数据库绝对没变”；失败画面仍保持上次确认主题，旧选择不重放。


## 同批继续：原账号刷新令牌轮换

`Refreshed`现是不可序列化的原请求能力，内部绑定原client ID/secret/refresh token的摘要；刷新得到的新access token不再作为公开字段让Bridge提前取走。只有`Account.accept_refresh`在原Vault/账号快照和目标/代理前置同事务确认后，才返回访问令牌及更新后的原账号能力。远端返回新的refresh token时严格校验、加密原子替换，原本机authorization ID不变；无变化时不重写记录，不进入配置journal或触发同步回环。

旧能力不能覆盖后来浏览器重新授权、客户端不符、路由改变、旧scope或SQL失败；所有拒绝均保留当前本机记录。远端已经轮换而本机CAS失败无法回滚Google，须重新明确授权/读取，不能宣称原token仍有效。正式Drive驱动必须先处理这一ACK，再捕获包含最新账号检查点的本机提案，不能混用轮换前后来源。

新增3项领域测试源码（轮换/无变化/稳定ID及旧修订、来源/路由/SQL失败、后来的浏览器授权保留），未执行；仅格式解析/diff。正式单目标/运行驱动尚未接，本节不代表Google真实授权或同步通过。


## 既有对象正式驱动（静态源码，未统一验证）

Target.drive明确绑定file_id/client_id/authorization_id，endpoint必须为固定Google文件端点，禁止Basic认证。只有真实本机授权匹配才可启用；已知目标在账号移除后仍可明确禁用。不同客户端归档隔离，重新授权同对象保持基线。原账号正文与目标/秘密加入LocalProposal和最终SQL CAS；候选保留该本机账号，不参与云载荷。

configuration_sync::Workflow按提供方调用真实文件层，先共享OAuth名额串行化刷新、确认原账号与路由轮换，再捕获新检查点。账号更换不打断无关WebDAV。刷新取消/远端轮换而本机未ACK单独显示authorization_unknown，不能把它当配置写入/上传成功。操作生命周期、审阅和最终Agent→传输→Vault门控沿用原WebDAV。404仍为已有目标错误；当前尚未提供正式发现/选择/首次创建页面，不能宣称Drive功能完成。

账户与同步设置修订现为Vault私有派生HMAC，不向Flutter暴露可校验低强度密码的裸哈希；访问令牌依然只在Rust。本批所有测试源未运行；Google v3强ETag/CAS真实语义依然需要授权私有对象验收，不得退为无条件PATCH。


## 正式发现/选择（静态源码，未统一验证）

新增reserve/discover/select三个API，复用原授权registry/五分钟TTL及真实worker租约。只在用户点击后刷新并发现本应用对象，原账号/目标及代理校验，实际轮换先ACK后返回新账号元数据。列表保留同集合不同ID，前端不默认选中；最终只准选择原候选ID。不同目标必须明确提供该集合E2E密码，保存前完整账号/路由复核与原目标修订SQL CAS；更换唯一目标须明确确认，保存不上传。

GoogleDriveObjectsController由应用持有，设置路由卸载不丢失原Native操作；关闭/完整恢复会等待取消，取消退出可恢复控制器。UI只见对象ID/集合/大小、账号和目标元数据，没有令牌。Drive目标通用超时/独立代理/启用可直接编辑，对象和集合只读；切WebDAV仍明确确认。

新增Native2/Flutter4+Widget1测试源码均未执行，3个API尚未正规生成。首次创建和跨重启未知创建结果的本机持久保护仍待编码，不提供假创建按钮。真实Google媒体ETag/CAS支持仍未验证。


## 明确首次创建与跨中断恢复（静态源码，未统一验证）

`drive_setup`在当前Vault的两个本机排除记录中原子保存元数据和确切E2E密文；密码/旧目标原记录只在外层加密Vault内，正文不经FRB，不进入配置同步或备份。只能消费实际generateIds能力，不接受任意UI ID制造创建能力。独立新集合的初始快照经过允许投影/完整验证，包含已确认的凭据与命令历史范围；不读取字体/画面/设备任务。用户先明确同意敏感范围，准备后核对单位数、字节数、唯一ID，再明确开始。

已有创建意图阻止生成第二份记录。每次继续都重新确认原账号授权身份/路由/目标快照/当前允许配置，GET同一个预生成ID；完整同ID同集合强ETag媒体正文完全相同才确认既有创建，只有该生成能力的404才准POST同一确切正文。saved target的404规则不变；409/412及未知写不换ID、不覆盖。开始POST前先原子保存attempted；网络或ACK丢失保留同一恢复正文。若本机源配置改变则保留意图并拒绝旧上传，不能静默重新生成内容覆盖未知远端对象。

实际远端ACK后才保存唯一目标。设置/秘密/旧基线归档/新初始变更及退休两个意图记录同一SQL事务；完整源检查开始的data_version延续到最终IMMEDIATE事务，不能在末尾重新读版本掩盖外部写者。SQL失败不假称目标已选，远端对象可能已存在，手动继续仍核对原ID。第一次发布只建立对象/选择目标，不伪造普通双向同步或旧基线ACK。

5个新增API/正式设置中准备、核对、创建继续、读取本机恢复记录、明确仅清理本机入口已有源码。读取恢复元数据无HTTP，跨重启只明确继续。授权刷新、已准备、创建未知、远端已确认但本机未提交和最终本机提交使用不同固定状态；取消/退出等待真实worker。仅清理本机恢复记录需明确确认，它不会删除远端对象，且提示以后发现并选择原ID。全量备份恢复后重新读取本机元数据，不自动联网。

新增Core5/HTTP1/Native1/Flutter4共11项测试源码未运行；原HTTP夹具只验证协议，不能替代Google媒体强ETag/CAS真实验收。5个API未生成、未编译/Analyze/运行。真实账号、Google端能力/条件语义仍是独立待验项，未降级为无条件写入。
