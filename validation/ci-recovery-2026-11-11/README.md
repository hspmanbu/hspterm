# Windows CI恢复（2026-11-11）

基于fix/round7-windows-feedback的447050f，保留前一agent全部提交。

- 原失败：run42955261463，Release/桥接一致性/Rust/Analyze成功，组件19项失败。
- 修复：窗口几何适配与组件原生通道替身；Windows目标/2倍DPI适配测试；资源采样假时钟推进；历史冷存储Windows锁冲突识别，恢复两项被Unix门控的并发测试。
- Ubuntu：workflow相同26文件158项通过，定向适配/资源13项通过，Rust历史3项通过，Analyze0，term-core严格Clippy通过，fmt/API契约/公共错误边界检查通过。
- run42963332377：Release/桥接一致性/Clippy通过；Windows历史并发创建测试遇到access denied(5)，未验收。活跃owner锁冲突识别已通过。续修2d51234将正常目录析构纳入registry锁，避免枚举与Windows删除挂起竞争；恢复的测试仍在Windows执行。
- 续修Ubuntu终端核心完整47项通过、严格Clippy通过。真实OpenSSH图片上传1项通过（内容一致、目录0700/文件0600、路径不执行、重连拒绝旧代次）；使用已匹配API的现有debug动态库，Windows私有析构修复由新CI验证。
- 当前Windows run42966641743正在运行：https://github.com/hspmanbu/hspterm/actions/runs/42966641743 。Windows结果待新CI补录。组件几何测试有明确通道替身；Windows11实机拖放、图片剪贴板及多屏行为仍需实测。第三阶段内存/性能优化暂停，没有开展新基准对照。
