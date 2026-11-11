# 第十四轮 Windows 反馈：静态复核

用户要求本轮仅在Ubuntu修改/静态复核，运行测试和正式编译交给Windows CI；第三阶段优化暂停。

- Flutter Analyze：No issues found（完整源码含测试源码）。
- FRB 2.13正规生成成功；新增clipboard_image_progress，绑定native id / generation / 原唯一临时源文件。
- bridge_contracts：265函数、82 DTO、332 Dart文件，0发现；仅词法契约，不是运行验收。
- bridge_error_boundaries：260公共Result入口受保护，公开错误短语白名单同步；仅源码检查。
- Rust/Dart格式与git diff --check通过；未运行Ubuntu构建、Clippy或运行测试。
- 静态跨层检查：图片进度取连续SFTP ACK，查询不含像素/输入正文且不产生SSH通道；单在途有界刷新，结束或关闭后停止；队列记录仅本次进程。
- 编辑替换等待旧初始化/上传/监测器收尾，草稿与其他SSH标签保留；新会话下载之前注册。
- WebDAV公开构造器允许HTTP(S)，仍禁URL凭据/query/fragment/redirect；独立代理和条件写入不变；Drive服务端点仍绑定HTTPS。
- 已编制回归：首次/闲置路径选择与外点退出、资源靠右/小窗口无省略、同文件编辑替换保留草稿、图片ACK队列进度、多行预览行号/尺寸/滚动条和选区、HTTP传输及Drive边界。CI完成前不将这些新增测试标为通过。

Windows11需实机复核：首次连接/闲置后面包屑、右侧资源栏宽度与缩放、同文件重复双击、真实图片剪贴板队列、预览框选区颜色及滚动条鼠标指针；实际WebDAV账号不由CI使用。

- 补充：同标签重连后仍替换旧路径编辑，SSH实际I/O代次校验不变；关闭注册表排空已经等待旧编辑的重新打开；新增静态回归源码。需后续新CI产物覆盖此Dart补充，3033b1f的run42986704180不能当作最终版本。

首轮CI run42986704180：Windows Release/桥接/Clippy/Analyze/原生启动几何成功，Rust133过、Flutter179过2失败。路径退出焦点交接已静态修正；下载关闭夹具改为明确等待实际downloadStarted。最终新CI待补录，不把首轮产物作为完成版本。
