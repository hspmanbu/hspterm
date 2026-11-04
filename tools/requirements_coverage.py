#!/usr/bin/env python3
"""Regenerate the clause index from V1.4; update status mappings as implementation advances."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
s = (ROOT / 'HSPTerm_最终需求规格_v1.4.md').read_text()
rows=[]; section=''; n=0
mapping={
 '2':('已实现工程；平台集成部分','Cargo.toml；crates/*；ui_flutter/lib/terminal','Phase2 Rust/Flutter/GTK验收'),
 '3.1':('部分','crates/ssh-core/src/lib.rs；crates/frb-bridge/src/api.rs','crates/ssh-core/tests/openssh.rs'),
 '3.2':('部分','crates/ssh-core/src/{budget,session}.rs；ui_flutter/lib/terminal/controller.dart','openssh.rs；native_bridge_test.dart'),
 '4':('部分','crates/term-core/src；ui_flutter/lib/terminal','term-core/tests；widget_test.dart；Phase2验收'),
 '4A.6':('已实现Ubuntu；目标平台待测','term-core/src/input.rs；terminal/view.dart','widget_test.dart；Codex/SSH GUI'),
 '4A.7':('部分：原视图/代次动作、上下/Enter/Esc/IME保护、动态可用性、本次最近8操作已接；加密自定义快捷键/本地按键所有权及冲突路由已静态接入未统一验证，Android独立入口暂缓','prototype/{app,command_palette}.dart；workbench/app.dart；COMMAND_PALETTE.md','命令面板组件/原型与原终端TUI键位；GTK真实双SSH原焦点保护，最终结果见PROGRESS'),
 '5.1':('真实多会话/标签组布局Ubuntu已验；Windows自绘标题栏原生动作/DWM边框/缩放与Snap命中、标题文字及标签后实际余白的窗口拖动/双击/系统菜单、标签手势隔离已静态接入，尚未编译及实测','ui_flutter/lib/{prototype,workbench}；windows/runner/flutter_window.cpp；prototype/window_chrome.dart；WINDOWS_WINDOW.md','原terminal_layout/live_workbench与真实GTK已验；新增window_chrome2项源码待统一测试，Windows行为待实测'),
 '5.2':('部分：加密保存/独立凭据/草稿/复制/批量元数据；显式工具中的分组/主机排序、跨组/收藏拖放、多选和原库快照事务已接；主列表直接树拖排及有限非敏感高级批改已有静态源码；新原子目录快照/旧读取发布抑制/保存后按ID重取和密钥已写ACK保护已有静态源码，未统一验证','prototype/hosts.dart；workbench/{model,host_ordering}.dart；storage-sync/src/repository{,/ordering}.rs；HOST_ORDERING.md','storage94/Bridge33；host_ordering模型/交互/窄窗/失败；真实Native SSH身份保持/旧快照/切库；独立GTK；最终结果见PROGRESS'),
 '5.3':('部分：真实目录/双限额LRU/CRUD/加密书签/缓存路径补全/上传下载/排序分页/全局浏览默认值加密CAS与真实面板及列表接线（新增源码未统一验证）/系统关联打开/加密确认阈值/内置文本编辑/字节进度/明确保存与本机加密草稿恢复已接；外部文本编辑监听回传/保留工作副本/确认清理已接；明确编码选择/严格无损往返已接；外部大正文分块编辑/当前会话递归文件名搜索与定位、终端选区定位/可选OSC7跟随及加密偏好已接；真实文件复制剪贴板/显式中转与双端任务已接；同账户剪切粘贴/移动意图与ACK日志、独立复制到/移动到目标及部分入队重试已接；新增Windows Explorer→SFTP OLE名字投放/目录高亮与延迟进入/原代次入队及批次退出所有权源码未统一验证；新增原目标逐路径暂存检查/显式清理/未知REMOVE意图与本机结束等待及跨重启独立清单源码待统一验证；新增普通文件Alt→Explorer虚拟文件下载/原代次完整Rust快照与64KiB原生磁盘spool源码待统一验证；新增完整树→Windows目录/空目录/64位文件描述符清单、固定归档散列的本地原生fork补丁/构建准备器源码；新增transfers::explorer真实源任务/持久快照与读租约、Native目录provider消费/ExportReady队列离线再拖出源码；新增本机归属marker/原Vault单次确认的孤立缓存清理和只读根引用保护，旧无归属缓存保留，尚未统一生成运行及Win实测；跨服务器剪切整树确认后来源后序删除/有界游标意图/未知不重发已接正式Bridge/加密检查点/队列/明确风险许可/离线本机结束源码，尚未统一生成验证；Android内置编辑待做','prototype/{files,cached_path_field}.dart；workbench/{model,file_preview,file_open_settings,file_editor,editor_controller,external_editor,file_search,file_search_controller,remote_destination}.dart；frb-bridge/src/{api,previews,editors,remote_transfers}.rs及editors/raw.rs','live_workbench_test.dart；openssh.rs；目录/书签/缓存补全/预览/打开设置测试；GTK目录/书签/隔离系统关联；editor_controller/external_editor/editor_bridge；edit协议/真实SSH'),
 '5.3A':('未实现真实路径发送；选区定位及路径核心见对应行','prototype/files.dart；TERMINAL_PATHS.md','原型回归；具体已接能力见对应行'),
 '5.4':('部分：真实队列/默认3可配置FIFO/暂停续传/本机恢复/失败详情/实测速率估时已接；全局限速/加密并发配置已接；任务内批次覆盖/跳过/更名、失败目录重扫合并及新任务加密默认策略已接；增量统计/分块加密检查点已接；远端复制共享FIFO/双向限速/双端身份与加密恢复、失败目录重扫意图与原子候选合并已接；新增本地↔远端任务内三个文件协作并行/有界合并ACK/全部worker收尾/重叠目标串行/逐文件活动进度源码未统一验证；新增远端中转内部3文件并行/同步暂存屏障/双端工作通道有限恢复源码未统一验证；安全同账户直接移动/编辑互斥/未知结果禁止盲重发及只读检查/离线本机审阅与明确结束（不推断成功，不放宽网络身份）已接；跨服务器剪切与来源删除/未知审计正式源码已接未统一验证；安全rsync直传新增显式策略/原Agent与目标回执/一次私有cap/固定rsync正文暂存及发布/每任务实际IO跟踪源码，未统一验证；新增原inode HMAC/xattr认证回执、原进程组只读核对及明确继续rsync delta恢复源码；未知/pgid0/不支持xattr保守拒绝，完整回执非秘密属性随rename保留；尚未统一验证','workbench/{queue,move_resolution}.dart；frb-bridge/src/{transfers,remote_transfers}.rs及remote_transfers/move_resolution.rs；ssh-core/src/{transfer,tree_transfer,remote_tree,task_scheduler}.rs','transfer_bridge/partitioned_transfer_bridge/remote_transfer_bridge重扫故障恢复/remote_move_resolution_bridge丢ACK及remote_move_offline_end离线/删除主机/故障审计测试；transfer_queue/transfer_rate/transfer_settings测试；真实GTK上传/冲突决定/详情；局部重扫/取消/加密重开恢复'),
 '5.5':('仅Mock','prototype/app.dart','prototype_test.dart'),
 '6':('未实现；共享核心部分可复用','terminal/view.dart（共享IME）；android/runner模板','widget_test.dart（非设备）；Android核心check'),
 '7':('部分：同Transport SFTP/流式续传/目录清单与可配置FIFO/分块检查点/总体限速已接；POSIX替换协商/响应已验；内置文本明确覆盖与失败草稿保留已接；外部文本及大正文原始字节分块监听回传已接；远端文件/目录完整快照复制及明确发布/无扩展回退已接；同账户直接移动/编辑互斥/未知结果禁止盲重发及只读检查/离线本机审阅与明确结束（不推断成功，不放宽网络身份）已接；跨服务器剪切与来源删除/未知审计正式源码已接未统一验证；安全rsync直传新增显式策略/原Agent与目标回执/一次私有cap/固定rsync正文暂存及发布/每任务实际IO跟踪源码，未统一验证；新增原inode HMAC/xattr认证回执、原进程组只读核对及明确继续rsync delta恢复源码；未知/pgid0/不支持xattr保守拒绝，完整回执非秘密属性随rename保留；尚未统一验证','ssh-core/src/{lib,transfer,tree_transfer,remote_tree,task_scheduler,bandwidth,edit}.rs；vendor/russh-sftp；frb-bridge/src/{transfers,editors}.rs','openssh.rs真实传输/恢复/特殊名/根更名及POSIX替换；sftp_budget/sftp_directory/sftp_rename/sftp_edit/sftp_publish协议；remote_transfer_bridge真实双SSH；remote_move_bridge真实移动/检查点故障/编辑保护；remote_move_resolution_bridge丢ACK/迟到/代次/本机结束；容量/路径规则'),
 '8':('部分：加密主机/凭据/草稿/目录书签与旧格式迁移；设备本机编辑正文/元数据分开加密且排除同步备份；平台密钥库/同步/备份/导入待做','storage-sync/src/{lib,repository,local_edits,external_edits,edit_blobs,raw_edits}.rs；frb-bridge/src/api.rs','storage-sync仓库/事务/格式回归；native_bridge/live_workbench测试'),
}
for line_no,line in enumerate(s.splitlines(),1):
 h=re.match(r'#{2,3}\s+(\d+[A-Z]?(?:\.\d+[A-Z]?)*)[. ]',line)
 if h: section=h.group(1);n=0
 is_item=line.startswith('- ') or (section in ['11', '5.3A'] and re.match(r'^\d+[a-z]?\.',line))
 if not is_item or section in ['9','10','12']:continue
 n+=1; ident=f'{section}-{n:02d}'
 status,code,tests=mapping.get(section,('未实现','—','—'))
 if section=='5.2' and n==1:status,code,tests=('部分：正式独立页/左右可调/加密排序与分组收藏预览已有Ubuntu验收；新增主列表多选行间/跨组/收藏落点及组顺序直接拖放、原手势scope修订和未保存提示已静态编制，测试待统一执行；目标平台仍待验','prototype/hosts.dart；workbench/{host_ordering,host_catalog_drag}.dart；storage-sync/src/repository/ordering.rs；HOST_CATALOG_DRAG.md','既有排序Rust4/组件/Native/GTK证据保留；新增Dart及Widget4/GTK1源码待统一执行，截图尚未生成')
 if section=='5.2' and n==5:status,code,tests=('部分：原字段内校验/定位及分组收藏批量已有；新增正式非敏感批量字段选择/逐台影响预览/原Vault修订事务CAS/网络继承与覆盖/SFTP偏好/ACK与刷新分离已静态编制，未统一生成编译测试；不批量修改凭据或连接端点','storage-sync/src/repository/bulk.rs；frb-bridge/src/host_bulk.rs；workbench/host_bulk.dart；prototype/hosts.dart；HOST_BULK_EDIT.md','新增Rust3/Flutter4/真实OpenSSH Native1测试源码待统一执行；仅格式化解析和diff检查')
 if section=='5.5' and n==1:status,code,tests=('部分静态实现待统一验证：原SSH ACK心跳耗时/原Root与代次失效、独立状态通知、确认PTY列行/尺寸锁、已载入真实任务记录、窄行底栏；无额外探测或取帧；新增单终端/原代次显式可选资源与进程源码，独立SSH exec有界读取、前台焦点5秒采样/失败停表、原列表30秒一次信号能力与单独确认、pidfd身份复核及SIGTERM回执不冒称退出；完整任务事件统计与统一运行/目标平台待验','ssh-core/src/{heartbeat,session}.rs；frb-bridge/src/api.rs；terminal/controller.dart；workbench/{connection_status,remote_inspection,remote_inspection_panel}.dart；RTT_STATUS.md；REMOTE_INSPECTION.md','新增Rust时钟2/状态1、Dart及组件3、真实OpenSSH Native1/GTK1测试源码待执行；仅格式化解析/diff检查，非编译实测')
 if section=='5.3' and n==6:status,code,tests=('部分静态源码待统一验证：新增原生OLE/CF_HDROP单向Explorer拖入，实际物理区域与目录命中/750ms导航/Copy-only/原owner及GetData重入复核、一次Drop与有界hover ACK/Model批次退出等待，旧代次拒绝；反向新增真实树下载/目录虚拟描述符/provider/持久源任务与实际读租约、离线就绪再拖出及归属缓存显式清理源码；原同服务器Flutter内部移动已有，全部新增未统一生成运行，完整Windows系统拖放未验','windows/runner/{explorer_drop,main,flutter_window}.cpp；platform/explorer_drop.dart；prototype/files.dart；workbench/model.dart；frb-bridge/src/api.rs；WINDOWS_EXPLORER_DROP.md','新增Dart/组件9项源码及原真实Native错误代次场景均未运行；C++未编译/语义检查/Win实测，新API参数待正规生成')
 if section=='7' and n==3:status,code,tests=('静态源码待统一验证：原Root 64个开通/活动SFTP stream所有权、晚open ACK及本机实际IO退休、开通3次且仅原代次、文件夹工作通道最多2次恢复/ACK与成功节点保留/检查点屏障；协议与权限不重试、不建新SSH；新增远端中转内部3文件/同步状态屏障/逐文件进度及两端工作通道最多2次恢复源码；未知创建/发布/清理不自动重放；新增任务级会话owner/异常真实收尾/FIFO worker租约/最后dirty屏障源码；统一执行仍待完成','ssh-core/src/{sftp_connector,session,tree_transfer/parallel}.rs；vendor/russh-sftp/src/client；frb-bridge/src/{transfers,remote_transfers,transfer_channels}.rs；ssh-core/src/remote_tree/{file,parallel,recovery}.rs；SFTP_RECOVERY.md','前9项源码及本轮中转分类3/协议4/私有OpenSSH3/Native1均未执行；故障夹具改用实际owned服务Future；新增Bridge3/原Native最终删除故障扩展也未执行；原测试全部保留')
 if section=='8' and n==1:status,code,tests=('部分：独立凭据/Argon2id/AES加密已验；Windows当前账户DPAPI显式再验证启用/固定token密文缓存/手动入口/精确open-only及退出等待已静态编制，5个API未生成、未编译；Android Keystore暂缓，Windows实测待做','storage-sync/src/secure_unlock.rs；frb-bridge/src/api.rs；workbench/windows_unlock.dart；windows/runner/secure_unlock.cpp；WINDOWS_UNLOCK.md','新增Rust2/Flutter6/Native2及Windows真实DPAPI1测试源码待统一执行，模拟通道不算DPAPI实测')
 if section=='8' and n in [2,3]:status,code,tests=('部分静态源码待统一验证：云白名单/独立凭据规范化、LWW永久墓碑/历史清空CRDT、E2E信封、强ETag条件WebDAV及独立代理、原子合并已有源码；新增Vault普通/CAS/删除同事务真实修改时间/离线待同步标记、ACK退休与时钟观察、本机加密目标/独立秘密/明确切换归档、原库修订保存页及2个API、目标/秘密改变拒绝旧云结果已编制；真实WebDAV运行/取消与worker退出等待、原票据风险审阅/412新确认、应用级750ms编辑去抖与8个新增API已静态接入；启动不请求，普通同步保留scope/无变化不扰动终端或Agent；新增Drive桌面OAuth/PKCE回环/本机独立加密授权/显式撤销与退出等待源码；新增原库修订/当前目标保护/显式确认的本机基线归档管理源码；新增Drive appDataFolder有界发现/预生成ID创建/强ETag读取与PATCH/完整对象ID ACK传输源码；新增Drive既有对象正式Target/真实账号检查点/刷新ACK后提案/Workflow和未知刷新状态已静态接线；新增正式手动发现/明确候选ID选择/切换确认及生命周期UI源码，新增首次创建敏感范围确认/实际生成ID能力/确切密文本机双记录/同ID核对恢复/设置与意图退休同SQL及5API/正式UI源码；Google实际媒体条件语义、新增引用冲突不可发布步骤/原单位元数据及逐项批量选择/完整校验后新票据再确认源码；运行验证仍待完成','storage-sync/src/backup/cloud_sync/{mod,journal,settings}.rs；frb-bridge/src/configuration_sync.rs；workbench/configuration_sync*.dart；google_drive_account及drive_authorization；CLOUD_SYNC_RUNTIME.md；GOOGLE_DRIVE.md；CLOUD_SYNC_ARCHIVES.md','前节点领域10/HTTP6、设置Rust16/Flutter7/Native1与运行Core1/Bridge3/Flutter7均为未运行源码；新增API未生成，reqwest/Rustls及Cargo.lock留统一解析/编译/Analyze/测试；仅格式化解析及diff检查')
 if section=='8' and n==4:status,code,tests=('静态实现待统一验证：完整允许配置/凭据/书签/历史/本机字体投影，Argon2id/AES-GCM认证分段备份、no-clobber发布，合并/替换/逐项与批量差异预览，原Vault/修订/data_version事务CAS，历史删除epoch/独立凭据/草稿保留，Agent撤销与既有SSH保持；新增API未生成、未编译测试，不计验收完成','storage-sync/src/backup；frb-bridge/src/backups.rs；workbench/configuration_backup*.dart；BACKUP_RESTORE.md','Rust仓库7+加密流1+data_version1、Flutter5、真实OpenSSH Native1/GTK1源码待执行；仅格式化和静态跨层/diff检查')
 if section=='8' and n==6:status,code,tests=('静态实现待统一验证：1000条固定代码/数字运行身份内存队列、关键连接/任务请求边界、正式设置查看/本地筛选/明确清空和ACK刷新分离；无正文/路径/任意错误字段/文件/同步；新增202个公开Result的无source错误边界/生产精确摘要清单、传输预览失败摘要、终端Debug与Trace去正文及Bridge依赖log静态关闭源码；新增195异步/7同步原作用域panic防护与不打印payload的非阻塞固定诊断hook源码；入口前FFI/tracing/其余UI和完整业务事件仍待继续审核','frb-bridge/src/diagnostics.rs；api.rs；workbench/diagnostics.dart；RUNTIME_DIAGNOSTICS.md','原Rust3/Flutter4/真实OpenSSH Native1待统一执行；另新增错误链Bridge4/Core1/Python3源未执行；202源码清单及格式解析/diff不是编译验收')
 if section=='8' and n==5:status,code,tests=('Ubuntu已实现：显式UTF-8文件/文本预览、Host首值/通配/否定、逐项筛选与警告确认、单跳依赖、原子加密正式元数据；不执行Match/ProxyCommand、不展开Include、不读取IdentityFile；缺凭据需明确配置，旧预览/同名/无效路由拒绝','storage-sync/src/{openssh_import,repository/import}.rs；frb-bridge/src/openssh_import.rs；workbench/openssh_import.dart；OPENSSH_IMPORT.md','Rust解析4/仓库2项；Native旧Vault/无凭据拒绝/明确密钥后真实SSH；组件3项；GTK预览/保存11秒；目标平台待验')
 if section=='4A.1':
  detail={1:'原actor实际按键跟踪/助手精确接受回执后Native加密批次采集，不读取远端history或屏幕回显',2:'原Vault/保存主机内存索引/20候选/16ms合并与光标旁纵向列表、首项选中和有界滚动',3:'上下选择、Tab只填入、Enter/点击受控执行、Esc关闭及原按键释放所有权已接',4:'原actor原子比较受控包、匹配A回执与执行S回执、旧票据/代次/权限/空行门控及超时不重发已接',5:'未知编辑/协议/TUI/隐藏输入失效；Flutter焦点/历史查看/IME预编辑隐藏，原终端路由保留',6:'原主机加密有界去重仓库与实际采集已接；临时目标不归档',7:'合格采集接入原加密同步投影/CRDT合并/750ms去抖和完整备份',8:'正式开关/单主机及全局清空/未保存保护与候选缓存版本失效已接',9:'助手实际普通输入确认、保守敏感过滤/清零和固定代码诊断，不采集隐藏read或TUI/粘贴',10:'独立候选覆盖层/内存缓存/单在途请求与无空闲查询已接；Android专用交互暂停'}
  status,code,tests=('静态源码待统一验证：'+detail[n]+'；逐主机主动集成默认关闭，仅支持已证明的Bash末端输入/ASCII退格，其他状态安全退化，不承诺任意Shell编辑','term-core/src/integration.rs；ssh-core/src/{session,integration}.rs；frb-bridge/src/api.rs；terminal/{suggestions,suggestions_overlay,view}.dart；SHELL_INTEGRATION.md','原仓库/管理Ubuntu证据保留；新增Core回执、真实隔离OpenSSH、Flutter候选/IME与源会话路径及真实Native历史测试源码均未统一运行，不计验收完成')
 if section in ['4A.2','4A.3','4A.4','4A.8']:status,code,tests=('未实现','—','—')
 if section=='4A.8':status,code,tests=('部分：真实网格HTTP(S)/IP/host:port被动识别/宽字符与软换行、Ctrl+Click/菜单、复制文本地址、原会话确认临时回环转发与浏览器失败局部清理已验；现有选区路径SFTP定位已接；OSC8 HTTP(S)共享单元/冷历史Reflow/有界变化行span/完整ST与取消/多分号与UTF8拒绝/明确打开已验；远端file URI同原SSH authority/单次解码/独立SFTP定位且永不本机打开已验；新增普通POSIX路径/path:line[:col]有界显示识别、行列与原文选择/原代次确认SFTP定位及选区入口源码未统一验证；Android长按仍待接','term-core/src/lib.rs；frb-bridge/src/{api,frame}.rs；terminal/{links,view,controller}.dart；workbench/terminal_links.dart；OSC8_LINKS.md；PORT_FORWARDING.md','链接单元/隐藏字符/鼠标捕获及Shift覆盖；真实Native临时L/不入库/无预探测；GTK确认/取消/浏览器失败/断线保护与普通链接不重连')
 if section in ['4A.2','4A.3','4A.4']:status,code,tests=('Ubuntu真实模块专项已验：加密全局/主机覆盖、关键词/有界正则/样式/顺序/启停/编辑/删除/测试与受限JSON预导入、变化可见行语义着色/平衡括号/选中完整同词高亮；远端ANSI与TUI优先，原文不变；加密云同步投影与运行发布已有静态源码待统一验证；Android专用入口暂缓，最终全量见PROGRESS','term-core/src/decorations.rs；storage-sync/src/display_settings.rs；frb-bridge/src/display.rs；workbench/display_settings.dart；terminal/{painter,same_word,controller}.dart；TERMINAL_DECORATIONS.md','Core装饰5项/存储3项；Native真实SSH/ANSI/导出不变/隐显与旧Vault；组件及Unicode同词/窄窗菜单/选区保留与原键盘和真实Codex等24项；实际GTK设置/主机继承/真实SSH绘制16秒；32规则压力32.174→8.007ms；目标平台待验')
 if section=='4A.5':status,code,tests=('部分静态源码待统一验证：完整OSC133范围/行身份与可变修订/冷历史半开读取、原会话帧保护的显式输出复制及上下一命令导航、10MiB预算与实际worker退出等待已编制；新增旧范围Reflow有界前后逻辑UTF-8摘要/确切端点映射/signed坐标与原ID保留源码，裁剪/填充歧义/超限安全降级，不作为命令采集或输入证明','term-core/src/{shell,commands,search}.rs及commands/reflow.rs；vendor/alacritty_terminal；frb-bridge/src/api.rs；terminal/{backend,controller,view}.dart；SHELL_INTEGRATION.md','原阶段/范围导出已验记录保留；新增Core10/Native1/Flutter4/真实OpenSSH1/GTK1共17项源码及新Reflow Core8/原Native扩展未运行；3API未生成，仅格式解析/diff')
 if section=='4A.9':status,code,tests=('协议与显示隔离/有界装饰已有Ubuntu专项验收；配置同步/备份范围已有后续静态源码未统一验证；实时历史候选/安全输入的可选集成已获用户批准，私有协议与采集源码新增但完整UI/动作仍待接','term-core；terminal；storage-sync/src/backup/cloud_sync；COMMAND_HISTORY.md','原协议/装饰证据保留；新增同步与完整备份测试源码未运行')
 if section=='4' and n in [1,2,3,4,10,12]:status='已实现Ubuntu基础；目标平台待测'
 if section=='4' and n in [5,6,8,9,11,13]:status='部分（OSC语义/段导航/字体等仍待做）'
 if section=='4' and n==5:status,code,tests=('部分：OSC52已验；被动OSC7严格解析/生命周期/同主机路径与选区显式SFTP定位已接；可选OSC7跟随/加密主机偏好已接；OSC133被动阶段已接；OSC8 HTTP(S)元数据/明确打开/冷历史Reflow已验；远端file URI原会话SFTP定位及无本机/浏览器打开已验；新增完整命令范围/复制导航及旧范围Reflow源码待统一验证','term-core/src/working_directory.rs；vendor/vte及alacritty_terminal；TERMINAL_PATHS.md','working_directory专项8项/shell_context7项；真实SSH阶段/OSC7隔离；clipboard/原桥接回归')
 if section=='4' and n==11:status,code,tests=('部分：既有字体绘制已有Ubuntu验收；新本机字体/导入/排版及终端持久光标/闪烁/RGB与ANSI16/深浅配色预设、OSC52/右键偏好、原Vault运行发布与备份恢复已静态编制，未统一生成编译测试；新增界面深浅主题原库修订加密持久化/保存ACK后切换/正式加载/错误重读与同步备份恢复源码；新增Nerd内置MIT许可子集候选（1111码点/固定源散列/完整组件许可）及许可查看已静态编制；新增原Vault/文档修订CAS的本机主机字体覆盖/继承、逐会话绘制与懒加载、失败临时回退/明确重试和退出等待源码；新增通用排版/内置家族预设独立共享字段、原本机映射优先与组合修订CAS/同SQL保存、云白名单及完整备份分离源码；统一运行和目标平台验证仍待做','term-core/src/preferences.rs；storage-sync/src/{typography,terminal_preferences}.rs；frb-bridge/src/api.rs；workbench/terminal_preferences.dart；storage-sync::appearance；workbench/appearance.dart；TERMINAL_PREFERENCES.md；APPLICATION_APPEARANCE.md','新增核心3/仓库2/设置4/粘贴鼠标3/真实OpenSSH Native1与GTK1测试源码待执行；字体另见TERMINAL_TYPOGRAPHY.md；仅格式化解析/diff检查')
 if section=='4' and n==7:status,code,tests=('静态源码待统一验证：BEL/OSC9文本与OSC777、5秒去重/单终端250ms及应用投递预算、显式16条关键词或有界正则/CR-LF片段、一次性输出静默、前后台策略/默认隐藏正文、原会话代次及运行策略失效、Windows可选桌面插件与明确点击定位/窗口激活、退出实际worker等待已接；不接SFTP事件；依赖/平台均未构建','term-core/src/notifications.rs；vendor/vte与alacritty_terminal；ssh-core/src/session.rs；workbench/{terminal_notifications,notification_settings,terminal_preferences}.dart；TERMINAL_NOTIFICATIONS.md','新Core5/存储1/Dart及组件5/真实私有OpenSSH1共12项测试源码未执行；仅格式化解析及diff；Windows通知/系统勿扰/激活仍待实机')
 if section=='3.1' and n in [2,3,6,8]:status='未实现（代理/转发/agent/tmux策略）'
 if section=='3.1' and n==2:status,code,tests=('部分：最多一级SSH跳板与唯一HTTP/SOCKS代理的加密保存/正式选择器/真实PTY及SFTP/手动探测已接并验；路线隔离TOFU/原尝试确认取消/无回退；云同步独立代理仍待做','ssh-core/src/proxy.rs；storage-sync/src/{ssh_proxy,repository}.rs；frb-bridge/src/api.rs；prototype/hosts.dart；SSH_NETWORK.md','代理协议10项/真实3项/仓库4项；jump真实6项/配置2项/仓库5项/桥接作用域3项；Native路线/PTY/SFTP与3项表单、真实GTK双端信任/保存；目标平台待验')
 if section=='3.1' and n==3:status,code,tests=('部分：原Transport有界TCP、本地-L/动态-D/远端-R真实Rust核心/状态/停止/原代次释放已验；R迟到ACK/取消未知/拒绝重试/精确入站路由与消费窗口已接；加密规则仓库/主机复制草稿与删除事务已验；配置FRB读写已验；原会话运行期FRB及可视化L/R/D手动管理/停止/断开销毁已验；原代次合并推送/隐藏零帧/空闲无poll已验；明确重连恢复/独立失败、本机加密草稿与修订墓碑/CAS/原子提交、终端链接确认临时回环转发与失败局部清理已验；Android正式交互与目标平台验收仍待完成','ssh-core/src/{tcp_channel,forwarding,remote_forward,session}.rs；storage-sync/src/forwarding_rules.rs；frb-bridge/src/forwardings；workbench/forwarding_dialog.dart；vendor/russh；PORT_FORWARDING.md','R专项13项（6真实OpenSSH+7受控peer）；原L/D16 OpenSSH+1受控peer；未授权入站受控peer；完整Rust289/Flutter186；Native原终端/Codex/规则/草稿与运行；9组件及链接交互；GTK管理/手动重连与临时链接确认2项；NDK与双模式构建')
 if section=='3.2' and n==1:status,code,tests=('Ubuntu已接并验：正式保存主机手动TCP/唯一代理/可选跳板认证/目标SSH握手与独立TOFU，取消/退出等待；不验证目标认证、不建标签或后台探测','ssh-core/src/{lib,session}.rs；frb-bridge/src/{api,connections}.rs；workbench/connection_test.dart；prototype/host_connection_test_dialog.dart；SSH_NETWORK.md','openssh_probe真实2项；Native/弹窗/生命周期/长目标8项；跳板Native与GTK双身份/不验证目标认证；GTK握手范围/停流取消；完整回归见PROGRESS')
 if section=='3.2' and n==2:status,code,tests=('Ubuntu已实现并验：共享总Budget/安全确认暂停计时；加密全局默认与主机显式继承/覆盖，旧主机保留原参数；仅下次明确连接生效','ssh-core/src/budget.rs；storage-sync/src/repository.rs；prototype/hosts.dart；workbench/model.dart','Budget单测；ssh_network_settings_bridge真实1秒代理超时/8秒取消；主机表单/窄窗缩放；GTK时限保存及重连')
 if section=='3.2' and n==6:status,code,tests=('部分：普通PTY/协议重置与SFTP原会话手动恢复已接；明确重连后的配置转发L/R/D恢复及局部失败独立显示已验；tmux基础明确重选已验；新附着/新建的实际身份回执及用户明确勾选手动重连记忆、关闭恢复/原Vault与SSH身份核对已有静态源码未统一验证；新增默认关闭的加密偏好、原运行期中断候选、原标签/实际回执代次/Vault/双端身份及待传项目恢复、主动暂停/跨启动排除、独立汇总及失败报告源码待统一验证；已知失败项及冲突仍需明确处理','ssh-core/src/session.rs；frb-bridge/src/{api,forwardings/runtime}.rs；workbench/model.dart；PORT_FORWARDING.md','真实Native独立L/R/D/禁用策略/端口占用/目标身份变化；GTK重新连接及三类TCP回显；原Phase2回归')
 if section=='3.2' and n==3:status,code,tests=('Ubuntu已实现并验：加密全局/主机覆盖的心跳间隔、独立ACK响应超时、连续失败阈值及0关闭；原Transport有界探测，不自动重连','ssh-core/src/{lib,heartbeat}.rs；storage-sync/src/network_defaults.rs；workbench/ssh_network_defaults.dart；SSH_NETWORK.md','虚拟时钟2项/加密记录2项/Route快照2项；Native真实ACK/停流/手动重连与0关闭；GTK设置/主机保存；完整294 Rust/188 Flutter')
 if section=='3.1' and n==1:status,code,tests=('Ubuntu已实现独立Transport/PTY与同Root关联SFTP；原actor身份回执与原代次、PTY/SFTP/转发/Agent有界背压隔离已验；目标平台待测','ssh-core/src/{lib,session}.rs；vendor/russh/src/client/mod.rs；frb-bridge/src/api.rs；SESSION_FLOW.md；CONNECTION_IDENTITY.md','真实多SSH/跳板/PTY/SFTP与布局身份；旧未读PTY阻塞复现→新8MiB逐字验证及5次重复；核心185/Native7；前节点完整workspace341')
 if section=='3.1' and n==4:status,code,tests=('Ubuntu已实现TOFU/变更拒绝和RSA SHA2主机验证；每次rekey信任检查、同原密钥不重问；原actor身份回执/代次/目标与准备Vault作用域、跨/同库重开旧确认拒绝已验；目标平台待测','ssh-core/src/{lib,session}.rs；vendor/russh/src/client/{kex,mod}.rs；frb-bridge/src/{api,connections/verification}.rs；SSH_RSA.md；CONNECTION_IDENTITY.md','原TOFU/跳板/取消/CAS；RSA-only SHA256/512首次确认/错误指纹/hostkeys证明/rekey；原Native复现旧确认不失效→新跨/重开库测试通过；完整workspace341/Native8')
 if section=='3.1' and n==5:status,code,tests=('Ubuntu已实现所列格式：Ed25519生成/导入/公钥/每次主密码私钥导出；RSA OpenSSH/PKCS1/PKCS8/PBES2与遗留AES128/256 PEM导入、2048–4096位ring SHA2认证；SHA2 RSA-only host/TOFU/rekey已验，SHA1拒绝；更多格式/目标平台未作无限支持承诺','ssh-core/src/{identity,lib}.rs；vendor/russh/src/keys/{rsa_ring,verify_ring}.rs及format；SSH_RSA.md；SSH_AGENT.md','RSA专项12项/六种格式真实OpenSSH认证/CRT与KDF成本/短签名/双SHA2主机及hostkeys证明/rekey；核心182后12项补验；Native加密PKCS8/持续输出重协商/手动重连；全Flutter207')
 if section=='3.1' and n==6:status,code,tests=('部分：应用内原Transport Agent核心已验；默认未授权拒绝/限时显式密钥选择能力/列表签名/撤销到期/新Root不继承/4流消费窗口；正式加密主机开关/FRB票据与原Vault/代次/实际端点/凭据复核、明确指纹及风险同意/撤销UI已验；密钥更改删除与切库撤销、关闭等待blocking工作、独立合并推送/隐藏零帧/绘制零查询；目标平台实测与Android专用入口仍待完成','ssh-core/src/{agent_forward,agent_protocol,agent_signer,session}.rs；frb-bridge/src/{api,agents}.rs；workbench/agent_dialog.dart；vendor/russh；SSH_AGENT.md','Agent单测6项、真实两个sshd认证/撤销到期/独立openssl验签/慢消费及受控标准peer共6项；窗口额度回归与5次压力重复；完整workspace330/Flutter206；Rust门控2项/组件4项/Native2项/GTK1项；Clippy/NDK/正式双模式与启动')
 if section=='3.1' and n==8:status,code,tests=('部分：Ubuntu真实原SSH认证后明确发现/附着或新建、默认只读ignore-size/风险确认接管、PTY初始尺寸锁和解除、原Vault/代次一次票据及独立模式推送已验；新增原会话/新建真实身份回执、显式配置的手动重连记忆/取消与关闭源码，未统一生成运行；Android专用入口及目标平台待做','ssh-core/src/tmux.rs；frb-bridge/src/tmux.rs；workbench/tmux_choice.dart；TMUX.md','核心3/Bridge作用域1/加密开关1/真实OpenSSH2/Flutter与Native专项10/GTK1；全量与构建实际结果见PROGRESS')
 if section=='3.1' and n==7:status,code,tests=('Ubuntu已实现：正式主机单次地址/端口/用户/显式一种认证覆盖；不改保存主机或凭据、不回退认证；原Vault/主机/跳板元数据复核、取消无标签、断线重新确认及新秘密、临时Root禁历史收集标记；目标平台待验','frb-bridge/src/{api,connections/temporary}.rs；workbench/{temporary_connection,model}.dart；TEMPORARY_CONNECTIONS.md','Rust4/组件3/真实双OpenSSH Native2/GTK1项；完整bridge30及全Flutter213；NDK/Clippy/双模式包与实际GTK启动通过')
 if section=='5.3A' and n==3:status,code,tests=('部分：实际路径复制已接平台剪贴板；安全上下文/专项验收待补','prototype/files.dart','现有原型菜单回归；真实路径复制专项待测')
 if section=='5.3A' and n==7:status,code,tests=('部分：Ubuntu正式选区/本地右键→原会话SFTP文件选择/目录导航已接；Android长按入口待做','term-core/src/working_directory.rs；frb-bridge/src/api.rs；terminal/view.dart；workbench/model.dart；prototype/files.dart','terminal_path_bridge真实双SSH/迟到目录；terminal_path_ui；真实GTK鼠标拖选/定位/隐藏行')
 if section=='5.3A' and n==8:status,code,tests=('部分：原绝对/同authority相对路径定位已有Ubuntu验收；新增关联终端子树相对路径复制/原Root代次及OSC7修订两次核对/菜单选择冻结与退出保护已静态编制；符号链接父归约不猜测，保留绝对兜底；完整安全注入仍待做','term-core/src/working_directory.rs；frb-bridge/src/api.rs；prototype/files.dart；workbench/model.dart；TERMINAL_PATHS.md','原协议/Native/GTK证据保留；新增核心2/Flutter菜单3/真实双SSH Native1测试源码待统一执行，仅格式化解析/diff检查')
 if section=='3.1' and n==2:status,code,tests=('SSH唯一代理及一级跳板已有Ubuntu核心/正式UI验收；云同步独立HTTP/SOCKS代理与单目标加密配置/运行已有后续静态源码待统一验证，不读取SSH代理或失败直连','ssh-core/src/proxy.rs；storage-sync/src/backup/cloud_sync/{settings,webdav,drive_files}.rs；workbench/configuration_sync_settings.dart；SSH_NETWORK.md；CLOUD_SYNC_SETTINGS.md','保留原SSH代理/跳板真实证据；云HTTP/独立代理与设置测试源码未运行')
 if section=='5.2' and n==4:status+='；正式HostManager未保存保存/丢弃/取消已有，通知定位现统一走离页保护；新增通知式取消/原标签消失回归源码未运行'
 if section=='5.4':
  status+='；新增单端/双端任务明确选择现有SSH标签、冻结nativeID/代次并Native复核、任务状态变更禁用及队列请求/列表读取退出等待源码待统一验证'
  code+='；workbench/transfer_connections.dart；TRANSFER_RECONNECT.md'
  tests+='；新6项选择器/引用及原单端/双端OpenSSH代次拒绝扩展源码未运行'
 if section=='4' and n in [6,8,9,13]:
  detail={6:'原URL/OSC8及同会话远端路径定位已有Ubuntu验证；新增普通POSIX路径/path:line识别与源代次菜单源码待统一验证，Android长按暂停',8:'原RAM+临时磁盘/历史限量/应用退出清理/宽字符Reflow已有Ubuntu验收；新增OSC133完整范围与旧历史重排一致性源码待统一验证',9:'原当前会话普通/正则搜索/计数导航/滚动标记/新行提示及不强制跟底已有Ubuntu验收；新增命令段完整范围菜单源码待统一验证',13:'原Windows默认8px及加密可配置padding/字体几何更新与原PTY尺寸合并源码已有；新增排版设置未统一生成编译'}
  status,code,tests=(detail[n],'term-core/src；terminal/{view,controller,painter}.dart；TERMINAL_TYPOGRAPHY.md；SHELL_INTEGRATION.md；PHASE2_VALIDATION.md','保留Phase2实际证据；后续源码统一验证未开始，不能算Windows实测')
 if section=='4A.9':
  status,code,tests=('原协议和显示装饰边界已有Ubuntu验证；新增可选集成/候选受控动作/原Vault权限与历史缓存失效源码待统一验证，默认关闭且未知/TUI不抢键，不加入排除项','term-core/src/integration.rs；terminal/suggestions.dart；storage-sync/src/backup/cloud_sync；SHELL_INTEGRATION.md','实际记录见PROGRESS；新源码/性能与平台未统一验证')
 if section=='5.3A' and n not in [3,6,7,8]:
  status,code,tests=('Windows静态接入待统一验证：同源SFTP文件/目录/批量拖入和菜单发送、路径栏当前目录、显式空行cd；源nativeID/代次与助手实际输入双重校验、POSIX引用、只填入不执行；确定未发送才复制降级，未知结果不重发/不改粘贴；无文件传输。Android入口暂缓','prototype/{files,cached_path_field}.dart；workbench/{surface,terminal_paths,app}.dart；frb-bridge/src/api.rs；ssh-core/src/session.rs；SHELL_INTEGRATION.md','新增5项源会话/剪贴板降级及拖动快照组件源码、受控OpenSSH3项和Native1项未运行；原终端定位证据保留')
 if section=='5.3A' and n==6:
  status,code,tests=('Ubuntu已有原会话绝对/可信OSC7相对路径定位；新增自动普通路径/path:line菜单源码待统一验证；Android长按暂停','terminal/{links,view}.dart；workbench/model.dart；term-core/src/working_directory.rs','原Native/GTK定位证据；新增识别专项源码未运行')
 if section=='5.3A' and n==8:
  status+='；本轮绝对路径受控插入/引用降级已接源码，保留原OSC7相对解析约束'
  status=status.replace('；完整安全注入仍待做','')
 if section=='8' and n==6:
  status=status.replace('；入口前FFI/tracing/其余UI和完整业务事件仍待继续审核','')
  status+='；新增FRB initializer提前固定panic hook、两真实Flutter入口错误正文禁止格式化/固定Widget及4类有界内存计数、明确诊断刷新清空源码；插件/FFI及平台动态泄漏检查仍待统一验证'
  code+='；runtime_errors.dart；workbench/diagnostics.dart'
  tests+='；新增3项Dart隐私/计数/刷新源码未运行；源检查不等于类型/动态泄漏验证'
 if section=='11':status,code,tests=('验收映射；以对应功能行状态为准','§3/4/4A/5/6/7/8对应实现','PHASE2_VALIDATION.md；validation/phase3a；新增业务待测')
 # Current evidence supersedes source-only checkpoint wording above. Keep the
 # detailed implementation/file mapping, but never report generated/tested code
 # as ungenerated, nor confuse Linux verification with Windows platform proof.
 current = {
  '2': ('共享Rust/Flutter/FRB正式代码已接入；Ubuntu构建与统一回归已执行；目标平台适配边界见PLATFORM_VALIDATION', 'Cargo Workspace/FRB2.13.0；Flutter Analyze；Linux及Windows GNU全目标严格Clippy'),
  '3.1': ('Windows连接/认证/TOFU/一级跳板/独立代理/转发/Agent/tmux代码已接入，Ubuntu自动化通过；Windows真实系统行为待验', 'ssh-core真实OpenSSH128项；native_bridge/ssh_jump/ssh_proxy/forwarding/agent/tmux桥接及GTK'),
  '3.2': ('连接测试、分阶段限时、心跳、保留画面与一次手动重连已接入并经Ubuntu回归；不自动重建Transport', 'connection_test/connection_status/native_bridge/workbench_lifecycle；真实SSH与GTK'),
  '4': ('共享终端核心与Windows显示输入/历史搜索/导出/字体/通知代码已接入并经Ubuntu回归；Windows IME/字体/通知实测待验', 'term-core42项及协议/历史/范围专项；native_bridge/widget/typography/terminal_preferences；GTK收尾见UNIFIED_VALIDATION'),
  '4A.1': ('已接入并经Ubuntu回归：'+(detail[n] if section=='4A.1' else '')+'；逐主机主动启用Bash集成，未证明状态安全退化；Android专用入口暂缓', '核心回执/真实OpenSSH；shell_suggestions_bridge/terminal_suggestions/history_controls及加密同步/备份测试'),
  '4A.2': ('Windows加密显示规则与可见区装饰已接入并经Ubuntu回归；远端颜色/原文/TUI优先；Android入口暂缓', 'display_bridge/display_settings/same_word及GTK；term-core装饰/存储同步回归'),
  '4A.3': ('Windows语义着色/彩虹括号及全局/主机设置已接入并经Ubuntu回归；仅显示层', 'term-core装饰；display_bridge/display_selection/display_settings及GTK'),
  '4A.4': ('Windows可见区同词高亮已接入并经Ubuntu回归；不改真实选区或历史', 'same_word/display_selection/widget；真实SSH显示回归'),
  '4A.5': ('命令段导航/完整输出复制、RAM与磁盘历史及Reflow证明已接入并经Ubuntu回归；实际Shell重绘覆盖后拒绝旧范围', 'term-core命令范围16项；真实OpenSSH静止重排/重绘拒绝2项；command_ranges_bridge及GTK'),
  '4A.6': ('Windows安全多行预览/编辑/取消/确认及bracketed paste已接入并经Ubuntu回归；Android专用交互暂缓', 'widget/terminal_paste_lifecycle/terminal_preferences；真实SSH及Codex协议回归'),
  '4A.7': ('Windows应用命令面板/可配置快捷键/权限与离页保护已接入；保存键位即时生效与Kitty释放归属已修并实测；Android入口暂缓', 'application_keys7项/command_palette/palette_settings；真实GTK快捷键/按键精确字节归属'),
  '4A.8': ('Windows URL/OSC8/IP/端口/路径菜单及原会话SFTP定位已接入并经Ubuntu回归；无被动联网；Android长按暂缓', 'terminal_links/relative_paths/terminal_path/osc8/forwarding_bridge及GTK'),
  '4A.9': ('排除项及协议优先边界保持；装饰/历史加密/同步/备份已接入并经Ubuntu回归；平台和真实服务商验证分别登记', 'term-core；display/history/configuration_sync/configuration_backup；UNIFIED_VALIDATION'),
  '5.1': ('真实标签一对一会话/标签组自由分屏/生命周期已接入并经Ubuntu回归；Win32窗口代码已接入，尚缺MSVC编译和Windows实际窗口验收', 'terminal_layout/window_chrome/live_workbench/workbench_lifecycle；真实GTK'),
  '5.2': ('Windows正式主机管理/独立凭据/加密草稿/批量/分组排序与离页保护已接入并经Ubuntu回归；不是Mock', 'host_bulk/host_ordering/host_catalog_drag/host_save_ack/settings_leave_guard；真实SSH及GTK'),
  '5.3': ('Windows正式SFTP/缓存分页/列与菜单/搜索书签/预览编辑已接入并经Ubuntu回归；OLE/Explorer原生代码待MSVC和Windows实测', 'directory/file_columns/file_search/file_preview/editor/explorer桥接与组件；真实GTK外部应用流程'),
  '5.3A': ('Windows十项路径操作已接入并经Ubuntu回归；原会话/代次、可信OSC7与实际Shell输入证明及安全复制降级；Android交互暂缓', 'terminal_paths_send/terminal_path_drop/relative_paths及Native双SSH；真实OpenSSH受控动作/GTK定位'),
  '5.4': ('Windows真实文件/文件夹任务/FIFO/限速/检查点恢复/重扫/冲突/跨服与明确来源删除已接入并经Ubuntu回归；Explorer系统交付待Windows实测', 'transfer/remote_transfer/direct_transfer/source_retirement桥接及Rust故障回归；真实GTK队列与编辑流程'),
  '5.5': ('Windows实际RTT/PTY/任务状态与显式远端只读指标/进程操作已接入并经Ubuntu回归；无默认额外探测', 'heartbeat/inspection；connection_status/remote_inspection_bridge；GTK状态栏'),
  '7': ('共享SFTP/真实传输与安全规则已接入并经Ubuntu回归；不跟随复制链接、不自动SSH重连、未知结果不盲重发', 'OpenSSH128项及SFTP协议故障专项；完整Native文件任务/恢复/直传回归'),
  '8': ('Windows加密配置/同步/备份/导入/诊断代码已接入并经Ubuntu回归；真实Google/WebDAV账号、Windows DPAPI另列待验，Android Keystore暂缓', 'storage-sync213项；Bridge75项；同步/备份/诊断/密钥桥接和组件；隔离HTTP服务代替真实云账号'),
 }
 if section in current:
  status,tests=current[section]
  tests+='；最新统一结果见UNIFIED_VALIDATION.md（不等于整条目标平台验收）'
 if section=='6':
  status='Android专项开发按用户要求暂缓；共享核心自动化通过不等于Android应用实现/设备验收'
 if section=='11':
  status='验收场景索引；按对应功能实现和测试证据判断，平台/真实账号待验不计通过'
  tests='UNIFIED_VALIDATION.md；PLATFORM_VALIDATION.md；对应功能行测试（Mock与真实测试分开）'
 summary=re.sub(r'^[\d]+[a-z]?\.|^- ','',line).strip().replace('|','／');summary=summary[:78]+('…' if len(summary)>78 else '')
 rows.append((ident,summary,status,code,tests,line_no))
header='''# V1.4 全量需求覆盖清单

本表逐条索引V1.4产品条目及验收场景，复合条目只要有子要求未实现即标“部分”。“已实现Ubuntu”不表示Windows/Android实机通过；Mock只能证明布局交互。实际代码/测试为依据，历史验收见PHASE2_VALIDATION.md和PHASE3A_REVIEW.md。排除/禁止事项仍遵循V1.4 §1/§9，不作为待恢复功能。阶段条目§10用于内部追踪，已取消逐阶段暂停。

当前依赖顺序：加密领域仓库→真实多会话工作台→会话SFTP与任务系统→协议语义/增强及完整网络配置→同步/备份/平台适配→Android。顺序可调整，所有条目保留到可验证完成。最新用户策略为Windows优先、Android暂缓；成批编码后已进入统一生成/编译/测试修正，FRB和两锁已正式生成。Rust完整647项及安全补丁影响范围Bridge75/SSH255项通过；Flutter143文件507个去重用例通过（中断后按清单续齐，非单条命令完整通过），GTK29适用文件通过；构建/静态/平台边界见UNIFIED_VALIDATION.md。表中已接入表示实际业务代码，不能据此宣称整个复合条目或Windows平台验收完成。

| ID | 要求（完整文字见链接） | 实际状态 | 代码 | 测试/证据 |
| --- | --- | --- | --- | --- |
'''
for ident,summary,status,code,tests,lineno in rows:
 header+=f'| {ident} | [{summary}](HSPTerm_最终需求规格_v1.4.md#L{lineno}) | {status} | {code} | {tests} |\n'
header+='''
## 跨条目边界

- 单SSH会话/单标签、同Transport关联SFTP；不广播、不自动重连、不加本地Shell；新主机先正式保存。
- 不采用WebView/Electron/Tauri；Rust负责协议/安全/任务，Flutter负责显示/平台输入，FRB2连接。
- Windows单主窗口，空白启动，关闭退出，无托盘；Android单终端显示、全屏SFTP，不移植桌面分屏。
- 凭据/私钥等机密不明文落盘/日志/仓库；终端历史只本次运行；命令历史需加密持久化及默认参与已启用的加密同步。临时预览退出清理；外部编辑工作副本另行持久保留，仅明确确认后清理；两者均不入云端/配置备份，见FILE_PREVIEWS.md和REMOTE_EDITING.md。
- 真实账号/付费任务/生产资源未经授权不使用。Windows、Android、Claude未提供运行条件时保留具体待测项目，不伪报。
'''
(ROOT / 'REQUIREMENTS_COVERAGE.md').write_text(header)
print(f'Indexed {len(rows)} requirement and acceptance clauses')
