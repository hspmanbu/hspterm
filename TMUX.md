# 可选 tmux 与原 SSH 会话

V1.4 §3.1 的 tmux 开关位于主机管理器的终端设置，默认关闭，作为正式主机元数据加密保存。开启后，在原 SSH 完成身份认证后、创建交互式 PTY 前，用专用 exec 通道读取版本和会话列表，再由用户明确选择附着、新建、普通 Shell 或取消。正式工作台及 Phase 2 最小真实 SSH 入口共用选择器；Mock 入口不启动真实连接。

## 生命周期及安全边界

- 每次明确连接、手动重连均重新选择；选择不建立第二条 SSH Transport，不向已有 PTY、Shell、Vim 或 Codex CLI 注入命令。不提供保存自定义启动命令。
- `ssh-core::tmux` 的发现通道复用原连接的消费窗口，检查请求 ACK、退出状态及通道结束；stdout 与 stderr 共用 64 KiB 预算，最多 256 项。stderr 不进入用户诊断，名称使用 Base64 协议承载、严格 UTF-8 验证并转义 UI 控制字符。远端需要 POSIX 命令环境以及 `base64`、`tr`；发现失败明确显示问题，不自动改用普通 Shell。
- 列表目标只使用已验证的 `$数字` ID，不把名称拼入 Shell。附着在 tmux 命令队列内再次核对原服务器 PID 与 session 创建时间，变化时不附着。新建名称只允许受限 Unicode 字母/数字、空格、下划线和连字符，最多 64 UTF-8 字节；不使用 `new-session -A`，同名竞态不转成意外附着。
- 只读观看默认开启，采用 `attach-session -r`，不参与远端尺寸计算。控制端采用 `-d`，必须另外勾选接管风险确认：**会分离其他客户端，包括只读观看端，其 SSH 可能结束、任务可能暂停**。不使用 `-x` 或发送 SIGHUP。只能尽力维持单控制端，不能阻止其他远端客户端随后改变状态；只读是 tmux 行为，不是对远端管理员的安全隔离。
- 支持最低版本范围为 tmux 3.2 及以上；真实环境当前只验证 3.4。3.2 官方手册明确 `-r` 等价于 `read-only,ignore-size`，`-d` 分离其他客户端。版本及行为依据：[tmux 3.2 官方手册](https://raw.githubusercontent.com/tmux/tmux/3.2/tmux.1)、[3.4 官方手册](https://raw.githubusercontent.com/tmux/tmux/3.4/tmux.1)。不支持或未知版本需要取消或明确选择普通 Shell。
- 可锁定此 PTY 的初始尺寸，窗口/分屏变化不再发送 resize；可通过已有终端尺寸控制显式解除。初始锁定来自实际连接回执，运行模式通过独立合并事件推送，不在终端绘制路径轮询。
- 选择票据绑定原 nativeID、连接代次、连接 Attempt 和原 Vault 实例，只能回答一次。关闭、取消、成功重开或切换 Vault 使原请求失效；迟到回答不能创建新的 PTY 或污染后续代次的错误。用户选择等待不消耗剩余网络时限，但仍响应取消和原连接关闭。
- SFTP、转发及终端继续归属原 SSH Root；移动标签/调整分屏不改变此身份。断线不自动重连，保留本地画面与历史。

## 已执行验收及复现

所有测试仅操作专门创建的临时 sshd 和 tmux socket，禁止调用用户默认 tmux 服务。真实 SSH 预检先证明 `TMUX_TMPDIR` 为夹具私有目录、无继承 `TMUX`；本机建/查/清理均传显式 `-S` 私有绝对 socket，socket 父目录权限为 0700。sshd 配置把 HOME、HISTFILE 和 TMUX_TMPDIR 放在同一 SetEnv 声明内，并核对有效配置及远端真实回显。

```sh
export PATH=/opt/flutter/bin:/root/.cargo/bin:$PATH
export CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=2
cargo test -p hspterm-ssh-core --test openssh openssh_tmux --locked -- --test-threads=1
cargo build -p hspterm-frb-bridge --locked
cd ui_flutter
flutter test test/tmux_choice_test.dart test/tmux_bridge_test.dart test/temporary_connection_test.dart test/native_bridge_test.dart --reporter expanded
python3 benchmark/external_editor_gtk.py flutter test integration_test/tmux_test.dart -d linux --reporter expanded
```

专项实际通过：Rust 核心 3 项、存储加密/旧字段兼容 1 项、Bridge 原作用域/一次回答 1 项、真实 OpenSSH 2 项、Flutter/Native 混合专项 10 项、GTK 1 项。覆盖控制与只读输入、观看 resize 不改变实际窗口、显式接管、取消/未确认不得回退、等待 3 秒不消耗 2 秒网络预算、加密开关、尺寸锁/解除、Unicode 与组合字、同 Root SFTP、重连重新选择、旧票据/切库/关闭弹窗及迟到回答。

GTK 截图使用私有服务器和合成名称：`validation/phase3b/tmux-consent.png`、`tmux-active.png`，已实际查看。原始专项日志 `.local/tmux-{openssh-3,focused-flutter,gtk}.log`；Native 20 次生命周期 RSS 差 716800 字节仅为短样本，不能据此声称长期无泄漏。全量回归/正式构建结果以 PROGRESS.md 最新记录为准。

首次真实测试未通过私有环境预检，未继续 tmux 操作；修正夹具后通过。全量编译另外发现子模块文件放在 tests 根目录被 Cargo 额外识别为独立测试，已改为 `tests/openssh_tmux/mod.rs`；不删除或跳过断言。

## 明确待完成

- V1.4 §3.2 **按配置恢复此前选择的 tmux 会话**尚未实现；当前每次手动连接重新明确选择，不能将此记录写成完整重连恢复。
- Windows/Android 实机、Android 专用选择入口及软键盘尺寸联动仍待验；Ubuntu 测试不是目标平台实测。
- 无真实多设备/长期网络波动验收。真实 tmux 服务配置可自行改变窗口策略或键绑定，不能声称可以强制覆盖全部服务器行为。
- tmux 内普通 Shell 识别、命令历史联想及安全路径发送仍须独立可靠输入证明，不能仅凭当前模式、OSC7 或 OSC133 启用注入。

后续同步/备份仅允许正式主机的配置开关；运行期 tmux 列表、选择票据、原会话 PID/ID、PTY 状态及授权不进入云端或配置备份。

最终本批回归：完整 Rust workspace 362 项、完整 Flutter 225 项（5分54秒）、严格 Clippy/Analyze、NDK25/API26 共享核心检查通过；最终 GTK 1 项11秒通过。新补 Native 尺寸复现与修复、去重/空闲检查合计选择器/Native8项24秒通过。正式 debug/release workbench_main 均重建并实际启动、调整大小和正常退出0，无终端历史/编辑工作副本/预览残留。原始启动样本见validation/phase3b/tmux-startup-*.json；短样本不作为持续内存/CPU优化结论。


## 2026-10-30 连续静态开发：既有附着的手动重连记忆（未统一验证）

此前“每次重选”的已验证版本保留为历史记录。新源码可在既有会话附着弹窗显式勾选“本终端手动重连时恢复”，只保留到终端关闭，不持久化/备份/同步。只读沿用只读/ignore-size，控制模式的勾选文案明确包括以后手动重连再次分离其他客户端的同意；未勾选保持原每次选择。

记忆绑定原Vault运行scope、保存主机ID、当前已认证SSH的地址/端口/算法/指纹/用户名及tmux PID/ID/创建时间；名字变化不改变身份，PID或创建时间变化不自动附着。Core在认证后把原verifiedHost/username随同发现请求交Bridge，不用当前Vault信任条目代替实际连接证明。新代次仍重新发现，匹配后仅回答原一次性选择通道，不向现有PTY注入、不重建第二个Transport；不匹配回到选择弹窗，绝不新建同名会话或降级Shell。

只在原连接收到Connected回执后激活候选，取消/失败不让旧owner污染新owner；实际tmux显示模式与恢复配置分别管理，切库撤销恢复权也不误清原SSH显示模式。临时覆盖连接不能启用/继承恢复。取消一次连接保留此前成功记忆；切库/完整备份恢复/关闭终端清除。内存owner/显示owner与代次复核防止迟到bind或清除影响后来连接。

新增“tmux 手动重连恢复设置”应用命令：显式读取原终端/代次，允许关闭以后恢复，当前SSH和tmux保持。关闭同时移除在途待提交记忆，避免新回执重新启用；没有空闲轮询。新增2个API及TmuxPrompt.restoreAvailable/TmuxSelection.restoreOnReconnect可选字段尚未正规生成，旧绑定不可运行。

新增Core身份1/Bridge跨指纹/账户/PID/创建时间/主机/临时源/未ACK/关闭/旧代次1/Flutter明确勾选与控制模式切换复位1，共3项测试源码，全部未运行；实际只格式解析/diff。全量编译/原真实SSH tmux回归和GTK统一收尾。**新建tmux后的身份获取与记忆尚未接，当前UI只允许已有会话附着勾选，不能标记完整tmux配置恢复完成。** 后续需真实确认新建结果和原Session身份，不通过同名猜测或创建后盲扫缓存冒充。


## 同批继续：新建会话的真实身份回执（覆盖上一节新建待接，未统一验证）

恢复勾选现同时覆盖新建与已有附着。新建选择`CreateRemembered`先验证受限名称，但在用户明确确认前不创建；原PTY及Agent端点准备之后，在原Transport专用有界exec通道发送`new-session -d -P -F`及原尺寸，不带-A、不按名称回查。仅完整状态0及严格PID/ID/创建时间回执才构造Identity，随后按该身份在tmux命令队列中原子复核并附着；不分离创建后竞态加入的客户端。未勾选的既有新建路径保持原实现。

身份由SshConnection/ConnectionReceipt送到Bridge，原选择和实际身份/只读/尺寸锁一致才激活记忆。新建时是控制端，恢复勾选文案同时确认未来手动重连接管会分离其他客户端。若创建已经确认、随后连接失败/取消，已创建会话明确保留；不自动删除、同名重建或猜测附着。用户可在下一次明确列表中选择它。

额外兼容审查：不能在原Agent准备之前先创建Shell pane，否则该pane可能缺少SSH_AUTH_SOCK。新建延后到Agent准备后，创建exec按已协商标准/旧Agent请求；OpenSSH可拒绝重复全连接请求，其他服务器可按通道接受，均在创建前确认该通道真实Socket环境。原端点已启用但新通道仍无环境时明确报错且不新建，不静默丢掉Agent能力。没有请求/授权私钥或调用真实用户Agent；新Root仍需重新限时授权。已存在tmux pane的旧SSH_AUTH_SOCK由远端自身环境决定，本客户端不注入Shell修改它。

新增Core创建回执/命令边界1、Bridge创建后身份激活/下一次控制恢复1、真实私有OpenSSH新建/Agent Socket/重附着/同名失败1、Flutter明确新建风险1，共4项测试源码，均未执行；前节点3项亦待统一回归。真实夹具先用私有-S及-f /dev/null启动服务再测产品新建，不读取开发者默认tmux服务或配置。仅Rust/Dart格式解析/diff，最终生成、编译、原Agent/网络/终端回归和GTK仍留统一阶段。

命令选型依据已读取的[tmux 3.2官方手册](https://raw.githubusercontent.com/tmux/tmux/3.2/tmux.1)的新建-P/-F/-d/-x/-y定义；这不是运行验收结果。Core新Identity和ConnectionReceipt字段不是云配置；FRB仍只需正规更新原2个可选DTO字段及2个操作API。
