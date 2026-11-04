# SSH ACK RTT 与真实底栏（静态源码，待统一验证）

正式工作台底栏消费焦点会话的连接状态、原SSH心跳ACK耗时、实际PTY行列/锁定标志和已载入真实任务记录数。无焦点时明确显示未选择终端；独立Mock入口保留模拟标识，不拿模拟数据替代正式读数。小宽度单行省略并提供完整提示，沿用原24px底栏。

## 样本定义及边界

- 复用现有 `send_ping_checked` 全局请求FIFO及ACK监视器，计时从请求进入到原请求应答，包括本机排队、代理/跳板/SSH路径开销。不是ICMP延迟或CPU指标；不从普通PTY输出估算，不增发专用探测、exec或轮询。
- 仅已有独立ACK心跳策略提供样本。关闭心跳、旧兼容模式、尚无成功样本显示 `—`。首次超时就撤下旧值，不等到最终断线阈值；监视器退出/取消/错误亦清空。相同样本不重复通知。
- Heartbeat只持数字watch，后台worker仍是原弱Handle/原Root取消关系。ManagedSession接收原Root的独立receiver，新连接替换；连接未建立或已断线时不接受样本，状态清除不继承上一代次。

## 独立更新链路

Heartbeat watch → ManagedSession.status.rtt_micros → Bridge `latency` 事件 → Controller.transportInfo → ValueListenableBuilder底栏。状态与代次/错误不变时只推延迟元数据，不重复发已连接诊断，不notify终端画面/整个工作台，不拉取RenderFrame，不checkpoint历史；接收器关闭停止监听，避免ready-error忙循环。

PTY列行与尺寸锁仅从已接受RenderFrame更新，常规字符变化且几何未变不触发底栏指标通知。固定tmux尺寸显示实际锁定尺寸，不把期望布局伪装成已确认PTY。任务数来自现有任务快照，提示中注明已载入；完整任务事件化统计及可选CPU/内存/磁盘/网络/进程明确同意采集仍待做，不能将整个§5.5标完成。

增加SessionStatus字段和BridgeEvent可选字段，保留原状态/错误分支以及旧可选参数构造用法。尚未正规生成FRB；禁止手改生成物或混用旧SO。Dart独立通知器在Controller.dispose释放，迟到事件仍由原id/代次/生命周期检查拒绝。

## 统一验证清单（尚未运行）

- Rust时钟2项：精确37ms ACK样本/退出撤下；首次超时先清空且不提前达到断线阈值。状态1项：断线/新代次不复用样本、相同值不重复通知。旧两项心跳期限与显式取消测试保留。
- Dart/组件3项：未知值和固定PTY文字、独立事件不通知终端或取帧/迟到代次/断线清空、同尺寸输出不更新指标及窄行缩放。
- 真实OpenSSH Native1项：隐藏会话成功心跳仍到达、取帧数不增长、原id/代次保持、断线清空、显式关闭心跳后的手动重连无样本。
- GTK1项：正式状态栏的真实RTT/PTY、720×540布局及原SSH身份；计划PNG `/tmp/hspterm-connection-status-{wide,compact}.png` 尚未生成。
- 实际仅格式化解析、跨层源码检查和git diff --check；未编译、Analyze或执行上述测试。Windows行为/真实DPI仍待目标平台验证。

静态审查确认vendor/russh的Channel.wait取得消息后同步消费credit，未在已取得数据到返回之间插入await；增加telemetry select不改变该取消安全路径。保持SSH无自动重连，心跳失败处理与有限重试阈值不变。
