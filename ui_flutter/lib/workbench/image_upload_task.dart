/// Ephemeral queue metadata. PNG bytes remain on disk and in bounded SFTP chunks.
class ImageUploadTask {
  ImageUploadTask(this.session, this.host);
  final String session, host;
  String? path;
  String? localPath;
  int done = 0;
  int? total;
  String state = '读取剪贴板', error = '';
  bool ended = false;
  bool get succeeded => ended && error.isEmpty && path != null;
  void apply(Map<String, dynamic> snapshot) {
    if (ended || snapshot.isEmpty) return;
    final remote = snapshot['path'],
        bytes = snapshot['done'],
        size = snapshot['total'];
    if (remote is! String ||
        !remote.startsWith('/') ||
        bytes is! int ||
        size is! int ||
        size < 0 ||
        bytes < 0 ||
        bytes > size) {
      throw const FormatException('图片上传进度无效');
    }
    path = remote;
    done = bytes;
    total = size;
    state = '上传中';
  }
}
