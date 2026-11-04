# 终端默认设置与安全粘贴（静态源码，待统一验证）

正式设置 → 终端与输入接入真实Rust仓库，替换该分类的Mock控件；独立原型仍使用模拟交互。保存前需载入原配置、参数校验和明确确认，默认值不能覆盖读取失败/未知版本。当前支持：

- 新建终端滚动历史上限0–1000000行。默认Windows100000、无记录时其他入口可提供自身平台默认；既有RAM+临时磁盘分页不变，修改设置不裁剪正在运行的终端，下一次新建终端生效。
- 默认块状/下划线/竖线、闪烁及光标RGB；DECSCUSR仍优先，远端重置或新PTY后使用本机默认。
- 默认前景、背景及ANSI16色，深/浅配色预设与6位RGB编辑。远端OSC动态颜色优先，OSC重置回到本机默认；TrueColor及真实字符属性不改。OSC颜色查询、渲染帧使用同一默认调色板。无主题包导入/导出。
- OSC52总开关，默认允许读写，既有10MiB安全上限保留。关闭同步更新核心/Bridge门控并清理待回复票据，可选渲染元数据同步Flutter状态。
- 右键菜单或粘贴；远端鼠标捕获优先，Shift+右键强制本地菜单；粘贴继续走原安全预览及bracketed-paste通路，不提供关闭多行安全确认的开关。

## 分层和生命周期

`term-core::preferences`定义有界默认值和验证类型；Terminal::apply_preferences只接预验证值，更新默认config并保留远端覆盖及原网格。`storage-sync::terminal_preferences`用 `config-terminal-preferences-v1` 加密存储，原Vault scope/修订/行CAS。不存SSH数据、输入、剪贴板或字体正文，允许将来配置同步。

新增 `create_configured_terminal` 供NativeBackend创建时载入默认值；原 `create_terminal(history_lines)` 的显式参数语义保留，不能用用户设置覆盖协议夹具。保存ACK后按原Vault运行绑定发布，不重建Transport/PTY或截断活动历史；切到别的配置库不会修改旧库绑定会话。配置恢复在候选阶段先验证，提交后迁移本批原scope绑定并发布；已建立会话保留。

读取/保存纳入Model退出等待。UI确认版本冻结，远端默认更新由Rust发布，隐藏终端仍不额外绘制。渲染的OSC52/right-click元数据不属于远端内容。新增3个API、两个可选RenderFrame字段须统一正规生成FRB后才能编译，不能加载旧SO。

## 粘贴安全修正

剪贴板异步读取前捕获Controller/nativeID/连接代次，读取后及确认后再次核对；换会话、重连、关闭后拒绝迟到文本。确认预览由路由自身持有TextEditingController，直到退出动画卸载才释放；IME候选未提交时不确认。编辑更新行数/UTF-8字节数，只发送用户确认版本；取消不发送，不落盘/日志。非括号粘贴多行确认和已有长文本风险规则不变。

## 统一验证清单（尚未运行）

- Rust core3项：远端光标/颜色覆盖及重置、新代次保持默认；原网格/TrueColor不变及无效更新原子拒绝；协议颜色查询一致。
- Rust storage2项：加密往返、旧scope/修订、未知版本；SQL失败无ACK且原记录保持。
- Flutter4项：严格格式/边界、预览取消/参数错误、未知状态及ACK后异常防重复、窄窗口配色编辑；粘贴/鼠标3项：迟到剪贴板、编辑确认及路由销毁、远端捕获/右键粘贴/Shift菜单。
- 真实OpenSSH Native1项：原SSH/SFTP身份、实时配色与远端覆盖、历史仅新终端应用、旧修订拒绝；GTK1项：实际设置确认/终端绘制及计划PNG `/tmp/hspterm-terminal-preferences-{confirmation,terminal}.png`。
- 本批实际只做Rust/Dart格式化解析、逐层静态审查和diff检查；以上全部待统一编译测试，PNG未生成，Windows未实测。

字体文件/本机映射仍遵循TERMINAL_TYPOGRAPHY.md；Nerd glyph内置候选及授权完整性、主机级排版覆盖/可同步偏好、界面主题持久化等仍未完成，不能以本模块代表整个§4字体/外观条目完成。核查的[Nerd Fonts Symbols Only说明](https://github.com/ryanoasis/nerd-fonts/blob/v3.5.1/patched-fonts/NerdFontsSymbolsOnly/README.md)列出混合图标许可，不能只凭仓库总LICENSE打包全部字体；此批没有引入该二进制资源。
