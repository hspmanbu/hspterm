# 第17轮反馈：源码与静态复核（2026-11-12）

分支：`fix/round7-windows-feedback`。执行方式按用户最新要求：Ubuntu只修改源码、生成绑定和静态检查；Windows CI负责构建/测试；dispatch后记录链接，不监视。第三阶段专项优化及Android继续暂停。

## 代码与复核范围

1. **终端背景黑线**：单元格实色边界关闭抗锯齿，避免分行Picture在分数DPI边缘与底色混合；不改变终端刷新率/协议。新增125%/150%/175%/200%像素边界回归源码。
2. **多行编辑**：采用外部主题正文的字体，背景为主题surface轻微提亮；选区颜色在背景上预混合为不透明色，重叠矩形不再叠加透明度。保留实际RenderEditable行号定位、唯一滚动条及全局坐标调高。
3. **打开/定位本地文件**：统一规范化Windows盘符/UNC路径，URI只作为Dart边界表示。原生ShellExecuteExW接收文件系统路径，不再把file:///D://…传给系统；Explorer以明确父目录PIDL和一个子项调用选中API，失败明确报错，不把“仅打开父目录”冒充已定位。普通下载和本地编辑共用打开逻辑。新增双斜线、中文/空格/#/%、UNC及Windows原生通道参数回归。
4. **图片任务与命名**：分类可折叠，折叠不停止/清除上传；条目显示实际文件名。直接在服务器安全/tmp中排他创建clipboard001.png起的编号PNG，不建每张图片子目录；已占用名称（包括符号链接）跳过，不覆盖/删除。最多探测4096个名称；文件0600、PNG/64MiB上限、原SSH身份/代次、ACK进度/取消/失败清理仍保留。原OpenSSH测试改为验证两个独立编号、原文件不被覆盖、权限和字节一致。
5. **统一粘贴**：去掉终端独立“粘贴图片”菜单；普通粘贴、快捷键和右键粘贴先取非空文本，没有文本才走既有PNG上传流程；文本多行确认保持原样。已有可配置图片快捷键保留，说明同步更新。
6. **tmux Alt点击**：Alt用于临时绕过本地拖选时，只从该次远端鼠标手势中去掉Alt位；按下/移动/抬起使用同一组修饰键，释放Alt后抬起也不串协议。普通SSH、非覆盖情形及其他修饰位保持。
7. **链接**：参考[xterm.js WebLinkProvider](https://github.com/xtermjs/xterm.js/blob/master/addons/addon-web-links/src/WebLinkProvider.ts)，只沿软换行扩展当前token，遇空白停止，保留16行/4096单元格/16384 UTF-16预算。兼容宽字符占位前的WRAPLINE；不猜测硬换行或光标定位的TUI行。对“APK: /绝对路径”形式的无效OSC8标注，仅在点击的可见token与其路径一致时识别真实路径；危险scheme、不一致label、越界/缺失target仍拒绝，不扫描远端文件。
8. **tmux远端历史条**：新增唯一FRB接口`terminal_tmux_history`，共用原SSH Inspector有界通道；仅可见且已附着tmux的终端每秒串行查询少量元数据，不取历史正文，不自动连接/授予进程权限。使用真实history_size/history_limit及scroll_position；拖动请求合并，原始server PID/session创建时间和pane ID经tmux命令队列条件保护。导航只用copy-mode命令，不注入PTY；返回底部退出copy-mode；只读不可导航；其他pane模式不抢占。断线/重连/关闭/隐藏会停止本机采样并丢弃过期响应。依赖远端Python3与tmux，不依赖新版本pane-scrollbars选项。应用自管且未进入tmux缓冲的历史不会伪装为可拖动历史。

## 本轮已执行的静态工作

- Flutter Analyze：零问题（最终结果另见PROGRESS）。
- 18个改动Dart文件格式检查、Rust workspace格式检查、git diff --check。
- FRB 2.13正式生成新增绑定；API词法契约266函数/82 DTO/338 Dart文件零发现；261个public Result错误边界齐全，静态错误白名单已更新。
- 两个新增Python文件AST语法检查；C++人工复核Unicode路径、Shell API参数、PIDL生存期及错误传播。
- 离线pub get仅将既有path 1.9.1从传递依赖升级为直接声明，无依赖版本升级。
- **没有在Ubuntu执行本轮应用构建、Rust/Flutter/Python运行测试、真实SSH或真实TUI验收。** FRB生成所需宏展开不能算应用编译/运行通过。

## 提交与CI

- 主源码：`4814dd5`；最终清理守卫：`c141ddc`，均已推送当前分支。
- Windows x64 Release CI：https://github.com/hspmanbu/hspterm/actions/runs/43145153511 。dispatch HTTP204；一次查询确认head_sha为c141ddc。之后不再监视或等待结果，本轮未确认构建成功/产物可下载。
- Flutter Analyze最终零问题；Rust/Dart格式、diff检查、266 API词法契约与261公共Result错误边界静态检查全部通过。新增运行测试均交由CI，没有本机执行。

## CI与后续实机

Windows workflow新增路径/像素/链接/tmux历史组件及Python协议防护用例；保留原FRB一致性、严格Clippy、Rust库测试、Analyze、既有组件、正式Release和原生窗口检查。CI链接在PROGRESS记录；本轮不等待结果。

Windows11请依次复测：

- Codex背景块在125/150/175/200%缩放是否无黑缝；多行预览的字体、底色、空行与有字位置选区是否一致。
- 普通下载和本地编辑：“打开文件”是否按关联程序打开；“打开所在文件夹”是否选中同一个实际文件；包含中文/空格/#的路径也验证。
- 图片组折叠/展开仍持续上传；普通Ctrl+V/右键粘贴分别测试文字、PNG截图、多行文本；确认编号PNG位于/tmp且只填路径、不执行。
- tmux中Codex顶部上条输入和编辑区Alt点击能否响应；正常SSH的鼠标与链接操作回归。
- tmux中agy resume历史输出后，右侧原生Flutter条是否出现、可拖到顶部/底部；人为减小tmux history-limit后范围不越界；Ctrl+B [后滚轮位置反映到滑块；隐藏标签/重连不跳到其他会话。
- 无Python3/只读/空历史/其他tmux模式时允许禁用远端历史拖动；终端普通输入不能受影响。Codex自管历史需其自身滚动，不承诺全部变成tmux历史。

已有遗留：tmux中新建可信Shell集成窗口/历史联想未实现；此前覆盖下载“待处理”是否彻底解决仍待用户实测，不能因本轮没有再反馈就记为已验收。
