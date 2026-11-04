# 主机顺序、分组与收藏

正式工作台「主机管理」右上角排序按钮打开批量工具。拖动握柄调整分组/主机顺序，拖动主机到分组或收藏，多选后可统一修改分组和收藏。搜索跨全部分组平铺；清空搜索回到原分组筛选。列表按需构建，紧凑双行显示主机及端点。

所有修改先留在内存提案，点击保存后预览影响，确认才原子写入配置库。关闭未保存提案须确认放弃。载入失败禁止保存空列表；事务失败保留提案供明确重试。已保存而界面刷新失败会显示“排序已保存，但列表刷新失败”，不会把旧提案自动重放。打开工具前照常处理未保存主机表单。

## 边界与持久化

- `storage-sync/src/repository/ordering.rs`、`frb-bridge/src/host_ordering.rs` 与 `workbench/host_ordering.dart`。绑定由FRB2.13生成。
- 排序快照绑定原Vault实例和全部主机元数据修订，范围只含原有分组/主机完整排列、分组归属和收藏。重开同库、切库或其他元数据已改变时，旧提案拒绝覆盖。分组标签与导航桶身份分开；用户可把真实分组命名为“收藏”或“全部主机”。
- Catalog及变动主机行通过比较原文的SQLite事务发布；只改分组/收藏字段。不读取或改写独立凭据、密钥正文、未保存草稿，不创建/断开/重连SSH，不改变既有终端和SFTP对象。
- 保留旧记录缺省字段；未知新字段拒绝编辑并保留原文，不用旧结构反序列化后静默抹去新数据。组/主机不得遗漏、重复、新建或删除。变动行成对明文总预算8MiB，超过要求分批修改，不部分保存；纯排序仍可操作大备注主机。限制不代替既有单记录和Catalog容量限制。
- 跨窗口拖放绑定原提案对象，重新载入后旧拖动失效。确认前冻结提交，等待期间禁用编辑与关闭；后台无限进度只在实际读写阶段显示。退出等待Model追踪的在途保存。
- 排序是正式Catalog/配置数据，未来加密同步/备份应保留；运行期Vault scope/revision不是配置，不同步。现阶段完整同步/备份尚未接入。

## 验证与恢复

Rust仓库测试覆盖真实临时加密库重开、凭据/草稿保持、另一连接修改、未来字段拒绝、数据库故障事务回滚和容量失败。Flutter测试覆盖实际拖放、确认取消、错误保留/明确重试、保存后刷新错误、载入失败、窄窗与缩放、导航名称重名与跨组搜索。Native测试在私有OpenSSH连接上排序后继续使用原SSH/PTY/SFTP与独立凭据，并检查旧快照/切库/同库重开失效。GTK测试使用私有真实配置库和保留域名`.invalid`的合成主机，不尝试连接。

执行命令（根目录先设置PATH、CARGO_INCREMENTAL=0、CARGO_BUILD_JOBS=2）：

```sh
cargo test -p hspterm-storage-sync --lib --locked
cargo test -p hspterm-frb-bridge --lib --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cd ui_flutter
flutter analyze
flutter test --reporter expanded
python3 benchmark/external_editor_gtk.py flutter test integration_test/host_ordering_test.dart -d linux --reporter expanded
```

GUI测试后重新构建正式`-t lib/workbench_main.dart`，不要交付测试入口。具体本轮结果、失败修正、截图、SO和启动指标见PROGRESS。

## 尚未完成

本工具不替代V1.4规定的主机管理独立页面。主页面已保留原列表/编辑、收藏、多选与搜索入口；主列表直接分组树拖排、完整非敏感高级批改、部分右键/键盘入口仍待开发，不能把§5.2整条标完成。当前Linux测试不证明Windows真实拖放/键盘/DPI或Android运行通过；无自动云同步、无批量凭据修改。
