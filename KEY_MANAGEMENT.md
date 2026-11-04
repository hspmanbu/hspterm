# 主机密钥管理

对应V1.4 §3.1认证要求。每台主机在密码/私钥之间明确选择，不自动回退。真实工作台入口是 `ui_flutter/lib/workbench_main.dart`；独立Mock与原Phase2终端入口保留。

主机编辑的认证页支持生成Ed25519（可选OpenSSH口令保护）、从本地文件导入、查看/复制/导出公钥，以及导出私钥。生成/导入先进入本机加密草稿，显式保存才成为正式凭据；新建草稿可从“恢复草稿”找回，退出重开仍可恢复。无效导入不会覆盖有效密钥，保存或密钥操作期间不能并发编辑/丢弃。

密钥生成/验证在Rust执行，不调用产品本地Shell，不依赖系统Agent。FRB仅返回公钥/算法/指纹；私钥导出每次重输主密码并显示风险，Rust直接写文件，不经过剪贴板或Dart返回值。Argon2验证失败不创建文件。同目录私有暂存、同步、无覆盖发布；Unix新私钥0600。Windows路径/权限与原生文件选择仍待实机验证。

选择器采用官方Flutter [file_selector 1.1.0](https://pub.dev/packages/file_selector)。Ubuntu实际GTK打开/保存均通过。Android该插件不提供桌面式保存位置选择，Phase4须接SAF，不把当前桌面入口当作Android实现。

`test/live_workbench_test.dart` 经真实FRB/SQLite/OpenSSH覆盖生成加密密钥认证、导入、错误口令/主密码、无效导入保留原密钥、公钥文件、导出不覆盖及明文不落配置库。GTK集成另外实际点击原生打开/保存、重启解锁、已有主机时恢复新建草稿并显式保存。`benchmark/native_file_picker_x11.py`只在隔离Xvfb输入一次性夹具路径，不输入密码/密钥；不是产品平台实现或IME验收。

实际发现并修复：密码弹窗返回时动画尚未销毁输入控件，立即dispose方法内控制器会触发TextEditingController已释放异常。现在由弹窗State拥有并在路由实际销毁时释放。主机保存离页竞态有独立生命周期测试。

会话持有独立非秘密目标快照，正式配置编辑不改写已连接目标；显式重连刷新目标/显示和TOFU提示。新连接代次清理旧SFTP缓存/选区。未来跨启动任务恢复必须校验实际服务器身份，不能只凭主机ID续传。

复现：根目录 `cargo test --workspace --locked -- --test-threads=1`；ui_flutter目录 `flutter analyze`、`flutter test --reporter expanded`、`xvfb-run -a dbus-run-session -- flutter test integration_test/live_workbench_test.dart -d linux --reporter expanded`。需Flutter/Cargo在PATH、OpenSSH及Xvfb/D-Bus；全部秘密运行时生成并清理，不提交产物。

未完成：代理/跳板/Agent、完整配置备份/同步与系统便捷解锁，Windows/Android运行验收。此模块不代表完整V1.4交付。
