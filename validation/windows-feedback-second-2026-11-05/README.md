# 第二轮 Windows 实机反馈修正（2026-11-05）

本轮针对用户日志与截图中的终端/SFTP问题。原始日志、截图不进入Git。Ubuntu结果不能替代 Windows 11 TSF/IME、真实最小化及用户服务器环境。

## 修正

- IME保留平台文本模型；组合段仅本机预览，稳定文本按增量提交，重复平台快照不重复发送。无效/隐藏viewport不发送PTY resize；字号缩放保存在终端控制器，UI重建不重置。
- 普通Readline的application keypad/cursor不作为TUI判据；屏幕/OSC133锚点失效不撤销独立私有Readline证明。Alt-screen/reset/损坏私有协议仍撤销。修复Bash字符类错误：原写法错误拒绝连字符，现准确拒绝C0/DEL，保留正常连字符路径/命令。
- 逐主机可选Bash助手输出经过百分号编码的OSC7当前目录和OSC133 A/B/C/D；不修改服务器启动文件。历史仍需原会话/库/主机范围校验和实际提交回执，不盲目记录TUI或隐藏输入。
- 操作反馈统一到可关闭6秒浮动通知，显式persist=false（Flutter新版带action默认持久化）。已连接时不再显示错误的link_off状态条，不因反馈条改变PTY高度。
- Ctrl+滚轮调整本标签字号，右键提供搜索。SFTP面包屑/可编辑路径、父目录占位、主机/全局书签列表、新文件EXCL、新建选中/可视、队列分隔强调、当前目录发送/跟随/跳转、紧凑可见复选框、空白右键及四项路径菜单。
- 文件剪贴板按终端标签隔离。同标签复制由固定远端Python3程序执行，正文不通过本机；剪切走SFTP rename，不使用下载再上传。跨标签明确使用二级菜单，保留来源/目标代次和目标目录快照校验。
- 属性弹窗快速读取元数据；目录大小通过真实SFTP分页元数据累计，不把目录inode大小当内容。UID/GID/八进制权限可改，递归不跟随子链接，根目录最后改。链接展示目标；大小查询失败仍可编辑已读取权限。

## 适用限制

- 用户需保存主机的Shell集成选项，再手动重连一次建立新助手；旧连接不会自动重建。普通Bash提示符下启用受控路径插入，Vim/tmux/隐藏输入/不确定行编辑状态仍安全复制降级。OSC7/OSC133本身不构成可靠输入证明。
- 相对路径定位必须有本连接真实上报的工作目录；不存在或无权限的路径仍会报真实错误。复制命令输出仅适用于助手启用后、具有完整边界的新命令，不能推测旧屏幕/TUI输出区间。
- 同机复制需要远端Python3且SSH exec与SFTP共享可证明的路径命名空间。校验用0600随机回执，无任意脚本输入；不具备能力时失败，不静默下载。每次复制120秒预算、目录深度128/节点100万，不提供此即时操作的跨启动恢复；失败可能留下部分目标，明确要求核对且不自动重试。断线可能留下私有回执，文件名.hspterm-copy-*，不能把未确认操作当成功。
- 目录内容大小30秒预算、深度128/项目100万；是文件/链接逻辑字节总和，不是磁盘占用。递归权限120秒，部分失败不回滚，不与其他远端程序并发修改同一树。
- welcome/机器信息一项的含义尚待明确：当前反馈可解释为希望恢复或希望隐藏。未过滤、伪造服务器输出，也未静默修改登录脚本。

## 已执行

- 正规FRB2.13.0生成，Flutter Analyze 0。
- Rust三库串行单测初轮：bridge77 / ssh79 / term42均通过。完整term-core含新集成测试、最终bridge及严格Clippy结果将在本目录结果文件补齐。
- 真实隔离OpenSSH可选Bash9项通过，包括连字符/中文目录OSC7、实际历史、完整OSC133及Readline keypad；不读取用户登录凭据。
- Flutter集中60项组件/交互回归通过，覆盖IME/通知/最小化/字号/右键搜索/属性/新菜单与原工作台/Explorer选择保护。
- 实际Native FRB/OpenSSH/SFTP4项通过：属性/新建/服务器复制、逐标签同机复制与剪切不创建传输任务、历史候选/受控路径、完整LiveWorkbench跨标签布局及明确跨服传输回归。
- Python服务器复制3项、实际Bash解码器1项（32个控制字符、NUL及连字符/中文路径，共34分例）通过。源码桥接契约审查243 API/75 DTO/300 Dart，0问题。

GTK可运行工作台、最终构建/格式、Windows Actions 状态另行补记。不得将本段计划项记为已通过。

## 集中验证收尾

