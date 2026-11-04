# Phase 2 后续平台验收

> 2026-11-04更新：Windows功能已接入正式源码；当前Ubuntu适用统一验证收齐，详[最终记录](validation/windows-unified-2026-11-04/README.md)。新锁Windows GNU全workspace/all-targets严格Clippy0警告通过，正式Ubuntu debug/release构建和正常退出通过；**Windows Server2022 Actions run41813471598已通过正规FRB生成、MSVC/Rust/原生C++ release构建、Analyze、窗口启动正常关闭，并产出HSPTerm-windows-x64包；Windows11全面系统交互仍未验证**。下方早期“未编码”属于历史节点，现状以本段、需求覆盖及最终记录为准。Android专项按用户要求暂缓。真实Google Drive OAuth客户端/账号和WebDAV服务商端到端仍需外部测试资源；隔离HTTP/GTK通过不算真实服务商验收。

本机只有 Ubuntu；Linux runner 是开发验收工具，不新增正式产品平台。本文件不能作为 Windows/Android 实机通过证明。Ubuntu 本轮结果和性能数据见 `PHASE2_VALIDATION.md`、`validation/phase2-ubuntu/`，恢复入口见 `PROGRESS.md`。

## Windows 11

在独立 Windows 11 机器安装 Visual Studio 的 C++ 桌面开发工具（含 Windows SDK/CMake）、Git、项目固定 Rust 工具链及 Flutter 3.47.7。保留现有Flutter runner；本轮已完成正规FRB生成及依赖锁更新，Ubuntu构建和严格静态检查已执行；业务运行回归仍按UNIFIED_VALIDATION.md继续，不能将旧Phase2验收直接用于新增功能。完整Windows源码构建入口见WINDOWS_WINDOW.md及tools/build_windows.ps1（可选-CreateArchive），正式Dart入口为lib/workbench_main.dart。下列Phase2基础命令仅在锁/绑定更新后适用。

在 PowerShell 的项目目录执行：

```powershell
rustup show
flutter doctor -v
cargo fmt --all -- --check
cargo check --workspace --all-targets --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cd ui_flutter
python ../tools/prepare_native_extensions.py
flutter pub get
flutter analyze
flutter test test/widget_test.dart
flutter build windows --debug
flutter build windows --release
flutter run -d windows --release
```

Windows CMake 使用本机 MSVC Cargo 构建 Rust release DLL，并将 `hspterm_frb_bridge.dll` 安装在程序旁。发布时复制完整 Flutter bundle（包括 data、字体和引擎 DLL），不要只复制 exe。用含空格及中文的安装目录重复启动/导出/解锁测试。

Windows 上的 Linux OpenSSH/Codex 自动夹具明确跳过；必须另行配置可控 SSH 测试服务器。不要把这些跳过项写成 Windows 通过。测试程序只支持 SSH 远端终端，没有本地 Shell。

人工验证（每项登记版本、布局/IME、结果和复现方式）：

- 空白启动、显式保存/连接、首次指纹确认、拒绝与变化阻断；密码/私钥认证；关闭窗口退出，没有托盘或自动恢复连接。
- PowerShell 启动后的最小界面能连接受控 SSH；执行打印颜色、中文、宽字符、组合字符的合成命令。比较 Vim/tmux/htop、Codex CLI 的真实界面与另一标准终端；禁止付费任务作为无授权测试。
- 方向/Enter/Tab/Esc/功能键、Ctrl/Alt/Shift/AltGr、不同键盘布局；微软拼音和物理键盘组合输入只提交一次。检查候选窗口位置、焦点切换及 IME 取消。
- 鼠标选择/复制、Shift 覆盖捕获、拖动释放、右键/滚轮；剪贴板 Unicode、大文本、关闭 OSC52 后双向无访问；多行粘贴编辑/取消/确认、重连后旧预览失效。
- 大输出、历史拖动、正则/大小写搜索、上下导航/数量/滚动条标记；缩放后旧搜索高亮失效并重建；到达行数上限不强制跟底，新增行提示继续增长。
- 调整真实窗口尺寸与 DPI（100/125/150/200%）；锁定 PTY 后远端 stty size 不变，解除锁定恢复当前布局尺寸。主/备用屏、宽字符、光标无残留。
- 在中文/空格路径流式导出，拒绝覆盖已有文件；断网保留画面/历史，仅明确按钮或断线焦点 Enter 手动重连一次。
- 多次连接/重连/关闭检查 CPU、私有内存和临时文件句柄。两个进程并存时不删除对方活跃历史；正常退出清理、强制结束后下次仅清理残留且不恢复旧画面。

