# OpenSSH Config 显式导入

正式主机管理右上角“导入 OpenSSH Config”读取用户明确选择的一份UTF-8文件，或解析用户粘贴的内容。仅用户点击“导入所选”后，才原子创建选中的正式主机元数据。不自动连接、不覆盖现有同名主机；凭据必须在主机认证页另行配置。正常新建/保存的凭据校验不被放宽。导入源及未转换设置只在弹窗内存中存在，不写草稿、历史或诊断。

Rust纯解析器遵循[OpenSSH ssh_config(5)](https://man.openbsd.org/ssh_config)的首个值优先、关键字不区分大小写、Host通配与否定、双引号、注释及等号分隔。明确Host别名生成候选，通配块仅提供默认值；全局/匹配块按源顺序应用。支持HostName（%h/%n）、User、Port、整数秒ConnectTimeout、ServerAliveInterval/CountMax；这些值为导入时快照，不继承应用全局默认。UTF-8 BOM/CRLF可读。不是系统OpenSSH完整运行期解析器，也不会在后续连接时自动读~/.ssh/config。

ProxyJump仅转换为同批选中的有效、无跳板明确Host别名，正式保存为独立host-ID引用；没有目标/嵌套/自身/多跳/@user:port等无法安全转换的路线禁止导入。ProxyCommand除none外禁止导入对应候选，绝不执行或降级直连。Match条件不执行，其条件块跳过；Include不自动展开。未转换字段、Match、Include及IdentityFile提示必须在预览核对并显式确认；认证算法/远端命令/自动转发等不会悄然继承。需要完整保留的选项应在正式主机页配置或修改源内容重新预览。

IdentityFile仅提示认证类型；不读取其值对应的秘密、不保存设备路径、不探测存在性。无User时由用户明确填写默认用户名；不读取本机账户替代远端用户名。预览显示实际将保存的地址/端口/用户/超时/心跳/跳板。导入后认证信息为空，SSH尝试在读取凭据时明确失败，不能凭空制造密码或自动回退认证。

边界：1MiB源、8192行、单行16KiB、256候选、每行64词、每类48条警告、有限模式匹配预算。模式用有界glob，不调用正则/Shell；词法错误只返回行号，不回显原文本。文件读取同时校验大小/流量/10秒无进度期限。解析在阻塞工作线程，FRB不阻塞SSH actor。预览捕获本次Vault打开身份，重新解锁/切库后旧提交拒绝；事务核对原catalog及新ID不存在，容量/重复/未知版本/数据库错误均保留原数据。导入不读取目标认证信息，不修改已有会话。

测试入口：storage-sync openssh_import及repository::import；ui_flutter/test/openssh_import{,_bridge}_test.dart；integration_test/openssh_import_test.dart（真实GTK）。解析4项/原子仓库2项通过（含写入第二个主机失败时全部回滚）；真实Native验证旧Vault拒绝、无凭据拒绝、明确导入密钥后实际SSH/中文PTY；组件3项（文件流使用真实事件循环）及实际GTK预览/选择保存11秒通过。两张validation/phase3b/openssh-import-{preview,saved}.png已查看。全量回归/双模式包以PROGRESS最终结果为准。后续备份/同步须与所有正式主机一起纳入，不能把仍未配置凭据的元数据排除或把临时源配置文本纳入同步。

## OpenSSH导入整批最终验证（2026-10-26）

完整Rust300项/Flutter192项（4:42）通过，原Phase2/真实Codex合成provider/SSH与SFTP/编辑/传输/转发回归保留；Clippy all-targets拒绝警告、Analyze无问题、格式、NDK/API26 aarch64共享核心check通过。GTK实际导入预览/选中保存11秒通过，两张PNG已查看。源文件解析/事务回滚/旧Vault作用域/无凭据拒绝/明确配置后真实中文PTY均已实际运行；早期FakeAsync文件流失败已通过真实事件循环修复，未跳过断言。

正式workbench_main debug/release重建，SO与target同模式SHA256匹配，独立启动/resize/退出均0，无历史/工作副本/preview残留。debug SO30f8a3cc48ba0d810d79c26a901f771707de02202083d9c68fdaa4a01bf44307；release faf0d3906f37c09d354a10c91ef54708ac3cce7db305065d8dab0880aa49ab3e。日志.local/openssh-import-*，原始startup JSON在validation/phase3b。5秒样本debug RSS501514240/聚焦CPU37.80%、失焦513253376/5.80%；release351154176/9.20%、失焦351490048/5.20%。不据短采样认定无泄漏或优化。不是Windows/Android实机或APK验证。
