# HSPTerm 开发恢复进度

## 当前状态

- /opt/hspterm；V1.4及后续明确修订唯一基线。一标签一独立SSH/PTY/SFTP，布局不拥有连接。
- 连续开发全部Windows/Android功能，不按阶段等待验收；缺实机只阻塞对应验证。按依赖成批静态编码/跨层审查，再集中生成/构建/调试/回归，未验证不得称完成。
- Phase1/2 Ubuntu基础及Phase3A布局原型已验；正式完整业务仍有大量待办，175条覆盖见REQUIREMENTS_COVERAGE，不能称全功能交付。
- 恢复先读AGENTS、完整V1.4、本文/覆盖、Git及在途日志；不覆盖未知修改/不盲重跑一次性脚本。历史事实见docs/history/PROGRESS_2026-10-28_TMUX.md及其引用。

## 最近稳定节点

- 909b002转发恢复/规则草稿/回环链接；093ab2a SSH默认及独立ACK心跳；c21a9fb受控OpenSSH导入；c04531b有界纯显示增强。
- 3d2e024/66eca8b内部Agent及正式同意/撤销；5179749 ring RSA认证/主机验签/rekey；bf00066原连接回执/Vault作用域；115c24e消费窗口隔离PTY与SFTP背压。
- a46da7e正式主机单次地址/用户/认证覆盖，不改保存凭据、重新确认新秘密、临时Root禁止未来历史采集，详TEMPORARY_CONNECTIONS。
- d8b830e OSC8有界行span/真实目标点击、VTE分号/ST/取消/分配前限制，冷历史极值滚动溢出修复，详OSC8_LINKS。此前正式包debug SO 03ea098768d573ecd8615aa15fb6486e54a3793350522bf62deb1e31e8514443、release f42f6b8fcdacf2585ecf0596d471d4cd3d84b798be2a9c61b87d595dc77c5d5c；本批正式包已更新，见下。

## 最近完成 tmux 批次 a529b75

- 正式加密主机开关默认关闭；认证后原连接专用有界exec发现/明确附着或新建，普通Shell仅显式选择，取消不回退；无用户自定义命令/无活Shell注入。核心URI之外的tmux元数据64KiB/256项、Base64名称、PID/ID/创建时间核对；新建不用-A。
- 默认只读-r含ignore-size；控制-d必须风险确认分离其他客户端（包括观看端，SSH/传输可能结束或暂停），禁止-x/SIGHUP，尽力单控制。PTY初始尺寸锁/解除、真实回执及独立模式推送已接。
- FRB票据绑定原Vault/Attempt/nativeID/代次，只答一次，关闭/取消/成功重开库失效，迟到答案不污染新Root；用户等待不计网络预算，Phase2最小入口与正式工作台共用选择器。详TMUX.md。
- 已实际通过：核心3、存储1、Bridge原作用域1、私有OpenSSH2；完整Rust workspace **362**（tmux-workspace-2.log）；严格all-target Clippy3、最终Analyze3；选择器/Native最终 **8项24秒**（新增等待期间resize、去重/空闲及新代次同步）；此前混合专项10/GTK1亦通过。
- 发现真实尺寸缺陷：选择期间改布局，成功连接回退旧PTY尺寸；Controller在每次进入Connected补发一次最新布局，Rust尺寸锁仍权威。tmux window_height不含状态栏，实际客户端132×36对应窗口132×35。
- 失败记录保留：早期环境预检失败未操作tmux；sshd SetEnv合并、0700私有socket、有效配置及真实环境回显核对后通过。Cargo将tests根子模块额外当目标，已移至openssh_tmux/mod.rs。首次全Flutter新Fake时钟测试挂起主动终止自有测试进程；改为有超时真实时钟后专项通过，不把被中断全量写成成功。
- 最终**完整Flutter225项5:54**通过，NDK25/API26共享核心check通过，独立GTK1项11秒通过。正式debug/release workbench_main构建及独立真实窗口启动/resize/关闭退出0，无历史/编辑工作副本/preview残留。81568已退出0，不再等待。日志.local/tmux-flutter-full-2.log、tmux-android-check.log、tmux-gtk-final.log、tmux-build-*.log、tmux-smoke-*.log。
- 正式同模式SO：debug `caf1ea9c57ad5e4a6f444b491e1113fe4029a84ee3e57eb2a0350794d2fa3a34`；release `4f8b081d414aabb08c4bef7d4069aa9960475d41cf54c80a9e14f30b61a1558b`。validation/phase3b/tmux-startup-*.json短样本：debug RSS510918656B/聚焦CPU35.80%，失焦515944448B/5.40%；release344317952B/8.80%，失焦344653824B/4.60%。5秒样本，不能宣称长期无泄漏或优化已定位。
- 截图validation/phase3b/tmux-{consent,active}.png已查看，仅私有服务器/合成名称；最终两张GTK截图已重新查看并复制。原Native20次生命周期RSS差716800B仅短样本。
- **按配置恢复先前tmux仍未做**，当前每次手动重连重新明确选择。Windows/Android实机未测；3.2手册已核对，真实仅tmux3.4，不宣称其他版本实测。

