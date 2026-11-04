# SFTP 目录书签

真实工作台在SFTP路径行提供「目录书签」。可收藏当前目录，编辑名称/绝对POSIX路径，选择当前保存主机或全局范围，点击书签访问目录，确认删除书签。删除确认说明范围且默认取消，只删除配置，不删除远端项目。特殊字符路径保持原文，经SFTP请求处理，不拼接Shell命令。

书签由Rust bookmarks::BookmarkRepository保存在解锁配置库的sftp-bookmarks-v1加密记录中；Argon2id/AES-256-GCM沿用现有Vault。稳定不透明ID，主机范围按保存主机ID隔离；同一主机多个独立SSH标签可以共享书签，各自导航/Transport不共享。全局路径由用户在当前关联服务器上显式打开，不连接到另一服务器。删除主机后不自动删除或转移其书签；原在运行会话仍可查看原范围，新建/保存已不存在主机的专属书签拒绝，可改为全局。

保存/list/编辑/删除仅访问本地配置，不验证远端目录是否存在、不做网络预读；只有明确选择导航时经LiveWorkbenchModel.loadDirectory访问捕获的源SSH会话。弹窗打开后焦点切到B，不会把A的书签动作发送到B；A关闭/断线则导航失败并显示错误，不建立新连接。侧栏宽度/开关、队列及会话身份不因导航重置。

名称UTF-8最多1024字节且不可含控制字符；路径必须绝对、无NUL，最多131072字节。单记录最多2MiB/10,000项，任何验证、未知版本或写入错误保留原数据，不以空配置覆盖。返回原有保存顺序；重复名称/路径可由用户保留。书签是可同步的配置类别，但WebDAV/Drive同步和完整备份尚未实现，当前仅本机加密持久化；不能声称已经跨设备同步。

验证：

- `cargo test -p hspterm-storage-sync bookmarks --locked`：全局/主机隔离、修改保持ID、特殊字符、重开加密、删除主机不重新归属、非法更新/数据库失败/未来版本保护。
- `flutter test test/bookmarks_test.dart --reporter expanded`：名称/路径验证、编辑、取消与确认删除、全局可见、切换焦点后原会话导航、迟到响应释放；480×460/1.5倍文本布局。
- `flutter test test/live_workbench_test.dart --reporter expanded`：真实FRB/Vault/OpenSSH书签保存/范围、重开、导航、身份不变及删除，原独立标签/SFTP/密钥/草稿回归保留。
- `xvfb-run -a dbus-run-session -- flutter test integration_test/live_workbench_test.dart -d linux --reporter expanded`：GTK实际点击工具栏/表单、主机转全局、取消/确认删除、导航和侧栏宽度/SSH代次不变。合成数据截图validation/phase3b/bookmarks.png，最终结果见PROGRESS。

Windows实机、Android UI/设备验收、同步/备份仍待后续完成；Ubuntu测试不替代目标平台验证。未改变终端协议或用户的终端标签/分屏模型。
