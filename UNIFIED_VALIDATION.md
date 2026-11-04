# Windows源码集中生成与验证

> 2026-11-04最终状态：Windows功能源码与当前Ubuntu适用验证收齐，目标平台及真实云账号验收单列。完整可恢复摘要见[最终验证目录](validation/windows-unified-2026-11-04/README.md)及results.json。
> Rust完整647项；安全补丁后Bridge75/SSH255；VTE56/alacritty178；Flutter143文件507个去重用例（53轮中断，56轮20文件52项续齐；非一条命令整轮507）；GTK29适用文件及新锁Kitty/Codex/SSH再过；Python22项、Analyze0、两平台全目标严格Clippy0警告；正式debug/release构建、启动清理退出和库散列通过。
> 末次测试辅助if加花括号为风格修正，Dart305文件格式0变更、Analyze0项。性能数据含软件栈raster限制，未宣称目标平台60fps或长期无泄漏。当前没有在途runner。

## Ubuntu完整测试的低空间复现参数

在根目录执行；`cargo`应来自rust-toolchain.toml对应工具链。本轮只减少测试/生成桥接层调试符号，不改变功能或密码学参数。完整Workspace会包含耗时的真实SSH和Argon2测试。

```sh
CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 cargo test --workspace --no-fail-fast --locked \
  --config 'profile.test.package.hspterm-frb-bridge.debug=0' \
  --config 'profile.test.package.hspterm-frb-bridge.strip="debuginfo"' \
  --config 'profile.test.package.hspterm-storage-sync.debug=0' \
  --config 'profile.test.package.hspterm-storage-sync.strip="debuginfo"' \
  --config 'profile.test.package.hspterm-ssh-core.debug=0' \
  --config 'profile.test.package.hspterm-ssh-core.strip="debuginfo"' \
  --config 'profile.test.package.hspterm-term-core.debug=0' \
  --config 'profile.test.package.hspterm-term-core.strip="debuginfo"' \
  -- --test-threads=1
cargo test -p vte --locked -- --test-threads=1
CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 CARGO_PROFILE_TEST_DEBUG=0 \
  CARGO_PROFILE_TEST_STRIP=debuginfo cargo test \
  --manifest-path vendor/alacritty_terminal/Cargo.toml \
  --target-dir target/vendor-validation --features hspterm-history --locked \
  -- --test-threads=1
```

Windows GNU检查命令见PLATFORM_VALIDATION。Flutter与GUI复现、正式入口恢复、当前产物路径见validation/windows-unified-2026-11-04/README.md。首次完整647项后更新的两项安全依赖仅进入SSH/Bridge；已在最终锁重跑该330项及双平台严格Clippy，配置/终端自身依赖图未变。

## 历史执行记录（保留失败、中断与修复过程）

2026-11-03：依用户“先编码、最后统一编译测试”策略，从b42cb1b及此前UNVERIFIED源码检查点进入集中收尾，不再逐模块启动构建。此文不是完成或验收通过声明；Android暂停，Windows实机后续单列。

- `tools/prepare_native_extensions.py`：已执行，固定归档散列及维护补丁准备成功，未修改全局pub缓存。
- Flutter `pub get`：已成功，固定FRB2.13.0及原生扩展0.9.1维护fork，解析新增16项依赖并更新pubspec.lock，不运行应用。
- FRB2.13.0正式`generate`：已开始，内部cargo expand确实编译检查依赖，不是词法扫描。初次阻于alacritty命令边界事件的EventListener缺约束，修复为五个相关方法的最小bound；随后修复Drive分页Option<String>推断、远端并行游标usize推断、私有元数据公开重导出和固定工具链原子try_update的过时警告。
- Cargo.lock已由真实依赖解析更新，未执行无关全依赖升级。尚未通过完整Cargo check/Clippy/FRB/Dart Analyze，仍需继续检查。
- Rust/Flutter/Python测试、应用debug/release构建及真实SSH/TUI回归尚未在本次统一收尾执行，不能将旧0e96be4运行证据应用到新增源码。

后续：先完成正式FRB，保留生成器输出（不手改），然后全量Dart Analyze和Cargo全目标/Clippy，统一修正；完成后运行全量现有测试及新增隔离SSH、Flutter交互、Python协议与性能回归，再构建可运行Ubuntu验收包。真实Windows构建/输入/窗口/OLE/DPAPI/通知实机不可用，不冒充通过；Android不在当前推进范围。磁盘约3GiB余量，单Rust job/关闭incremental；不清理用户文件或未知构建物。

