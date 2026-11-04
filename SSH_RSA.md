# RSA 兼容性与私钥导入

当前代码沿用已锁定的 ring 0.17.14，不开启 RustCrypto `rsa` 功能，也不新增密码学依赖。依赖决定依据 [RustSec RUSTSEC-2023-0071](https://rustsec.org/advisories/RUSTSEC-2023-0071.html)（2026-10-27核对仍无修复版本）。

## 协议与生命周期

RSA 私钥签名仅 SHA256/512，私钥2048–4096位；原私钥准备与签名由 ring 完成。原 OpenSSH 缺失的 CRT 指数通过固定宽度常数时间余数计算，临时值清零，详 SSH_AGENT。RSA 公钥验证使用 ring，范围2048–8192位。实际验收位数以测试记录为准，不能将允许范围等同所有位数都经过真实服务器验证。

主机 KEX、OpenSSH hostkeys-proof 和受控服务器 userauth 均经统一验证函数。依据 [RFC8332 §3](https://www.rfc-editor.org/rfc/rfc8332.html#section-3)，SHA2 复用 ssh-rsa 公钥编码/指纹，短签名可省略前导零：仅按模数宽度左补零，不截断超长签名。KEX 签名算法必须与协商方法一致；HSPTerm 不提出 ssh-rsa/SHA1 主机算法，私钥/Agent 不降级 SHA1。非RSA族保留原验证后端。

每次 KEX（含 rekey）均调用信任策略；Client 保留原已接受 HostKey，相同身份无重复弹窗，改变则拒绝。原 Transport 的 `verified_host_key` 是握手中已验证的身份，不从后来打开的配置库重读。目标与跳板各有独立 Client/cache，不能混用。Bridge已使用此证明及原代次回执关联运行能力，详CONNECTION_IDENTITY；最新实际结果见PROGRESS。

## 外部格式与资源上限

- OpenSSH RSA；未加密 PKCS#1 RSA PEM；未加密 PKCS#8 rsaEncryption PEM。
- 加密 PKCS#8 PBES2（AES CBC/GCM、PBKDF2或scrypt）；遗留 OpenSSL RSA PEM AES128/256-CBC。遗留 EVP_BytesToKey/MD5 仅导入旧文件，不用于新存储或导出。
- PEM入口256KiB、RSA DER16KiB；两素数、版本0、2048–4096位。ring 从原 DER 导入并执行本地签名检查 CRT，再转换借用整数为受清零所有权管理的私钥；不丢弃错误 CRT 后重算来掩盖损坏。不分配随后丢弃的私密 dP/dQ Mpint。
- rsaEncryption 参数仅 NULL/缺省；可选 PKCS#8 公钥必须与私钥匹配。其他 OID（例如 PSS 私钥）不误当 rsaEncryption。
- PBKDF2 1–1,000,000次；scrypt的N必须大于1且为2次幂，r/p非零，N×r×p≤1,048,576，128×r×(N+2p)≤64MiB。派生前检查，不用超时取消不可抢占 KDF 冒充资源上限；显式派生长度必须与密码算法匹配。OpenSSH bcrypt仍限1–256轮。
- 解密正文/派生密钥/输入解码缓冲清零。错误只返回类别，不输出私钥、口令或签名请求正文。口令缺失/错误不会退回密码认证或另一私钥。不把提供口令的未加密 PKCS#8 错当密文。
- ring对RSA私钥指数等仍施加其自身验证限制；超上限外部密钥须在可信环境转换，不静默削弱算法或修改文件。

新密钥继续生成Ed25519；私钥导出仍走既有每次主密码验证、保留所存原格式的流程。本批未增加RSA PKCS#8导出API或系统Agent读取。

## 测试入口与结果

```sh
export PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH
export CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=2
cargo test -p hspterm-ssh-core --locked -- --test-threads=1
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build -p hspterm-frb-bridge --locked
cd ui_flutter
flutter test test/rsa_bridge_test.dart test/agent_bridge_test.dart test/native_bridge_test.dart
```

`openssh_rsa`：实际 RSA-only SHA256/512 主机、首次确认/指纹不符拒绝、PTY/SFTP、hostkeys证明和重协商；SHA1-only主机拒绝；错误正文/算法/损坏及超长签名/省略前导零。六种RSA私钥格式实际认证、错误口令/版本/截断/尾随/CRT、合法DER包装的恶意PBKDF2/scrypt成本。受控russh服务器RSA用户签名验证属于真实SSH协议测试，不能称OpenSSH服务端代码。

`rsa_bridge_test`：真实FRB加密PKCS#8凭据/RSA主机确认/大量输出中的重协商/手动重连，目标不是静态界面。已有Vim/tmux/htop、Codex合成provider和Agent/转发/SFTP回归须保留。

最终执行结果、日志和包状态见PROGRESS；未运行源码不计通过。Windows/Android实机仍待验，NDK共享核心check不等于APK或设备验证。

已执行节点（2026-10-27）：核心182项后借用整数修正补12项通过；Flutter207项5:02、Clippy/Analyze/NDK通过。正式debug/release及匹配SO、两个独立窗口启动/resize/退出0，日志.local/rsa-*；哈希/短样本见PROGRESS与validation/phase3b/rsa-startup-*.json。首次受控peer失败为公钥注释比较错误已修；rekey信任回调缺失确实已修，未跳过断言。
