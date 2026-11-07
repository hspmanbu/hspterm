import 'package:hspterm/prototype/model.dart';

/// WorkbenchModel fixture for the round-9 column tests: the demo workspace
/// with permission/owner metadata attached and a remembered column layout.
class ColumnHost extends WorkbenchModel {
  ColumnHost() {
    demo();
    final session = sessions.first;
    session.files.addAll([
      DemoFile(
        '/home/ubuntu/project/perm-a.txt',
        'perm-a.txt',
        kind: '文本',
        permissions: 0x81a4,
        owner: 'ubuntu',
      ),
      DemoFile(
        '/home/ubuntu/project/perm-dir',
        'perm-dir',
        folder: true,
        kind: '文件夹',
        permissions: 0x41ed,
        owner: 'ubuntu',
      ),
      DemoFile(
        '/home/ubuntu/project/perm-b.bin',
        'perm-b.bin',
        permissions: 0x8180,
        owner: '1001',
      ),
    ]);
    _remembered[session.host.id] = SftpColumnLayout(
      order: const ['name', 'owner', 'modified', 'size', 'kind', 'permissions'],
      hidden: const <String>{},
      widths: const {'name': 210.0, 'owner': 96.0},
    );
  }

  final Map<String, SftpColumnLayout> _remembered = {};
  final List<(String, SftpColumnLayout)> recorded = [];

  @override
  SftpColumnLayout? rememberedColumns(String hostId) => _remembered[hostId];

  @override
  void rememberColumns(String hostId, SftpColumnLayout layout) {
    _remembered[hostId] = layout;
    recorded.add((hostId, layout));
  }
}
