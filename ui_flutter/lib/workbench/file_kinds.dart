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
  if (symlink) return folder ? '目录链接' : '符号链接';
  if (folder) return '文件夹';
  final base = name.toLowerCase();
  if (const {
        'dockerfile',
        'containerfile',
        'makefile',
        'gnumakefile',
        'cmakelists.txt',
        'justfile',
        'vagrantfile',
        'procfile',
        '.gitignore',
        '.gitattributes',
        '.dockerignore',
        '.editorconfig',
        '.bashrc',
        '.zshrc',
        '.profile',
        '.env',
        'cargo.lock',
        'go.mod',
        'go.sum',
        'package-lock.json',
        'yarn.lock',
        'pnpm-lock.yaml',
      }.contains(base) ||
      base.startsWith('.env.')) {
    return '配置文件';
  }
  if (base == 'license' ||
      base == 'copying' ||
      base == 'authors' ||
      base == 'changelog') {
    return '文本';
  }
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  return switch (ext) {
    'md' || 'markdown' => 'Markdown',
    'log' => '日志',
    'txt' || 'rst' || 'rtf' || 'adoc' || 'tex' => '文本',
    'json' => 'JSON',
    'yaml' || 'yml' => 'YAML',
    'xml' => 'XML',
    'csv' || 'tsv' => 'CSV',
    'ini' || 'conf' || 'cfg' || 'toml' || 'env' || 'properties' => '配置文件',
    'py' || 'pyw' => 'Python',
    'sh' || 'bash' || 'zsh' => 'Shell',
    'js' || 'mjs' || 'cjs' || 'jsx' => 'JavaScript',
    'ts' || 'tsx' => 'TypeScript',
    'rs' => 'Rust',
    'go' => 'Go',
    'java' || 'class' || 'jar' => 'Java',
    'kt' || 'kts' => 'Kotlin',
    'cs' || 'fs' || 'vb' => '.NET',
    'swift' || 'm' || 'mm' => 'Swift/Objective-C',
    'php' ||
    'rb' ||
    'lua' ||
    'pl' ||
    'r' ||
    'dart' ||
    'scala' ||
    'vue' ||
    'svelte' => '源代码',
    'ipynb' => 'Notebook',
    'sql' => 'SQL',
    'c' || 'h' => 'C',
    'cpp' || 'cc' || 'cxx' || 'hpp' || 'hxx' => 'C++',
    'css' || 'scss' || 'sass' || 'less' => 'CSS',
    'html' || 'htm' => 'HTML',
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'bmp' ||
    'webp' ||
    'svg' ||
    'ico' ||
    'avif' ||
    'heic' ||
    'tif' ||
    'tiff' ||
    'psd' => '图片',
    'mp3' ||
    'wav' ||
    'flac' ||
    'ogg' ||
    'm4a' ||
    'aac' ||
    'opus' ||
    'wma' => '音频',
    'mp4' ||
    'mkv' ||
    'avi' ||
    'mov' ||
    'webm' ||
    'm4v' ||
    'mpeg' ||
    'mpg' ||
    'flv' => '视频',
    'pdf' => 'PDF',
    'doc' || 'docx' => 'Word',
    'xls' || 'xlsx' => 'Excel',
    'ppt' || 'pptx' => 'PowerPoint',
    'zip' ||
    '7z' ||
    'rar' ||
    'tar' ||
    'gz' ||
    'bz2' ||
    'xz' ||
    'zst' ||
    'tgz' ||
    'tbz2' ||
    'txz' => '压缩包',
    'apk' || 'aab' || 'deb' || 'rpm' || 'appimage' || 'msix' => '安装包',
    'ttf' || 'otf' || 'woff' || 'woff2' => '字体',
    'bin' || 'dat' || 'wasm' => '二进制',
    'exe' || 'msi' || 'bat' || 'cmd' || 'ps1' => '可执行',
    'so' || 'dll' || 'dylib' || 'a' => '动态库',
    'iso' || 'img' => '磁盘映像',
    'db' || 'sqlite' || 'sqlite3' || 'mdb' => '数据库',
    'pem' ||
    'key' ||
    'crt' ||
    'pub' ||
    'cer' ||
    'p12' ||
    'pfx' ||
    'der' => '密钥',
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