## 下一批静态代码与其他未完成

1. 命令历史存储基础位于crates/storage-sync/src/command_history.rs：加密有界仓库、原主机/Vault内存候选、保守敏感过滤、主机/全局清除epoch及旧设备载荷抑制、CAS保存、9项测试源码。完整存储90项（含新9项）93.91秒通过；末次时钟边界保护及去掉无用drop后新9项7.09秒通过，workspace全target Clippy与NDK共享核心check均通过（.local/command-history-{storage,final,clippy-final,android-final}.log）。不重跑已结束41097/66350；旧.local草稿不可覆盖正式源码。此基础无实际输入采集入口，可靠Shell追踪/实时候选UI/设置入口/加密云端仍未接；不得把9项合成仓库测试称为真实终端采集通过。详COMMAND_HISTORY.md。本批未改FRB/Flutter调用，无需重复此前225项UI回归；正式双模式包仍为a529b75。
2. 可靠OSC133 C/D保留范围和导航/输出复制；安全普通Shell输入证明→合格单行历史/关闭/清空/候选填入和执行；十项安全路径发送。OSC7/133不能单独证明安全编辑，禁止猜测清行/TUI注入。现有OSC7跟随/选区定位勿重做。
3. tmux按配置恢复/完整未完成任务恢复；文件内并行、直传、跨服剪切及安全暂存清理/编辑互斥；主机高级批改/排序。
4. 完整加密备份原子合并/替换、WebDAV/Drive端到端同步/冲突、DPAPI/Keystore。同步只准正式catalog/独立凭据/允许设置/书签/合格历史；排除草稿/布局/设备任务/正文/滚动缓存/临时秘密/Agent票据/tmux运行态。凭据恢复在原Vault临界门控撤销Agent。
5. 字体/通知、path:line和命令面板等；Windows原生窗口/Explorer拖放；Android独立全屏UI/SAF/IME/触控/扩展键盘/前台服务/APK。无实机不阻塞可做编码，但不得假称目标平台实测。
6. 失焦CPU约5–6%尚未定位；无长期浸泡结论，不能以短RSS差声称无泄漏。真实Codex继续隔离HOME/CODEX_HOME、本机合成provider；不用真实账号/付费任务或真实凭据，Claude账号不要求。

## 可复现环境

- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；CARGO_INCREMENTAL=0、CARGO_BUILD_JOBS=2须传全部子构建；仅一个重构建管道。FRB2.13正规生成后cargo fmt，不手改绑定。
- 正式入口ui_flutter/lib/workbench_main.dart，原Phase2 lib/main.dart及纯Mock prototype_main.dart保留。GTK逐文件私有桌面benchmark/external_editor_gtk.py；跑完须重新构建正式入口，独立启动用benchmark/workbench_smoke.py。
- 当前磁盘约1.4GiB，曾测试临时峰值0余量；仅清已结束Cargo缓存/18个完成Rust测试ELF释放948275120B，未删Native SO/源码/用户数据/性能基线。后续重跑全Rust会重建这些测试缓存，先检查容量。
- NDK25/API26共享核心可check，不是APK/设备；Windows无实机。现有一次性integrate_*和旧审查副本不可覆盖正式源码。

