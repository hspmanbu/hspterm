# SFTP 浏览器目录分页

正式工作台从 `sftp_list_directory` 全量返回切换到 `sftp_open_directory` / `sftp_directory_page` / `sftp_close_directory`。原API保留给原验收入口及兼容调用，不能将它描述为分页接口。

`ssh-core::directory::DirectoryReader`通过现有ReadDirStream按需拉取，不在下一次请求前额外发READDIR。单次最多256项，按UTF-8名称、展开路径和每项128字节元数据预算限制到256KiB；源NAME包已有256KiB协议限制。超长前缀导致的小包放大也受控制。全目录至多1,000,000项及32MiB展开路径，不保证任意长度路径都能达到该项数；容量不足明确失败，保留原缓存，不静默截断。限制连续无有效项目的回复，拒绝重复/空/包含斜杠或NUL的名称；正常点目录项过滤。canonical结果必须是合法绝对POSIX路径。

完整EOF必须确认服务端CLOSE；失败或丢弃的分页读取Future锁存不可复用状态，重新打开才可继续。每个终端只持有一个当前游标，绑定原SSH代次和客户端单调递增请求号；新请求替换旧请求，过期open拒绝，旧finally不会关闭新游标或另一个终端的同号游标。该请求号在每个SSH代次内单调递增，不是远端路径或全局会话身份。

每次目录读取在**原SSH Transport的独立SFTP子通道**上进行。取消/早退/读取错误/终端关闭释放整个子通道，使OPENDIR已执行但回复未收到的服务器句柄也随通道清理；不等待排在阻塞READDIR后面的CLOSE响应。Gate限制同一终端目录通道的资源持有；受管SSH层在调用方取消时同时取消尚未完成的SFTP协商，不留后台协商等待至超时；断线状态watch独立于Flutter事件消费，释放闲置游标。正常EOF仍须检查CLOSE错误。正常显式关闭错误向调用方返回，异步Drop或断线清理为尽力清理，不能宣称远端恶意服务器已确认释放。

Flutter每批转换元数据并追加到本地List，不再一次解码/转换整个目录。完整EOF及关闭成功后才更新路径、导航历史和LRU；失败保留旧列表，过期结果不发布。仍然在用户打开一个目录后逐批读取**该目录的全部元数据**，完成后统一排序/过滤，以维持全目录排序和选择的一致性。这不是仅请求视口条目，也不是目录元数据磁盘分页。不会访问未打开的其他目录、预读子目录或轮询外部变化。

每会话缓存最多16目录，并按估算元数据权重64MiB优先淘汰最旧快照。权重在分页转换时累加：目录及每项对象各计256字节，路径、名称及显示字符串按每UTF-16码元2字节计入；不依赖字符串压缩或去重，也不是实测堆大小/RSS。刷新替换旧权重并更新LRU，移动失效及新SSH代次清理时同步释放权重。当前目录即使独自超预算仍完整保留，避免排序/选择丢文件；离开后可被淘汰。因此不是全进程硬内存上限。

自动化证据：

- `cargo test -p hspterm-ssh-core --test sftp_directory --locked`：不预取/复用包内余项、页数/字节预算、关闭失败和读取Future中断不可复用、非法canonical、长前缀容量保护；原目录任务/取消/更名协议回归保留。
- `cargo test -p hspterm-frb-bridge directories --locked`：旧请求/代次不能清理新游标；阻塞READDIR时取消，确认读取Future和Gate及时释放。
- `cd ui_flutter && flutter test test/directory_reader_test.dart test/directory_paging_bridge_test.dart --reporter expanded`：完整批次后才发布、后续页/关闭失败不发布部分文件、过期清理绑定原身份；真实OpenSSH4097条、跨会话同号游标、24次通道循环、PTY仍可交互、远端退出/手动重连和关闭终端。
- `integration_test/live_workbench_test.dart`：真实GTK读取4096目录、只绘制可见行、滚动及外部改名后显式刷新，原传输/设置/密钥/草稿操作保留。

最终全量命令、结果和平台边界以PROGRESS.md为准。Ubuntu通过不是Windows/Android实机验证。大清单增量检查点、递归搜索、预览编辑等仍继续开发。


## 2026-11-02继续：目录/搜索游标显式通道退休（未统一验证）

- 删除ChannelLease::Drop中脱离调用方的spawn/忽略close结果。Cursor自己持Channels，State保留已替换/关闭但未退休游标；失败保存reader/原gate，下一次打开先完成旧退休，不打开重叠目录通道。release与打开阶段/分页分别有真实门控，避免尚未登记的open被提前prune；取消RPC仍由原游标保存已建立通道。
- close只处理匹配generation/request的旧游标，不能关闭新游标；close_all处理活动和保留项，所有结果尝试后汇总首错。Root断线监视器仍只负责取消/尽力收尾，失败owner留原State供明确清理；不把后台无调用方当成功，也不把本机IO退休等同peer CLOSE。整个runtime销毁仍依赖原Root的实际stream界限，正常退出必须显式close_all。
- 原阻塞READDIR目录/递归搜索夹具改为run_owned真实peer，扩展丢弃RPC Future的两种路径；新增打开阶段替换/等待真实barrier/不关闭新游标1项源码测试。都未执行。只rustfmt/216源码保护清单/diff；未编译/测试。原普通CRUD缓存remote_sftp生命周期仍需审核，其余Windows源码继续，最后统一验证不变。
