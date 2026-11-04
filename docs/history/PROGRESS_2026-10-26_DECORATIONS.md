# HSPTerm 开发恢复进度

## 当前执行策略与基线

- /opt/hspterm；V1.4及后续用户明确修订为唯一产品基线。一终端标签一独立SSH/PTY/SFTP；SplitTree仅管理TabGroup布局。
- 连续实现完整Windows/Android功能，不在阶段边界等待验收。不将Mock或静态源码称为真实功能。Windows/Android实机验证不阻塞可编码工作。
- 最新用户要求：按依赖成批静态编码与跨层审核，再集中编译、调试和回归；不每个小功能反复构建。保留既有测试和真实Phase2入口。
- 新会话先读AGENTS、完整V1.4、本文和REQUIREMENTS_COVERAGE；核对Git/未提交修改/在途日志后恢复，不清理未知文件。

## 已完成且验证的最近节点

- 909b002：可选明确重连恢复L/R/D、独立失败状态；加密规则草稿/CAS/修订墓碑与原子提交；终端链接确认临时回环转发、浏览器失败只清本次实例；完整289 Rust/186 Flutter/GTK/NDK与双模式正式包。
- 093ab2a网络批次：加密全局连接时限/心跳间隔/ACK响应超时/连续失败阈值，主机显式继承/覆盖，正式设置和主机保存界面。旧主机false/None保持原参数，新UI主机默认继承；只影响下一次明确连接，interval0关闭。
- 独立心跳只以真实SSH全局ACK为回应；有界单次等待/失败阈值、迟到ACK FIFO、原Root终止、弱Handle/关闭等待。默认旧策略兼容，不自动重连。
- 本批最终Rust294/Flutter188（4:24）通过；Clippy all-targets拒绝警告、Analyze无问题、格式及NDK/API26 aarch64共享核心check通过。真实OpenSSH验证ACK、2000行输出、停流超时、默认修改不热改、手动重连读取0关闭；真实Codex合成provider和原TUI/转发回归保留。
- 实际GTK设置/主机继承与响应超时保存14秒通过，两张ssh-network-{defaults,host-policy}.png已查看。旧代理表单新增控件后需真实滚动，测试已修正，8项通过。SFTP opener生成时误借self已修复，保留static原能力契约。
- 正式workbench_main debug/release及匹配SO/独立启动resize/退出0通过，无终端历史/编辑工作副本/preview残留。debug SO202eabe27e0dfbdda4f2f85c39cf19045bbca0e59344d41cd2577747a3ee5219；release eff2026cd563c97accbc586f6240a66bdf121e6854e757ed03596f08175a71fa。
- 5秒启动样本debug RSS516710400/聚焦CPU37.00%，失焦518504448/5.00%；release338276352/9.00%，失焦338616320/5.20%。仅短采样，失焦开销未完全定位，不宣称长期无泄漏或性能优化。JSON见validation/phase3b/ssh-network-defaults-startup-*.json。
- 本批日志.local/ssh-network-batch-{workspace,flutter-all,android,clippy,analyze-final,format-check,build-debug,build-release,bundle-hashes,smoke-*}；最终管道已结束，不重复运行。早期错误/失败日志保留，不计通过。

## 当前静态编码与直接下一步