## 最近完成远端file URI批次（提交号以git log核实）

- term-core::resolve_remote_reference严格单次解码/实际原SSH authority/控制与bidi拒绝，不规范化POSIX路径或改变原literal解析；FRB原路径/SFTP定位复用原Root/代次/身份，不新增API/DTO。Flutter远端URI与浏览器/转发字段分离，CtrlClick/原菜单只定位原SFTP；本机file URI和Windows盘符形状绝不交系统打开。原相对路径仍须OSC7，不猜hostname别名。
- 完整核心60/Bridge33/严格all-target Clippy、Analyze与NDK共享check通过；全Flutter229项5:37通过。最后普通URI边界补强后相关链接/OSC8/捕获与Shift覆盖/浏览器spy/真实双SSH10项6秒通过；全量在最后这处补强前，不能混称同一次运行。
- GTK第一轮重复注册同Mouse设备而断言失败，修正夹具复用已知鼠标，生产鼠标路由不变；第二轮1项17秒通过：原鼠标选区/URI hover零目录动作→CtrlClick定位原隐藏文件（260目录之后）/主机配置保存及被动跟随，原Root/代次/另一会话/正文保持、无传输。截图validation/phase3b/remote-file-uri.png已查看。
- 82101已退出0，正式debug/release workbench_main及各自独立实际窗口启动/resize/退出0，无历史/编辑工作副本/preview残留。SO debug `3548b6222193609f7af6b2df3bc01303fe6da354861ff0167779791959117eb1`；release `9aac0f438690bcf34b8d0a43810291ebb1071b304c93e735e3a206724af308c4`。日志.local/remote-file-*，原始validation/phase3b/remote-file-startup-*.json。
- 5秒启动短样本debug RSS505688064B/聚焦CPU34.80%，失焦507363328B/4.80%；release338735104B/5.80%，失焦339070976B/4.60%。不能宣称长期无泄漏/CPU问题已定位，旧基线保留。
- 更多path:line、Android长按仍未实现；hostname与保存实际地址不匹配时拒绝，不把Ubuntu当实机。下一批可推进主机分组/主机排序和非敏感高级批改；现有Repository.reorder_hosts只为底层接口，不当成正式UI已支持。命令历史设置/采集/补全仍未接，安全输入证明不得省略。

## 在途主机排序/分组批次（静态编制中，未验证）

651f543已提交远端file URI；正式双包SO仍为该节点。当前新增storage-sync::host_ordering（repository/ordering.rs）：默认/正式分组与主机完整排列校验，原Vault+SHA256全部主机元数据快照、只允许分组/收藏改动、目录与变动主机行CAS同事务，凭据/草稿不读取不重写；未知字段拒绝保留原数据，8MiB成对变动元数据预算防巨量备注内存膨胀，纯排序不受此写预算限制，成功返回已确认候选修订不靠事后重读判成功。新增复用既有sha2 0.11依赖，Cargo.lock只加本包依赖项；offline metadata已更新，不是编译。

Bridge load_host_ordering/apply_host_ordering及4类DTO已编制，尚未正规生成绑定。Flutter正式HostManager新增排序入口，先处理原未保存表单、模态期间阻止后方编辑；原Mock入口不启动服务。独立HostOrderingDialog/HostOrderDraft包括整组/主机拖排、跨组拖放、拖入收藏、多选批改、搜索、Save预览、数据变化/失败保留、不可变原快照及冻结提交。可保存后主机列表刷新失败时单独标识已保存，不把它当事务失败重发；Model原pending追踪保留关闭等待。新DTO文件ui_flutter/lib/src/rust/host_ordering.dart目前尚未生成，不能用旧SO跑新代码。

