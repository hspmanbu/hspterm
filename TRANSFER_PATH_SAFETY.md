# SSH 文件传输的本地路径映射

远端清单保留 POSIX 路径。Windows 写入前逐个检查原始 POSIX 分量，再拼接本地路径，防止反斜杠或盘符被本机路径解析器重新解释。无法表示的名称明确失败，不清洗、截短或悄悄换名；普通兄弟文件继续。用户明确为单个文件更名后，可使用新的目标名。

Rust `local_path` 在文件读写和目录创建前检查 Windows 名称、保留设备别名（含扩展名/大小写/上标数字）、数据流、尾随点/空格、控制字符及设备命名空间。接受普通盘符、UNC、长路径盘符/UNC和格式正确的卷GUID前缀。根目录由用户选择，远端相对分量不得改变根。它不代替原有打开后句柄类型、符号链接及重解析点检查。

依据：[Microsoft 文件与命名空间规则](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file)、[控制台句柄名称](https://learn.microsoft.com/en-us/windows/console/console-handles)。保留名采用保守处理；非普通Win32文件名称返回可归因错误，不尝试访问原始设备。Unix/Android不套用这些名称限制；真实OpenSSH验证NUL.txt、冒号、反斜杠、尾随点/空格、换行、中文/组合字符原样双向传输。

单文件任务更名同时更新实际目标和加密检查点/UI路径，源路径不变；旧目标与部分数据不删除。文件夹内部更名只改该节点。真实FRB测试检查单文件上传/下载更名后路径、内容和旧文件保留。

## 已做和待做的验证

- Ubuntu单元测试运行Windows名称/分量/卷GUID规则及POSIX不误限规则；真实OpenSSH执行POSIX特殊名传输。
- 已安装x86_64-pc-windows-gnu标准库，以真正Windows目标对`local_path.rs`库和测试代码执行`rustc --emit=metadata -D warnings`。这是单个纯Rust模块的编译检查，未链接或运行Windows程序，不是整个Windows工作区/Flutter构建。
- Windows11仍需运行`cargo test -p hspterm-ssh-core --lib local_path --locked`，再在独立临时目录做受控SSH下载：合法兄弟项成功，保留名/流名/别名项明确失败；哨兵普通文件及其数据流未被更改。仅在单元断言中验证物理设备/管道路径拒绝，不对原始磁盘或设备实际执行I/O。
- 验证文件/父目录在实际NTFS、UNC、大小写、junction/reparse/cloud文件、长路径下的行为，以及明确更名/取消/重开库续传。Ubuntu逻辑与模块编译不能替代这些检查。Android SAF另有授权/命名规则，本模块不是SAF实现。

Ubuntu复现独立模块检查（不生成可运行Windows程序）：

```sh
mkdir -p .local
rustup target add x86_64-pc-windows-gnu
rustc --edition 2024 --target x86_64-pc-windows-gnu --emit=metadata --crate-type lib crates/ssh-core/src/local_path.rs -o .local/local-path-windows.rmeta -D warnings
rustc --edition 2024 --target x86_64-pc-windows-gnu --emit=metadata --test crates/ssh-core/src/local_path.rs -o .local/local-path-tests-windows.rmeta -D warnings
```
