> 历史原型验收记录：本文件中的阶段暂停/等待视觉确认条款已被最新连续开发指令取代。原型测试证据继续有效，但Mock不计为真实功能。

# Phase 3A Windows 工作台 UI 原型 · 视觉验收

本阶段提供可运行、可交互的 Flutter 桌面原型。所有主机、会话、远端文件、传输及设置为明确标识的模拟数据，只在当前进程内存中变化。不发起 SSH/SFTP/DNS/云端请求，不读写真实主机配置或文件。真实 Phase2 终端及测试能力仍在独立入口保留。

**Phase3A 终端标签/分屏已按用户反馈修订；本次布局等待用户重新视觉验收。** 当前停止增加功能，用户确认并明确授权前不进入 Phase3B。最新恢复状态见 PROGRESS.md。

## 运行

Ubuntu 已有本项目 Flutter/Rust/GTK 工具链。从项目目录：

```sh
cd /opt/hspterm/ui_flutter
/opt/flutter/bin/flutter run -d linux -t lib/prototype_main.dart
```

无图形桌面的自动化环境使用 Xvfb/D-Bus；原型构建及独立启动：

```sh
flutter build linux --debug -t lib/prototype_main.dart
flutter build linux --release -t lib/prototype_main.dart
xvfb-run -a dbus-run-session -- build/linux/x64/release/bundle/hspterm
```

有 Ubuntu 图形桌面时直接运行完整 bundle 中的 `hspterm`，不要单独复制可执行文件。当前 debug/release 构建入口是 prototype_main.dart；切换真实 SSH 测试程序时显式指定：

```sh
flutter run -d linux -t lib/main.dart
```

Windows 后续可使用 `flutter run -d windows -t lib/prototype_main.dart`；本轮没有 Windows 构建或运行验证。Flutter内容内的一体化栏是视觉原型，Windows runner 仍保留系统窗口装饰；Win32标题栏命中测试、拖动/双击/Snap/系统菜单/原生关闭等待尚待 Windows 集成和实测。当前只实现可选 GTK 原型窗口通道，不把 Ubuntu 结果当作 Windows 通过。

## 页面和已实现的原型交互

| 区域 | 可以实际操作 |
| --- | --- |
| 首页 | 每次新启动空白；选择保存的模拟主机，双击卡片或选择后Enter打开；收藏/最近卡片双列/单列；新建主机、主机管理、显式打开示例工作台 |
| 终端标签 | 一个标签一个独立模拟SSH会话；新连接默认加入焦点标签组，点击只显示对应会话。单组标签栏与顶栏一体化；多组在所属区域显示，不重复。拖动排序、重命名/固定/关闭、连接状态、横向滚动/溢出导航，选中标签自动显露；全局会话列表仅导航 |
| 终端区域 | 拖动已有标签到区域四边分屏、到中央或标签栏跨组移动；右键标签/标签组菜单四向分屏，组内切换、分隔线调比例、空组自动收缩、取消分屏合并全部标签。临时最大化区域/恢复、小窗折叠/恢复保留原树及比例；操作不新建或复制会话。关闭、断开保留标签、一次性手动模拟重连分别处理 |
| SFTP | 侧栏宽度、收起图标栏、恢复、临时最大化；当前焦点决定关联内容，切焦点不改侧栏宽度/开关；可编辑绝对路径、后退/上级、目录双击、筛选/排序/隐藏/紧凑视图、列宽拖动及横向滚动 |
| 文件操作 | Ctrl/Shift多选、F2主文件名选中/Enter确认/Esc取消、字段错误、Delete确认（默认取消）；右键图标栏和文字菜单、合成文件预览；仅Mock文件拖到目录时目标高亮/延迟进入/模拟移动，不绘制额外拖拽预览；不提供Ctrl+C/X/V文件操作 |
| 队列 | 文件/文件夹一个顶层任务；双行条目、活动/等待/暂停/失败/部分完成/成功/取消；状态数量，无总体进度条；当前/全部任务、完成默认折叠、单个内联详情、当前文件/失败列表、重试、Ctrl/Shift多选和批量暂停/继续/取消；高度拖动与侧栏内最大化 |
| 主机管理 | 独立页，分组/收藏/搜索/列表宽度；基础新建与高级分类；单选编辑、双击打开独立模拟终端标签；显式保存、字段校验/聚焦、草稿保存/丢弃/取消；复制风险提示、批量非敏感字段编辑和影响预览、批量删除确认 |
| 设置 | 外观、终端/输入、快捷键、SSH、SFTP/传输、历史命令、彩色高亮、加密/同步；实际切换深浅主题，开关/下拉框/规则示例/确认框可操作，其余参数仅原型内存演示 |
| 窗口 | GTK最小尺寸提示720×540、拖动/最小化/最大化调用；活动模拟会话/任务退出确认，取消保留状态。系统关闭请求和内容内关闭按钮共用确认。Windows原生接入尚未实现/验收 |

