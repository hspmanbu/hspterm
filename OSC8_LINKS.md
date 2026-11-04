# 终端 OSC 8 链接

V1.4 §4。沿用 VTE/Alacritty 单元属性解析，并修正URI多分号截断、取消时部分目标提交和非法UTF-8误当关闭的问题；仅完整ST/BEL生效，不从显示文字反推目标，不向 SSH 写入链接或注释。语法参考 [终端超链接协议说明](https://raw.githubusercontent.com/gnachman/iterm2-website/master/source/feature-reporting/Hyperlinks_in_Terminal_Emulators.md)；实际兼容范围以测试和代码为准。

网格在保留属性前限制URI/id为4096/1024 UTF-8字节，超长URI保留空的不可激活属性，避免历史重复序列化巨大目标；超长id使用正常生成身份，不将URI写trace。Snapshot 共享原 Hyperlink 属性，冷历史仍按原加密单元序列保存，Reflow 使用原算法。RenderRow 用半开物理列范围传输链接，每个连续范围只传一个 URI；文字、宽字符/组合字符、复制、搜索和 UTF-8 导出保持原始内容。增量比较包括链接属性，即使标签文字不变而目标改变，也发布该行；无变化不重复发送。Controller 保留未变化行的元数据，覆盖/全帧/尺寸变化时替换或清除，不从另一会话借用。

桥接每补丁最多扫描64K单元、2048 范围/256KiB URI，单 URI 最多4096字节；URI超限的范围显式无目标，范围预算不足时屏蔽整行。屏蔽不能回退激活另一条标签中看似正常的 URL。只根据实际点击单元判断隐藏属性，不把隐藏内容作为 tooltip。

当前 HTTP(S) 激活复用完整目标悬停、Windows式 Ctrl+Click/本地菜单、原会话确认、系统浏览器及回环地址临时转发流程。悬停不访问网络，不下载网页；确认界面显示真正 URI。带用户信息、控制字符、双向控制、非法端口或其他方案不打开。远端鼠标捕获优先，Shift维持原本地覆盖路径。file:// 采用独立 remoteFileUri 字段，只在原 SSH 的关联 SFTP 定位，绝不交本机系统/浏览器或当作端口转发；未知方案仍不打开。authority 及严格单次解码在 Rust 按实际 SSH 目标复核，详TERMINAL_PATHS.md。path:line 扩展和 Android 长按入口仍待接。

断线保留历史中的普通网页链接，显式浏览器打开不重连 SSH；回环转发仍要求原有效连接。新 PTY 不继承旧光标链接模板；旧历史只保留原单元属性。链接元数据不进入配置同步、备份或命令历史。

测试源码：term-core/tests/hyperlinks.rs、frb-bridge/src/frame 及 hyperlinks；Flutter osc8_test、osc8_bridge_test，GTK integration_test/osc8_test。最终term-core58/VTE56/frame3/Native及真实Codex8项通过；新解析补丁前完整Flutter217项5:37通过，补丁后另做Native/输入专项，最后普通/OSC8 URL控制字符组件5项通过；真实GTK悬停/点击9秒、原链接→确认/取消/临时转发/失败局部清理13秒通过。all-target Clippy、Analyze、NDK共享核心check及正式debug/release真实窗口启动/resize/退出均通过。首轮滚动溢出和旧多分号截断失败日志、夹具隐藏取帧超时已保留，详情见PROGRESS归档。

远端 file URI 批次：完整终端核心60、Bridge33、严格Clippy/Analyze/NDK共享核心检查通过；全Flutter229项5:37通过。最后补强普通file URI的标点保留/拒绝引号边界歧义后，相关纯Dart/OSC8捕获及Shift覆盖/浏览器spy/真实双SSH专项10项6秒通过；不把早先全量与最后专项混为同一次运行。真实GTK原路径选择/OSC8 file hover不联网→CtrlClick选中原会话隐藏文件/主机保存跟随同文件一项17秒通过。首轮GTK夹具重复PointerAdded失败，复用原鼠标生命周期后通过，未改生产鼠标路由。截图validation/phase3b/remote-file-uri.png仅私有服务器合成内容，已查看。正式双模式构建/独立启动结果及哈希见PROGRESS。

- 2026-11-03普通path:line[:col]显示识别及原会话确认定位已有新源码，详TERMINAL_PATHS最新节，未统一验证；覆盖上文“path:line仍待接”的旧状态。显式OSC8仍不接纳裸路径，不能回落激活标签；Android入口仍暂停。