## 2026-11-04集中检查进展

- FRB2.13.0正式生成已成功，新增诊断/主机批量/Explorer DTO等缺失文件已生成；私有缓存、proposal和关闭状态明确frb(ignore)，避免派生Default被自动暴露为API。不手改生成逻辑。
- `flutter analyze --no-pub`：全lib/test/integration_test **No issues found**（2.6s）；此前289项已修正，包含可选接口显式类型、生命周期测试更新、异步context门控、真实Dropdown/TextField检查及固定Flutter onReorderItem语义。自动修复仅限定4类样式/冗余import，不屏蔽规则。
- `cargo check --workspace --all-targets --locked`：**通过**（28.14s），仅1个无用测试常量已删除；已补Bridge生产SFTP错误类型依赖，并以真实生成结果修复可见性问题。
- Python工具10项、固定直传/原生准备器协议12项：**22项通过**。只使用临时夹具，无真实账号。
- 严格Clippy首轮发现3项新集成模块样式警告，正在统一修正，未宣称通过；完整Rust/Flutter测试与应用构建仍待执行。

- 严格`cargo clippy --workspace --all-targets --locked -- -D warnings`：**通过**（33.95s）。机器可修建议已应用并复核；OAuth记录增加类型别名。五个恰为8参数的actor/FRB/任务边界保留显式身份和策略参数、逐函数说明原因，不全局禁用lint或改协议规避检查。无用测试初始化/显式drop已清理，不删测试。
- Bridge仅输出实际使用的cdylib与测试rlib，不再生成无消费者的staticlib，减少磁盘与链接开销；Windows现有DLL、Android共享库路径不变，尚未构建目标平台。
- 原生debug共享库统一构建已开始，后续运行全量Rust/Flutter测试。当前0e96be4仍是最后完整运行验证点，不能以静态检查全部通过替代新增功能运行结果。

- `cargo build -p hspterm-frb-bridge --locked`：Ubuntu debug原生共享库**通过**（1m32s），现有旧库已由实际新构建替换；完整workspace测试启动中，单test-thread防共享Native状态串扰。Codex测试源码确认使用env -i/私有HOME与CODEX_HOME，不读取真实认证文件，不发送付费任务。

## 运行测试首轮与磁盘恢复（2026-11-04）

全量Flutter首轮实际运行到109项通过，发现Explorer离线快照重租失败、同一isolate重复FRB初始化、关闭中的字体读取等待自身在途保存、默认Material主题队列行高溢出和Windows模拟测试的全局平台覆盖未及时还原。真实隔离Codex TUI已通过本轮测试，无真实登录凭据或付费任务。首轮随后因磁盘满而中止，不能将未执行项/环境中断当通过；被停止的runner末尾stream关闭错误不作为产品成功或已修复结论。

Rust workspace首轮已经编译所有测试并开始Bridge测试，已记录若干通过后因磁盘余量不足停止，没有全量通过汇总。停止时验证原cargo/Flutter进程身份，仅停止本次构建/测试及其子进程。未删除源码、配置、用户文件或原有构建；只对本轮新生成且未被进程映射的25个ELF编译产物移除DWARF调试段，保留代码/符号/测试，回收1278.7MiB，现约1.2GiB余量。后续须限制链接峰值，不能在磁盘满的结果上推断功能失败或验收通过。

已按首轮失败新增修正源码：共享初始化Future/初始化已完成检查；关闭时字体读取立即拒绝；队列行高用可扩展最小值；窗口模拟覆盖try/finally恢复；Explorer缓存目录在创建时明确0700（tempfile默认0777/umask，后续严格重租检查必须一致，不放宽检查）。后者须重建新库再验；其他首轮失败正在定向回归，之后继续完整测试。

失败回归20项已全部通过（窗口/字体关闭/队列/双次Native初始化及真实来源退休），未删除用例。新Native共享库以仅本包debug=0/strip=debuginfo重新构建通过37.68s，磁盘恢复约2GiB；export_cache修正现在实际进入新库，下一轮完整用例验证。完整Rust测试采用四个本项目包的profile.test.package.<包>.debug=0及strip="debuginfo"（单job/test-thread），依赖和功能不变，用于限制本机空间占用；同批完整Flutter单并发测试已重新启动。首轮与本轮的失败/通过记录分别保留，不合并虚构总通过数。

