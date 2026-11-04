# SFTP已有缓存路径补全

正式工作台与独立Mock共用CachedPathField，真实模式只传入源终端的会话目录LRU。候选由已访问目录路径及对应父目录里已知的文件夹名称组成；不访问SSH/SFTP、不更新LRU、不预读、不解析未知符号链接，不用其他标签的目录数据。目录缓存仍需明确刷新，补全结果不代表服务器当前存在保证。

路径保持POSIX大小写及空格/Unicode原文。点击候选只填入路径；路径栏明确提交后才通过原关联会话导航，不发送终端命令。候选显示相对输入父目录的尾部，悬停显示完整绝对路径；上下键切换时自动滚动让选项可见。原绝对路径/NUL校验保留。重连代次/标签切换重建字段并取消旧工作；失焦也取消。

每次最多保留12个按原始字符串有序的候选。每512个元数据项目让出事件循环，新查询取消旧扫描，不复制整个大目录列表。仅补全最多4096个UTF-16单元的路径；更长路径仍可手动输入并正常提交，这是候选计算边界，不是SFTP路径或文件列表的截断限制。未缓存父目录不会发请求获取候选。

IME composing期间不展示候选，也不改写组合文本。Flutter RawAutocomplete会忽略同文本的composition-only更新，因此同一文本的候选Future共享并等待最终提交；新文字、失焦和销毁都释放等待并取消旧查询，无无限轮询。

文件列表的Delete/F2/Enter/Ctrl+A只在列表自身拥有primary focus时触发，路径/过滤文本框的输入不再冒泡成文件操作。回归先真实复现路径内Delete弹出文件删除确认，再加入焦点保护；原文件列表快捷操作保持。

验证入口：`cd ui_flutter && flutter test test/cached_path_field_test.dart --reporter expanded`，覆盖本会话缓存/特殊字符、未知符号链接不探测、4096行异步取消/结果上限、点击不导航/明确提交、同文本IME最终提交、会话重建不泄露候选、路径文字编辑不触发文件删除/重命名/批量选择。

`xvfb-run -a dbus-run-session -- flutter test integration_test/live_workbench_test.dart -d linux --reporter expanded`另验证真实GTK/SSH元数据：已有目录缓存中输入并选择候选时，目录epoch和SSH代次不变；明确提交后导航正确、侧栏宽度保持。截图与最终测试结果见PROGRESS.md；Ubuntu测试不替代Windows/Android原生输入法与键盘。
