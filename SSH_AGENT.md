# SSH RSA 与应用内 Agent 转发

V1.4 §3.1。Rust核心、正式主机选项、FRB原会话授权确认/状态/撤销及工作台UI已接入并通过Ubuntu验证。完整V1.4仍有大量独立功能未完成，不能将本模块完成视为整个产品完成。

## RSA 私钥认证

现有 ring 0.17.14 后端承担 RSA PKCS#1 v1.5 / SHA-256、SHA-512 私钥签名，不启用 RustCrypto `rsa`。2026-10-27 核对 [RUSTSEC-2023-0071](https://rustsec.org/advisories/RUSTSEC-2023-0071.html) 仍无修复版本。无新增外部依赖版本；已有 crypto-bigint 开启 zeroize，仅以固定 U4096 的常数时间余数补 OpenSSH 未保存的 CRT dP/dQ，私有临时值及编码缓冲清零。实际组件验证和签名都交给 ring，不自写 RSA 模幂。

支持 OpenSSH 格式、可带口令的 2048–4096 位 RSA 私钥。SHA-1 不降级；不支持的位数/组件在认证前明确失败。无 EXT_INFO 的旧服务器可明确尝试 SHA-256，明确不支持 SHA-2 则拒绝。缓存准备结果，主应用在 blocking worker 准备组件，非 RSA 不再等待 RSA 扩展查询。

后续RSA批次已补PKCS#1/PKCS#8与PBES2/传统AES PEM导入、ring SHA2主机验签及每次rekey信任检查。边界/成本限制/实际测试位数与结果见SSH_RSA.md；不能表述为所有RSA格式/任意位数/平台实测完成。

## Agent 连接与授权生命周期