完整Flutter第二轮首项Explorer真实离线重租/按需读取/原源不删现已通过，新0700创建权限修正得到实际验证；随后双次初始化与来源删除未知结果、字体关闭等继续通过，完整runner仍未结束。既有Native完整生命周期场景已追加4个并发入口和后续重复调用的同一初始化验证，不删除其SSH/TUI/内存断言。

## 运行续修（2026-11-04，完整结果仍待收敛）

第二轮Rust已记录Bridge72/3、SSH单元78/0、OpenSSH121/5；storage-sync仍在运行。不是全量通过。失败修正后独立实测：OpenSSH集成7/0（7.57s）、迟到OPEN/取消/Root关闭与SFTP所有权6/0（1.69s）；Flutter Explorer9/0（8项交互+1项路径验证）、连接状态3/0、候选/IME5/0、暂存3/0、原型布局23/0；各次结果不能叠加冒充一轮全量。Flutter Analyze 0项（4.3s）。

主要修正：russh本地关闭后的对端CLOSE确认不再被过早guard丢弃，仍拒绝未知/未确认OPEN；SFTP拒绝及时报告且保留真实清理worker；Bash中文位置与字节编码分离、缓存PS1重放R不重置/复活proof；Explorer通道排序Future与消息handler生命周期；候选失效及最新输入排空；暂存确认不做空闲无限动画；Mock移动稳定ID。Drive凭据permit修正已进入上述Bridge运行；目录retired回收及tmux合规夹具尚待新Bridge验证。Native库重建后再运行全量Flutter，不能让旧库替代本次Rust修正。

- 续修后Bridge全量75/0（114.05s）、term-core全量42/0（6.16s）均通过，包含目录取消释放、Drive worker退休、tmux真实身份夹具和缓存R重放保护。新Native debug库已构建通过52.38s。当前完整Flutter第三轮与修正后126项OpenSSH、原storage-sync213项仍在运行；另启动真实release Native构建，不复用旧release库。新增受控填入/执行的中文+组合字符断言由本轮126项覆盖，完整结果尚待收敛。

## 2026-11-04续修检查点：并发回执与同步停用（集中验收未完成）

- 19567d8后扩大OpenSSH126项回归为125通过/1失败：真实检查在错误操作后返回Busy，已复现为worker先发回执后释放准入permit的竞争。检查和直传现在先释放已完成IO的permit再发送回执；检查两项真实回归和SSH单元78项通过。没有提前释放仍未知或在途的通道。
- storage-sync完整213项实际结果212通过/1失败（1039.22s）：未知主机字段已被更早的严格解码拒绝，但排序API错误分类与原合同不同。新增From映射保留OrderingError::Format，原数据/凭据不改，排序4项回归通过。完整原始失败不擦除。
- Flutter假时钟与真实stream/compute isolate需共同排空：新增测试专用support/terminal_cleanup.dart，必须断言真正完成/失败，仍等待Native关闭；修复应用快捷键、远端检查、候选及同步控制器的测试调度。21项交互回归通过，显示设置滚动后等待布局4项通过。文件移动测试更新为现有明确跨服中转/来源删除风险按钮，未修改正式许可。
- 同步实质修正：停用目标立即取消去抖/在途操作并推进编辑代次；定时回调和开始自动同步前再次核对授权，预留操作迟到也不得prepare HTTP。同步控制器/归档/真实加密设置18项通过（含新预留期间停用测试）。归档确认期间停止背后进度动画，操作仍禁用且原owner/token校验保留。Native设置测试统一走正式initializeRust，不依赖隐含动态库搜索路径。
- 严格全workspace/all-target Clippy再次通过（38.53s）；Bridge开发profile固定为已验证debug=0/strip=debuginfo，仅减少生成桥接层调试符号，其他core保留原诊断/发布配置不变。需在所有后续源码修正后再做最终静态检查。
- Native release构建通过6m50s；正式工作台Ubuntu Flutter release构建通过，包内Rust库与对应target/release散列一致。该包早于最新同步/归档Dart修正，最后必须重建，不能当最终包。release GTK实际启动/退出、无启动联网历史或配置库、预览run清理通过；短采样RSS339.7MiB，CPU焦点14.0%/失焦5.4%；第二次线程采样RSS349.5→356.5MiB，CPU11.4%/5.6%，主要为UI/raster/llvmpipe。尚非帧时序、长期泄漏或Windows性能通过证据。
- 构建低空间期间只清理本次release插件生成的已完成中间目录（Git忽略、mtime晚于本轮日志birthtime、无进程映射），最终bundle及旧文件保留，回收约400MiB。恢复时当前约6GiB余量，不重复清理用户文件。
- Flutter完整第三轮前52文件214项通过后，按实际中断/已通过日志恢复执行；后续分文件首批80个文件的状态写/tmp/hspterm-flutter-file-results-6.json，最后live_workbench日志已通过且无残留进程，已补记恢复结果；其中设置库/显示设置/文件菜单三项原失败已独立通过。当前剩46文件以/tmp/hspterm_flutter_remaining_runner7.py运行，结果/tmp/hspterm-flutter-file-results-7.json，每文件真实进程idle120秒/总900秒看门狗，超时记失败，不跳过当通过。旧未知exec session不重用。
- 尚未收敛：真实Native命令区间在23→65宽度变化后消失，已确认本地重排阶段仍有效，实际Bash重绘后才退休；新增实际SSH流定位，需确认该范围是否真被重绘覆盖，不能放宽proof来强行通过。纯核心81组前后长提示符、中文/组合字及23/65/17重排已通过。command_ranges_bridge_test.dart当前有临时仅数字探针，完成定位后必须移除。新openssh_ranges.rs仍是诊断回归，未宣称通过。
- 下一步继续46文件和失败修正→最终Analyze/Clippy/构建及GTK回归。Android暂停；Windows真实编译/输入/OLE/DPAPI等仍待目标平台，不把Ubuntu结果冒充Win实测。不宣称全Windows完成。