- 最终term-core全部105、bridge77、ssh单元79；真实Bash9项通过。严格Clippy最终0警告。源码桥接检查及其10项自身测试、Bash语法、Rust/Dart格式和diff检查通过。
- GTK真实工作台最终1项通过（不是Mock）：真实SSH、实际目录内容大小、属性表单、新文件EXCL、选中可见、中文路径受控填入且没有回车/传输、无效viewport不清屏，原native ID/代次保持。首次GTK夹具在视图挂载前等待帧导致超时，已修正为先连接、挂载再等待真实帧；最终通过。
- 组件回归60项通过，后补新建置尾/滚动再布局测试后该文件与上下文菜单9项全过；去重为61组件用例。新建项临时置于列表尾部并选中，明确排序/刷新或目录切换后恢复正常排序；lazy ListView旧extent需要后续帧校准，已通过80行压力夹具，旧一次jump不足问题已修。
- Native4项最终全过；同机复制回执改为本次随机nonce框定标记，允许非交互Shell自己的banner而不把它当复制失败，相关真实SFTP两项再验通过。
- 重新构建正式lib/workbench_main.dart Debug包（不交付测试入口），独立GTK启动/退出结果见debug-startup.json。
- 本轮两张GTK检查截图保留在/tmp/hspterm-feedback-second-{properties,workbench}.png作临时视觉检查，不进入仓库；布局已实际查看。用户自己的ssh-screen截图不清理。

## 发布后补充

55ad8c7已正常Git推送并触发Windows run41970895508。补充UI组合态门控与失焦后旧IME快照抑制，24项组件回归与Analyze0通过。相对路径菜单旧用例按用户四项菜单修订更新（不再打开菜单便发起OSC7查询），对应3组件+原Native相对路径1项通过。大型GTK回归脚本同步新书签/子菜单/同机服务器内操作；首轮到目录失败重扫处因ensureVisible后未pump点击旧坐标失败，正在第二轮，不计整例通过。发布状态以PROGRESS最新head/run为准。

## 大GTK回归通过

最终/tmp/hspterm-second-full-gtk3.log，03:34 +1 All tests passed。真实上传/队列/目录重扫/批量更名/4096项懒列表、书签、内置和Mousepad编辑、GBK及CRLF、16MiB以上文件原字节编辑、目录搜索、同机服务器内复制与rename、跨标签子菜单、失败重扫保留成功项、目录补全、统一应用文件打开/传输设置、主密码与加密主机/草稿流程全部验证。第二轮后半段失败是旧脚本仍找已取消的单项保存按钮，已同步settings-apply；没有删去断言来规避业务失败。

补充后本轮去重65组件、5个Native真实SSH/SFTP、2个GTK整例通过；不是把每个整例内部断言虚增为多个测试。最新产品源码a0910ce；Windows run41971663339/job127061543477仍在运行。本轮末尾维护只涉及Ubuntu整例脚本旧选择器与验证文字，产品源码与此云构建一致。

原Mock工作台GTK截图/交互整例也实际00:29 +1通过，保留独立原型入口；其中数据明确为Mock，不计真实SSH/SFTP验收。截图只在/tmp/hspterm-feedback-second-prototype供本轮检查，不提交。正式工作台同产品源码的独立启动已过，最后再次恢复lib/workbench_main.dart入口，避免留测试入口的bundle。

## 缓存清理

最终恢复正式入口后，已安全清理本轮target/build/.dart_tool/ephemeral和生成插件元数据及本轮测试PNG；实际释放3,969,970,176字节，恢复约12.97GiB可用空间，详cache-cleanup.json。源码、正式FRB生成物、字体/vendor/锁、文字/JSON测试证据及Git历史均保留。用户原始.log、ssh-screen/、tools/AGENTS.md未清理且不提交。现在没有可运行的Linux bundle；恢复必须先prepare_native_extensions.py和pub get后重建。

## Windows 云构建成功

- run41971663339/job127061543477正式completed/success，产品源码a0910cee20bcca55505f94ea9eeff3e3ff7d270f。MSVC Release、Flutter Analyze0、66组件用例、原生启动退出、正常关闭位置与大小恢复全部通过。Ubuntu脚本维护及文档提交不改变此产品源代码，已逐路径diff验证。
- 完整包：[HSPTerm-windows-x64](https://github.com/hspmanbu/hspterm/actions/runs/41971663339/artifacts/13390548974)，40,000,381字节，SHA256 3a2957eb889dd2470acd3a45a399e953a34b792263c53bd356ec799b206972f4；2026-11-19到期。完整解压后保留同目录DLL/data并运行hspterm.exe。
- 同类云runner锁库启动三样本工作集：此前115.66/111.66/111.64MiB，本轮115.00/111.97/111.94MiB，保留before/after JSON；不足以据此判断用户机器的精确内存或长期泄漏，未冒称Windows11实机结果。
- 本轮产品任务已收尾，用户Windows11原生IME/实际最小化和新的SFTP交互仍须复测；Codex/Vim等复杂TUI不会因启用Bash助手而允许盲注入，继续安全复制。欢迎信息仍待用户明确显示或隐藏。
