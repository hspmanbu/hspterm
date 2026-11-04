/// Device-only metadata. A review is bound in Rust to an original task, vault,
/// actual target, generation and checkpoint. UI maps never grant authority.
abstract interface class StagingCleanupPort {
  Future<Map<String, dynamic>> stagingTasks(int offset);
  Future<Map<String, dynamic>> stagingInventory(String id, int offset);
  Future<Map<String, dynamic>> prepareStaging(
    String id,
    String host,
    int index,
  );
  Future<void> applyStaging(
    String id,
    String host,
    String ticket,
    bool uncertain,
  );
  Future<Map<String, dynamic>> prepareStagingEnd(String id);
  Future<void> endStagingWait(String id, String ticket);
}