### 本次恢复与已收敛问题（2026-11-04）

- 旧工具session已失效且无测试进程；先按日志恢复，80文件记录最后live_workbench实际All tests passed，补记为恢复通过。尚余46文件由runner7继续（/tmp/hspterm-flutter-file-results-7.json），不重跑已通过文件。原三项失败已在独立回归修正，不能直接读取旧JSON就说仍失败。
- OSC133问题已定位为Bash的真实重绘改写旧输出区域：本地reflow后proof有效，后续SSH字节后失效，按旧坐标实际导出已不同于原命令输出。保留生产校验；Native正向夹具以阻塞read保持远端静止（其后仍测试断线、手动重连），独立真实SSH同时覆盖静止重排与Bash覆盖拒绝。Native1项通过5秒、实际SSH2项通过2.09秒；临时数字探针已删除。纯核心额外81组/243次缩放通过。没有改写远端数据或放松row proof。
- 远端未知RENAME恢复测试原先试图在真实元数据通道仍忙时换库，与已实现安全屏障冲突；现在验证换库明确拒绝、原检查正常完成，实际IO退休后才重开/加载任务。原来源重建保护、未知动作不得重发及旧票据失效断言保留；Native回归1项17秒通过。
- 可选Shell联想的Native夹具用合法newHostId和实际组名，原“fixture”ID被正式校验正确拒绝，未放宽生产校验；真实加密历史/单次候选/路径同源1项5秒通过。
- 当前最新Flutter Analyze 0项（8.3秒）；21项终端/菜单/输入交互及18项同步、4项显示设置已独立通过。Ubuntu正式debug工作台构建进行中；release检查点仍须在最终Dart修正后重建。剩余文件测试、完整GTK及最终资源回归尚未完成，Windows实机/Android暂缓边界不变。

### 单文件回归收齐、整套复核启动（2026-11-04）