Linux 正常退出目前通过 AppLifecycleListener 等待 Rust 资源释放。当前 Flutter 的退出请求回调支持范围及 Windows runner 的 WM_CLOSE 衔接必须在 Windows 检查；尚未实现/验证 Windows 原生关闭等待，不能把 Linux 正常关闭测试视为通过。异常残留只在下次启动清理且不恢复画面。

Windows 原生标题栏、工作区/分屏、Explorer 拖放和完整 SFTP 不属于本轮最小界面验收；按原计划在 Phase 3 实现。

## Android

本机已有 `/opt/android-sdk` 中的 SDK35/36、NDK25。Rust `aarch64-linux-android` workspace 的 NDK/API26 交叉检查已执行；详见本轮记录。交叉检查不是 APK、JNI 打包或设备通过。未为本轮安装完整模拟器环境。

可复现共享核心静态检查（Ubuntu 项目目录）：

```sh
rustup target add aarch64-linux-android
HSPTERM_NDK=/opt/android-sdk/ndk/25.2.9519653/toolchains/llvm/prebuilt/linux-x86_64/bin
env CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$HSPTERM_NDK/aarch64-linux-android26-clang" \
    CC_aarch64_linux_android="$HSPTERM_NDK/aarch64-linux-android26-clang" \
    AR_aarch64_linux_android="$HSPTERM_NDK/llvm-ar" \
    cargo check --workspace --target aarch64-linux-android --locked
```

后续 Phase 4 必须处理的实际集成边界：

- 构建/打包所选 ABI 的 Rust `.so`，校验 FRB 初始化、最低 API 与 NDK/Gradle/Flutter版本一致；当前模板未打包 Rust 库，不可称为可用 Android 客户端。
- Android 应用私有 cache 目录应由平台提供给临时历史层；不能假定桌面 `std::env::temp_dir()` 在 Android 沙盒中可写。验证权限、进程被杀后的残留清理和运行锁。
- 设备上的中文/第三方 IME、composing、物理键盘/AltGr、软键盘 resize/固定尺寸平移、横竖屏、触控选择/手柄、双行扩展键盘。
- 全屏终端/SFTP切换，不移植 Windows 分屏；本地文件采用 SAF/MediaStore；后台传输、锁屏/网络切换、前台服务/电量策略、Keystore与恢复按需求执行。
- OSC52/剪贴板按 Android 前后台访问规则实测；运行期画面/历史不进入备份或云同步。真实设备字体、GPU、RSS和热/电量不能由 Ubuntu 数值推断。

真实 Claude Code 账号验收当前不要求，本轮没有执行；通用 ANSI/键盘协议和真实 Codex TUI 结果不能替代它。

## 连续开发：密钥文件与真实工作台后续验收

当前正式工作台运行用 `flutter run -d windows -t lib/workbench_main.dart`，Linux已执行真实SSH标签组/关联SFTP与GTK原生文件选择测试。Windows仍须实测生成/导入/公私钥导出、主密码每次验证、已有文件拒绝覆盖、中文/空格路径、取消选择器及私钥文件权限；Linux通过不能代替这些检查。编辑主机后旧连接目标不变、手动重连刷新目标与TOFU提示，SFTP旧缓存失效。

Android共享核心在密钥模块加入后再次通过NDK25/API26 check。`file_selector`的桌面保存位置功能不适用于Android，Phase4接SAF文件创建/读取授权；不将桌面UI当作Android实现。Keystore、ABI/JNI/APK、IME、后台/设备测试仍未完成。

## 连续开发：内置文本编辑

Ubuntu已接文件菜单编辑及本机加密草稿恢复，操作/架构/工程容量边界见REMOTE_EDITING.md。Windows后续应实测：Ctrl+S仅保存编辑文档、不发送远端按键；中文组合输入先提交候选；UTF-8/UTF-16 BOM与CRLF；关闭出场动画、dirty确认、正常退出落草稿；断网/重连后明确保存；切换标签/服务器不能错写。以正式`workbench_main.dart`运行，原Phase2入口保留。

共享Rust编辑/加密草稿已有NDK25/API26 check；这不是Android编辑页面、APK或设备验收。Android后续以独立全屏编辑适配软键盘/旋转/系统返回、进程回收后的本机草稿恢复，不能直接将桌面Dialog布局当成移动端完成。桌面已接外部文本编辑器选择、目录事件回传和持久工作副本，既有系统关联“打开”仍不回传本地修改；当前结果见PROGRESS.md。

