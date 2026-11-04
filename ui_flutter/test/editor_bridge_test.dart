import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/editors.dart'
    show EditorDocument, EditorSummary;
import 'package:hspterm/src/rust/transfers.dart' as transfers;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';
import 'support/editor_close_failure_sftp.dart';

List<int> utf16le(String text) => [
  0xff,
  0xfe,
  for (final unit in text.codeUnits) ...[unit & 255, unit >> 8],
];
Future<rust.Profile> profile(LocalSshd server, {String id = ''}) =>
    rust.saveProfile(
      profile: rust.Profile(
        id: id,
        name: 'Editor loopback fixture',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
Future<void> connect(TerminalController c, String host) async {
  c.confirmHostKey = (_) async => true;
  await c.start();
  await c.connect(host);
  await waitFor(() => c.connected, 'editor SSH');
}

Future<void> pattern(File file, int length, int value) async {
  final handle = await file.open(mode: FileMode.write);
  try {
    final block = List<int>.filled(65536, value);
    for (var written = 0; written < length;) {
      final n = (length - written).clamp(0, block.length);
      await handle.writeFrom(block, 0, n);
      written += n;
    }
    await handle.flush();
  } finally {
    await handle.close();
  }
}

Future<void> expectPattern(File file, int length, int value) async {
  var count = 0;
  await for (final block in file.openRead()) {
    expect(block.every((b) => b == value), isTrue);
    count += block.length;
  }
  expect(count, length);
}

void main() {
  setUpAll(() async {
    if (Platform.isLinux) await initializeRust();
  });
  test(
    'large raw editor streams exact bytes, cancels safely and recovers offline without a full Flutter body',
    () async {
      final server = await LocalSshd.start();
      final c = TerminalController(const NativeTerminalBackend());
      final other = TerminalController(const NativeTerminalBackend());
      try {
        final vault = '${server.directory.path}/raw-editor.vault';
        await rust.unlockVault(
          path: vault,
          password: 'test-only-raw-editor-master',
        );
        final host = await profile(server);
        await connect(c, host.id);
        await connect(other, host.id);
        final generation = c.generation;
        final remote = File('${server.directory.path}/large 中文 raw.txt');
        const length = 17 * 1024 * 1024 + 19;
        await pattern(remote, length, 0xc1); // deliberately not valid Unicode
        final token = rust.reserveRawEditor(
          id: c.id!,
          generation: generation,
          path: remote.path,
        );
        final original = await rust.prepareEditor(
          editorId: token,
          operation: rust.beginEditorOperation(editorId: token),
        );
        expect(original.text, isEmpty);
        expect(original.summary.rawBytes, length);
        expect(original.summary.revision, original.summary.savedRevision);
        await expectLater(
          rust.updateEditor(
            editorId: token,
            expectedRevision: original.summary.revision,
            text: 'must not replace raw bytes',
            encoding: 'utf8',
            lineEnding: 'lf',
          ),
          throwsA(anything),
        );
        final work = await rust.openExternalEditor(
          editorId: token,
          baseDirectory: server.directory.path,
        );
        expect(work.existing, isFalse);
        await expectPattern(File(work.path), length, 0xc1);
        await pattern(File(work.path), length + 7, 0xfe);
        final changed = (await rust.captureExternalEditor(
          editorId: token,
          expectedRevision: original.summary.revision,
        ))!;
        expect(changed.text, isEmpty);
        expect(changed.summary.rawBytes, length + 7);
        expect(
          changed.summary.revision,
          greaterThan(changed.summary.savedRevision),
        );
        await expectPattern(remote, length, 0xc1);
        await expectLater(
          rust.saveEditor(
            editorId: token,
            operation: rust.beginEditorOperation(editorId: token),
            expectedRevision: changed.summary.revision,
            id: other.id!,
            generation: other.generation,
          ),
          throwsA(anything),
        );
        await rust.saveTransferPreferences(
          value: const transfers.TransferPreferences(
            concurrency: 3,
            uploadBytesPerSecond: 65536,
            downloadBytesPerSecond: 0,
            defaultConflict: 'ask',
          ),
        );
        final operation = rust.beginEditorOperation(editorId: token);
        final pending = rust.saveEditor(
          editorId: token,
          operation: operation,
          expectedRevision: changed.summary.revision,
          id: c.id!,
          generation: generation,
        );
        final failed = expectLater(pending, throwsA(anything));
        await waitFor(
          () =>
              (rust
                      .editorProgress(editorId: token, operation: operation)
                      ?.acknowledged ??
                  0) >
              0,
          'raw partial write',
        );
        await rust.cancelEditorOperation(editorId: token, operation: operation);
        await failed;
        expect(await remote.length(), lessThan(length + 7));
        await expectPattern(File(work.path), length + 7, 0xfe);
        await rust.saveTransferPreferences(
          value: const transfers.TransferPreferences(
            concurrency: 3,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            defaultConflict: 'ask',
          ),
        );
        final saved = await rust.saveEditor(
          editorId: token,
          operation: rust.beginEditorOperation(editorId: token),
          expectedRevision: changed.summary.revision,
          id: c.id!,
          generation: generation,
        );
        expect(saved.revision, saved.savedRevision);
        await expectPattern(remote, length + 7, 0xfe);
        expect(
          await rust.captureExternalEditor(
            editorId: token,
            expectedRevision: saved.revision,
          ),
          isNull,
        );
        await rust.disconnectTerminal(id: c.id!);
        await waitFor(() => c.phase == 'Disconnected', 'raw disconnect');
        await rust.closeEditor(editorId: token, keepDraft: true);
        await pattern(
          File(work.path),
          90001,
          0xb0,
        ); // external editor outlives app
        final resumed = rust.reserveSavedEditor(draftId: saved.id);
        final offline = await rust.prepareEditor(
          editorId: resumed,
          operation: rust.beginEditorOperation(editorId: resumed),
        );
        expect(offline.text, isEmpty);
        expect(offline.summary.rawBytes, length + 7);
        expect(offline.summary.terminalId, isNull);
        final reopened = await rust.openExternalEditor(
          editorId: resumed,
          baseDirectory: server.directory.path,
        );
        expect(reopened.existing, isTrue);
        final newest = (await rust.captureExternalEditor(
          editorId: resumed,
          expectedRevision: saved.revision,
        ))!;
        expect(newest.summary.rawBytes, 90001);
        await expectPattern(remote, length + 7, 0xfe);
        expect(c.generation, generation);
        await expectLater(
          rust.closeEditor(editorId: resumed, keepDraft: false),
          throwsA(anything),
        );
        final cleaned = await rust.cleanupExternalEditor(
          editorId: resumed,
          editorClosed: true,
        );
        expect(cleaned.summary.externalDirectory, isNull);
        expect(await File(work.path).exists(), isFalse);
        await rust.closeEditor(editorId: resumed, keepDraft: false);
        expect(await rust.listEditorDrafts(), isEmpty);
        // Simulate a crash/disk failure before an initializer marker commits.
        // A partial work file must not silently become an editor-ready document.
        final brokenSource = File(
          '${server.directory.path}/raw-incomplete.txt',
        );
        await pattern(brokenSource, 100, 0x81);
        final broken = rust.reserveRawEditor(
          id: other.id!,
          generation: other.generation,
          path: brokenSource.path,
        );
        final brokenDoc = await rust.prepareEditor(
          editorId: broken,
          operation: rust.beginEditorOperation(editorId: broken),
        );
        final brokenWork = await rust.openExternalEditor(
          editorId: broken,
          baseDirectory: server.directory.path,
        );
        await rust.releaseExternalEditor(editorId: broken);
        await File('${brokenWork.summary.externalDirectory}/format-v1')
            .delete();
        await pattern(File(brokenWork.path), 3, 0xb1);
        await expectLater(
          rust.openExternalEditor(
            editorId: broken,
            baseDirectory: server.directory.path,
          ),
          throwsA(anything),
        );
        expect(
          await File('${brokenWork.summary.externalDirectory}/format-v1')
              .exists(),
          false,
        );
        await expectPattern(File(brokenWork.path), 3, 0xb1);
        final recoveredPartial = await rust.cleanupExternalEditor(
          editorId: broken,
          editorClosed: true,
        );
        expect(recoveredPartial.summary.rawBytes, 3);
        expect(
          recoveredPartial.summary.revision,
          greaterThan(brokenDoc.summary.revision),
        );
        expect(recoveredPartial.summary.externalDirectory, isNull);
        await expectPattern(brokenSource, 100, 0x81);
        await rust.closeEditor(editorId: broken, keepDraft: false);
        expect(await rust.listEditorDrafts(), isEmpty);
      } finally {
        await rust.shutdownEditors();
        await other.shutdown();
        other.dispose();
        await c.shutdown();
        c.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux,
  );
  test(
    'explicit legacy encoding retries safely, refuses lossy saves and preserves external codec',
    () async {
      final server = await LocalSshd.start();
      final c = TerminalController(const NativeTerminalBackend());
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/codecs.vault',
          password: 'test-only-codec-master',
        );
        final host = await profile(server);
        await connect(c, host.id);
        final generation = c.generation;
        final remote = File('${server.directory.path}/codec.txt');
        const gbk = [0xd6, 0xd0, 0xce, 0xc4];
        await remote.writeAsBytes([...gbk, 13, 10]);
        final token = rust.reserveEditor(
          id: c.id!,
          generation: generation,
          path: remote.path,
        );
        Future<EditorDocument> prepare([String? encoding]) =>
            rust.prepareEditor(
              editorId: token,
              operation: rust.beginEditorOperation(editorId: token),
              inputEncoding: encoding,
            );
        await expectLater(prepare(), throwsA(anything));
        expect(await rust.listEditorDrafts(), isEmpty);
        final doc = await prepare('gbk');
        expect(doc.text, '中文\r\n');
        expect(doc.summary.encoding, 'gbk');
        await expectLater(
          prepare('utf8'),
          throwsA(anything),
          reason: 'a live draft must not be reinterpreted',
        );
        final changed = await rust.updateEditor(
          editorId: token,
          expectedRevision: 1,
          text: '中文\n中文',
          encoding: 'gbk',
          lineEnding: 'crlf',
        );
        Future<EditorSummary> save(int revision) => rust.saveEditor(
          editorId: token,
          operation: rust.beginEditorOperation(editorId: token),
          expectedRevision: revision,
          id: c.id!,
          generation: generation,
        );
        await save(changed.revision);
        final before = await remote.readAsBytes();
        expect(before, [...gbk, 13, 10, ...gbk]);
        final invalid = await rust.updateEditor(
          editorId: token,
          expectedRevision: changed.revision,
          text: '😀',
          encoding: 'gbk',
          lineEnding: 'preserve',
        );
        await expectLater(save(invalid.revision), throwsA(anything));
        expect(
          await remote.readAsBytes(),
          before,
          reason: 'encoding failure must happen before truncation',
        );
        final emoji = await rust.updateEditor(
          editorId: token,
          expectedRevision: invalid.revision,
          text: '😀',
          encoding: 'gb18030',
          lineEnding: 'preserve',
        );
        await save(emoji.revision);
        expect(await remote.readAsBytes(), [0x94, 0x39, 0xfc, 0x36]);
        final work = await rust.openExternalEditor(
          editorId: token,
          baseDirectory: server.directory.path,
        );
        await File(work.path).writeAsBytes(gbk);
        final captured = (await rust.captureExternalEditor(
          editorId: token,
          expectedRevision: emoji.revision,
        ))!;
        expect(captured.text, '中文');
        expect(captured.summary.encoding, 'gb18030');
        await save(captured.summary.revision);
        expect(await remote.readAsBytes(), gbk);
        await File(work.path)
            .writeAsBytes([0xef, 0xbb, 0xbf, ...utf8.encode('中文 é')]);
        final unicode = (await rust.captureExternalEditor(
          editorId: token,
          expectedRevision: captured.summary.revision,
        ))!;
        expect(unicode.summary.encoding, 'utf8_bom');
        await save(unicode.summary.revision);
        expect(await remote.readAsBytes(), [
          0xef,
          0xbb,
          0xbf,
          ...utf8.encode('中文 é'),
        ]);
        await rust.cleanupExternalEditor(editorId: token, editorClosed: true);
        await rust.closeEditor(editorId: token, keepDraft: false);
        expect(await rust.listEditorDrafts(), isEmpty);
        await remote.writeAsBytes([0x2d, 0x4e, 0x87, 0x65]);
        final bareToken = rust.reserveEditor(
          id: c.id!,
          generation: generation,
          path: remote.path,
        );
        final bare = await rust.prepareEditor(
          editorId: bareToken,
          operation: rust.beginEditorOperation(editorId: bareToken),
          inputEncoding: 'utf16_le_no_bom',
        );
        expect(bare.text, '中文');
        expect(bare.summary.encoding, 'utf16_le_no_bom');
        final bareEdit = await rust.updateEditor(
          editorId: bareToken,
          expectedRevision: 1,
          text: '中文 😀',
          encoding: 'utf16_le_no_bom',
          lineEnding: 'preserve',
        );
        await rust.saveEditor(
          editorId: bareToken,
          operation: rust.beginEditorOperation(editorId: bareToken),
          expectedRevision: bareEdit.revision,
          id: c.id!,
          generation: generation,
        );
        expect(await remote.readAsBytes(), utf16le('中文 😀').skip(2).toList());
        await rust.closeEditor(editorId: bareToken, keepDraft: false);
        expect(c.generation, generation);
      } finally {
        await rust.shutdownEditors();
        await c.shutdown();
        c.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
  test(
    'external work files survive exit, recover offline and clean up without losing the encrypted pin',
    () async {
      final server = await LocalSshd.start();
      final c = TerminalController(const NativeTerminalBackend());
      final vault = '${server.directory.path}/external.vault';
      try {
        await rust.unlockVault(
          path: vault,
          password: 'test-only-external-master',
        );
        final host = await profile(server);
        await connect(c, host.id);
        final remote = File('${server.directory.path}/external 中文.txt');
        await remote.writeAsBytes(utf16le('initial 中文\r\n'));
        final initialBytes = await remote.readAsBytes();
        final token = rust.reserveEditor(
          id: c.id!,
          generation: c.generation,
          path: remote.path,
        );
        final initial = await rust.prepareEditor(
          editorId: token,
          operation: rust.beginEditorOperation(editorId: token),
        );
        final working = await rust.openExternalEditor(
          editorId: token,
          baseDirectory: server.directory.path,
        );
        expect(working.existing, false);
        expect(working.summary.externalDirectory, isNotNull);
        expect(await File(working.path).readAsBytes(), initialBytes);
        expect(
          await rust.captureExternalEditor(
            editorId: token,
            expectedRevision: 1,
          ),
          isNull,
        );
        final replacement = File('${working.path}.atomic');
        await replacement.writeAsString('external 中文 é 😀\n');
        await replacement.rename(working.path);
        final changed = (await rust.captureExternalEditor(
          editorId: token,
          expectedRevision: 1,
        ))!;
        expect(changed.text, 'external 中文 é 😀\n');
        expect(changed.summary.encoding, 'utf8');
        expect(changed.summary.revision, 2);
        expect(await remote.readAsBytes(), initialBytes);
        await expectLater(
          rust.captureExternalEditor(editorId: token, expectedRevision: 1),
          throwsA(anything),
        );
        await expectLater(
          rust.closeEditor(editorId: token, keepDraft: false),
          throwsA(anything),
        );
        await rust.saveEditor(
          editorId: token,
          operation: rust.beginEditorOperation(editorId: token),
          expectedRevision: 2,
          id: c.id!,
          generation: c.generation,
        );
        expect(await remote.readAsString(), changed.text);
        await rust.disconnectTerminal(id: c.id!);
        await waitFor(
          () => c.phase == 'Disconnected',
          'external editor disconnect',
        );
        final generation = c.generation;
        await rust.closeEditor(editorId: token, keepDraft: true);
        await rust.shutdownEditors();
        // A GUI editor can keep writing after HSPTerm exits. The raw copy must
        // survive; restoring the encrypted draft alone must not auto-upload it.
        await File(working.path).writeAsString('newer after exit 中文\n');
        await rust.unlockVault(
          path: vault,
          password: 'test-only-external-master',
        );
        await expectLater(
          rust.discardEditorDraft(draftId: initial.summary.id),
          throwsA(anything),
        );
        final resumed = rust.reserveSavedEditor(draftId: initial.summary.id);
        final old = await rust.prepareEditor(
          editorId: resumed,
          operation: rust.beginEditorOperation(editorId: resumed),
        );
        expect(old.text, changed.text);
        expect(
          old.summary.externalDirectory,
          working.summary.externalDirectory,
        );
        final reopened = await rust.openExternalEditor(
          editorId: resumed,
          baseDirectory: '/unused-base-must-not-retarget',
        );
        expect(reopened.existing, true);
        expect(reopened.path, working.path);
        final recovered = (await rust.captureExternalEditor(
          editorId: resumed,
          expectedRevision: 2,
        ))!;
        expect(recovered.text, 'newer after exit 中文\n');
        expect(c.phase, 'Disconnected');
        expect(c.generation, generation);
        expect(await remote.readAsString(), changed.text);
        await expectLater(
          rust.cleanupExternalEditor(editorId: resumed, editorClosed: false),
          throwsA(anything),
        );
        final backup = File(
          '${working.summary.externalDirectory}/editor-backup.keep',
        );
        await backup.writeAsString('unknown local sibling must survive');
        await expectLater(
          rust.cleanupExternalEditor(editorId: resumed, editorClosed: true),
          throwsA(anything),
        );
        expect(await backup.exists(), true);
        expect(await File(working.path).exists(), true);
        await backup.delete();
        // Fault injection after filesystem cleanup but before the encrypted pin
        // update: the body must survive and missing-directory recovery must work.
        final trigger = await Process.run('python3', [
          '-c',
          "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"CREATE TRIGGER reject_unpin BEFORE UPDATE ON records WHEN NEW.id LIKE 'local-edit-meta-%' BEGIN SELECT RAISE(ABORT,'controlled local commit failure'); END\"); c.commit()",
          vault,
        ]);
        expect(trigger.exitCode, 0);
        await expectLater(
          rust.cleanupExternalEditor(editorId: resumed, editorClosed: true),
          throwsA(anything),
        );
        expect(
          await Directory(working.summary.externalDirectory!).exists(),
          false,
        );
        expect(
          (await rust.listEditorDrafts()).single.externalDirectory,
          isNotNull,
        );
        final reset = await Process.run('python3', [
          '-c',
          'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("DROP TRIGGER reject_unpin"); c.commit()',
          vault,
        ]);
        expect(reset.exitCode, 0);
        final cleaned = await rust.cleanupExternalEditor(
          editorId: resumed,
          editorClosed: true,
        );
        expect(cleaned.summary.externalDirectory, isNull);
        expect(cleaned.text, recovered.text);
        await c.connect(host.id);
        await waitFor(
          () => c.connected && c.generation > generation,
          'manual reconnect before external save',
        );
        await rust.bindEditor(
          editorId: resumed,
          id: c.id!,
          generation: c.generation,
        );
        await rust.saveEditor(
          editorId: resumed,
          operation: rust.beginEditorOperation(editorId: resumed),
          expectedRevision: cleaned.summary.revision,
          id: c.id!,
          generation: c.generation,
        );
        expect(await remote.readAsString(), recovered.text);
        await rust.closeEditor(editorId: resumed, keepDraft: false);
        expect(await rust.listEditorDrafts(), isEmpty);
      } finally {
        await rust.shutdownEditors();
        await c.shutdown();
        c.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
  test(
    'real editor identity, encrypted recovery, cancellation and manual reconnect',
    () async {
      final server = await LocalSshd.start();
      final changedServer = await LocalSshd.start();
      final c = TerminalController(const NativeTerminalBackend());
      final other = TerminalController(const NativeTerminalBackend());
      final vault = '${server.directory.path}/editors.vault';
      try {
        await rust.unlockVault(
          path: vault,
          password: 'test-only-editor-master',
        );
        final host = await profile(server);
        await connect(c, host.id);
        await connect(other, host.id);
        final source = File(
          '${server.directory.path}/editor 中文 space\' dollar\$.txt',
        );
        await source.writeAsBytes(
          utf16le('original 中文 é 😀\r\nlonger initial content\r\n'),
        );
        final before = await source.readAsBytes();
        final abandoned = rust.reserveEditor(
          id: c.id!,
          generation: c.generation,
          path: source.path,
        );
        final abandonedOp = rust.beginEditorOperation(editorId: abandoned);
        expect(
          rust
              .editorProgress(editorId: abandoned, operation: abandonedOp)!
              .total,
          isNull,
        );
        await rust.cancelEditorOperation(
          editorId: abandoned,
          operation: abandonedOp,
        );
        expect(
          rust
              .editorProgress(editorId: abandoned, operation: abandonedOp)!
              .phase,
          'cancelled',
        );
        await expectLater(
          rust.prepareEditor(editorId: abandoned, operation: abandonedOp),
          throwsA(anything),
        );
        expect(await rust.listEditorDrafts(), isEmpty);
        await rust.closeEditor(editorId: abandoned, keepDraft: false);
        final token = rust.reserveEditor(
          id: c.id!,
          generation: c.generation,
          path: source.path,
        );
        final readOperation = rust.beginEditorOperation(editorId: token);
        final opened = await rust.prepareEditor(
          editorId: token,
          operation: readOperation,
        );
        final readProgress = rust.editorProgress(
          editorId: token,
          operation: readOperation,
        )!;
        expect(readProgress.phase, 'complete');
        expect(readProgress.acknowledged, before.length);
        expect(readProgress.total, before.length);
        final draftId = opened.summary.id;
        expect(token, startsWith('editor-'));
        expect(draftId, startsWith('edit-'));
        expect(opened.summary.terminalId, c.id);
        expect(opened.summary.port, server.port);
        expect(opened.summary.encoding, 'utf16_le');
        expect(opened.summary.lineEnding, 'crlf');
        expect(opened.text, 'original 中文 é 😀\r\nlonger initial content\r\n');
        expect(
          () => rust.reserveSavedEditor(draftId: draftId),
          throwsA(anything),
        );
        await expectLater(
          rust.unlockVault(
            path: '${server.directory.path}/must-not-create.vault',
            password: 'test-only-another-master',
          ),
          throwsA(anything),
        );
        expect(
          await File('${server.directory.path}/must-not-create.vault').exists(),
          false,
        );
        await c.text("printf '%s%s\\n' EDITOR_ PTY\n");
        await waitFor(
          () => screen(c).contains('EDITOR_PTY'),
          'PTY remains live during editor use',
        );
        const changed = 'edited 中文 é 😀\nnext line\n';
        final edited = await rust.updateEditor(
          editorId: token,
          expectedRevision: 1,
          text: changed,
          encoding: 'utf16_le',
          lineEnding: 'crlf',
        );
        expect(edited.revision, 2);
        expect(edited.savedRevision, 1);
        expect(await source.readAsBytes(), before);
        await expectLater(
          rust.updateEditor(
            editorId: token,
            expectedRevision: 1,
            text: 'old late update',
            encoding: 'utf8',
            lineEnding: 'lf',
          ),
          throwsA(anything),
        );
        var operation = rust.beginEditorOperation(editorId: token);
        expect(
          rust.editorProgress(editorId: token, operation: readOperation),
          isNull,
        );
        await rust.cancelEditorOperation(editorId: token, operation: operation);
        await expectLater(
          rust.saveEditor(
            editorId: token,
            operation: operation,
            expectedRevision: 2,
            id: c.id!,
            generation: c.generation,
          ),
          throwsA(anything),
        );
        expect(await source.readAsBytes(), before);
        operation = rust.beginEditorOperation(editorId: token);
        await expectLater(
          rust.saveEditor(
            editorId: token,
            operation: operation,
            expectedRevision: 2,
            id: other.id!,
            generation: other.generation,
          ),
          throwsA(anything),
        );
        expect(await source.readAsBytes(), before);
        operation = rust.beginEditorOperation(editorId: token);
        final saved = await rust.saveEditor(
          editorId: token,
          operation: operation,
          expectedRevision: 2,
          id: c.id!,
          generation: c.generation,
        );
        expect(saved.savedRevision, 2);
        expect(
          await source.readAsBytes(),
          utf16le(changed.replaceAll('\n', '\r\n')),
        );
        final fullDraft =
            'unsaved private editor marker 中文\n${'x' * (1024 * 1024)}';
        final dirty = await rust.updateEditor(
          editorId: token,
          expectedRevision: 2,
          text: fullDraft,
          encoding: 'utf8',
          lineEnding: 'lf',
        );
        expect(dirty.revision, 3);
        expect(dirty.savedRevision, 2);
        await rust.saveTransferPreferences(
          value: const transfers.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 65536,
            downloadBytesPerSecond: 0,
          ),
        );
        operation = rust.beginEditorOperation(editorId: token);
        final upload = rust.saveEditor(
          editorId: token,
          operation: operation,
          expectedRevision: 3,
          id: c.id!,
          generation: c.generation,
        );
        final cancelled = expectLater(upload, throwsA(anything));
        await waitFor(
          () =>
              source.existsSync() &&
              source.lengthSync() > 0 &&
              source.lengthSync() < utf8.encode(fullDraft).length,
          'partial throttled editor save',
        );
        await waitFor(
          () =>
              (rust
                      .editorProgress(editorId: token, operation: operation)
                      ?.acknowledged ??
                  0) >
              0,
          'acknowledged editor byte progress',
        );
        final writing = rust.editorProgress(
          editorId: token,
          operation: operation,
        )!;
        expect(writing.phase, 'writing');
        expect(writing.acknowledged, lessThan(writing.total!));
        expect(writing.total, utf8.encode(fullDraft).length);
        await rust.cancelEditorOperation(editorId: token, operation: operation);
        await cancelled;
        expect(
          rust.editorProgress(editorId: token, operation: operation)!.phase,
          'cancelled',
        );
        await rust.disconnectTerminal(id: c.id!);
        await waitFor(
          () => c.phase == 'Disconnected',
          'explicit editor SSH disconnect',
        );
        final disconnectedGeneration = c.generation;
        final partial = await source.readAsBytes();
        expect(partial.length, lessThan(utf8.encode(fullDraft).length));
        operation = rust.beginEditorOperation(editorId: token);
        await expectLater(
          rust.saveEditor(
            editorId: token,
            operation: operation,
            expectedRevision: 3,
            id: c.id!,
            generation: c.generation,
          ),
          throwsA(anything),
        );
        expect(c.phase, 'Disconnected');
        expect(
          c.generation,
          disconnectedGeneration,
        ); // no automatic SSH reconnect
        final noLeak = rust.beginEditorOperation(editorId: token);
        await rust.cancelEditorOperation(editorId: token, operation: noLeak);
        await profile(changedServer, id: host.id);
        await c.connect(host.id);
        await waitFor(
          () => c.connected && c.generation > disconnectedGeneration,
          'manual changed-target reconnect',
        );
        operation = rust.beginEditorOperation(editorId: token);
        await expectLater(
          rust.saveEditor(
            editorId: token,
            operation: operation,
            expectedRevision: 3,
            id: c.id!,
            generation: c.generation,
          ),
          throwsA(anything),
        );
        expect(await source.readAsBytes(), partial);
        await rust.closeEditor(editorId: token, keepDraft: true);
        await rust.shutdownEditors();
        await rust.unlockVault(
          path: vault,
          password: 'test-only-editor-master',
        );
        final inventory = await rust.listEditorDrafts();
        expect(inventory, hasLength(1));
        expect(inventory.single.active, false);
        expect(inventory.single.revision, 3);
        expect(inventory.single.savedRevision, 2);
        expect(
          latin1
              .decode(await File(vault).readAsBytes())
              .contains('unsaved private editor marker'),
          false,
        );
        final resumed = rust.reserveSavedEditor(draftId: draftId);
        expect(resumed, isNot(token));
        final restored = await rust.prepareEditor(
          editorId: resumed,
          operation: rust.beginEditorOperation(editorId: resumed),
        );
        expect(restored.text, fullDraft);
        expect(restored.summary.terminalId, isNull);
        // A late old view cleanup cannot delete or close a newly restored editor.
        await rust.closeEditor(editorId: token, keepDraft: false);
        expect((await rust.listEditorDrafts()).single.active, true);
        await expectLater(
          rust.discardEditorDraft(draftId: draftId),
          throwsA(anything),
        );
        await expectLater(
          rust.bindEditor(
            editorId: resumed,
            id: c.id!,
            generation: c.generation,
          ),
          throwsA(anything),
        );
        await rust.bindEditor(
          editorId: resumed,
          id: other.id!,
          generation: other.generation,
        );
        final oldOp = rust.beginEditorOperation(editorId: resumed);
        await rust.cancelEditorOperation(editorId: resumed, operation: oldOp);
        final freshOp = rust.beginEditorOperation(editorId: resumed);
        await rust.cancelEditorOperation(editorId: resumed, operation: oldOp);
        expect(
          rust.editorProgress(editorId: resumed, operation: oldOp),
          isNull,
        );
        expect(
          rust.editorProgress(editorId: resumed, operation: freshOp)!.phase,
          'waiting',
        );
        expect(
          (await rust.prepareEditor(
            editorId: resumed,
            operation: freshOp,
          )).text,
          fullDraft,
        );
        await rust.saveTransferPreferences(
          value: const transfers.TransferPreferences(
            concurrency: 3,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
          ),
        );
        final complete = await rust.saveEditor(
          editorId: resumed,
          operation: rust.beginEditorOperation(editorId: resumed),
          expectedRevision: 3,
          id: other.id!,
          generation: other.generation,
        );
        expect(complete.savedRevision, 3);
        expect(await source.readAsString(), fullDraft);
        await rust.closeEditor(editorId: resumed, keepDraft: false);
        expect(await rust.listEditorDrafts(), isEmpty);
      } finally {
        await rust.shutdownEditors();
        await c.shutdown();
        await other.shutdown();
        c.dispose();
        other.dispose();
        await server.close();
        await changedServer.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux,
  );

  test(
    'real SSH controlled SFTP write CLOSE failure retains the complete dirty draft',
    () async {
      final server = await LocalSshd.start(sftpFixture: editorCloseFailureSftp);
      final c = TerminalController(const NativeTerminalBackend());
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/close-editor.vault',
          password: 'test-only-editor-close',
        );
        final host = await profile(server);
        await connect(c, host.id);
        final token = rust.reserveEditor(
          id: c.id!,
          generation: c.generation,
          path: '/fixture.txt',
        );
        final initial = await rust.prepareEditor(
          editorId: token,
          operation: rust.beginEditorOperation(editorId: token),
        );
        expect(initial.text, 'original controlled editor document');
        const text = 'new editor text 中文 é';
        await rust.updateEditor(
          editorId: token,
          expectedRevision: 1,
          text: text,
          encoding: 'utf8',
          lineEnding: 'lf',
        );
        final failedSaveOperation = rust.beginEditorOperation(editorId: token);
        await expectLater(
          rust.saveEditor(
            editorId: token,
            operation: failedSaveOperation,
            expectedRevision: 2,
            id: c.id!,
            generation: c.generation,
          ),
          throwsA(predicate((e) => e.toString().contains('远端文件关闭失败'))),
        );
        final failedProgress = rust.editorProgress(
          editorId: token,
          operation: failedSaveOperation,
        )!;
        expect(failedProgress.phase, 'failed');
        expect(failedProgress.acknowledged, utf8.encode(text).length);
        expect(failedProgress.total, utf8.encode(text).length);
        final dirty = (await rust.listEditorDrafts()).single;
        expect(dirty.revision, 2);
        expect(dirty.savedRevision, 1);
        expect(c.connected, true);
        await rust.closeEditor(editorId: token, keepDraft: true);
        final recovered = rust.reserveSavedEditor(draftId: dirty.id);
        final document = await rust.prepareEditor(
          editorId: recovered,
          operation: rust.beginEditorOperation(editorId: recovered),
        );
        expect(document.text, text);
        expect(document.summary.savedRevision, 1);
        await rust.closeEditor(editorId: recovered, keepDraft: false);
      } finally {
        await rust.shutdownEditors();
        await c.shutdown();
        c.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
    skip: !Platform.isLinux,
  );
}