- 分文件续跑46项记录41通过/2失败/3看门狗超时；这5个原问题均已独立修正并实测：remote_move_resolution（17秒）、shell_suggestions（5秒）、terminal_commands/paste（合并14项通过）和terminal_shutdown（4项通过）。不能把原JSON直接改成假“首轮全过”。全部142个Flutter测试文件现已有运行及修复后通过证据；为核对全套调度，额外完整flutter test单并发复核正在运行，日志/tmp/hspterm-unified-flutter-final-23.log，尚未宣称整轮全过。
- 新增SSH回归文件原放tests根目录被Cargo额外当独立binary，导致最终workspace21轮编译失败（无测试执行）。已按现有项目结构移入tests/openssh_ranges/mod.rs，父openssh模块仍正常引用；workspace完整22轮正在运行，日志/tmp/hspterm-unified-rust-final-22.log。不得忽略新增测试目标编译错误。
- 正式Ubuntu debug工作台构建成功；实际GTK启动、Native加载、无启动配置库/历史、预览缓存退出清理/正常退出通过。短采样debug RSS448.3MiB，失焦376.7MiB，CPU17.6%/7.8%；仍只是短软件图形栈采样，不等同泄漏证明或目标平台指标。
- 29个适用GTK集成文件正在按独立桌面/真实Native顺序执行，状态/tmp/hspterm-gtk-final-22/results.json；file_preview专用隔离MIME receipt，其他使用external_editor_gtk私有XDG/Xvfb。Windows DPAPI文件明确记deferred、不在Linux伪报通过。看门狗idle240秒/总1200秒记失败并继续，需后续修正，不能跳过错误。执行器/tmp/hspterm_gtk_runner22.py，日志/tmp/hspterm-gtk-runner-22.log。

### Windows Rust交叉审核收敛（2026-11-04）

- 最小MinGW工具链实际安装完成（6新增、0升级/删除）；Windows GNU全workspace/all-targets check通过2m36s。修正4处DirBuilder仅Unix才需mut、1处仅Unix父目录fsync才需File导入，未改权限或业务行为；Windows严格Clippy0警告通过41.50s，Linux全目标严格Clippy0警告通过49.62s。命令/边界写PLATFORM_VALIDATION.md，不等同Windows Flutter/C++/MSVC构建运行。
- 完整Flutter最终23轮和Rust22轮仍在途；GTK已有一个状态栏等待超时和一个真实外部编辑流程失败，需要继续修正。为定位状态栏，同一Linux build目录的GTK调度器被自有协调器暂缓推进，当前app退出后才顺序重试，无并行GUI构建；/tmp/hspterm-gtk-status-coordinator-28.log及/tmp/hspterm_gtk_status_retry28.py负责finally恢复SIGCONT。若会话/工具中断，先检查602864（必须核对argv为hspterm_gtk_runner22.py）状态T及协调器是否仍运行，再恢复该自有调度器，不能误停其他程序。

### 全量核心验证通过，桌面交互续修（2026-11-04）

- Rust完整workspace第22轮：647项通过、0失败、0忽略，28个测试/文档测试套件；其中真实OpenSSH128项、storage-sync213项（1091.78秒）。日志 `/tmp/hspterm-unified-rust-final-22.log`。Flutter完整第23轮：502项全部通过，20分07秒，日志 `/tmp/hspterm-unified-flutter-final-23.log`。两者均为完整运行，取代旧局部证据；不等于Windows实机通过。
- GTK第22轮29个适用文件：24通过/5失败，DPAPI另1个明确延期。正在依次重测失败文件，日志 `/tmp/hspterm-gtk-retry-30/`。状态栏与终端偏好夹具挂载正式App后会由真实TOFU弹窗取代原自动同意回调，现明确点击本地合成服务器的“信任并保存”，不跳过生产安全确认。状态栏重测已通过。
- 产品修正：正式WorkbenchApp原先只将初始PaletteBinding传给应用级按键路由，保存新键位未刷新。现仅在模型绑定身份变化后重建该配置，保留原Navigator/路由Key与按键释放所有权，不因每个任务事件重建。新增正式App/原Navigator/F8生效/禁用回归，5项快捷键测试通过；Analyze 0问题（4.6秒）。路由专用测试隔离Native缓存，缓存实际生命周期仍由原Native/GTK测试覆盖。
- 其余GTK失败续修：palette与排版保存滚动后等待布局，live_workbench两处旧确认文字改为正式明确中转风险文字；均待本次GTK回归，不将尚未重跑宣称已过。正式debug/release工作台必须在最后GUI测试后重建，当前debug bundle为集成测试入口。Android继续暂缓。

### Kitty修饰键所有权修正（2026-11-04）

