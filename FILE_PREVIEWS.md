# SFTP 文件打开与临时预览

正式工作台文件双击/Enter/右键“打开”已接真实下载和桌面系统关联程序。文件夹直接在SFTP进入；符号链接只在用户明确打开时解析，目录目标在原会话浏览，不在列目录时后台探测链接。每次文件打开建立新票据/新临时文件，不复用旧正文。源目录快照、nativeID、SSH代次在等待缓存初始化或链接解析前后校验，焦点/标签移动不改变目标，旧操作不重定向到重连后的新服务器。

## 核心与生命周期

- reserve为内存同步操作，先分配可取消的不透明票据；即使下载尚未启动，也可取消。后台使用原Transport的独立SFTP通道，源会话仅弱引用，已完成的预览不持有SSH/终端历史资源。
- 共享现有全局FIFO名额与下载方向限速。正文流为64KiB有界读取，不预取；进度只存元数据，Flutter仅在下载活动期间150ms取快照，等待确认/完成/错误/关闭均停止定时器。不向终端写入文件路径或命令。
- 默认超过100MiB先询问，确认前不读取正文；即使预检和打开之间大小变化，第一次内容读取前再判定。正式设置→SFTP与传输的“文件打开确认阈值（MiB）”可显式加密保存，0表示每次确认（含空文件），正数严格超过时确认。首次准备在工作线程读取配置并在票据内保存快照；已弹出的确认不因设置改变而变化。大小属性缺失/非普通文件拒绝，不猜测完整性。
- 成功要求实际字节、大小、本地flush/sync及服务端文件CLOSE响应均成功。服务端CLOSE错误不能用已收齐字节冒充完成；upload/download原语现将其归因为远端关闭失败。取消、断线和旧代次均停止准备并删除未发布文件，保留先前已成功的独立预览。
- 正常退出先取消/等待所有准备任务，释放所有slot，再关闭整个运行缓存；锁库首页也等待初始化与清理。运行/registry锁避免其他实例清理活跃运行，遗留运行下次初始化清理。外部程序占用造成删除失败时明确返回或报告延迟清理，不冒称全部删除。

平台通过path_provider提供缓存位置，Rust不假设Android的std临时目录可写。预览根与配置库、传输检查点、终端滚动历史、未来编辑器缓存分别管理。为外部程序读取，文件正文是用户私有目录中的临时明文文件；不入SQLite/命令历史/诊断/同步/配置备份。Unix验证目录所有者/0700及锁文件NOFOLLOW；Windows ACL/文件占用和多进程实际行为仍待实机验收。

缓存只使用随机独立目录和preview+安全ASCII扩展名，不把远端名称当本地路径组件；原名称仍在UI/票据保留。各次文件路径不同，不截断正文、不设置缓存总字节固定上限。一次最多32个未处理票据防止未开始任务累积；这不是已完成缓存容量限制。

## 系统关联与边界

