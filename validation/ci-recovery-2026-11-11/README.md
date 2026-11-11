# Windows CI恢复（2026-11-11）

基于fix/round7-windows-feedback的447050f，保留前一agent全部提交。

- 原失败：run42955261463，Release/桥接一致性/Rust/Analyze成功，组件19项失败。
- 修复：窗口几何适配与组件原生通道替身；Windows目标/2倍DPI适配测试；资源采样假时钟推进；历史冷存储Windows锁冲突识别，恢复两项被Unix门控的并发测试。
- Ubuntu：workflow相同26文件158项通过，定向适配/资源13项通过，Rust历史3项通过，Analyze0，term-core严格Clippy通过，fmt/API契约/公共错误边界检查通过。
- Windows结果待新CI补录。组件几何测试有明确通道替身；Windows11实机拖放、图片剪贴板及多屏行为仍需实测。第三阶段内存/性能优化暂停，没有开展新基准对照。