- 实际GTK快捷键第30轮已能打开面板，但捕获到Ctrl/Shift按下后缺少释放：它们在组合键尚未形成时合法发给SSH，随后本地面板拿走焦点。现在只登记实际转发的修饰键，真实释放按原控制器/nativeID/代次返回；全局和终端事件去重，不将旧代次释放注入重连后或另一个标签。F8与面板Enter本体/释放仍留本机，不缓冲或吞掉原始修饰键按下。
- 路由/原终端/候选回归22项通过；新增切换终端与代次变化两项后快捷键文件7项通过。真实Kitty GTK第33轮通过（23秒），按确切协议字节断言原修饰键按下与释放配对，F8和晚到Enter释放均未流入远端；日志 `/tmp/hspterm-gtk-key-regression-33/palette_shortcut_test.log`。
- 第30轮状态栏、终端偏好、字体排版均通过。大型真实工作台流程已通过实际上传/重扫/重命名、4096目录、Mousepad保存及大于16MiB原始字节回传、GBK/CRLF、复制移动和递归搜索；最后预览设置保存点击发生在滚动布局完成前，已补等待，整场第36轮待重跑。没有改业务成功或风险确认规则。
- 完整GTK首轮生成的30个已完成app.dill（明确生成于该轮起止时间、Git忽略、无进程映射）已清理，回收2.335GB，保留当前构建、旧缓存、源码及所有最终bundle。
- 下一步：第33轮真实Codex/SSH输入回归→第36轮完整工作台→扩展release性能基准→最后重建正式debug/release入口及启动退出检查。全过程顺序使用同一个Linux GUI构建目录，恢复时先核对 `/tmp/hspterm-gtk-key-regression-33.log`、`/tmp/hspterm-gtk-workbench-retry-36.log`、`/tmp/hspterm-build-benchmark-34.log`，不要并发构建或交付测试入口。

### 安全扫描与最终复核新发现（2026-11-04，继续收尾）

- GTK29个Ubuntu适用文件均已有通过证据：第22轮24个，第30轮状态栏/偏好/字体3个，第33轮Kitty快捷键1个，第36轮大型真实工作台1个；DPAPI仅Windows另列，不计Ubuntu通过。第33轮Codex/SSH也再次通过。工作台完整场景已实测原预览/传输设置最终保存，合成Mousepad/SSH文件操作并非Mock。
- 新增上游补丁测试：根包vte56项通过；alacritty独立锁/本地vte补丁/hspterm-history特性下132单元+45参考记录+1文档=178项通过。原根命令不能运行有dev依赖的排除workspace包，现使用其独立manifest；offline缺旧锁依赖后正常下载，未改锁。
- 完整Flutter第37轮在途，发现tmux取消状态事件与connect Future迟到回执的文案竞争（中文取消被AnyhowException包装覆盖）。生产report现对FRB AnyhowException使用已审计message，与状态详情一致；新增两种顺序及真实tmux3项共5项回归通过（28秒）。不放宽断线/旧票据断言。原完整502通过与新一轮失败分别保留。
- Cargo audit按2026-11-03数据库发现crypto-bigint0.7.5和ctutils0.4.3分别命中RUSTSEC-2026-0387/0385；已查官方公告。最低补丁0.7.6也被撤回，因此继续选择同0.7系列非撤回0.7.10，ctutils升至同0.4系列0.4.8，无全依赖升级；最终audit及SSH受影响验证待收齐。该图仅经russh进入ssh-core/bridge，不进入storage-sync自身。旧647测试不是新锁的回归证据。
- 为隔离上述变更，**自有构建调度器650330（argv须为hspterm_build_and_benchmark34.py）暂SIGSTOP**，已启动release benchmark编译子任务允许完成，但不自动开始后续debug/正式包。恢复时先检查状态T、子编译完成和最终锁，再安排新锁Native构建/SSH回归，最后SIGCONT或更换已确认的自有调度器，不能遗忘暂停或误操作用户程序。完整Flutter37使用之前已构建Native；新锁Native/TUI验证单列，不冒称同一轮。
- Android暂缓；Windows MSVC/C++/真实输入、系统功能及真实云账号仍缺当前环境，边界不变。

### 真实工作流与输入竞态复核（2026-11-04）

