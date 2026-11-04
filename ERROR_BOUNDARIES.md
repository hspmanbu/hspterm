# 公开错误及终端数据的静态脱敏边界

本批未统一编译/生成/运行。当前完整已验证节点仍为`0e96be4`，以下是源码契约和验证入口，不是全应用安全验收结论。

## FRB错误链

本项目固定FRB2.13.0，正式生成的`SseEncode for anyhow::Error`使用`format!("{:?}", self)`。`anyhow::Error`的Debug会展开source链；仅在外层加中文context、仅给SshError一个安全Display/Debug，不能阻止内层错误正文一起出现。

`api.rs`全部202个公开Result函数在业务源码中保留原函数签名和成功值，执行原业务后调用`public_errors::finish`。失败构造一个没有原source/context的新PublicFailure；不保留原错误链。已发生操作仍按原代码完成/清理，不增加重连、回退、写库或网络行为。整个函数体多一层结果作用域，私有worker及其资源owner未重构。旧生成文件未手改，统一阶段重新正规生成。

允许摘要是生产Rust源码中的精确静态中文文字（不是匹配前缀或“含中文就安全”）；测试模块及测试文件不入清单。额外只开放已审计的阶段/HTTP或SOCKS状态数字、规则序号、配置行号及跳板递归摘要。新领域类型/动态消息不能自动获得信任；未知、JSON、IO和异常worker用固定的未确认摘要，不能回显原字符串，也不能把未知结果写成“未操作”或“成功”。部分动态错误会比过去更概括，仍可从原UI的目标、任务状态和结构化字段定位；不能为恢复详细文字而重新接回原错误链。

传输/跨服务器任务header、预览失败快照、大正文编辑IO转换使用相同摘要。同步领域的明确未知结果状态和安全审阅仍沿原结构化字段处理；此边界不把这些失败改成普通成功，也不屏蔽原确认。

`tools/bridge_error_boundaries.py`只维护业务源码和`public_error_literals.rs`：词法识别字符串、字符、raw字符串、嵌套注释及顶层函数；`--write`补保护并刷新精确摘要，随后人工看diff；无参数执行源码清单检查。它不修改FRB产物、不拉依赖、不编译、不运行程序。清单检查发现缺失必须修复，不能把未来API留在旧保护之外。原scope/修订、会话身份和所有业务校验仍是各模块职责，摘要不是权限检查替代品。

## Debug与依赖日志

ClipboardStore/PtyWrite/Title、Cell和Snapshot的Debug不包含剪贴板/终端正文或超链接；Snapshot只打印几何及修订元数据。标题trace、未知OSC/CSI/DCS去正文，未知DCS不按字节产生日志，避免把不支持的图形/控制载荷复制到日志或制造逐字节日志流。真实文本、协议、渲染、搜索和导出仍保留原数据。

应用私有`frb-bridge`启用`log/max_level_off`，并对STATIC_MAX_LEVEL建立编译常量闸门，防止依赖库raw packet/未知扩展等日志绕过固定1000条诊断。共享Core不强制通用库用户关闭日志；独立Core测试可捕获已经去正文的trace，整个产品构建则不应产生log记录。最终依赖解析还须核对只有预期的log版本和特性，不能把源码Cargo声明当成最终二进制验证。

这不等于panic hook、tracing、第三方直接stderr或所有Dart平台错误已审核完成。下节追加了函数体panic保护，入口前FFI/其他平台异常仍是后续审核入口；新anyhow错误在用户明确开启Rust backtrace时可能携带代码位置，但不应带原错误/终端/凭据正文。不得因此承诺所有错误路径安全或资源状态一定可继续使用。

## 待统一验证

1. `cargo test -p hspterm-frb-bridge public_errors`四项：原SshError链能包含合成秘密→公开Debug不含、JSON/未知中文字符串/IO不回显、静态摘要/枚举阶段/重复包装、真实公开API无source回执。
2. `cargo test -p hspterm-term-core --test debug_redaction`：原文本仍在网格中，Event/Cell/Snapshot Debug与已开启trace不显示合成正文；产品特性关闭log时验证无记录。测试只使用公开合成文本。
3. `python3 tools/test_bridge_error_boundaries.py`三项：raw字符串/字符/嵌套注释伪函数、同步/异步与私有方法区分、测试数据排除。然后执行源码清单检查。
4. 最终FRB正规生成/完整编译/Clippy/Flutter Analyze与原Native/输入/复制/传输/备份/同步回归；重点审查通用错误摘要是否使需要处理的失败失去可操作提示，必要时添加明确类型化摘要，不能恢复任意原文。
5. Windows/Android目标平台的异常和OS错误仍须实际验证，Ubuntu不能代替。

参考：[log编译期过滤](https://docs.rs/log/latest/log/#compile-time-filters)。FRB当前行为直接核对本仓库既有生成源码及固定版本公开crate源；本批没有读取账号、密码、私钥或真实服务错误来进行验证。


## 续批：函数体panic与默认hook（仍未统一验证）

202个入口现为195个原异步Future的AssertUnwindSafe/catch_unwind及7个原同步闭包的catch_unwind。原业务直接在原请求Future内运行；不spawn额外工作，不因调用方取消留下新的无主任务。异常展开按Rust规则释放实际局部owner，既有blocking worker仍按原独立owner等待。panic返回固定的未确认、需保留状态并重启错误，不当作成功或允许自动重试，不能推断所有中途修改均回滚。

受保护调用首次执行前初始化原固定诊断store，再安装一次应用自有panic hook。原hook可能直接打印敏感panic payload，故不转调；只try_lock记录CoreWorkerPanicked固定元数据。锁占用时累计到原dropped字段而不阻塞hook；不格式化payload/来源位置，不写文件/stderr或保存异常正文。诊断UI有明确失败标签；新枚举尚未生成绑定。

新增Rust3项源码验证Future实际Drop、同步秘密panic不回显、诊断锁持有时不阻塞；Python新增旧边界迁移1项，全部待统一执行。实际只执行源码迁移/202清单/格式解析。最后统一测试应运行7项公开错误/诊断新测试及Core Debug、Python4项；旧测试不可删除。

这里使用unwind防护，不能捕获panic=abort、栈溢出或C++/平台异常，也未覆盖函数体之前的全部FFI解码路径。原处理器中途语义状态未作全局“恢复成功”保证，应用明确提示重启；panic后不自动重连、不自动重放写入。
