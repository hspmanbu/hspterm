# 应用命令面板

最新静态批次已接命令面板加密快捷键设置与ApplicationKeyScope本地按键所有权。其Rust仓库100项/Bridge33项及Analyze有通过记录，但新Scope Fake测试尚未结束，真实Kitty GTK夹具未运行；后续新增字体接口尚未重新生成桥接，必须在统一收尾正规生成/编译后验证。下文的“仍未实现”及252项均是0e96be4稳定节点快照，不代表当前未提交/源码检查点已经通过。Android暂缓。

正式工作台和独立Mock共用`prototype/command_palette.dart`。通过顶栏应用菜单打开，输入中文或大小写不敏感文本筛选；上下键选择（到端点循环），Enter/小键盘Enter调用，Esc关闭。长列表按需构建，键盘选中项滚入视口，适配小窗口/缩放；危险操作继续使用原来的粘贴、导出、未保存表单等确认。

当前可列出已有可用的主机管理、设置/字体、新终端入口、SFTP侧栏、任务队列、单会话导航、编辑草稿恢复、终端搜索/选择复制/粘贴/历史导出和字号操作。新终端入口沿用选择已保存主机流程，不创建无配置连接；导航不批量关闭/重连其他会话。没有选择文本则隐藏复制；无可用终端视图不展示其终端动作。输入的筛选文字不是远端命令，不交给SSH或历史仓库。

## 身份与生命周期

- 工作台在**打开面板时**构造操作提案，捕获原终端视图/Controller代次，避免在build时提前捕获尚未挂载的视图。切焦点、视图更换、关闭或重连后原终端操作失效，不悄悄改向新的终端；选择返回后再次校验。
- 订阅原Model和有可用性状态的Controller；只有可见动作ID/标签真正变化才重建，反复收到相同高频输出通知不请求面板重绘。关闭时释放监听。
- 面板打开去重；选择/关闭只消费一次，路由已经退出时迟到点击不再弹出后方页面。异步应用操作沿原入口执行，错误回工作台；已销毁页面不再更新界面。
- IME composing期间的上下/Enter/Esc返回平台IME并停止其他Flutter快捷键继续处理，避免候选键执行应用操作或关闭后方页面。此行为有合成TextInput测试，不能替代Windows/Android真实IME测试。
- 最多保留8条本次运行的最近**应用操作ID**，不持久化筛选文字、主机标签、终端内容或远端命令。ID为程序常量/不透明会话ID；空筛选优先最近项，已不可执行的动作不显示。关闭应用清除这份运行期导航记录，不进入云端/配置备份。

## 测试与边界

```sh
cd ui_flutter
flutter analyze
flutter test test/command_palette_test.dart test/prototype test/widget_test.dart test/history_controls_test.dart test/host_ordering_test.dart --reporter expanded
python3 benchmark/external_editor_gtk.py flutter test integration_test/command_palette_test.dart -d linux --reporter expanded
```

组件覆盖最近ID/无原文保存、中文搜索、上下/Enter/Esc、IME、状态失效、100次无变化通知不调度新帧、长列表选中项滚动、缩放布局、路由退出迟到点击及实际应用入口。GTK使用私有OpenSSH真实连接，验证原终端动作、最近操作、切到另一个真实会话后旧动作撤销、原Transport和代次保持且仍可输入。截图仅合成终端横幅，详PROGRESS与`validation/phase3b/command-palette-*.png`。

**仍未实现**持久化自定义唤出快捷键、完整用户键位冲突配置和Android独立顶部/长按入口。现有Ctrl+Shift+P只在原有应用快捷键路由允许时生效；TerminalView键盘协议与TUI优先级本批未改，不宣称组合键在真实终端焦点下一律被应用拦截。字体持久设置与Android正式界面也没有因该面板自动完成。具体运行结果、构建和失败修正见PROGRESS。

本批最终Analyze无问题，相关54项19秒、专项7项3秒、真实双SSH GTK1项16秒通过；随后**完整Flutter252项6:13全部通过**，包括既有Codex隔离provider/真实SSH/SFTP/传输编辑及输入协议回归。正式debug/release均已恢复`workbench_main`并实际启动/缩放/正常关闭。中途debug打印Built后管道143退出，没有把它当完整通过；确认文件状态后从独立启动续跑成功，详历史PROGRESS与日志。Windows/Android实机和自定义快捷键仍待做。


- 正式设置点击路径静态补正：快捷键页不再展示仅弹“编辑原型”通知的假编辑按钮，也不将未接入的Ctrl+Shift+F/D/M列为现有组合键。Mock入口保留原型；正式页保留已接真实加密自定义命令面板设置及实际终端复制/粘贴/历史浏览、新建入口的只读说明，搜索/分屏/最大化沿现有菜单/面板。未改变真实键盘路由或远端协议。仅Dart格式解析/diff，交互回归留统一阶段。
