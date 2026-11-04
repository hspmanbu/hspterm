# Windows 连续编制期间的源码审核

当前用户策略是全部编码/源码审核在前，统一依赖锁、FRB生成、编译/Analyze/Clippy和测试在后。本文不将词法扫描当作类型检查、构建、运行或验收通过。最后完整已验证节点仍为PROGRESS所列0e96be4。

## 可重复的只读接口检查

```bash
cd /opt/hspterm
PYTHONDONTWRITEBYTECODE=1 python3 tools/bridge_contracts.py
```

2026-11-03：230个Rust公开API函数、72个唯一命名Bridge公开数据结构、259个Flutter lib/test/integration_test源码文件，直接命名调用检查0项发现。没有生成/读取旧绑定作为真值，没有解析依赖或编译/运行应用。数据字段值类型和生命周期仍须后续真正工具检查。

工具按Rust词法读取根api.rs公开函数与Bridge唯一命名的公开结构字段，忽略test模块、方法和重复歧义结构；只处理Flutter实际导入src/rust/api.dart的别名函数调用，以及实际Rust导入的已知结构构造。检查参数/字段名及非Option的必填项，StreamSink为FRB隐式参数。Dart注释、raw/triple/嵌套插值字符串不当作可执行调用；只识别调用顶层逗号之后的命名标签，不把三元表达式的属性名当参数。首次扫描的唯一结果是工具将`condition ? one.path : other.path`误判为path参数，已修正扫描器；没有据此改动正确业务源码。

明确边界：不处理字符串插值中的表达式、动态调用、函数tear-off、泛型公开函数、同名歧义结构或跨crate导入结构的完整解析；不判断Rust/FRB/Dart类型兼容、Option生成行为、异步资源退休、平台库、ABI及缺少生成导入。生成器版本/绑定/Native库必须在统一阶段按正式脚本重建，0项词法发现不表示全量静态审核完成。

新增6项扫描器回归测试源码在tools/test_bridge_contracts.py，未运行。最终统一测试阶段须连同原bridge_error_boundaries测试执行，不能把运行本只读扫描工具算成执行回归测试。

## 其他源码检查

- `cargo fmt --all`/Dart format只证明语法格式器可解析，不替代编译和Analyze。
- `tools/bridge_error_boundaries.py --write`维护公开Result错误边界和精确公共摘要；它不验证全体业务错误/FFI/运行时安全。
- `tools/requirements_coverage.py`生成需求覆盖文档，不是产品功能测试。
- `git diff --check`只检查差异中的空白错误，不替代语义或资源审核。

Windows实机、Android暂停与Shell输入证明的需求冲突仍按PROGRESS和AGENTS管理；所有未运行新增测试保留，不能删除失败或伪造完成度。

## 正式点击路径复核续接

按ecc:click-path-audit先建立状态sets/resets映射，再审核主机、SFTP导航及危险确认、设置和终端退出。源码修正主机保存旧对象/密钥ACK、目录历史竞争/确认代次、失败关闭所有权与重试，并补设置未保存跨页保护和原目录快照。具体测试源码数量/未运行状态见PROGRESS；没有以源码推导代替真实点击验收。最新接口词法扫描为233函数/73唯一结构/268个Dart源0发现，仍有本文明确盲区。

通知“查看终端”原绕过离页保护的源码路径已改为PrototypeAppState.activateTab，与普通标签共用guard和确认后存活检查；Windows窗口激活不代表授权丢弃草稿。新增两项组件回归源码未运行，不能据此称Windows通知实测通过。

2026-11-03续批：逐层核对传输任务→本地选择对话框→冻结引用→Model→Native恢复入口→原连接/实际身份检查；增加Native可选generation并在固定错误摘要清单登记。队列测试Fake override已同步新增可选参数，原真实单/双端Native测试已编制错误代次拒绝且目标不变分支。所有新测试未运行。最新词法扫描233 API/73唯一结构/270 Dart文件0项。非生成Dart相对import/export/part文件检查未发现缺失；diagnostics.dart、host_bulk.dart、transfers/explorer.dart三类新生成导入尚缺，属于最终正规FRB生成工作，不能以旧绑定代替。

需求覆盖生成器已纠正旧“快捷键/主列表拖排/高级批改/云独立代理/历史云与备份完全未接”的记录；现在区分旧Ubuntu已验与后续静态源码未验证，并登记通知/历史开关离页保护和显式双端恢复选择。175条索引包含Android/架构/验收与复合要求，不能把源码文件存在或索引数量换算成已验百分比。可靠Shell编辑状态/敏感输入证明仍无批准方案，候选及直接路径注入不因此开放。

2026-11-03本批：用户已明确允许逐主机主动可选Shell集成，旧“无批准方案”已解除。按actor→核心Proof/计划→助手实际比较→数字回执→Native单次候选→Flutter覆盖层→源SFTP路径逐层复核，修复PS1后缀重复、控制锁重入、失败回执退休、候选旧鼠标票据、拖动文件对象可变及controller替换预编辑残留。新增API仍需正规FRB；格式解析和词法0项不表示类型/ABI/行为验证。15项新增测试源码未运行。当前236函数/74结构/277Dart源，实际最后证据看PROGRESS；Android暂停，无Windows实机通过声明。

续批：提前FRB runtime初始化hook及两个真实Dart入口的未处理异常边界已编制；本机SDK核对ErrorWidget.message/withDetails，移除旧验收入口的原生加载异常全文输出，关闭失败保留原owner。Native历史清空/开关与已接受在途SQL批次加入epoch复核；Bash包处理先耗尽有界正文再拒绝失去Ready，初始allexport不安装私有变量。新增跨会话/旧代次实际Flutter拖放及不支持allexport的真实隔离SSH测试源码；均未运行，不能据此称通过。Python17文件仅AST解析，不执行其中测试。最后全量静态工具/平台验证仍按用户统一收尾策略。
