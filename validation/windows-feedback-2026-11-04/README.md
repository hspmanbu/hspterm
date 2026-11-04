> 清理说明（2026-11-04）：按用户要求移除本机截图和构建产物，文字/JSON结果保留。截图可从 Git 历史版本查询或用现有测试重新生成。

# Windows 使用反馈：七项修正

用户确认上一版 Windows 启动内存约 70–80 MB；该数值为用户观测，不与 Ubuntu 图形栈 RSS 混算。本次保留延迟字体目录和虚拟列表优化。

| 反馈 | 实际处理 |
| --- | --- |
| 每次看似要求设置主密码 | 启动只检查固定配置库是否存在；已有库显示解锁和一个密码框，首次创建才显示确认密码。不重建配置库，不取消加密；原 Windows DPAPI 显式便捷解锁入口保留。 |
| 控制键有效，字母/中文无效 | 终端自定义 `TextInputConfiguration` 补上实际 Flutter View 的 `viewId`。固定版本 Windows 引擎 `text_input_plugin.cc` 的 setClient 在缺少整数 viewId 时直接返回，尚未创建文字/IME模型；这解释了控制键/粘贴可用但文字无效。没有采用延时重复发送字符等绕行。 |
| SFTP 路径发送安全复制提示 | 保留可信输入保护，提示精简并提供“发送说明”，可以直达原关联主机的终端配置；主动启用可选 Bash 集成、保存并手动重连后才能在可信普通 Shell 中直接填入。不自动启用或重连，不向 TUI 盲送路径。 |
| 设置统一提交 | 常驻“取消 / 应用 / 确定”；分类按需创建，切分类保留草稿/滚动位置，不提示未保存；只在离开整页时提示。应用所有已编辑分类，失败定位对应分类；已确认保存不重复提交，丢失回执/失去源快照不能假装成功。取消只丢弃未应用草稿。 |
| 设置布局 | 内容宽度/条目留白/辅助文本换行调整，开关改为较小桌面形状、整行仍可点击。缩短技术说明，修复加密页各独立面板间距及过时的“同步未接入”文案；必要安全说明保留。 |
| SFTP 大小 | 以 KB/MB/GB 显示；极小非空文件不显示假零值。排序、属性元数据和传输仍使用原 byteSize；目录不冒充已统计的总大小。 |
| 悬停 Alt 拖出说明 | 去除文件行的常驻 Tooltip；原 Alt 拖至 Explorer 功能保留。 |

设置修订已写 V1.4 末尾。公共提交只保存回调/布尔状态，不复制秘密或草稿正文；字体和终端偏好共用的 portable 记录只在确认本页相关值未变时重新获取 CAS，不放松跨库/真实外部修改保护。各独立仓库按顺序确认，并不伪称跨全部配置的一笔原子事务。

## 实际验证

- 17 文件 103 项 Flutter 组件回归通过，1 分 01 秒。包括跨分类草稿/应用/取消/确定、失败/回执丢失、当前 View ID、原键盘/IME组合输入、字体目录、主机覆盖、SFTP大小及路径操作保护。
- 7 个不同 GTK 集成用例通过：新增配置库识别/跨分类真实加密提交/回读，原真实 OpenSSH 字体+PTY、终端偏好、历史、显示规则、SSH默认值、Kitty快捷键。重复运行同一用例没有重复计数。最终布局补验结果见 PROGRESS/checks.json。
- 新设置用例覆盖全部九个分类，真实窗口 1280×720 与 760×620。18 张 PNG 使用本机临时合成 Vault，无用户主机、凭据或云账号。已查看外观、终端、紧凑SFTP及加密页，截图为实际 Flutter 运行结果。
- Analyze 0 项、Dart 格式检查、actionlint 通过；正式 debug/release 入口恢复为 workbench_main.dart，启动/正常退出及预览租约清理结果见 JSON。
- 早期按旧分类警告/保存按钮编写的测试失败、主题基线夹具错误和模态“取消”与新常驻按钮重名均已修正。没有跳过生产错误、删除安全确认或重写真实终端状态以通过测试。

主要截图：[外观](https://github.com/hspmanbu/hspterm/blob/17d04096c446c82c79bfad098a4135086b0e2b98/validation/windows-feedback-2026-11-04/appearance.png)、[终端](https://github.com/hspmanbu/hspterm/blob/17d04096c446c82c79bfad098a4135086b0e2b98/validation/windows-feedback-2026-11-04/terminal-input.png)、[SFTP](https://github.com/hspmanbu/hspterm/blob/17d04096c446c82c79bfad098a4135086b0e2b98/validation/windows-feedback-2026-11-04/sftp-transfers.png)、[加密与同步](https://github.com/hspmanbu/hspterm/blob/17d04096c446c82c79bfad098a4135086b0e2b98/validation/windows-feedback-2026-11-04/security-sync.png)；各图 `compact-` 前缀对应较小实际窗口。

复现（ui_flutter 目录）：

```sh
flutter test --no-pub test/settings_leave_guard_test.dart test/widget_test.dart test/typography_settings_test.dart test/directory_reader_test.dart test/terminal_paths_send_test.dart
python3 benchmark/external_editor_gtk.py flutter test --no-pub -d linux integration_test/settings_feedback_test.dart --reporter expanded
flutter analyze --no-pub
# GTK 集成之后恢复正式入口
flutter build linux --debug --no-pub -t lib/workbench_main.dart
flutter build linux --release --no-pub -t lib/workbench_main.dart
```

## Windows 复测

新 CI 将执行原生构建/分析、扩大后的相关组件测试（含 View ID 和 IME逻辑）、启动与正常关闭。Windows11真实文字、中文输入法、TUI键位仍须新版实际运行确认，不能用 Ubuntu 结果冒充。

1. 使用新构建完整解压包。已有主机继续保留，重开仅解锁原库，不输入第二次确认密码。
2. 点击终端后分别输入英文、中文组合输入，按 Enter/Tab/方向/Esc/Ctrl，检查一次提交、不重复或丢字。
3. 依次修改字号、终端设置、SFTP默认值；跨分类再返回应保留草稿，“应用”后重开核对，“取消”不保存新草稿，“确定”保存后离开。保存失败不得关闭或冒充成功。
4. 从路径发送说明直达原主机“终端”，显式启用可选 Bash 集成，保存并手动重连；普通 Shell 路径仅填入、不执行；Vim/密码提示等仍只复制。
5. 检查各分类在窄窗口/高DPI下的间距、滚动和常驻按钮；文件大小单位正确，普通悬停不再反复提示 Alt 拖出。

新构建链接/提交状态见 PROGRESS 最新节。
