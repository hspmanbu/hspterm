import 'lost_rename_reply_sftp.dart';

/// Same owned OpenSSH proxy as the rename fixture, but drops a successful
/// REMOVE response. The destination uses a separate ordinary SFTP server.
/// Logs only a bounded synthetic operation count, never packet payloads.
String get lostRemoveReplySftp {
  const marker = 'if packet[4]==18:';
  if (!lostRenameReplySftp.contains(marker)) {
    throw StateError('shared controlled mutation fixture changed');
  }
  return lostRenameReplySftp
      .replaceFirst(marker, 'if packet[4]==13:')
      .replaceAll('.rename-count', '.remove-count');
}
