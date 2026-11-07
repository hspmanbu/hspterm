//! Local SFTP file classification (round-9): extension + listing metadata
//! only — never remote reads. Produces the human-readable kind label used by
/// the type column and the icon mapping in the file list.
library;

/// Returns the display kind for a listing entry. Metadata (folder/symlink)
/// wins over the extension; unknown extensions fall back to 文件.
String sftpFileKind(
  String name, {
  required bool folder,
  required bool symlink,
}) {
  if (symlink) return '符号链接';
  if (folder) return '文件夹';
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  return switch (ext) {
    'md' || 'markdown' => 'Markdown',
    'log' => '日志',
    'txt' => '文本',
    'json' => 'JSON',
    'yaml' || 'yml' => 'YAML',
    'xml' => 'XML',
    'csv' || 'tsv' => 'CSV',
    'ini' || 'conf' || 'cfg' || 'toml' || 'env' || 'properties' => '配置文件',
    'py' || 'pyw' => 'Python',
    'sh' || 'bash' || 'zsh' => 'Shell',
    'js' || 'mjs' || 'cjs' => 'JavaScript',
    'ts' || 'tsx' => 'TypeScript',
    'rs' => 'Rust',
    'go' => 'Go',
    'java' => 'Java',
    'c' || 'h' => 'C',
    'cpp' || 'cc' || 'hpp' => 'C++',
    'css' => 'CSS',
    'html' || 'htm' => 'HTML',
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'bmp' ||
    'webp' ||
    'svg' ||
    'ico' => '图片',
    'mp3' || 'wav' || 'flac' || 'ogg' || 'm4a' => '音频',
    'mp4' || 'mkv' || 'avi' || 'mov' || 'webm' => '视频',
    'pdf' => 'PDF',
    'doc' || 'docx' => 'Word',
    'xls' || 'xlsx' => 'Excel',
    'ppt' || 'pptx' => 'PowerPoint',
    'zip' || '7z' || 'tar' || 'gz' || 'bz2' || 'xz' || 'zst' || 'tgz' => '压缩包',
    'exe' || 'msi' || 'bat' || 'cmd' || 'ps1' => '可执行',
    'so' || 'dll' || 'dylib' || 'a' => '动态库',
    'iso' || 'img' => '磁盘映像',
    'db' || 'sqlite' => '数据库',
    'pem' || 'key' || 'crt' || 'pub' => '密钥',
    _ => '文件',
  };
}

/// Renders Unix permission bits as an `ls`-style string, e.g. `rwxr-xr-x`,
/// with the leading type character from the metadata. `null` → `—`.
String permissionString(
  int? mode, {
  bool folder = false,
  bool symlink = false,
}) {
  if (mode == null) return '—';
  final type = symlink
      ? 'l'
      : folder
      ? 'd'
      : '-';
  String triple(int shift) {
    final bits = (mode >> shift) & 7;
    return '${bits & 4 != 0 ? 'r' : '-'}${bits & 2 != 0 ? 'w' : '-'}${bits & 1 != 0 ? 'x' : '-'}';
  }

  return '$type${triple(6)}${triple(3)}${triple(0)}';
}