1. 保存已验证网络节点；继续受控OpenSSH Config导入：用户显式文件/文本→有界纯解析→逐项预览/警告/选择→原子创建主机；不执行Match exec/ProxyCommand、不自动展开Include、不读取IdentityFile秘密，不在运行时自动读~/.ssh/config。解析、仓库事务、桥接、界面和测试成批编写后统一验证。
2. 未注册静态准备crates/ssh-core/src/agent_protocol.rs：仅有界Agent帧/列表和签名能力接口，尚未编译/无实际Signer/授权/Transport路由/UI，不计Agent功能完成。RFC9987与OpenSSH PROTOCOL.agent已核对。需原Root限时同意、选中密钥签名及撤销、PTY前请求、新旧协议协商/消费窗口和真实测试，不能盲复用上游允许管理密钥的AgentServer。
3. 其他网络未完：可选tmux附着/单控制端/尺寸锁、完整按配置恢复未完成任务；已完成跳板/唯一代理/TOFU/转发/网络默认不重复实现。
4. 可靠OSC133 C/D历史锚点及裁剪/Reflow、命令导航/输出复制；安全普通Shell输入跟踪→十项路径联动/加密单行历史与联想。OSC7/133不能单独证明安全输入，禁止盲清行/TUI注入。
5. 按175项覆盖清单继续：显示装饰/字体/OSC8/通知/命令面板，主机排序/批改，文件内并行/直传/跨服务器剪切/暂存清理/编辑互斥，配置同步/备份/DPAPI/Keystore，Windows原生和完整Android/SAF/IME/触控/扩展键盘/前台服务。未列细项以V1.4为准，未取消。

## 生命周期与安全边界

- 标签/分屏移动不重建Transport；保存/删除配置不改运行实例。SFTP/任务/编辑/转发能力绑定原nativeID/代次/目标身份，断线后保留画面。具体锁顺序与关闭约定见AGENTS和领域说明。
- 同步/备份只取正式配置及允许历史，不含草稿/布局/设备任务/滚动历史/预览/编辑正文/临时凭据/运行端口。复制草稿内规则也不能只按前缀扫描当正式配置。
- 未知移动/取消ACK不得推断成功或盲重发；不读取真实Codex登录凭据/账号任务；合成测试秘密不提交。

## 恢复与构建

- PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH；CARGO_INCREMENTAL=0、CARGO_BUILD_JOBS=2；同一时间只一个重构建/测试管道，避免外部SIGTERM。
- FRB2.13.0正规flutter_rust_bridge_codegen generate；随后cargo fmt --all；不能手改生成绑定。
- cargo test --workspace --locked -- --test-threads=1；cargo clippy --workspace --all-targets --locked -- -D warnings；ui_flutter内flutter analyze/test。新FRB API先生成匹配Native再运行Flutter。
- main.dart保留Phase2真实SSH，prototype_main.dart独立Mock，workbench_main.dart正式。GTK集成测试后必须重建正式debug/release并核对SO/独立启动，不能交付测试入口。
- NDK25.2.9519653/API26 aarch64 check可用；Windows和Android设备未验，完整业务/原生代码仍有未完成，不仅是验证。详PLATFORM_VALIDATION。
- 完整前序记录归档docs/history/PROGRESS_2026-10-26_NETWORK_DEFAULTS.md及FORWARDING系列，档内在途状态已被本文最终结果替代。

## 下一批：受控OpenSSH导入（仅静态代码，尚未验证）

网络稳定提交093ab2a。已编写有界纯Config解析/首值优先/Host通配及否定/明确别名候选、单跳依赖和危险路线拒绝；未知字段/Match/Include只警告且必须确认，不执行或自动读文件/密钥。元数据原子导入使用正式catalog/CAS与独立新ID、不覆盖同名、不制造凭据；正常save仍需凭据。Vault新增每次打开的临时instance scope，旧预览不能写新库。FRB源快照预览/选择保存、正式主机管理显式导入弹窗/分组/警告/缺User与凭据提示已静态编码；尚未生成绑定、编译或运行。继续补解析/事务/Native/组件/GTK测试及静态审核，再统一生成和集中验证。未注册Agent准备保留，不计实现。

导入批次：官方FRB生成、Clippy all-targets、Analyze与匹配Native已通过；解析4/原子仓库2项通过，真实Native导入/旧Vault拒绝/无凭据拒绝/明确配置后真实PTY通过。GTK完整主机入口/预览/警告/选中保存11秒通过，两张openssh-import-{preview,saved}.png已查看。组件文件流测试最终修复为真实事件循环处理timeout流，3项通过；先前把原因猜作length未解决，失败日志均保留。当前最终串行全量/NDK/双模式正式包管道.local/openssh-import-*仍在运行，不能提前标通过。