侧栏队列的最大化只占左侧内部，不侵占终端；SFTP临时最大化则展示完整文件区域，恢复后保留模型和布局。截图中的卡片“连接”、传输进度、暂停/成功等均是模拟状态，不能用于判断真实网络、文件传输或吞吐能力。

设置的非主题参数不改变 Phase2 终端配置；部分高级主机控件仅演示选择，未接入正式配置序列化。草稿没有加密自动保存/异常恢复；正式版需求仍保留，不能将本轮内存原型视为实现。

## 与终端核心的隔离

`ui_flutter/lib/prototype/terminal_preview.dart` 直接使用现有 `TerminalPainter`、缓存及 RenderFrame 数据类绘制合成字符网格。没有启动 NativeTerminalBackend、没有加载 FRB 或解析远端协议。底部输入框仅回显为 `[local preview]`，不执行命令。它不是新增本地Shell，也不代替真实终端键盘/IME/Unicode协议测试。

路径菜单只将模拟路径插入其关联模拟终端草稿或复制明确选择的模拟文本；默认无回车、无上传下载。断线拒绝模拟插入。完整十项路径联动、安全输入状态判定、OSC7/133、Explorer↔SFTP系统拖放仍是正式业务待办。原型内部的Mock拖放不代表Windows Explorer系统拖放已完成。

## PNG 截图

自动化测试实际在 Ubuntu Flutter GTK 进程中生成；截取Flutter视图，不包含操作系统外部装饰。全部内容为合成数据。

入口：[截图清单](validation/phase3a/screenshots/manifest.json)。常规1440×900，紧凑720×540。

| 截图 | 页面 |
| --- | --- |
| [01-start-dark.png](validation/phase3a/screenshots/01-start-dark.png) | 空白启动/快速连接 |
| [02-workbench-dark.png](validation/phase3a/screenshots/02-workbench-dark.png) | 深色A/C同组、B在右侧分屏，SFTP跟随A |
| [03-transfer-details.png](validation/phase3a/screenshots/03-transfer-details.png) | 队列内部最大化、文件夹详情与失败项 |
| [04-file-context-menu.png](validation/phase3a/screenshots/04-file-context-menu.png) | 文件右键图标栏和路径菜单 |
| [05-inline-rename.png](validation/phase3a/screenshots/05-inline-rename.png) | 原位重命名 |
| [06-delete-confirmation.png](validation/phase3a/screenshots/06-delete-confirmation.png) | 文件删除确认 |
| [07-host-manager.png](validation/phase3a/screenshots/07-host-manager.png) | 主机列表与配置 |
| [08-host-validation.png](validation/phase3a/screenshots/08-host-validation.png) | 新建主机校验错误 |
| [09-settings-dark.png](validation/phase3a/screenshots/09-settings-dark.png) | 深色设置 |
| [10-history-settings.png](validation/phase3a/screenshots/10-history-settings.png) | 历史命令开关与敏感信息说明 |
| [11-settings-light.png](validation/phase3a/screenshots/11-settings-light.png) | 浅色设置 |
| [12-workbench-light.png](validation/phase3a/screenshots/12-workbench-light.png) | 浅色工作台 |
| [13-workbench-compact.png](validation/phase3a/screenshots/13-workbench-compact.png) | 小窗折叠/滚动 |
| [14-sftp-maximized.png](validation/phase3a/screenshots/14-sftp-maximized.png) | SFTP完整详细列 |
| [15-exit-confirmation.png](validation/phase3a/screenshots/15-exit-confirmation.png) | 活动任务退出确认 |
| [16-terminal-tabs-normal.png](validation/phase3a/screenshots/16-terminal-tabs-normal.png) | 三个独立标签，普通模式仅显示选中终端 |
| [17-terminal-group-maximized.png](validation/phase3a/screenshots/17-terminal-group-maximized.png) | 临时最大化标签组，仍可在组内切换 |
| [18-split-group-tabs.png](validation/phase3a/screenshots/18-split-group-tabs.png) | 跨组移动后左A、右B/C，选中B |
| [19-tabs-recombined.png](validation/phase3a/screenshots/19-tabs-recombined.png) | 菜单取消分屏，三个标签回到一组，会话身份不变 |
| [20-tab-drop-target.png](validation/phase3a/screenshots/20-tab-drop-target.png) | 实际拖动中的目标高亮，与SFTP文件载荷隔离 |

## 验证与复现

自动检查不替代用户的视觉确认。尚未建立用户批准的golden图片基线；本轮执行实际截图生成、PNG格式/尺寸校验、布局断言及截图查看，不声称视觉基线已由用户批准。汇总见[测试记录](validation/phase3a/test-summary.json)。此前的阶段验收证据见PHASE2_VALIDATION.md，本轮对原入口另外复验。

