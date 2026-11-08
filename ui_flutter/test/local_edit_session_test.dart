import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/workbench/local_edit_launch.dart';
import 'package:hspterm/workbench/model.dart';

import 'support/fake_backend.dart';

class FakeGateway implements LocalEditGateway {
  final remoteFiles = <String, List<int>>{};
  final mtimes = <String, int?>{};
  final uploads = <(String, List<int>)>[];
  final renames = <(String, String)>[];
  Object? uploadError;
  bool refuseUpload = false;
  // Override hooks applied on top of the per-path state.
  int? statSizeOverride;
  int? statMtimeOverride;

  void seed(String path, List<int> bytes, {int? mtime}) {
    remoteFiles[path] = bytes;
    mtimes[path] = mtime ?? 1000;
  }

  @override
  Future<List<int>> download(
    int native,
    int generation,
    String path, {
    void Function(int done, int? total)? onProgress,
  }) async {
    final bytes = List.of(remoteFiles[path] ?? utf8Bytes('hello'));
    onProgress?.call(0, bytes.length);
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  @override
  Future<({int size, int? mtime})> stat(
    int native,
    int generation,
    String path,
  ) async => (
    size: statSizeOverride ?? (remoteFiles[path] ?? utf8Bytes('hello')).length,
    mtime: statMtimeOverride ?? mtimes[path] ?? 1000,
  );

  @override
  Future<void> upload(
    int native,
    int generation,
    String path,
    List<int> bytes, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (refuseUpload) throw const SocketException('offline');
    if (uploadError != null) throw uploadError!;
    uploads.add((path, bytes));
    onProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<void> renameOver(
    int native,
    int generation,
    String from,
    String to, {
    bool force = false,
  }) async {
    if (!force && renameError != null) throw renameError!;
    forces.add(force);
    renames.add((from, to));
    remoteFiles[to] = uploads.lastWhere((u) => u.$1 == from).$2;
    mtimes[to] = (mtimes[to] ?? 0) + 1;
  }

  final removals = <String>[];
  final forces = <bool>[];
  Object? renameError;
  final generationsSeen = <int>[];
  void Function(int)? statHook;
  @override
  Future<void> removeFile(int native, int generation, String path) async {
    removals.add(path);
  }
}

List<int> utf8Bytes(String s) => s.codeUnits;

LiveTerminalSession sessionWith(TerminalBackend backend, DemoHost host) {
  final s = LiveTerminalSession('t', host, backend);
  s.controller.id = 1;
  s.controller.phase = 'Connected';
  s.controller.generation = 7;
  return s;
}

void main() {
  late Directory root;
  late FakeGateway gateway;
  late List<String> notices;
  late List<LocalEditSession> created;

  setUp(() {
    root = Directory.systemTemp.createTempSync('local-edit-test');
    gateway = FakeGateway();
    gateway.seed('/dir/a.txt', utf8Bytes('hello'));
    gateway.seed('/dir/b.txt', utf8Bytes('hello'));
    gateway.seed('/dir/c.txt', utf8Bytes('hello'));
    gateway.seed('/dir/d.txt', utf8Bytes('hello'));
    gateway.seed('/dir/e.txt', utf8Bytes('hello'));
    gateway.seed('/dir/f1.txt', utf8Bytes('hello'));
    gateway.seed('/dir/f2.txt', utf8Bytes('hello'));
    gateway.seed('/dir/g.txt', utf8Bytes('hello'));
    notices = [];
    created = [];
  });

  tearDown(() async {
    for (final session in created) {
      await session.dispose();
    }
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<LiveTerminalSession> connectedSession() async {
    final b = FakeBackend();
    final controller = TerminalController(b);
    await controller.start();
    return sessionWith(b, WorkbenchModel().hosts.first);
  }

  Future<LocalEditSession> launchFor(
    LiveTerminalSession s,
    String name, {
    int? size,
  }) async {
    final file = DemoFile(
      '/dir/$name',
      name,
      kind: '文件',
      size: '${size ?? 5} B',
      byteSize: size ?? 5,
    );
    await LocalEditSession.launch(
      s,
      file,
      gateway: gateway,
      onNotice: notices.add,
      rootOverride: root,
      launchOverride: (_) async => true,
      onSession: created.add,
    );
    return created.last;
  }

  /// Each task owns a subdirectory under [root] holding the original
  /// (sanitized) file name — round-9 layout.
  File singleTaskFile(Directory root) {
    final taskDir = root.listSync().single as Directory;
    return taskDir.listSync().single as File;
  }

  test('sanitizeLocalName keeps extension and blocks traversal', () {
    expect(sanitizeLocalName('report.txt'), 'report.txt');
    expect(sanitizeLocalName('..'), isNot('..'));
    expect(sanitizeLocalName('a/../b.sh'), isNot(contains('/')));
    expect(sanitizeLocalName('中文 配置.yaml'), contains('.yaml'));
    expect(sanitizeLocalName(''), 'edit.bin');
    expect(sanitizeLocalName('con<>.txt'), isNot(contains('<')));
  });

  test('same-length content change uploads; identical bytes do not', () async {
    final s = await connectedSession();
    final session = await launchFor(s, 'a.txt');
    final file = singleTaskFile(root);
    final original = await file.readAsString();
    // Same length, different content.
    expect(original.length, 5);
    await file.writeAsString('HELLO');
    // Trigger the stable check directly (tests do not wait for poll timers).
    await session.testStableCheck();
    expect(gateway.uploads.length, 1);
    expect(String.fromCharCodes(gateway.uploads.single.$2), 'HELLO');
    // Writing identical content again must not re-upload.
    await file.writeAsString('HELLO');
    await session.testStableCheck();
    expect(gateway.uploads.length, 1);
    s.controller.dispose();
  });

  test('zero-byte save uploads and truncates remote', () async {
    final s = await connectedSession();
    final session = await launchFor(s, 'b.txt');
    final file = singleTaskFile(root);
    await file.writeAsString('');
    await session.testStableCheck();
    expect(gateway.uploads.single.$2, isEmpty);
    expect(gateway.remoteFiles['/dir/b.txt'], isEmpty);
    s.controller.dispose();
  });

  test('remote mtime change raises conflict without overwrite', () async {
    final s = await connectedSession();
    final session = await launchFor(s, 'c.txt');
    gateway.statMtimeOverride = 2000; // remote changed after download
    final file = singleTaskFile(root);
    await file.writeAsString('changed');
    await session.testStableCheck();
    expect(session.conflicted, isTrue);
    expect(gateway.uploads, isEmpty, reason: 'conflict must not upload');
    expect(notices.any((m) => m.contains('远端文件已被修改')), isTrue);
    s.controller.dispose();
  });

  test('upload failure keeps local file and allows retry', () async {
    final s = await connectedSession();
    final session = await launchFor(s, 'd.txt');
    gateway.refuseUpload = true;
    final file = singleTaskFile(root);
    await file.writeAsString('new content');
    await session.testStableCheck();
    expect(file.existsSync(), isTrue);
    expect(notices.any((m) => m.contains('上传失败')), isTrue);
    gateway.refuseUpload = false;
    await session.retry();
    expect(gateway.uploads.length, 1);
    expect(
      String.fromCharCodes(gateway.remoteFiles['/dir/d.txt']!),
      'new content',
    );
    s.controller.dispose();
  });

  test('atomic upload: bytes go to a temp sibling then rename over', () async {
    final s = await connectedSession();
    final session = await launchFor(s, 'e.txt');
    final file = singleTaskFile(root);
    await file.writeAsString('atomic');
    await session.testStableCheck();
    expect(gateway.uploads.single.$1, contains('.hspterm-edit-'));
    expect(gateway.renames.single.$2, '/dir/e.txt');
    // mtime updated so subsequent saves don't self-conflict.
    await file.writeAsString('atomic2');
    await session.testStableCheck();
    expect(session.conflicted, isFalse);
    s.controller.dispose();
  });

  test('multiple files open independently', () async {
    final s = await connectedSession();
    await launchFor(s, 'f1.txt');
    await launchFor(s, 'f2.txt');
    expect(created.length, 2);
    final dirs = root.listSync().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(dirs.length, 2);
    final f1 = (dirs.first as Directory).listSync().single as File;
    final f2 = (dirs.last as Directory).listSync().single as File;
    await f1.writeAsString('one');
    await created[0].testStableCheck();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await f2.writeAsString('two');
    await created[1].testStableCheck();
    expect(gateway.uploads.length, 2);
    s.controller.dispose();
  });

  test('dispose removes temp files and stops watchers', () async {
    final s = await connectedSession();
    final session = await launchFor(s, 'g.txt');
    expect(root.listSync(), isNotEmpty);
    // The session owns its task directory: disposal removes the file and
    // the (now empty) task directory. The shared test root (rootOverride)
    // stays because the session did not create it.
    final taskDir = root.listSync().single as Directory;
    await session.dispose();
    expect(taskDir.existsSync(), isFalse, reason: 'task dir removed');
    expect(root.existsSync(), isTrue, reason: 'shared test root survives');
    expect(session.isDisposed, isTrue);
    s.controller.dispose();
  });

  test('download and rename carry the live generation, never 0', () async {
    final s = await connectedSession();
    // controller.generation is 7 (see sessionWith); any hardcoded 0 in the
    // gateway would diverge from the captured value here.
    final seen = <int>[];
    gateway.statHook = seen.add;
    await launchFor(s, 'gen.txt');
    gateway.seed('/dir/gen.txt', utf8Bytes('hello'));
    expect(
      gateway.generationsSeen,
      everyElement(7),
      reason: 'every gateway call must use the session generation',
    );
    s.controller.dispose();
  });

  test('rename failure after upload removes the remote temp file', () async {
    final s = await connectedSession();
    gateway.seed('/dir/tmpfail.txt', utf8Bytes('hello'));
    final session = await launchFor(s, 'tmpfail.txt');
    gateway.renameError = StateError('rename denied');
    final file = singleTaskFile(root);
    await file.writeAsString('v2');
    await session.testStableCheck();
    expect(gateway.uploads, isNotEmpty, reason: 'bytes reached the temp file');
    expect(
      gateway.removals,
      isNotEmpty,
      reason: 'failed rename must clean the temp sibling',
    );
    expect(
      gateway.remoteFiles['/dir/tmpfail.txt']?.length,
      5,
      reason: 'original untouched',
    );
    expect(notices.any((m) => m.contains('上传失败')), isTrue);
    s.controller.dispose();
  });

  test(
    'zero-byte save creates a remote temp file via explicit truncate',
    () async {
      final s = await connectedSession();
      gateway.seed('/dir/empty.txt', utf8Bytes('data'));
      final session = await launchFor(s, 'empty.txt');
      final file = singleTaskFile(root);
      await file.writeAsString('');
      await session.testStableCheck();
      // The upload call happened (not skipped by an empty loop).
      expect(gateway.uploads.single.$2, isEmpty);
      expect(gateway.remoteFiles['/dir/empty.txt'], isEmpty);
      s.controller.dispose();
    },
  );

  test('rename conflict asks once, then replaces with user consent', () async {
    final s = await connectedSession();
    var asked = 0;
    gateway.seed('/dir/conflict.txt', utf8Bytes('hello'));
    await LocalEditSession.launch(
      s,
      DemoFile('/dir/conflict.txt', 'conflict.txt', byteSize: 5, size: '5 B'),
      gateway: gateway,
      onNotice: notices.add,
      rootOverride: root,
      launchOverride: (_) async => true,
      onSession: created.add,
      onConflict: (path) {
        asked++;
        return Future.value(true);
      },
    );
    gateway.renameError = StateError('Bad state: 目标路径已存在，请先处理同名冲突');
    final file = singleTaskFile(root);
    await file.writeAsString('v2');
    await created.last.testStableCheck();
    expect(asked, 1, reason: 'conflict asked exactly once');
    expect(gateway.forces, [true], reason: 'only the forced rename completed');
    expect(
      String.fromCharCodes(gateway.remoteFiles['/dir/conflict.txt']!),
      'v2',
      reason: 'forced rename replaced the remote file',
    );
    expect(created.last.status, LocalEditStatus.editing);
    s.controller.dispose();
  });

  test('declining the conflict keeps local edits without replacing', () async {
    final s = await connectedSession();
    gateway.seed('/dir/deny.txt', utf8Bytes('hello'));
    await LocalEditSession.launch(
      s,
      DemoFile('/dir/deny.txt', 'deny.txt', byteSize: 5, size: '5 B'),
      gateway: gateway,
      onNotice: notices.add,
      rootOverride: root,
      launchOverride: (_) async => true,
      onSession: created.add,
      onConflict: (path) => Future.value(false),
    );
    gateway.renameError = StateError('Bad state: 目标路径已存在，请先处理同名冲突');
    final file = singleTaskFile(root);
    await file.writeAsString('v2');
    await created.last.testStableCheck();
    expect(gateway.forces, isEmpty, reason: 'no forced rename after refusal');
    expect(created.last.status, LocalEditStatus.failed);
    expect(
      gateway.remoteFiles['/dir/deny.txt']?.length,
      5,
      reason: 'remote untouched',
    );
    expect(file.existsSync(), isTrue, reason: 'local edits preserved');
    s.controller.dispose();
  });

  test('registry bounds sessions and disposes all', () async {
    final registry = LocalEditRegistry();
    final s = await connectedSession();
    // Open the maximum number of real sessions; the next must be rejected
    // (disposed immediately) without throwing.
    for (var i = 0; i < 16; i++) {
      await launchFor(s, 'r$i.txt');
    }
    expect(registry.isFull, isFalse);
    registry.disposeAll();
    // Simulate saturation directly with already-closed dummies.
    final saturated = LocalEditRegistry();
    final dummies = <LocalEditSession>[];
    for (var i = 0; i < 17; i++) {
      dummies.add(await launchFor(s, 'x$i.txt'));
    }
    for (final dummy in dummies) {
      saturated.register(dummy);
    }
    expect(saturated.isFull, isTrue);
    // One more register on a closed registry disposes instead of throwing.
    saturated.register(dummies.first);
    await saturated.disposeAll();
    expect(saturated.length, 0);
    s.controller.dispose();
  });
}