## 临时文件与系统关联打开

Ubuntu已用真实SSH/GTK/GIO及隔离默认查看器验证文件打开，含中文/空格/#/%缓存路径，不能替代Windows系统关联实测。Windows11需在相同特殊字符用户目录下打开文本/图片/未知扩展名，验证ShellExecuteW及失败重试；大于100MiB先取消再确认；多个预览保留各自正文。应用退出时分别测试外部程序释放和占用缓存，确认失败明确报告、下次只清理不活跃残留；检查当前用户ACL、两个进程间锁、强制终止后的残留清理和源SSH断开不影响别的会话。

Android Rust缓存路径由平台提供、共享核心NDK检查已过，但桌面file URI不能代替内容URI/授权。Android内置预览/编辑、SAF及设备测试仍待开发，不将临时文件“打开”称为可用远端编辑器。详见FILE_PREVIEWS.md。

## 外部文本编辑器后续平台验收

Windows11：使用正式工作台，在中文/空格用户目录选择exe（参数不经Shell），分别验证Notepad类单进程和VS Code类派生启动器；启动器退出不能删除工作文件。保存及原子替换需触发原会话回传，扩展长度路径/UNC通知匹配需实测；界面焦点/标签移动不改来源。取消/断线后继续保存只落本机，明确恢复后才再上传。退出后外部程序保存的新正文须能从原工作副本恢复；确认全部编辑器关闭后清理，备份/swap/未知文件、其他实例租约、ACL和重解析点应拒绝不安全操作。纯路径比较单测不代替NTFS/网络共享验证。

Ubuntu以隔离Xvfb/D-Bus和一次性OpenSSH夹具验证共享链路；测试夹具的Mousepad不能替代Windows程序、IME或文件锁语义。Android需求仅内置编辑器，桌面程序选择菜单隐藏；Android独立页面、SAF/Keystore/进程回收仍待开发，不因共享Rust编译通过而标为完成。

## 连续开发：真实传输队列后续验收

Ubuntu已通过真实32MiB暂停/恢复、目标身份不符拒绝、目录冲突/更名/下载、取消与断开落检查点；原生GTK选文件上传和队列详情另验。Windows仍须实测本地目录选择、中文/空格/特殊文件名、目录权限/重解析点、关闭等待和进程重启手动恢复，Explorer拖入/拖出尚未接入。Android桌面选择器不代表SAF实现，前台服务/后台任务/设备恢复仍待实现与实测。完整边界见TRANSFER_ENGINE.md。

## Windows传输名称规则准备

新增TRANSFER_PATH_SAFETY.md列出名称/路径分量规则、真实POSIX回归及Windows待验步骤。本机已安装Windows GNU目标标准库，单独local_path模块和测试metadata编译通过，不是完整Windows应用构建或运行。实际NTFS/UNC/重解析点/云文件行为仍需Windows11；Android SAF不由普通桌面Path检查替代。

## 明确文本编码后续平台验收

Ubuntu已验证GBK选择/中文/真实CRLF回传、GBK不可表示字符拒绝不截断、GB18030及带/无BOM UTF-16；共享核心带encoding_rs已通过NDK/API26 check，不能当Android编辑页验收。Windows真实IME/编辑器和Android全屏编辑后续需验证所选编码持久恢复、格式转换失败保留完整草稿、外部程序保持legacy编码、以BOM明确切换Unicode。编码选择期间SSH代次/目录改变应拒绝，不自动重连。当前完整实现与测试见PROGRESS最新恢复入口，16MiB以上桌面外部模式已另接原始字节分块链路，Android内置页面仍待开发。

## 外部大正文后续平台验收

Ubuntu只验证共享核心与Linux桌面外部编辑，不代表Windows程序/文件通知/ACL或Android运行。Windows11需用实际编辑器验证大文件初始化、原子替换/持续写入通知、路径/锁、退出后继续修改及显式清理；磁盘不足的部分工作文件不能普通启动或被覆盖，确认清理先保留其原始字节。Android只要求内置编辑，不能用桌面选择程序入口代替；分页编辑、SAF路径和进程回收恢复仍待实现。当前NDK检查结果见PROGRESS，不当作APK/设备结果。

## 网络模块后续目标平台验收

