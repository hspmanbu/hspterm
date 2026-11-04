import 'dart:convert';

class SyncReferenceChoice {
  SyncReferenceChoice(Map<String, dynamic> v)
    : id = v['id'] as String,
      label = v['label'] as String,
      localAvailable = v['local_available'] as bool,
      remoteAvailable = v['remote_available'] as bool,
      localDeleted = v['local_deleted'] as bool,
      remoteDeleted = v['remote_deleted'] as bool,
      winner = v['winner'] as String,
      localGroup = v['local_group'] as String?,
      remoteGroup = v['remote_group'] as String?,
      localJump = v['local_jump'] as String?,
      remoteJump = v['remote_jump'] as String? {
    if (v.length != 11 ||
        !v.keys.toSet().containsAll({
          'id',
          'label',
          'local_available',
          'remote_available',
          'local_deleted',
          'remote_deleted',
          'winner',
          'local_group',
          'remote_group',
          'local_jump',
          'remote_jump',
        }) ||
        id.isEmpty ||
        id.length > 256 ||
        id.runes.any((n) => n < 32 || n == 127) ||
        label.runes.length > 80 ||
        !['local', 'remote'].contains(winner) ||
        (!localAvailable && !remoteAvailable) ||
        localDeleted && !localAvailable ||
        remoteDeleted && !remoteAvailable ||
        winner == 'local' && !localAvailable ||
        winner == 'remote' && !remoteAvailable ||
        [
          localGroup,
          remoteGroup,
          localJump,
          remoteJump,
        ].whereType<String>().any(
          (s) => s.length > 64 || s.runes.any((n) => n < 32 || n == 127),
        )) {
      throw const FormatException('同步引用选项元数据无效');
    }
  }
  final String id, label, winner;
  final bool localAvailable, remoteAvailable, localDeleted, remoteDeleted;
  final String? localGroup, remoteGroup, localJump, remoteJump;
}

/// Top-level for compute(): potentially large metadata decoding stays off the
/// Flutter frame/input isolate. Native already enforces bounded configuration.
List<SyncReferenceChoice> parseSyncReferences(String value) {
  final rows = jsonDecode(value) as List;
  if (rows.isEmpty || rows.length > 24000) {
    throw const FormatException('同步引用选项数量无效');
  }
  final result = rows
      .map((row) => SyncReferenceChoice(row as Map<String, dynamic>))
      .toList(growable: false);
  if (result.map((v) => v.id).toSet().length != result.length) {
    throw const FormatException('重复引用选项');
  }
  return List.unmodifiable(result);
}
