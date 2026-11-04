# 设置页面字体目录内存修正

用户报告 Windows Release 启动后约 200 多 MB、打开设置后约 300 多 MB。本次确认并消除一处与系统字体数量成比例的无效布局；没有把该报告直接判定为内存泄漏，也没有声称已解释全部 Windows 基础占用。

旧 `TypographySettingsPanel` 挂载即枚举系统字体，所有候选加入 `DropdownButtonFormField`。固定 Flutter 3.47.7 源码 `material/dropdown.dart` 的 `DropdownButton.build` 将所有候选放进 `IndexedStack`，关闭菜单时仍创建和布局隐藏文本。最多 4096 项的原生目录上限变成了数千个无用文本节点。

修正为点击字体选择器才枚举；选择器支持搜索、可见行虚拟列表、取消、加载失败保留内置/导入候选。未展开时只显示所选字体。选择仍只修改草稿，明确保存后才应用，不改变凭据、加密参数、终端内容或 SSH 生命周期。关闭选择器后目录/文本视图由路由释放；不加入永久字体目录缓存。

## 实际 Release 对照

Ubuntu/Xvfb/Impeller 软件图形栈，两个独立 Release 进程，使用相同的真实字体设置面板、主题、4096 项合成系统字体字符串、四次挂载/卸载。未创建 SSH、Vault、账号或导入字体正文。原始数据为 [before.json](before.json) / [after.json](after.json)。这是可复现压力场景，不代表用户机器实际安装 4096 种字体。

| 样本 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 简单文字基线 RSS | 251.62 MiB | 254.20 MiB |
| 首次设置面板 RSS | 432.13 MiB | 289.71 MiB |
| 相对各自基线的首次增量 | 180.51 MiB | 35.52 MiB |
| 首次设置段落关联元素 | 8392 | 193 |
| 四次进入设置的系统字体枚举次数 | 4 | 0 |

`paragraph_elements` 为 Element 的 renderObject 属于 RenderParagraph 的计数，包含关联包装元素，不是唯一原生段落个数；前后采用相同算法。RSS 包含引擎、字体/图形缓存和分配器保留，不等于 Dart 活跃堆，也不能用四次短周期证明长期无泄漏。基线存在约 2.6 MiB 环境波动。没有使用强制 GC、进程工作集裁剪、降低 Argon2id 成本或删减字体来降低数字。

复现（在 `ui_flutter` 目录；before 使用父节点 0b9b170 的面板源码及同一基准文件，after 使用本次源码；不要覆盖正在开发的工作树）：

```sh
flutter build linux --release --target benchmark/settings_memory.dart
xvfb-run -a dbus-run-session -- ./build/linux/x64/release/bundle/hspterm
# 正规交付必须恢复正式入口：
flutter build linux --release --target lib/workbench_main.dart
```

基准亦可在 Windows 编译运行，输出 `platform: windows` 的 RSS/峰值；但目前本次对照数据仅 Linux。Windows 原生任务管理器工作集/专用字节、实际系统字体目录和不同 GPU 下的结果仍需复测。旧 Windows CI run41813471598 已确认 MSVC 正规生成/构建/Analyze/窗口启动关闭成功（Artifact13314479216）；该旧包不含本次内存修正。

测试最终结果与新构建链接见 PROGRESS 最新节。