当前Ubuntu已验证HTTP CONNECT/SOCKS5、主机级总时限/心跳及明确握手测试，不能替代Windows/Android实机。目标平台需验证代理域名/IP/IPv6、无认证/独立认证、拒绝/慢响应/停机与取消、目标TOFU及变化保护、SFTP/PTY共Transport、参数修改仅下次明确连接生效。测试连接需实际点击首次“信任并保存”，结果不证明目标认证；取消/返回/关闭窗口需无标签/最近/SFTP或资源残留，过期弹窗不能取消后来测试。小窗口/系统缩放及长主机信息可滚动关闭；Windows IME及Android设备输入仍待测。完整跳板/转发/Android正式业务尚未实现，不把软件缺项列为仅实机待验。

## 一级跳板待目标平台验收
Ubuntu真实App/三台独立回环OpenSSH与合成唯一代理已验，NDK/API26共享workspace check通过；这不等于Windows或Android运行验证。Windows11与Android后续核对：选择一个已保存无跳板主机；首次分别显示实际跳板/目标指纹，不同跳板访问相同私网地址须独立信任；代理仅作用外层跳板；目标密码/私钥独立；拒绝/取消两端确认释放连接；手动重连时捕获最新配置；删除跳板后现有Transport可继续但新连接拒绝，绝不自动直连。平台键盘/IME及原生窗口仍待实现/实测的条目不因本项通过而完成。

## 2026-10-26 全局网络默认与独立心跳

全局连接时限/心跳间隔/ACK响应时限/连续失败阈值已接加密配置、正式设置及主机继承选项。默认30/30/10秒、失败3次；间隔0完全关闭。旧主机保留明确参数与旧心跳策略，新建UI主机默认继承。读取损坏或未来版本拒绝覆盖；修改只影响下一次明确连接，不热改原Transport。独立监视器仅等待真实全局请求ACK，PTY输出不能代替回应；有界失败后结束原连接，不自动重连，关闭等待任务退出。

集中验证：Rust294、Flutter188通过；all-target Clippy拒绝警告、Analyze、格式、NDK/API26 aarch64共享核心check通过。真实OpenSSH/合成代理验证ACK保持在线、2000行PTY、停流超时、修改默认不热生效、手动重连读取0关闭；实际GTK设置/主机保存14秒通过。截图validation/phase3b/ssh-network-{defaults,host-policy}.png已查看，无可见溢出。重现GTK：`python3 benchmark/external_editor_gtk.py flutter test integration_test/ssh_defaults_test.dart -d linux --reporter expanded`（ui_flutter目录）。旧代理表单测试需真实滚动到下方控件，修正后8项通过。

正式workbench_main debug/release构建、同模式SO SHA256匹配及独立GTK启动/缩放/关闭0通过，无历史/工作副本/preview残留。5秒启动样本debug RSS516710400字节/聚焦CPU37.00%，失焦518504448/5.00%；release338276352/9.00%，失焦338616320/5.20%。原始JSON为validation/phase3b/ssh-network-defaults-startup-{debug,release}.json；短样本不证明长期泄漏与否，也不宣称失焦开销已消除。Windows/Android实机及完整应用仍未完成，NDK检查不是APK验证。

## OpenSSH导入整批最终验证（2026-10-26）

完整Rust300项/Flutter192项（4:42）通过，原Phase2/真实Codex合成provider/SSH与SFTP/编辑/传输/转发回归保留；Clippy all-targets拒绝警告、Analyze无问题、格式、NDK/API26 aarch64共享核心check通过。GTK实际导入预览/选中保存11秒通过，两张PNG已查看。源文件解析/事务回滚/旧Vault作用域/无凭据拒绝/明确配置后真实中文PTY均已实际运行；早期FakeAsync文件流失败已通过真实事件循环修复，未跳过断言。

正式workbench_main debug/release重建，SO与target同模式SHA256匹配，独立启动/resize/退出均0，无历史/工作副本/preview残留。debug SO30f8a3cc48ba0d810d79c26a901f771707de02202083d9c68fdaa4a01bf44307；release faf0d3906f37c09d354a10c91ef54708ac3cce7db305065d8dab0880aa49ab3e。日志.local/openssh-import-*，原始startup JSON在validation/phase3b。5秒样本debug RSS501514240/聚焦CPU37.80%、失焦513253376/5.80%；release351154176/9.20%、失焦351490048/5.20%。不据短采样认定无泄漏或优化。不是Windows/Android实机或APK验证。

