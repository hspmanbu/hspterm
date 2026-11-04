# Phase 3A 终端标签/分屏结构

依据用户本次明确修订及V1.4 §3.1/§5.1，取代此前DemoWorkspace下Pane树。基础布局模型同时服务独立Mock与真实工作台；下方早期原型说明保留，真实资源所有权见新增章节。

- `WorkbenchModel._sessions`持有`TerminalSession`稳定对象：ID、模拟连接状态/代次、主机、输入草稿/回显及SFTP目录历史/缓存。正式后端应把Transport/PTY/终端控制器绑定此ID，而不是Flutter节点。
- `TerminalTab`持有唯一sessionId、名称及固定状态；`TabGroup`持有有序tabs和selectedId；`GroupLeaf`只持有groupId，`GroupSplit`只持有方向/比例/子树。
- 每次openHost新建一会话及一标签，加入焦点组。不恢复上次进程状态。新建入口是页面状态，不生成空会话占位标签。
- moveTab先验证目标，移走已有标签，删除空组并收缩树，再插入目标组或在目标组旁创建布局组；不修改会话注册表、不连接/断开、不创建第二输入视图。同组单标签边缘分屏不做操作。
- mergeGroups保持全部会话及当前选中，将所有标签合并（固定标签前置）；closeTab仅删除指定标签及会话。setDisconnected保留对象；只有显式模拟重连才增加connectionGeneration。生产资源释放待Phase3B接入原有ManagedSession生命周期，不把widget.dispose当作会话关闭。
- maximizedGroupId为独立显示覆盖，原树/比例不变；小窗折叠同理。每个可见组只挂载其selected终端组件，未显示会话状态仍由注册表持有。原型回显/草稿可在组件重建后恢复；真实PTY输出仍由Phase2核心处理，本轮未改。
- 单组时唯一标签栏在一体化顶栏；多组时每个区域显示自己的标签栏，顶栏仅显示导航/布局状态。标签拖动载荷`TerminalTabDrag`与SFTP `RemoteDrag`类型隔离；边缘移动是分屏，中央/标签栏移动是合并或排序。标签组溢出菜单及全局只读导航可访问不可见标签。
- focus = focusedGroup.selectedTab.sessionId；SFTP/当前任务按此ID关联。侧栏开关/宽度、队列高度均属于WorkbenchModel，不由终端选择重置。

验收入口：`test/prototype/terminal_layout_test.dart`覆盖三个标签、四向移动、空组收缩、一次归属、草稿/SFTP状态、区别关闭/断开/重连、最大化/恢复、500次确定性混合操作及真实鼠标拖动；`workbench_test.dart`保留其他区域回归，`integration_test/prototype_test.dart`在真实GTK窗口操作并生成截图。Phase2源码和SSH/Codex测试入口保留。

## 真实工作台资源所有权

- `workbench/model.dart` 的 `LiveTerminalSession` 拥有单独 `TerminalController`、原生 ManagedSession ID 和输入视图 GlobalKey；TabGroup/SplitTree 无 SSH 资源所有权。工厂创建时只有正式保存主机可连接，其他页面不自动联网。
- `LiveTerminalSurface` 复用 Phase2 TerminalView/Painter；挂载/卸载只领取/释放可见性租约，不销毁控制器。租约可防止重挂载时旧节点 dispose 错误隐藏新节点；不可见控制器继续消费网络事件，免取帧。
- 移动/排序/分屏/合并/最大化保持会话对象、原生 ID 和连接代次；关闭标签才释放该会话。显式断开保留原生状态，手动重连重建 PTY 并增加代次。退出等待所有创建中/关闭中任务与控制器关闭。
- 关联 SFTP 由原生 Entry 按 SSH 代次缓存；协商在 Transport 作用域独立任务中完成，不占住排空 PTY 的 actor。断开取消协商；重连成功按该会话配置恢复 SFTP。目录响应核对会话和代次，拒绝过期数据；16目录LRU，无后台轮询。
- `test/live_workbench_test.dart` 使用真实 FRB/SQLite/OpenSSH 验证三会话独立、隐藏输出、布局身份、加密草稿迁移、SFTP 内容、符号链接安全删除、手动重连和逐会话释放。原Mock/Phase2验收入口与测试保留。

- 真实会话独立持有非秘密主机目标快照；编辑正式主机不改变正在连接的服务器描述。显式重连前刷新为最新正式目标，TOFU回调使用该次实际目标；不同会话彼此不改写。重连成功后清除旧代次目录缓存，文件选区/重命名按代次失效，防止旧服务器内容留在新目标中。后续任务恢复必须另校验服务器身份，不以主机ID代替实际目标。
