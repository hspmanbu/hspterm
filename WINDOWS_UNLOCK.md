# Windows 账户便捷解锁（静态源码，待统一验证）

默认关闭；仅 Windows 正式工作台提供。设置 → 加密存储中明确确认当前账户风险并重新验证主密码后启用；启动仍先显示锁库页，用户点击「使用 Windows 账户解锁」才读取缓存，既不自动解锁也不自动连接 SSH。手动主密码入口一直保留。

## 数据及身份边界

- SQLite 仍由既有 Argon2id/AES-256-GCM 保护。Rust `secure_unlock` 从当前连接的格式版本及16字节随机salt生成域隔离SHA-256 token；token不是密钥。启用还必须匹配本次Vault实例scope并通过主密码验证。
- Native只接受64个小写十六进制字符token，不接受任意文件路径。用SHGetKnownFolderPath(LocalAppData)派生 `HSPTerm/SecureUnlock/<token>.dpapi`。缓存无配置索引，不参与云同步/配置备份；关闭只删除当前token缓存，不删除SQLite或凭据。
- CryptProtectData/CryptUnprotectData采用当前用户上下文、额外token+产品域entropy及CRYPTPROTECT_UI_FORBIDDEN；不用LOCAL_MACHINE或交互提示。当前Windows账户中有权运行程序的人也可能解密，无法把它当作第二因素；忘记Windows账户/迁移设备时应使用主密码。
- 缓存 `HSPDP001` + u32小端密文长度 + DPAPI密文，长度最多64KiB。普通文件/重解析点检查、有界读取；随机CREATE_NEW同目录临时文件写入并Flush/关闭后MoveFileEx发布。失败先关闭再删自有临时文件。缓存存在只表示格式可读，不表示Windows能解密。
- 读取失败/损坏状态不按“未启用”默认覆盖；可以显式确认清理当前token缓存。底层只有密文落盘；可控UTF8/原生堆缓冲擦除，但Dart不可变字符串、编解码内部副本不保证全部擦除。

## 开库及生命周期

正式UI首次创建使用 `create_configuration_vault`（create-only），已有库使用 `vault_unlock_hint` + `unlock_existing_vault`（open-only，安装为活动Vault之前核对稳定token）。便捷解锁同样用这条open-only通路；文件删除、替换、旧密码均失败，不会自动新建库。旧最小测试入口的兼容open-or-create API保留。

启用写缓存由Model.runLocalSettings跟踪，退出等待操作完成；根锁库页退出等待在途开库和Model清理，避免原生窗口/MethodChannel先销毁。设置操作的ACK与刷新失败分开；换库后不重复原操作。没有后台轮询、原始密码日志或SQLite内密码副本。

## 尚未执行的统一验证

- Rust secure_unlock两项：只读hint不创建、元数据版本、稳定token与原scope/密码验证；Native桥接两项：create-only/open-only/token隔离，模拟Windows通道只验证核心调用。
- Flutter组件六项：显式同意/取消、错误密码/旧scope、未知缓存状态、非Windows隔离、退出等待、null通道响应拒绝。Mock不证明真实DPAPI。
- Windows真实夹具 `integration_test/windows_dpapi_test.dart`，明确只生成私有测试Vault/已知token缓存，检查密文不含合成密码、真实保护/解保护及移除。Ubuntu跳过；无Windows实测或构建结论。测试结束Rust可能仍持最后Vault句柄，测试库目录需在进程退出后删除，不强行删活库。
- 最终先正规生成FRB（本批5个新接口），再Rust/Flutter编译、Analyze、完整回归。Windows构建用tools/build_windows.ps1；实际运行/账户切换/Unicode长路径/损坏缓存/退出时正在开库待Windows验证。

API依据：[CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)、[CryptUnprotectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptunprotectdata)、[MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)。这些文档说明平台接口，不是本项目测试结果。