## 2026-10-26 只读终端显示增强

全局/主机加密覆盖、真实关键词/正则/属性/顺序/测试/JSON预导入、变化可见行语义着色/彩虹括号与同词高亮已接；原ANSI/TUI优先，不改原文。完整Rust308/Flutter198回归通过，随后仅样例按行/预算语义修复补Core6和Flutter/真实SSH6项通过。实际GTK设置/继承/SSH绘制16秒，三张PNG已查看且无真实hostname。Clippy/Analyze/格式/NDK共享核心check、最新双模式包及匹配SO已通过；不是Windows/Android实机，也不表示配置云同步或完整Android业务完成。

32规则重复扫描压力32.174→8.007ms，原文完整保留，预算帧可无装饰；正常场景引擎p95最高0.443886ms。单次有界匹配不可抢占，不宣称硬实时/Flutter整帧性能。数据与复现见TERMINAL_DECORATIONS及validation/phase3b/display-*；短启动RSS不证明长期泄漏与否。

选区补验：纯颜色/下划线完整刷新现在保留实际选区，内容/视口/几何/隐藏或宽度映射/TUI模式变化仍清除失效选区。Core6/Flutter6样例专项后，又补原键盘/可见性/Native及真实Codex合成provider等24项29秒通过；没有把预计309/200称为最后全量。20次生命周期RSS差761856字节仅短样本。正式debug/release再次重建并匹配同模式SO，两个独立启动/resize/退出0，均无历史/工作副本/preview残留。最新5秒启动样本debug511193088字节/聚焦CPU37.40%、失焦512860160/5.20%；release345436160/7.60%、失焦345776128/5.20%，数据display-selection-startup-*.json。短样本不等于长期无泄漏或所有平台性能已验。


## 2026-10-27 正式应用内 Agent

主机默认关闭开关、下一次明确连接申请socket、原终端限时选择密钥/实际目标及公钥指纹预览/风险勾选/撤销已接真实业务。原Transport/Vault/代次一次性票据、源密钥更改删除和切库撤销、关闭等待blocking crypto、独立状态推送均有自动化覆盖。完整Rust330/Flutter206项通过，Clippy/Analyze/NDK共享核心check通过；实际GTK授权、远端真实签名验签与撤销19秒通过，三张agent-{host-option,consent,active}.png在validation/phase3b。正式debug/release构建、匹配SO、独立启动/resize/退出通过，GTK后已恢复正式debug入口。

RSA私钥签名已支持OpenSSH2048–4096/SHA2；RSA host-key及PKCS导入仍待接，不能当全RSA支持。5秒启动数据agent-*startup*.json保留；release聚焦RSS341331968B/CPU14.80%，失焦6.00%，不是长期泄漏结论。Windows/Android真实构建/输入/挂起授权生命周期待平台验证，共享aarch64 check不是APK/实机。详细边界、哈希、日志及下一步见SSH_AGENT和PROGRESS。


## 2026-10-27 RSA 与原连接身份回执

RSA SHA2 host/KEX/hostkeys证明与六种RSA私钥格式导入已通过真实OpenSSH/Native验证，CRT/KDF有界，详SSH_RSA。原actor回执替代当前Vault信任记录重读，跨/同路径重开旧确认失效、已建立SSH保留，详CONNECTION_IDENTITY。完整workspace341项、本批Native8项49秒、Clippy/Analyze/NDK共享核心check通过；前一RSA节点全Flutter207项通过。本批正式debug/release与同模式SO匹配，两个独立窗口启动/resize/退出0，原始数据connection-receipt-startup-*.json保留。不是Windows/Android实机或APK验证，短CPU/RSS不证明长期泄漏与否。

## 2026-10-28 主机排序与命令历史管理

真实加密主机/分组排序、跨组/收藏拖放、快照CAS保护与活SSH身份保持已通过Ubuntu Native/GTK，详HOST_ORDERING。命令历史管理页（仅统计/偏好/明确清除，不含输入采集和候选）已通过Rust/Native/GTK，详COMMAND_HISTORY。NDK25/API26共享核心check及正式Linux双模式构建/窗口正常退出通过。最新完整Flutter239项在主机排序节点，后续管理相关50项通过，未混称同轮全量。

