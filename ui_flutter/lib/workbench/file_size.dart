/// Display only; sorting and transfers keep the original byte count.
String remoteFileSize(int? bytes) {
  if (bytes == null) return '—';
  if (bytes > 0 && bytes < 11) return '<0.01 KB';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 2 : 1)} KB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(mib < 10 ? 2 : 1)} MB';
  return '${(mib / 1024).toStringAsFixed(2)} GB';
}