下一批独立静态准备：term-core/src/decorations.rs为只读可见网格装饰引擎，包含有界Rust regex/规则顺序/远端ANSI优先、宽字符映射、普通屏幕保守门控与平衡括号；尚未注册mod、编译或接配置/FRB/绘制，不能计显示增强完成。导入回归管道结束后继续本批持久设置与真实界面、渲染适配及专项测试，整批完成后统一验证；不在边界等待验收。

## OpenSSH导入整批最终验证（2026-10-26）

完整Rust300项/Flutter192项（4:42）通过，原Phase2/真实Codex合成provider/SSH与SFTP/编辑/传输/转发回归保留；Clippy all-targets拒绝警告、Analyze无问题、格式、NDK/API26 aarch64共享核心check通过。GTK实际导入预览/选中保存11秒通过，两张PNG已查看。源文件解析/事务回滚/旧Vault作用域/无凭据拒绝/明确配置后真实中文PTY均已实际运行；早期FakeAsync文件流失败已通过真实事件循环修复，未跳过断言。

正式workbench_main debug/release重建，SO与target同模式SHA256匹配，独立启动/resize/退出均0，无历史/工作副本/preview残留。debug SO30f8a3cc48ba0d810d79c26a901f771707de02202083d9c68fdaa4a01bf44307；release faf0d3906f37c09d354a10c91ef54708ac3cce7db305065d8dab0880aa49ab3e。日志.local/openssh-import-*，原始startup JSON在validation/phase3b。5秒样本debug RSS501514240/聚焦CPU37.80%、失焦513253376/5.80%；release351154176/9.20%、失焦351490048/5.20%。不据短采样认定无泄漏或优化。不是Windows/Android实机或APK验证。

导入最终管道已退出0，早期“在运行”由以上结果替代。下一步执行已静态准备的显示增强整批：core decorations/存储display_settings/Bridge display尚未注册或验证；Flutter设置/同词高亮和一次性集成脚本暂在.local/{display_settings.dart,same_word.dart,integrate_display.py}，应在本节点提交后执行一次并继续交叉审核/补测试，再集中生成构建。脚本不是幂等，失败须先检查各文件状态，不盲重跑。Agent准备仍单独未注册。

## 显示增强批次已接入静态源码（尚未生成/编译/验证）

导入稳定节点c21a9fb已完成300 Rust/192 Flutter/GTK/NDK与双模式正式包。已执行一次.local/integrate_display.py，不可重跑：装饰引擎/加密版本修订设置/全局及主机覆盖、配置复制与草稿丢弃/主机删除事务、原Vault绑定Runtime、变化可见行FRB绘制颜色与下划线、正规设置页/规则编辑排序/规则测试与有界JSON预导入、同词可见区精确匹配缓存已接源码。原始Snapshot/SSH/历史/复制搜索不改写；TUI默认停用、远端ANSI优先，显式强制规则另处理。新增7项core/存储测试正在补充Native/组件/GTK，尚未运行，不计已完成。Cargo新增仅本地term-core依赖，需统一首次构建更新锁中依赖边；不升级外部版本。必须补齐测试、静态交叉审核，再正规FRB生成及集中编译调试。Agent文件仍未注册。

显示增强专项进展：官方FRB2.13.0已生成、Clippy all-targets及Analyze修正格式后无问题、匹配Native通过。Core4项、显示存储3项与既有规则复制回归、Flutter组件/同词/真实OpenSSH5项13秒通过；实际验证ANSI优先/显式强制、原始导出不变、无SSH输出时刷新、备用屏幕保守停用、隐藏无帧、原代次与旧Vault拒绝。静态审核进一步修正连接准备与Save之间旧策略覆盖竞态：原Vault门控内捕获并绑定，无锁跨SSH await。GTK首轮因滚动后未等布局完成而点到固定标题栏失败，已添加实际滚动/布局等待重跑；不得算首轮通过。另补窄窗规则操作菜单及组件测试、真实合成可见网格release微基准源码；尚待统一最终验证。日志.local/display-*，Agent仍未注册。