Rust四项测试源码已补：真实临时加密Vault的排序/分组/收藏与重开、凭据/草稿/其他字段保持；另一Vault连接并发/旧作用域/重复或遗漏ID/未知字段拒绝；SQLite触发器失败回滚及原提案显式重试；70台大备注容量拒绝不部分保存且纯排序仍可。均尚未编译/运行。剩余先静态补Flutter纯模型/拖放/失败与窄窗测试、Native真实加密及活SSH身份、GTK实际交互截图，再统一FRB/构建/测试/修正。不要将未验证源码或接口单独视作正式能力。

主机排序批次静态编制继续：Rust4项、Flutter草稿/拖放/确认/失败显式重试/保存后刷新失败/载入失败/窄窗与缩放7项、Native真实加密+活SSH/SFTP身份保持/旧元数据/切库与同库重开2项、GTK正式主机管理入口与拖动/预览/保存及截图1项测试源码已补。所有测试尚未执行。已复查提交前冻结提案、拖放owner防旧快照、SourceScope/全元数据版本、变更行CAS、保存ACK与后续刷新失败分开，不自动重放已保存提案；HostManager在排序期间拦截后方编辑并先处理未保存表单。分组/主机列表虚拟化，原Mock仍不触发Native。原主列表直接拖排/高级其他属性批改没有冒充完成。下一步正规FRB生成及统一构建/测试/修正。旧静态包装脚本已执行，不可重复套源码。

主机排序集中验证进展：25096已结束1，FRB生成/完整storage94项118秒/Bridge33项24.51秒/严格workspace all-target Clippy/Native构建通过；停在新增测试两项Analyze提示，已修正。第二轮Analyze通过，Native真实SSH/SFTP及加密隔离2项均通过，组件首轮6项失败（ListTile背景层遮挡点击反馈，以及确认等待时仍显示无限进度条导致pumpAndSettle超时）；修正真实UI的Material层、确认/实际提交进度分离后组件8项4秒通过。新增保存分组名与“全部主机/收藏”导航重名不冲突、搜索跨组平铺；正式组以ID导航、真实hostGroups保留同名分组。83851正在完整Flutter→独立GTK，不要盲重跑。磁盘余量不足时仅删除已结束Rust4个测试ELF缓存释放426556432B，不删SO/用户文件/性能旧基线。

下一批已开始静态编制命令历史设置/清除投影：command_history/controls.rs目前未注册模块/未编译，不影响正在运行的主机排序回归；仅统计与原库/原历史版本绑定的开关及清除操作，不暴露命令正文，不新增采集端点。需在主机排序稳定节点提交后再接FRB/正式设置/失效测试，不能视作历史联想已可用。

83851已结束0：完整Flutter239项5:54通过（含真实Codex隔离provider/原SSH与SFTP/传输编辑等现有测试）；独立GTK排序1项11秒通过，实际主机管理入口、主机跨组/收藏/组序/主机序、确认前Native修订不变、确认后真实加密保存且零SSH会话。截图validation/phase3b/host-order-{proposal,confirmation}.png已查看，仅合成fixture-*.invalid/无凭据。36935在执行NDK→正式debug/release workbench_main重建及双模式独立窗口启动/resize/关闭，NDK已通过，不要交付GTK测试入口。

主机排序稳定节点最终验证：36935已结束0，NDK25/API26共享workspace check通过；正式debug/release均workbench_main，独立GTK窗口启动/resize/正常关闭退出0，加载匹配SO，无未连接历史/编辑工作副本/preview run残留。SO debug `2b839ff17302b927e8f1fba253c75a6d30641974e939c37dd82ddee1bc1b8901`；release `ddacf1cdda4395e6a59a7f17e787914fe3e8487aa67d942849d77f25cd7583d8`。5秒样本debug RSS508358656B/聚焦CPU35.00%、失焦510029824B/5.00%；release334766080B/7.60%、失焦335106048B/4.80%。原始host-order-startup-*.json保留，不证明长期无泄漏/失焦CPU已定位。Windows/Android实机仍未测。

下一批静态文件command_history/controls.rs、frb-bridge/src/history_controls.rs、workbench/history_controls.dart尚未注册/生成/编译；本次主机排序提交不包含它们。将继续接桥接、正式设置、原Vault/历史版本和删除epoch保护、出错/关窗等待与确认测试，禁止暴露记录采集入口或把基础偏好当完整联想完成。