使用Flutter官方[URL Launcher桌面file协议](https://pub.dev/packages/url_launcher#file-scheme-handling)（锁6.3.3/BSD-3-Clause），以externalApplication打开已存在的本地file URI，不经Shell命令字符串、不以WebView绘制终端。已检查Windows3.1.6插件源码使用解码后的UTF-16路径交给ShellExecuteW；这是静态检查，不能当作Windows运行通过。Windows含中文/空格/#/%的缓存路径及各种默认程序仍需实测。

此“打开”仅临时下载/交给系统关联程序，**不将外部程序对缓存的修改回传服务器**。应用内编辑、显式外部编辑、文件监听/自动上传、编辑缓存保留与恢复仍待后续模块。Android需要内置预览/编辑与内容URI授权，当前桌面file-URI入口明确不作为Android能力宣称。

## 可复现验证

- `cargo test -p hspterm-storage-sync preview_cache --locked`：新slot/安全扩展名/部分文件释放、活跃运行隔离与残留回收、被租用缓存不可删除、不安全目录/锁链接拒绝。
- `cargo test -p hspterm-storage-sync file_open_settings --locked`：默认/严格边界/每次确认/整数上界、加密保存重开、较新或损坏配置拒绝覆盖。该用户配置与缓存正文分离，配置同步/备份仍待整体集成。
- `cargo test -p hspterm-ssh-core --test sftp_budget --locked`：原线速READ预算；完整内容收到后仍阻塞等待CLOSE、CLOSE失败不成功。
- `cd ui_flutter && flutter test test/file_preview_bridge_test.dart --reporter expanded`：真实OpenSSH的新鲜数据/大文件确认、取消前置票据/部分文件、共享并发/限速、独立会话与文件链接、目录链接解析、断线/旧代次、退出清理；另有真实SSH下受控SFTP协议子系统失败CLOSE用例，不是正常OpenSSH服务伪装通过。
- `flutter test test/file_preview_test.dart --reporter expanded`：模拟桥接的明确单测，覆盖取消后迟到完成不启动应用、确认、关联失败重试、不持续空闲轮询、缓存等待中SSH/目录代次变化拒绝。此组不代表系统关联实测。
- `flutter test test/file_open_settings_test.dart --reporter expanded`：读取失败不以默认覆盖、重读、空值与整数校验、显式保存及保存失败；正式GTK工作台集成另实际保存50MiB并读回Rust，不保留旧Mock阈值控件。真实FRB预览测试还验证0MiB空文件确认、1MiB自定义阈值、设置改变不改变已弹出的确认。
- `HSPTERM_PREVIEW_CAPTURE=/opt/hspterm/.local/preview-open.png python3 benchmark/preview_association.py --run /opt/flutter/bin/flutter test integration_test/file_preview_test.dart -d linux --reporter expanded`：真实GTK/FRB/OpenSSH/GIO/file-URI，在独立XDG目录注册受控Python查看器；两次打开新数据及Unicode哈希/大小核对、目录链接进入、大文件取消、会话/侧栏不变、退出删除缓存。查看器仅记录合成数据摘要，不改用户MIME设置，不访问外部账号。
- `benchmark/workbench_smoke.py`另实际启动/关闭正式debug/release，要求锁库首页初始化的预览run也在正常关闭后消失。最终结果以PROGRESS.md为准，未执行的项目不记为通过。

截图validation/phase3b/file-preview.png仅含合成回环数据。Windows/Android/真实外部用户编辑器及强制断电仍待实际验证。root控制文件可保留，终端画面/预览正文不会跨重启恢复。


## 2026-11-02异常收尾源码补正（未统一验证）

PreviewJob现登记实际SFTP Channels，实际blocking worker使用原作用域supervise，FIFO TaskPermit存于run Future之外，覆盖正常与unwind后的通道清理尝试，不把仅停止队列当实际IO完成。清理失败仍保留任务/slot/通道owner，不能取消调用一开始就移出registry；仍退休的失败owner计入原32项准入预算。并发cancel有原finished版本屏障，不以JoinHandle已被其他调用take作为完成证明。

shutdown先逐个确认取消，错误时保留运行缓存及唯一owner/锁，再次明确退出可在Root关闭后重试；不会先drain registry再丢异常流。单次清理超时仍可能返回错误并释放该次FIFO许可，**未退休owner仍保留且禁止冒称清理成功**，不要声称任意故障都已完成IO退出。强制进程终止等不可恢复情形维持下次缓存清理规则。

新增preview_cancellation_barrier_test.dart私有OpenSSH测试源码1项，覆盖实际低速下载中的并发取消、源未删、原SSH保持、下一次共享FIFO及完整字节；尚未执行。还需在统一阶段用受控IO/Root故障验证cleanup超时、panic、shutdown失败重试和缓存owner保护。已有真实文件预览验收属于旧构建，不覆盖本次源码。Explorer普通文件导出也使用此收尾逻辑，不将外部接收方的落盘状态混为预览已确认。
