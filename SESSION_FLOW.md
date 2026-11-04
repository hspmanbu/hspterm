# PTY/SFTP 共享 Transport 背压

真实缺陷：默认russh session通道用有界Data消息队列，但共享SSH dispatcher等待慢PTY队列，导致同一Transport的独立SFTP协商也停止。新增OpenSSH测试在完全不读取PTY时，由隔离远端文件屏障确认生产者已flush 1.5MiB，然后申请SFTP；原逻辑4.22秒在3秒SFTP截止失败（.local/session-flow-before.log）。

修复为显式`channel_open_session_flow_controlled`，复用已验证TCP/Agent接收窗口/FIFO/实际消费credit。HSPTerm PTY及SFTP选择此接口；原库默认session API与跳板通道策略保留。窗口仍受配置字节数约束，64KiB合并、128项队列；共享dispatcher不等待应用消费，仅实际消费后补优先级credit。发送窗口仍增量grant新ACK，不能恢复已排队预留额度。没有移除全局pending门控、扩大无界缓冲、丢弃数据或磁盘旁路。

PTY读取与PTY/SFTP请求确认若遇ReceiveWindowError明确失败；不能把本机窗口/队列错误忽略为成功或EOF。SFTP ChannelStream沿既有错误映射传播。生命周期、原代次和Root取消边界不改；流的存在不授予网络/Agent权限。

修复后SFTP在PTY未读取时成功，再排空并逐字检查全部8MiB原始F字节和首尾标记；首轮1.47秒、五次重复1.36–1.38秒均通过。核心完整185项通过，含TUI/Agent/转发/重连/SFTP任务/预算/恢复；Native7项67秒通过，含真实Codex（隔离HOME/回环合成provider，无真实账号）、原Phase2 TUI/传输/Agent/跨库/RSA。Clippy all-targets拒绝警告和NDK共享核心check通过。未重复无关workspace长测试；前一稳定节点完整341项与全Flutter207基线保留，不将预计342/208称新全量。

正式debug/release构建、同模式SO匹配，release独立窗口启动/resize/退出0，无历史/工作副本/preview残留。5秒release短样本RSS344326144B/聚焦CPU7.80%，失焦344662016/4.80%；不是长期泄漏或性能优化结论。原数据validation/phase3b/session-flow-startup-release.json，日志.local/session-flow-*。具体哈希/最新Git/下一步见PROGRESS。Windows/Android设备未验；共享NDKcheck不是APK。