## 在途命令历史设置/清除（静态编制）

主机排序稳定提交a3a83f7已创建；新批注册command_history::controls、FRB只读统计/设置开关/明确清除3入口及DTO，正式设置页替换该分类Mock，Mock独立入口保留。设置/清除绑定原Vault实例+历史密文解密后原文字节修订，仓库CAS保留逻辑删除epoch及writer；只投影主机名/ID/计数，不暴露正文或采集入口。保存失败保留选择；载入失败不保存默认；确认等待与实际写入进度分开；清除不提交尚未保存开关，零条仍可保存清除epoch；Model跟踪写入以便关闭等待。原终端滚动历史无清空动作。

已补Rust3项、Flutter交互5项、Native实际加密设置/清除/旧版本/切库重开及原活SSH/无采集1项、GTK正式设置入口/确认/截图1项源码，均尚未生成或编译。先完成跨层审查后统一FRB/存储/Bridge/Clippy/Analyze/Flutter/GTK/NDK及正式包；不得将静态实现标验证通过。主机排序正式包及SO仍为a3a83f7。

32188正在统一验证命令历史管理，FRB已生成/存储97项已编译；新3项早期失败初查为测试夹具新建密码主机未提供合成凭据（Repository正确拒绝CredentialRequired），夹具已补凭据，保留首次日志。等待其余旧94项完成后核实实际错误再有针对性续跑，不能把首次全量标通过。无生产认证规则放宽。

32188已结束101：旧94项通过、新3项均确认为夹具CredentialRequired，无其他失败。87539继续验证：修正夹具后命令历史完整12项14.22秒通过（新3+原9），Bridge完整33项24.69秒通过；Clippy/Native/Flutter/GTK仍在途，勿把此状态写成完整workspace97同轮全绿。仅夹具改动，不重复旧94项。

87539已结束1，历史12项/Bridge33/严格Clippy/Native构建均通过；仅停在新Dart代码7项curly_braces lint，已使用限定规则dart fix修正，没有运行全局其他修复。34675已Analyze通过，正在新管理/原排序/真实SSH/原型布局与原终端组件组合回归→独立GTK。历史修正不是完整97同轮全绿：首次旧94通过，新3夹具失败；修正后12历史通过。磁盘低余量时再次仅清已结束Rust测试ELF，原SO和旧性能基线保留。

34675已结束0：Analyze无问题，新增管理5/真实Native1加原排序/真实SSH与原型分屏/原终端组件合计50项37秒通过；独立GTK正式设置/开关显式保存/单主机取消/全局零条清除epoch1项10秒通过。真实Native验证旧历史版本/错误密码/切库/同库重开保护、原活SSH输入仍正常且管理不会采集输入。截图history-controls-{settings,confirmation}.png已查看复制，仅合成主机，无正文/凭据。31051正在NDK→正式双模式构建/独立启动及新增/proc线程采样，不要盲重跑；NDK已通过。完整Flutter最后一轮仍为a3a83f7的239项，本批是相关50项，不写成245全量。

31051已结束0：NDK25/API26共享workspace check、正式debug/release workbench_main构建及两种独立实际窗口启动/resize/正常关闭通过，Rust加载，未连接时无历史/编辑工作副本且preview run清除。SO debug `9ce3565cbd87e9f133f37a8086166f1de6525840f9b527c605edeeb33c18b2be`；release `288b6e8653ad28975c757774ce573354136a726b3e3dfe303a212b5285f3af78`。5秒启动样本debug RSS518946816B/聚焦34.80%、失焦520609792B/5.00%；release348786688B/5.80%、失焦349126656B/4.40%，原JSON保留，不是优化前后同负载对照或泄漏证明。

新增benchmark/workbench_idle_threads.py已实际执行/语法检查，只启动私有空配置锁库窗口，不附加用户进程/不用ptrace或账号。release独立5秒样本聚焦CPU5.20%/RSS343945216B、失焦4.40%/344285184B；失焦CPU计数集中在主线程5ticks、Flutter raster3ticks及llvmpipe合计16ticks，100ticks/s。原始history-controls-idle-threads.json保留。能定位线程分布，不能据此认定具体重绘根因、Rust泄漏、帧率或已优化；后续仍须帧/调度证据，未为了降数值关闭正确功能。没有Windows/Android实机或APK测试。

