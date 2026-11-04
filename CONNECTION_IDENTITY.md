# 原 SSH 身份回执与配置库作用域

V1.4 §3.1/§3.2/§7/§8：传输恢复、Agent、SFTP必须归属实际原连接，不能从可修改的配置记录重新推断运行中的服务器身份。

`SshConnection::verified_host_key`来自本次已通过密码学验证和用户信任策略的握手。目标与跳板的Client缓存独立；拒绝的密钥不进入缓存，同原密钥rekey不重复询问，换密钥拒绝。`ManagedSession::connect_verified`经原actor成功响应同时交付`ConnectionReceipt {generation, host_key, username}`；旧connect/test_connection公开接口保留。回执仅不可变身份元数据，没有Transport所有权或秘密；移动/丢弃回执不会断开SSH，重连不会修改旧回执。

Bridge连接成功后用回执关联Target，而非异步重读当前Vault里的trust条目。关联前复核原代次/连接状态/关闭标记和原请求地址、端口、用户；Agent额外绑定连接准备时捕获的Vault.instance_id，不从后来更新的显示设置推断来源。迟到无效回执报错，不关联到其他代次。未来传输或能力获取不能绕过实际Target完整身份检查。

指纹确认Scope在准备路由时绑定原Vault.instance_id；同一次跳板/目标准备和最终确认都必须同实例。成功重开/切库，在同Vault临界区清掉未确认slots及待确认oneshot；事件队列中迟到旧请求也因无匹配slot而拒绝。旧请求不能把信任记录写入新库；相同文件路径重新打开也是新实例。错误主密码不替换库，也不使现有确认或SSH失效。已接受/已pin的原连接继续使用其真实旧身份，切库不强制断开已建立SSH；Agent原授权另按其规则失效。

锁序仍为Vault→Verification或registry→core；不持Vault/parking锁跨网络await。元数据清理不等待用户点击，也不发网络请求。终端resize/历史分配失败时，新创建的Root也须先await关闭，再发布失败；不能仅Drop遗留crypto worker。主机凭据、输入/输出不进回执或诊断。

验证：旧5179749 Native库（debug SHA256 0ca87…）运行新跨库测试，换库后旧确认未失效，12秒在5秒等待边界失败；同一测试重建Native后通过。不是把预计行为当复现，也不是Windows/Android实机测试。Rust额外覆盖拒绝不缓存、原key缓存/改变拒绝、跨服务器手动重连旧回执不变，以及跨库/同路径重开无法准备或保存指纹。Native覆盖旧请求失败、新库再次提示、错误主密码不破坏原确认、已建立SSH换库后仍可输入。

完整运行结果/哈希/平台边界见PROGRESS。复现与验证日志.local/connection-receipt-*；Native专项`ui_flutter/test/connection_identity_bridge_test.dart`，其余Agent/跳板/连接探测/RSA/Phase2 TUI回归须保留。静态审查副本目录不是新源码权威，不要恢复旧副本覆盖正式文件。

本批最终验证：完整workspace341项，Native专项8项49秒，Clippy/Analyze/NDK共享核心check均通过；正式双模式包及匹配SO、独立启动/resize/退出均0。前一节点全Flutter207通过，本批没有把预计208称全量运行。当前包哈希及短启动资源数据在PROGRESS，Windows/Android实机仍待验。
