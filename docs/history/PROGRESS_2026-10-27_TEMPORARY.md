# 单次覆盖开发过程（已由最新进度替代）

## 下一静态批次：已保存主机单次临时覆盖（未注册/未验证）

- 新`crates/frb-bridge/src/connections/temporary.rs`尚未mod注册：本次元数据结构、显式Saved/Password/PrivateKey模式、零化秘密/明确256KiB文件读取、结构校验及测试源码。没有存储写入，不猜默认密钥/不回退认证。普通SSH核心仍在实际连接时验证完整路线；不要调用其私有validate方法（静态审查已修）。
- 新`ui_flutter/lib/workbench/temporary_connection.dart`尚未接菜单/模型：可编辑地址端口用户、显式保存/密码/私钥模式和系统文件选择表单；仅元数据可用于下次重新确认，秘密对象用后释放。尚未编译/组件或Native验证，不称已支持临时连接；这两文件不得混入背压已验证提交。
- 下一步成批完成共用connect helper/FRB一次性入口、明确临时代次禁历史收集、正式主机菜单/初次新标签/断线重连重新确认、组件及真实双目标/错凭据无回退/不持久化/旧确认或布局关闭测试，再统一生成/编译/修正。不自动把临时目标回连至原保存地址、不复用旧秘密；取消表单不新建连接/占位标签。
- 继续tmux附着/单控制端/尺寸锁、可靠OSC133/安全Shell输入/合格单行历史与路径联动、175项其余配置同步/平台业务。沿用全功能连续策略，累积相关静态代码和交叉审查后集中验证，不每个小改动重跑全部长测试；不等待阶段验收。

背压稳定提交115c24e；未注册的临时覆盖源码继续成批编制中，不能混入已验证模块。temporary.rs新增非秘密TemporarySource（原Vault.scope/主机+跳板元数据标签），准备/最终读取须复核，避免表单停留期间切库或改路线后静默连接；当前仍无API注册/业务入口。UI已补文件选择异常的本地错误，不能把未使用界面称正式连接能力。下一步需把秘密从API入参立即包入有零化所有者的Request、在读文件前先核对原Source/原Entry，接同一connect helper及临时代次；不得跳过主机先保存或沿用过时静态副本覆盖正式代码。

单次覆盖批次继续静态接入：temporary.rs已mod注册；temporary_connection_source与connect_terminal_once已写入API，共用connect_terminal_inner并保持原普通/legacy接口，覆盖时不读取未选保存凭据，Source前后复核、临时历史禁收集标记已编码。一次性.local/integrate_temporary_native.py已执行，**不可重跑**；脚本初次切片选中了legacy auth块导致括号错误，已按明确范围修复并正规格式化。尚未生成FRB/编译/运行，当前工作树属于待集中验证批次，不能以115c24e旧包冒充新功能。下一步完成Flutter菜单/会话驱动/重新确认、组件与Native测试再统一生成和修复。

单次覆盖静态批次已完成主要链路：新增Source元数据与Host/Jump标签，Owned Request即时零化/4个文件worker名额，API复用原connect helper、显式参数DTO、原保存认证/本次密码/本次文件三选一；临时代次禁命令历史标记。正式主机页按钮/Source表单、会话connect驱动及断线Enter重新确认/取消无连接、关闭释放临时秘密已接；新增Rust4/Flutter组件3、Native2、GTK1测试源码。所有新接口**尚未生成FRB及编译验证**，不是已可用能力。一性integrate_temporary_ui.py已执行不可重跑；native脚本也已执行且切片错误已修，不能恢复其旧输出。下一步批量FRB正规生成、lint修正、编译及实际测试，保留115c24e稳定包。

临时覆盖首轮已验证：FRB2.13正规生成/Native debug编译通过，Rust4项/Flutter及真实Native11项36秒通过；原保存配置/公钥不变、实际远端SSH_CONNECTION端口证明目标覆盖、错误临时口令不回退、取消重连不建Root均已运行。GTK实际主机按钮/编辑端口/首次主机指纹/真实SSH/断线重新确认/取消14秒通过，三张/tmp/hspterm-temporary-{connection,session,reconnect}.png已查看且仅fixture$，尚未复制提交。旧dart fix一度加入26个无关文件的const改动已精确撤回，当前Analyze无问题。随后仅加强组件模式切换秘密清理检查、给未暴露的私有类型加Override前缀避免FRB歧义提示，接下来统一正规生成/相关crate与全Flutter/Clippy/NDK/正式双包，不能以GTK test runner作交付。
