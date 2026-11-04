# Windows 窗口接入与构建

当前为**未编译、未实机验证的静态代码**，不能用Ubuntu结果代替Windows验收。源码节点/验证状态见PROGRESS。

## 窗口实现

Windows runner现在实现原工作台已经使用的`hspterm/prototype_window`通道：initialize、drag、minimize、maximize、systemMenu、close。这是正式工作台与Mock共用的原窗口动作，不创建额外窗口或系统托盘。Phase2最小程序没有调用initialize，继续保留系统标题栏。

initialize仅在DWM边框准备成功后启用整合标题栏，保留原Win32窗口样式/系统菜单/最大最小化语义，以WM_NCCALCSIZE去掉重复的原生标题栏区域。最大化客户端限制于所在监视器工作区；WM_NCHITTEST处理边缘和四角缩放，DPI变化仍沿原Win32Window/Flutter尺寸通路。最小尺寸沿用原型720×540有效像素，部分小Snap区域可能因此不能容纳窗口，后续应结合真实窄窗布局验证，不能保证所有Snap布局。

现有标题栏Logo支持原生移动循环、双击最大化/还原，Windows右击打开系统菜单。最大化按钮通过NativeMaximizeRegion提交实际渲染边界×DPR后的物理客户端坐标，不按固定按钮宽度猜坐标；原生返回HTMAXBUTTON，以接入Windows11系统Snap菜单。区域只在布局/缩放变化时更新，卸载清空；Linux不发送此窗口几何调用。空白标题栏更大拖动区域、触屏系统菜单及原生按钮悬停视觉仍需后续专项检查，不能称所有原生窗口细节已完成。

close只发送WM_CLOSE，绝不直接DestroyWindow/exit。保留最先调用Flutter engine HandleTopLevelWindowProc的顺序：本地Flutter engine源码中的WindowsLifecycleManager负责可取消关闭并回调既有AppLifecycleListener；用户取消、未保存表单和编辑/任务状态保存失败仍可阻止退出。工作台自绘关闭按钮先经过既有退出流程，系统Alt+F4/系统菜单关闭由引擎发同一可取消请求。WM_DESTROY释放通道和引擎；没有关闭后驻留逻辑。

此实现没有为窗口功能更改任何SSH Transport、PTY或SFTP归属。现阶段不会根据Windows缺失而反复编译Linux窗口。

## 可复现Windows构建入口（待执行）

Windows11安装Flutter稳定工具链、Visual Studio2022的Desktop development with C++及Windows10/11 SDK、Rust MSVC工具链，确保cargo/flutter在PATH中。按仓库版本安装FRB codegen2.13.0和所需cargo-expand。不要接受不认识的SDK许可或从非可信来源下载二进制。

```powershell
cd C:\path\to\hspterm
rustup target add x86_64-pc-windows-msvc
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
.\tools\build_windows.ps1
# 如需ZIP（拒绝覆盖已有同名ZIP）：
.\tools\build_windows.ps1 -CreateArchive
```

脚本先解析Flutter依赖、正规生成桥接，再明确编译Windows MSVC release Rust库及`workbench_main.dart`正式入口，复制匹配DLL并核对SHA256。输出在`ui_flutter/build/windows/x64/runner/Release`，分发整个目录，不只复制exe。不会把源仓库、Vault、用户主机或开发日志打包。脚本本轮未在PowerShell/Windows上执行，也未生成Windows产物；Windows ARM64方案仍待补，不伪称兼容。

## 待统一/实机验证

- `test/window_chrome_test.dart`2项只验证Flutter坐标缩放/同值不重复调用/卸载清空与Linux隔离，尚未运行，不能证明实际Win32行为。
- Windows编译及启动、100/125/150/200%缩放、跨屏DPI、八方向缩放、最大化/还原/任务栏工作区、Win+方向键、拖至屏边Snap、最大化按钮悬停Snap、Alt+Space与Logo右键系统菜单。
- 点击自绘关闭、Alt+F4、系统菜单关闭各验证一次：活动SSH/编辑/传输时取消不退出；确认后等待持久状态保存再关闭；保存失败留在应用，不留下工作线程/临时历史。不要用只启动空窗口的检查替代此项。
- Windows真实鼠标/触控、输入法、Windows消息序列与DWM重启尚待目标平台。Ubuntu原型/正式工作台、窗口事件与标签拖动回归留统一测试阶段执行。

参考：[DWM自定义窗口框架](https://learn.microsoft.com/en-us/windows/win32/dwm/customframe)、[Windows11 Snap命中要求](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-snap-layout-menu)。关闭链路以当前本机Flutter engine `windows_lifecycle_manager.cc`与Flutter `services/binding.dart`实际源码为依据，未重新实现它。


Explorer拖入SFTP的OLE源码现已接入，见WINDOWS_EXPLORER_DROP.md。main已由COM-only初始化改为OleInitialize配对生命周期，GetMessage错误退出；窗口销毁先停用/撤销DropTarget再释放引擎。仅单向名字投放和任务入队，不是反向Explorer下载，所有Windows编译/运行仍未执行。


## 2026-11-03 标题空白区域与真实状态续接（源码，未运行）

新增WindowDragRegion只包标题文字、顶栏多组模式的实际空白，以及单组顶栏标签后的实际剩余空间。复用原drag/maximize/systemMenu方法，仍进入Win32原生移动循环；不包标签或窗口按钮/终端区域。单组按实际固定tab宽/数量、32px溢出按钮计算独立滚动区与空白，空白仍是标签拖入的追加目标；分屏内部标签组不传窗口动作，绝不把分屏区域拖动误作窗口拖动。顶栏组计数有限宽省略，标题栏无需增加新层级。仅Win右键调用系统菜单，双击最大化和拖动保留原Ubuntu开发通道。

正式标签Tooltip改用真实statusLabel，Mock才显示“模拟连接”。未增加SSH/布局对象重建。新增3项组件测试源码覆盖三类窗口动作、标签拖动与会话身份保持、内部区域无窗口手势。全部未执行，仅Dart格式解析及diff；不因此宣称Windows Snap、触摸、DWM等已实测，真实坐标/消息泵验收仍保留。