```sh
# ui_flutter目录
flutter analyze
flutter test --reporter expanded
xvfb-run -a dbus-run-session -- flutter test integration_test/prototype_test.dart -d linux \
  --dart-define=HSPTERM_SCREENSHOTS=/opt/hspterm/validation/phase3a/screenshots --reporter expanded
xvfb-run -a dbus-run-session -- flutter test integration_test/ssh_terminal_test.dart -d linux --reporter expanded
xvfb-run -a dbus-run-session -- flutter test integration_test/codex_terminal_test.dart -d linux --reporter expanded
# 重建独立原型入口（GUI测试会覆盖debug bundle的临时入口）
flutter build linux --debug -t lib/prototype_main.dart
flutter build linux --release -t lib/prototype_main.dart
xvfb-run -a dbus-run-session -- python3 benchmark/prototype_smoke.py build/linux/x64/release/bundle/hspterm
```

本次实际结果：Flutter33项（原12+原型21）、Rust Workspace42项、analyze及格式检查通过；GTK原型、原SSH及真实Codex GUI各1项通过。标签测试包括500次混合操作、24标签溢出导航、真实鼠标跨组拖动、焦点/SFTP/草稿及身份保持。原SSH GUI20次生命周期RSS样本差值-1,044,480字节；不是长期泄漏结论。

debug/release已重新构建为prototype_main.dart并独立启动/正常关闭退出0，均不加载Rust库或生成终端历史。首页空闲5秒CPU均0.0%，RSS约421.1/266.0MiB；原始字节值及1160a7a旧样本保存在test-summary。短样本不作为性能提升或长期资源承诺。

本次验证结果和原始样本以[测试记录](validation/phase3a/test-summary.json)为准。终端标签的模型及生命周期约束见[TERMINAL_LAYOUT.md](TERMINAL_LAYOUT.md)，取代旧工作区容器结构。普通预览仍是合成帧，不宣称已接入真实多会话SSH后端。

已发现并修复：分屏不再新建会话；标签栏外层双击手势不再延迟单击；移动后选中标签自动滚入可见区域。原Rust空闲测试曾两次在命令标记后立即快照时失败，后续Shell输出与断言竞态；仅测试夹具增加有界静止等待，保留未变化快照及无空闲通知断言，不改生产终端核心。

## 人工视觉检查建议与待确认边界

1. 启动空白，点击“打开示例工作台”：三个独立标签、默认只显示一个终端。或逐次用“+”选择主机，每次只增加一个标签；在标签之间切换检查输入草稿和关联主机。
2. 将API标签拖到终端右边缘（或右键“四向分屏”），检查Web/数据库留在原组，API单独在右组。把数据库拖到右组中央，在B/C间切换；右键重命名、固定、断开/手动重连、关闭取消及确认，各动作应独立。
3. 拖分隔线、临时最大化/恢复、缩小到720×540再放大；用全局会话导航定位隐藏组。将某组最后一个标签移到另一组，空组应消失；或菜单“取消分屏”合并，全部会话身份/草稿保留。
4. 收起SFTP后切换焦点，展开确认关联主机/目录变化，侧栏宽度和开关保留；拖列宽、横向滚动。只在原型内部拖动模拟文件，观察目标高亮；悬停约750ms进入目录。
5. 文件Ctrl/Shift多选、F2改名、Esc取消、Delete取消；展开右键图标栏、目录切换、SFTP最大化与恢复。
6. 队列内部最大化，展开文件夹、暂停/继续、右键切换模拟成功/失败/部分完成、多选批量取消；确认没有整体进度条或系统通知。
7. 主机编辑未保存时切换/离开/批量操作，测试保存/丢弃/取消和校验；浏览设置、切换浅色，再回工作台。
8. 关闭有模拟会话的窗口，取消退出；重新启动应为空白，不恢复上次布局或模拟会话。

已知原型限制：最低验证逻辑尺寸720×540；DPR为测试模拟，不能替代真实显示器DPI/系统缩放。队列最大化或焦点/页面切换造成文件列表重新挂载时，局部选区/列宽/筛选等可重置；会话注册表、标签/分屏树、侧栏宽度和队列高度保留。高级主机字段、规则等尚未接入完整序列化/持久化；这些限制不取消正式版状态保持和存储需求。

待后续正式业务：真实多会话/主机库与高级配置、SFTP请求和编辑/任务/续传、凭据与草稿持久化、云同步/备份、全部路径联动与终端增强。Windows原生标题栏/Snap/DPI/IME/Explorer拖放与Android仍未实测。Linux/Xvfb缺少完整窗口管理器，通道调用成功不能证明Windows窗口行为。

Phase3A交付后暂停：用户需要确认信息密度、色彩/字号、标题栏/标签、侧栏宽度、队列和分屏布局，再明确授权 Phase3B；本报告不构成该授权。

本次仅修订终端标签与分屏；SFTP/队列/主机/设置沿用已验收界面，只有关联会话类型及必要术语变化。进入Phase3B前须由用户再次确认本次截图与实际布局。