`ConnectConfig.agent_forwarding` 默认 false；true 时 PTY ACK 后、Shell 请求前申请 Agent socket。被拒不关闭正常 SSH；未申请/未授权的入站始终拒绝。遵守 [RFC9987 §7](https://www.rfc-editor.org/rfc/rfc9987.html#section-7)：只有明确 `agent-forward` 值为字符串 `0` 才请求 `agent-req`，其余兼容 `auth-agent-req@openssh.com`；入站支持 `agent-connect` / `auth-agent@openssh.com`。这不是 Windows 系统 Agent，不读取外部 Agent 或任何默认密钥文件。

`SshConnection/ManagedSession::agent_connector` 仅返回原 Transport 能力。调用者必须先显式选择应用内密钥并确认本次限时授权，`authorise` 绑定原 epoch，最多 16 个、授权最长 1 小时；旧确认、撤销、原 Root 关闭、重新连接均不继承授权。撤销只关闭 Agent 权限及流，不关闭 PTY/SFTP/TCP 转发。远端能在授权期间请求这些密钥签名，应在正式 UI 中说明风险和实际目标。

最多 4 个入站流，共用容量 4 的请求队列和单个 blocking 签名任务。帧 256KiB、公开密钥 16KiB、待签数据 128KiB；仅允许身份列表与签名。添加/移除密钥、锁、PKCS11、扩展等拒绝；RSA flags 按位集合处理，2→SHA256、4/6→SHA512，0（SHA1）及未知位拒绝，非 RSA 仅 flags0。回复仅公钥/签名，注释为空，不返回原私钥。

消费驱动接收窗口复用已验证的 russh 有界 FIFO/credit，慢 Agent 流不能阻塞共享 PTY dispatcher；后续PTY/SFTP已显式选用session消费窗口（SESSION_FLOW）；原库默认接口/跳板策略不变。每个实际目标/跳板 Client 独立路由。Malformed/截断帧只关闭该流并计元数据错误，不记录请求正文。限时使用单调时钟与壁钟双检查；每次操作复查，不定时轮询。Android 挂起恢复/锁屏生命周期仍须平台集成和实机验收。

ManagedSession 正常断开、错误、退出均先等待连接收尾，`close` 等待心跳、Agent worker 及在途 crypto；取消 blocking job 不冒充已停止。Root 子令牌不取消外部父令牌。

## 压力修复与密钥解析边界

重复真实压力曾复现撤销后 PTY 停写：绝对窗口更新把已预留、仍在队列的发送额度恢复，超发进入全局 pending-data 门控。仅消费驱动通道现在增量 grant 新 ACK，保留共享预留，不取消全局有界门控；默认非流控通道沿用原行为。`channels/send_window.rs` 被测试直接引用，覆盖排队与 ACK 交错、溢出不改值；真实 OpenSSH 慢消费者修复后五次重复通过，完整核心回归172项通过。最初单次通过不足以否定竞态，失败日志保留在忽略的 .local。

OpenSSH 私钥 bcrypt rounds 限1–256（默认16），在不可抢占派生前拒绝0/257/u32::MAX；更大 rounds 的外部文件需在可信环境重新编码到受支持参数，不假装错误口令。Base64 中间字符串/解码缓冲使用 Zeroizing。此资源边界另补恶意参数即时拒绝测试，最后46单测+4 RSA+6 Agent专项通过；Clippy和NDK共享核心check再次通过，不将预计173项称为新全量运行。

## 可复现验证

前置：Ubuntu、ssh-keygen、OpenSSH sshd、Python3、openssl、当前账户可用于隔离 loopback sshd。所有测试键与服务器都临时创建、自动回收；无生产账户或系统 Agent。

```sh
export PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH
CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=2 cargo test -p hspterm-ssh-core --locked -- --test-threads=1
cargo clippy --workspace --all-targets --locked -- -D warnings
```

专项在 `agent_protocol/agent_signer/agent_forward` 单测和 `tests/openssh_agent`、`tests/openssh_rsa`：真实 Ed25519 验签/帧与权限边界；真实 OpenSSH RSA256/512 登录/PTY/SFTP、弱密钥/错误口令；两台隔离 sshd 经应用内 Agent 身份列表及认证、撤销/到期/新 Root；RSA flags2/4/6 由独立 openssl 验签并拒绝错误正文/弱算法；真实 OpenSSH 四个不读回复的 socket 与 PTY 共存；受控 SSH peer 验证标准协商、双通道别名、4流容量/错误计数及签名压力时 PTY。受控 peer 是协议测试，不能称真实 OpenSSH 新标准协商已验。

最终执行结果、在途日志和构建状态以 PROGRESS.md 为准；Windows/Android 实机未验。

## 正式工作台接入（2026-10-27）

主机管理→认证→“申请应用内 Agent socket”，正式保存后仅下一次明确连接生效。终端所属标签组菜单→“应用内 Agent · 限时授权”，选择已保存主机的应用内私钥，预览实际 SSH 目标/主机指纹/所选公钥指纹，勾选风险确认后授权。默认5分钟，界面支持1/5/10/30/60分钟；Native接口限1–3600秒、1–16个不同密钥。没有文件扫描或系统 Agent 读取。复制主机只复制 socket 偏好及独立凭据，不复制授权。

关闭此对话框不撤销现存授权；撤销按钮等待原 worker 收尾，保留 PTY。断线、手动重连、密钥凭据修改/来源主机删除、切换或重新打开配置库都会使相关授权/旧确认失效；库重开后原终端须明确重连才能再次授权。保存非认证元数据不热改原 Transport。服务器拒绝 socket 时仍保留普通 SSH Shell。

预览只保留120秒内存票据与非秘密身份、凭据摘要；不保留预览解析的私钥。最终确认在 Rust 再次读取凭据，复核原 nativeID/代次/端点、Vault.instance_id、来源主机/凭据ID及内容摘要和实际公钥指纹。重复公钥、旧票据、复用票据、取消票据、跨代次和跨库均拒绝，不撤销其他会话或静默建立 SSH。运行授权、票据、临时端口均不持久化/同步。

锁序为 Entry 操作名额→全局 Agent 读写门控→Vault→registry→core；不持 Vault 或 parking_lot 锁跨网络/crypto await。每 Entry 最多一个准备/确认批次；名额在等待切库读锁前取得，且跟随实际 blocking worker，即使调用者消失也不会提前释放。关闭/断开先禁止新准备，再等待原批次；切库写门控等旧准备/确认结束，在替换库的同一 Vault 临界区同步改变原 connector epoch，封闭最终检查与异步安装之间的竞争。现存签名 worker 独立于配置锁，撤销后不再发布新签名；收尾等待其结束。

状态经原 worker watch、Weak registry 和100ms固定窗口触发已有事件流。Controller.agentChanges独立于绘制通知；只在生命周期有效性实际改变或 Agent 元数据改变时刷新，100次绘制通知不触发密钥列表查询。隐藏终端仍接收状态但无帧拉取。密钥元数据读取失败不会隐藏原授权或禁用撤销。crypto worker panic明确标失败并向收尾报告，不冒充成功/自然到期。

## 正式验证节点

完整 workspace 330项、Flutter206项（5:02）通过；Clippy all-targets拒绝警告、Analyze、NDK25/API26 aarch64共享核心check通过。4项组件与2项真实Native/OpenSSH测试覆盖上述状态、原代次、库重开、凭据更改删除、重复密钥/过量选择、隐藏推送和零绘制查询；另2项Rust门控测试验证阻塞任务调用者被取消后关闭仍等待、切库写锁阻止旧/迟到准备。实际GTK最终19秒完成主机开关保存、指纹/风险确认、远端ssh-add真实签名验签、对话框关闭保持授权、撤销不关闭SSH。三张干净截图在validation/phase3b/agent-{host-option,consent,active}.png；远端清屏顺序2J→3J→home并断言无登录背景，未修改图片。日志.local/agent-ui-gtk-clean-captures.log。正式debug/release均重建、SO同模式匹配、独立启动/resize/退出0；GTK之后再次构建正式debug入口，见PROGRESS。

正式 Ubuntu 验收构建：`cd ui_flutter && flutter run -d linux --release -t lib/workbench_main.dart`。原最小SSH入口 `lib/main.dart`、独立Mock `lib/prototype_main.dart` 保留；不要将Mock当真实Agent测试。Windows/Android实际运行与移动专用界面待验；共享核心check不等于APK/设备通过。