- 构建调度器650330已SIGCONT，**不再暂停**；其benchmark release编译264.3秒、扩展19场景实际运行50.3秒成功；新锁正式debug57秒通过，正式release继续编译。无需再恢复该PID或重复启动旧调度器。
- 扩展基准覆盖实际Vim/tmux/htop、5万中文/组合字符行、滚动100次、Reflow、5次显式重连、5万正则与标记、负载输入、原生窗口变化、实际PTY与关闭：5.604秒空闲0桥接帧/0渲染帧、CPU0.178%；负载输入20次中位32ms/P95 54ms/最大55ms。该基准Native为安全升级前编译，记录保留为对照 `validation/windows-unified-2026-11-04/performance-before-security-patch.json`；最终新锁基准另跑，不将旧图当新图。关闭后RSS未立即下降不直接判泄漏，图形栈/分配器保留与持续增长区别列明。
- Flutter37第二个失败为Shell候选夹具在受控填入后按Enter，仅等待shellInputChanges增加就立即打前缀；重复5次重现1失败，阶段诊断确认是第二个前缀，5个输入事件。S提交回执也会增加此计数，不能当新Readline prompt。夹具现等待实际新revision的合成提示符显示，保留全部候选/清空/原会话/只填入/一次执行及错误代次断言；修后连续5次通过（5–6秒/次）。生产proof未放宽，也不靠屏幕推断真实用户输入。
- 当前完整Flutter37仍用于收集其余缺陷（原两项失败保留），最后同新锁库/固定源码全量复核将由 `/tmp/hspterm_final_delivery53.py` 执行，日志 `/tmp/hspterm-final-delivery-53.log` 和逐步JSON；等待37/34/48三个已有任务真正退出后才推进，校验安全4步和Shell5次均通过。顺序：新锁release性能→Kitty/Codex/SSH真实GTK→重建正式debug/release→全量Flutter→Analyze→双模式正常启动退出。先检查其状态，不重复执行，也不交付benchmark/integration_test入口。

安全公告来源：[crypto-bigint / RUSTSEC-2026-0387](https://rustsec.org/advisories/RUSTSEC-2026-0387.html)、[ctutils / RUSTSEC-2026-0385](https://rustsec.org/advisories/RUSTSEC-2026-0385.html)。本次只更新两项同次版本补丁；初次尝试的0.7.6已撤回，未保留在最终锁中。新锁Bridge75项、SSH全部255项均通过（189.3秒/288.5秒，含编译）；Linux/Windows GNU严格静态检查仍按48号顺序完成。当前audit数据库0条漏洞、0条警告仅为此数据库的检查结果，不是绝对安全保证。

### 最终固定源码/新锁回归已启动（2026-11-04）

- 98fb042为安全补丁与Readline夹具修正检查点。新锁影响范围Bridge75、SSH255全过；Linux严格Clippy56秒、Windows GNU严格Clippy53.5秒全目标0警告通过。配置/终端自身依赖图不变，之前完整workspace647项及VTE56/alacritty178项证据保留，不重复虚加总。
- Flutter第37轮真实结束：503通过/2失败，19分44秒。两个失败均已修并有独立回归，失败原记录不删。新固定源码/新Native库的完整第53轮已运行，日志 `/tmp/hspterm-final-flutter-tests-53.log`，未结束不可提前写507全过。第53轮上游新锁性能、Kitty精确按键归属、实际Codex正常/备用屏幕及原SSH/Vim/tmux/htop GTK均通过；SSH GTK20次Native生命周期RSS差值−1,314,816字节。
- 第53轮正式debug/release工作台均重建通过（5.2秒/6.4秒，缓存有效），入口 `lib/workbench_main.dart`；不再是集成测试/性能入口。最后完整Flutter、Analyze和两模式正式正常关闭smoke仍由53号执行器顺序完成，状态 `/tmp/hspterm-final-delivery-53.json`，不得启动重叠GUI构建。
- 新锁19场景release性能基准49.2秒通过，原始聚合数据 `validation/windows-unified-2026-11-04/performance-after-security-patch.json`。5.603秒空闲0桥接帧/0渲染帧、CPU0.178%；5万Unicode行1.716秒；负载输入20样本中位30ms/P95 46ms/最大53ms。普通命令往返回显中位53ms/P95 78ms。软件图形栈高输出raster P95约90ms、负载约47ms，不能宣称60fps实测通过；后续Windows GPU/字体/IME与长时资源验证仍单列。峰值和退出后RSS不独立等于泄漏，实际租约/历史清理及重复生命周期分别验证。