新增`benchmark/workbench_idle_threads.py`在私有锁库窗口测线程CPU，不附加用户进程/读取凭据。失焦短样本约4.4%主要分布在主线程/raster/llvmpipe，原JSON保留；尚无充分帧调度证据认定根因或宣布已解决，不把短RSS变化当泄漏。Windows真实鼠标/DPI/键盘/窗口和Android页面/设备仍待实现或验证，共享check不是APK/实机。
# Windows优先静态补充（2026-10-28，未运行）

最新用户要求Windows优先，Android开发暂缓。新增`TERMINAL_TYPOGRAPHY.md`和`WINDOWS_WINDOW.md`记录字体存储/系统字体/原生标题栏与Snap命中源码、`tools/build_windows.ps1`正式x64构建脚本及明确目标平台验收步骤。新字体Bridge API尚未统一生成，旧绑定/DLL不可使用；本批没有Windows/Ubuntu构建或新增测试通过结果。此前已通过的记录仅为其对应历史节点，不得移作本批证明。


## 新增静态源码待验：Explorer → SFTP

WINDOWS_EXPLORER_DROP.md列出单向OLE拖入源码、9项未运行Dart/组件与既有Native代次扩展，以及实际Windows缩放/窗口/取消/GetData重入/退出验收。Linux可最终运行路由测试，不能证明OLE、原生句柄或DPI表现。反向拖到Explorer下载仍未编码，不能标系统拖放完成。Android暂缓，现阶段不补设备测试。

## 2026-11-03 Windows连续源码阶段补充

本页以上“原生关闭等待/Explorer/完整工作台尚未实现”为Phase2当时状态；后续已有Windows原生窗口、OLE/虚拟目录、DPAPI、真实多会话工作台及完整业务的静态源码，具体见WINDOWS_WINDOW.md、WINDOWS_EXPLORER_DROP.md、WINDOWS_UNLOCK.md和最新PROGRESS。本机仍无Windows实测，后续源码也尚未统一生成绑定/编译测试，不能把实现或旧Ubuntu通过当成Windows验收。

新增可选Bash的Windows验收：主机默认关闭，主动确认并保存后新连接才安装；复制/临时目标不继承。使用私有非生产测试主机确认普通命令录入/再次前缀联想、上下/Tab仅填入/Enter与点击仅一次执行/Esc恢复；隐藏read、Vim/Codex及tmux内层不弹候选、不抢按键，中文IME预编辑不查询/提交。源SFTP文件/目录/批量拖入仅原标签接受、不上传下载；空行cd才明确执行，失效只复制或未知结果提示、不重复执行。清空/关闭记录后旧候选和等待落库命令不回灌。跨组移动/焦点切换不重连、不重置侧栏。系统异常显示固定提示和仅内存计数，诊断不含命令/凭据/异常栈，真实隐私及性能仍须验收。Android专项按用户要求暂缓。

## Ubuntu上的Windows Rust交叉检查（2026-11-04）

已安装Ubuntu的最小`gcc-mingw-w64-x86-64-posix`工具链（6个新增包，无升级/删除），使用已有Rust `x86_64-pc-windows-gnu`标准库：

```sh
CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 \
CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc \
CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc \
AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar \
cargo clippy --workspace --all-targets --target x86_64-pc-windows-gnu --locked -- -D warnings
```

`cargo check`全workspace/all-targets通过（2m36s），随后清理5项只在非Unix出现的unused mut/import；Windows GNU严格Clippy通过（41.50s），Linux同范围严格Clippy亦通过（49.62s）。只按平台决定DirBuilder的可变绑定和父目录File导入，目录权限/回收行为保持不变。

这是真实Rust Windows条件分支及所有目标的交叉类型/lint检查，**不是Windows Flutter/原生C++编译、MSVC ABI链接或Windows运行验证**。仍需以上Windows 11步骤验证窗口、IME、OLE文件提供者、系统通知与DPAPI，正式Windows包仍由tools/build_windows.ps1生成匹配MSVC DLL；不交付GNU检查产物冒充Windows客户端。

## GitHub Actions Windows构建（2026-11-04，首次运行待验证）

用户已授权上传至私有仓库hspmanbu/hspterm并触发构建。工作流为.github/workflows/windows-build.yml，使用Windows Server2022 x64/Visual Studio2022固定版本构建；包含Flutter Analyze和实际主窗口启动/正常关闭检查，提供完整Release目录Artifact。原生C++/MSVC结果以实际run为准；即使成功，也不替代Windows11真实IME/Explorer/DPAPI/通知/GPU验收。tools/build_windows.ps1新增应用本地MSVC CRT打包，Windows CMake复用同一个显式MSVC目标。