## 在途应用命令面板（静态编制）

命令历史管理稳定提交4bfbc40；其正式双模式包/SO仍有效。下一批新增prototype/command_palette.dart并接正式/Mock应用操作描述：稳定应用操作ID、最多8条本次运行最近操作（不留搜索文字/标签或命令内容）、中文不区分大小写搜索、上下/Enter/Esc、选中项滚动、IME composing时不拦截候选键；只列可执行操作并在选择后再校验。真实终端搜索/复制/粘贴/导出绑定原焦点视图与代次，不因面板等待期间切焦点/重连改向；保留原粘贴/导出确认。面板打开去重，异步操作错误回原Model。只接本机应用动作，无SSH文本注入或批量管理。静态未编译，接下来补测试/GTK后集中验证；可持久化自定义快捷键/终端捕获冲突配置仍待开发，现有TerminalView键盘路由不改。

命令面板静态交叉审查修正：原本在Workbench build提前捕获view会漏掉随后才挂载的真实终端，改成打开面板时构造命令提案并捕获原视图/代次。可用性监听原controller，但只有可见动作ID/标签变化才重建面板，远端高频输出不因通知本身重绘。选择/关闭去重，避免出场动画中重复Enter误弹后方页面。已补纯模型/组件/IME/长列表/实际原型入口7项与真实SSH GTK1项源码，未执行。快捷键可配置及完整捕获策略仍待接，未改现有终端协议输入。

命令面板验证进展：73125已结束1，Analyze通过、相关53项52通过/1失败（长列表测试少等了一帧post-frame跳滚，未等待下一帧就命中测试）；夹具等待调度完成后专项7项通过，包含新增出场动画迟到点击。21965 GTK1项13秒通过。随后补IME Escape平台路由/原controller不变通知不重绘与实际双SSH切焦点保护；66451停在Dart const Set不允许LogicalKeyboardKey自定义相等的编译检查，改常量List。4846最终Analyze/专项7项3秒/独立真实双SSH GTK1项16秒通过。截图command-palette-{search,recent}.png已查看复制，仅合成横幅/私有会话。76486正在最终组合回归→正式双模式重建/启动；未改Rust/FRB，所以共享核心NDK与Rust最后验证仍4bfbc40，不无谓重跑。尚未做快捷键配置，覆盖表保持部分。

76486最终组合Flutter54项19秒通过，正式debug构建打印Built后管道退出143；未生成debug smoke日志，release未开始，无在途子进程。原因尚不明，不当成功也不盲重做已完成构建；确认bundle存在后35868从debug独立启动继续→release构建/启动→最终完整Flutter回归。没有把被中断管道描述为产品断言失败或完整验收通过。

35868已结束0：从已完成debug构建继续的独立窗口启动成功，release正式构建/启动成功；两种正常关闭均0，无未连接历史/工作副本/preview run残留。最终完整Flutter252项6:13全部通过（包含真实Codex隔离loopback provider、原真实SSH/SFTP/编辑/传输/输入回归及本轮新增），不是预测值。新面板代码没有Rust/FRB改动，同模式SO仍debug `9ce3565cbd87e9f133f37a8086166f1de6525840f9b527c605edeeb33c18b2be`、release `288b6e8653ad28975c757774ce573354136a726b3e3dfe303a212b5285f3af78`，已重新核对bundle。

command-palette-startup-*.json短样本debug RSS513523712B/聚焦38.59%、失焦515190784B/6.20%；release339017728B/9.20%、失焦349425664B/5.20%。保留早期原数据，无稳定帧率/数小时无泄漏或已修正失焦CPU结论。本批相关54项19秒/专项7项3秒/真实双SSH GTK1项16秒已通过，截图已查看。后续从可配置应用快捷键/明确TUI优先级及输入生命周期继续，不必重复此面板基础UI；所有剩余V1.4条目依然保留。