显示批次GTK修正后16秒通过，实际SSH/规则编辑/主机继承已运行，三张PNG已查看。发现terminal截图中的一次性sshd默认提示符仍含宿主hostname；已改集成夹具为本次Shell显式PS1=fixture$，需在当前最终管道结束后再跑GTK替换截图（不可修图冒充真实界面），随后重新构建正式入口，当前截图不可先提交。Core release合成160x60可见区100次微基准：关闭mean0.000051ms、关键词0.136867、正则0.165701、32规则0.268831、语义+括号0.351550，p95分别0.000050/0.148660/0.187484/0.275238/0.370920ms（display-core-benchmark.tsv）；仅引擎CPU，不是Flutter帧耗时/端到端延迟。

唯一最终串行管道session56775运行中：.local/display-{workspace,analyze-complete,flutter-all,android,format-complete,build-debug,build-release,bundle-hashes,smoke-*}。当前Clippy包含新example已通过；尚未完的结果不能计通过。不得并发重构建；先等结果，再补上述GTK提示符与截图/正式包。新增可见区同词缓存按Controller身份/帧计数/选区，不在光标闪烁重复扫描；窄窗口规则操作菜单补了组件测试，待全量验证。

Agent下一批静态准备新增agent_signer.rs（未注册/未编译）：内部密钥有界队列/单blocking签名任务，真实Ed25519/ECDSA与RSA按flags签名、有界TTL/原Root子授权撤销、列表/签名能力不含私钥，关闭等待不能抢占的crypto而非detach；附真实Ed25519验签/撤销/到期/Root取消测试源码。需注意当前workspace关闭russh默认features只选ring，RSA实际签名功能也尚未启用；注册时应统一接正确rsa能力并验证真实RSA认证/签名，不得把现有RSA可解码误称认证已验。没有新增外部依赖或注册此源，Agent仍非可用功能；还需原Transport端点协商/入站流控/显式限时同意UI/Bridge/密钥选择与Android生命周期测试。当前显示最终验证管道不包括此文件。

显示性能后续补核：.local/display_regex_stress.rs准备了Rust regex find_iter潜在二次扫描的合成模式(?:.*[^A-Z]|[A-Z])及1/32规则、4096列网格。待当前唯一管道结束后，使用现有release rlib以rustc一次性编译/运行（不另建Cargo工程、不改锁）测量；若存在明显长帧，先增加可见装饰匹配间的耗时预算并补验，不能以常规0.37ms样本冒充最坏模式已通过。再跑安全PS1 GTK/替换截图和最终正式包；不要在当前CPU敏感原SSH测试期间并发压力负载。

预算修复测量：同一合成模式32条规则从32.174ms降至8.007ms，该帧丢弃装饰而不丢终端文本；单规则1.258→1.286ms。新普通场景p95：关键词0.153710ms、正则0.179828、32规则0.230223、语义括号0.443886（display-core-benchmark-budget.tsv；before/after原始指标见display-regex-stress.json，复现examples/decorations_stress.rs）。预算是在有界匹配边界检查，非可抢占硬实时保证。Clippy/装饰5项/安全PS1实际GTK16秒再通过，terminal新截图已查看且仅fixture$合成提示符。唯一最终复验session94556运行.local/display-final-*；旧session56775已正常0结束，不能重复等旧会话。

待在当前最终管道结束后补一个小修复：Decorator::test当前对整个测试样例匹配，可能让跨换行规则测试结果不同于实际按行装饰；应按行统计并对测试工作量明确报预算，补Core与Native专项即可，不需要无依据再次跑全部长传输。随后更新记录/正式包和Git稳定提交。Agent两个源文件均未注册/未编译，不属于显示测试快照。
