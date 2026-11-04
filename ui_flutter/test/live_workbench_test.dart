import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

/// Real FRB/OpenSSH/SQLite fixture; all files, keys and server ports are disposable.
Future<void> exerciseWorkbench({
  Future<void> Function(LiveWorkbenchModel)? attach,
  Future<void> Function()? pumpLayout,
  Future<void> Function()? afterReady,
  Future<void> Function()? detach,
  String? previewCacheSubdirectory,
  String? editorWorkSubdirectory,
}) async {
  await initializeRust();
  final server = await LocalSshd.start();
  final cachePath = previewCacheSubdirectory == null
      ? null
      : '${server.directory.path}/$previewCacheSubdirectory';
  final m = LiveWorkbenchModel(
    previewCacheDirectory: cachePath,
    editorSupportDirectory: editorWorkSubdirectory == null
        ? null
        : '${server.directory.path}/$editorWorkSubdirectory',
  );
  try {
    if (cachePath != null) await Directory(cachePath).create();
    final vault = '${server.directory.path}/workbench.vault';
    await rust.unlockVault(path: vault, password: 'test-only-workbench-master');
    await m.load();
    expect(m.hosts, isEmpty);
    expect(m.sessions, isEmpty);
    // Upgrade the original saved-profile format without exposing its secrets.
    await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'Legacy fixture',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    await m.load();
    expect(m.hosts.single.id, startsWith('host-'));
    expect(
      (await rust.listProfiles()).single.id,
      m.hosts.single.id,
      reason: 'the original Phase2 entry must still see migrated saved hosts',
    );
    await m.load();
    expect(m.hosts, hasLength(1), reason: 'migration must be idempotent');
    final group = await rust.createHostGroup(name: 'Loopback fixtures');
    await m.load();
    final candidate = DemoHost(
      m.nextId(),
      'Real workbench fixture',
      '127.0.0.1',
      group.name,
      user: server.username,
      port: server.port,
      auth: '私钥',
    );
    await m.persistDraft(
      candidate,
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    expect(m.hosts, hasLength(1));
    expect(m.recoverableDrafts, hasLength(1));
    final host = await m.persistHost(
      candidate,
    ); // promote encrypted draft credentials
    expect(host.credentialSet, true);
    expect(m.recoverableDrafts, isEmpty);
    // Invalid imports must not overwrite a working encrypted credential.
    await expectLater(
      m.persistHost(host, secret: 'not-a-key', passphrase: 'not-a-passphrase'),
      throwsA(anything),
    );
    await m.persistDraft(
      host,
    ); // metadata-only drafts retain the formal credential
    await m.load();
    expect(m.recoverableDrafts.single.credentialSet, true);
    await m.persistHost(m.recoverableDrafts.single);
    expect(m.recoverableDrafts, isEmpty);
    await m.batchHosts({host.id}, favorite: true);
    expect(m.hosts.firstWhere((h) => h.id == host.id).favorite, true);
    final copied = await m.copyHost(host);
    expect(m.hosts, hasLength(2));
    expect(m.recoverableDrafts.single.id, copied.id);
    final copy = await m.persistHost(copied);
    expect(copy.id, isNot(host.id));
    final generated = DemoHost(
      m.nextId(),
      'Generated identity',
      '127.0.0.1',
      group.name,
      user: server.username,
      port: server.port,
      auth: '私钥',
    );
    final key = await m.prepareKey(
      generated,
      passphrase: 'test-only-generated-key-password',
    );
    expect(key.algorithm, 'ssh-ed25519');
    expect(m.hosts.any((h) => h.id == generated.id), false);
    expect((await m.publicKey(generated.id)).fingerprint, key.fingerprint);
    final publicFile = File('${server.directory.path}/exported-public.pub');
    await m.exportPublicKey(generated.id, publicFile.path);
    expect(await publicFile.readAsString(), '${key.publicKey}\n');
    final exported = File('${server.directory.path}/exported-private');
    await expectLater(
      m.exportKey(generated.id, exported.path, 'wrong-master'),
      throwsA(anything),
    );
    expect(await exported.exists(), false);
    await m.exportKey(
      generated.id,
      exported.path,
      'test-only-workbench-master',
    );
    final published = await Process.run('ssh-keygen', [
      '-y',
      '-P',
      'test-only-generated-key-password',
      '-f',
      exported.path,
    ]);
    expect(published.exitCode, 0);
    expect(published.stdout.toString().trim(), key.publicKey);
    await expectLater(
      m.exportKey(generated.id, exported.path, 'test-only-workbench-master'),
      throwsA(anything),
    );
    final invalidImport = File('${server.directory.path}/invalid-private');
    await invalidImport.writeAsString('not a private key');
    await expectLater(
      m.prepareKey(generated, path: invalidImport.path),
      throwsA(anything),
    );
    expect((await m.publicKey(generated.id)).fingerprint, key.fingerprint);
    final imported = DemoHost(
      m.nextId(),
      'Imported identity',
      '127.0.0.1',
      group.name,
      user: server.username,
      port: server.port,
      auth: '私钥',
    );
    await m.prepareKey(
      imported,
      path: '${server.directory.path}/client',
      passphrase: 'test-only-passphrase',
    );
    expect(
      m.recoverableDrafts.any((h) => h.id == imported.id && h.credentialSet),
      true,
    );
    await m.discardDraft(imported.id);
    final generatedHost = await m.persistHost(generated);
    await File('${server.directory.path}/client.pub')
        .writeAsString('\n${key.publicKey}\n', mode: FileMode.append);
    if (attach != null) await attach(m);
    // Explicit trust only for this test's freshly generated public host key.
    final fingerprint = await Process.run('ssh-keygen', [
      '-l',
      '-E',
      'sha256',
      '-f',
      '${server.directory.path}/host.pub',
    ]);
    final expectedFingerprint = fingerprint.stdout.toString().trim().split(
      RegExp(r'\s+'),
    )[1];
    var confirmations = 0;
    var expectedAddress = '127.0.0.1';
    m.confirmHostKey = (target, event) async {
      expect(target.address, expectedAddress);
      expect(event.text, expectedFingerprint);
      confirmations++;
      return true;
    };
    final browse = Directory('${server.directory.path}/workbench-files');
    await browse.create();
    await File('${browse.path}/README.txt')
        .writeAsString('HSPTerm isolated fixture');
    await File('${browse.path}/中文.txt').writeAsString('中文 é');
    for (var i = 0; i < 3; i++) {
      m.openHost(host);
      m.focus!.path = browse.path;
    }
    final sessions = m.sessions.cast<LiveTerminalSession>(), tabs = m.tabs;
    expect(tabs, hasLength(3));
    expect(m.layoutGroups.single.tabs, hasLength(3));
    await waitFor(
      () => sessions.every((s) => s.controller.connected),
      'three real SSH transports',
    );
    await waitFor(
      () => sessions.every((s) => s.sftpEnabled && !s.loadingDirectory),
      'three associated SFTP channels',
    );
    expect(confirmations, inInclusiveRange(1, 3));
    final nativeIds = sessions.map((s) => s.controller.id).toSet();
    expect(nativeIds, hasLength(3));
    Future<void> layout() async {
      if (pumpLayout != null) {
        await pumpLayout();
      } else {
        final visible = m.layoutGroups
            .where(
              (g) => m.maximizedGroupId == null || g.id == m.maximizedGroupId,
            )
            .map((g) => m.session(g.selected).id)
            .toSet();
        for (final s in sessions) {
          await s.controller.setVisible(visible.contains(s.id));
        }
      }
    }

    for (var i = 0; i < sessions.length; i++) {
      final c = sessions[i].controller;
      await c.text(
        r"export PS1='fixture> '; printf '\033[2J\033[H'; printf '%s%s\n' WORKBENCH_"
        " $i",
      );
      await c.key(rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0));
    }
    m.selectTab(tabs.first.id);
    await layout();
    await waitFor(
      () => screen(sessions.first.controller).contains('WORKBENCH_0'),
      'first terminal frame',
    );
    final hiddenFrames = sessions[1].controller.frameCount;
    await sessions[1].controller.text(r"printf '%s%s\n' HIDDEN_ CONTINUES");
    await sessions[1].controller.key(
      rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(sessions[1].controller.frameCount, hiddenFrames);
    m.moveTab(tabs[1].id, m.focusedGroupId!, placement: TabPlacement.right);
    await layout();
    await waitFor(
      () => screen(sessions[1].controller).contains('HIDDEN_CONTINUES'),
      'hidden output retained when tab split',
    );
    expect(sessions.map((s) => s.controller.id).toSet(), nativeIds);
    expect(sessions.every((s) => s.controller.generation == 1), true);
    final tree = m.root;
    m.maximize(m.focusedGroupId!);
    await layout();
    m.maximize(m.focusedGroupId!);
    await layout();
    expect(m.root, same(tree));
    m.moveTab(tabs[2].id, m.focusedGroupId!);
    m.selectTab(tabs[1].id);
    await layout();
    expect(m.session(tabs[1]), same(sessions[1]));
    if (afterReady != null) await afterReady();
    // Server-backed mutation and exact binary/Unicode content, never mock list edits.
    final s = sessions.first;
    await m.loadDirectory(s, server.directory.path);
    final bookmarkGeneration = s.controller.generation;
    await m.savePathBookmark(
      s,
      name: 'Host fixture bookmark',
      path: browse.path,
      global: false,
    );
    await m.savePathBookmark(
      s,
      name: 'Global fixture bookmark',
      path: server.directory.path,
      global: true,
    );
    final bookmarks = await m.listPathBookmarks(s);
    expect(bookmarks, hasLength(2));
    expect(
      (await rust.listSftpBookmarks(hostId: copy.id)).single.name,
      'Global fixture bookmark',
    );
    await rust.unlockVault(path: vault, password: 'test-only-workbench-master');
    expect(
      (await m.listPathBookmarks(s)).map((b) => b.id),
      bookmarks.map((b) => b.id),
    );
    await m.savePathBookmark(
      s,
      id: bookmarks.first.id,
      name: 'Renamed fixture bookmark',
      path: browse.path,
      global: false,
    );
    await m.loadDirectory(s, (await m.listPathBookmarks(s)).first.path);
    expect(s.path, browse.path);
    expect(s.controller.generation, bookmarkGeneration);
    for (final bookmark in bookmarks) {
      await m.deletePathBookmark(bookmark.id);
    }
    expect(await m.listPathBookmarks(s), isEmpty);
    await m.loadDirectory(s, server.directory.path);
    await m.createRemoteDirectory(s, "folder ' 中文");
    final directory = s.files.firstWhere((f) => f.name == "folder ' 中文");
    final path = '${directory.id}/bytes 中文.bin';
    final data = Uint8List.fromList([
      ...utf8.encode('中文 é\n'),
      ...List.generate(20000, (i) => i % 256),
    ]);
    await rust.sftpWriteChunk(
      id: s.controller.id!,
      path: path,
      offset: 0,
      data: Uint8List.sublistView(data, 0, 10000),
      truncate: true,
    );
    await rust.sftpWriteChunk(
      id: s.controller.id!,
      path: path,
      offset: 10000,
      data: Uint8List.sublistView(data, 10000),
      truncate: false,
    );
    final downloaded = BytesBuilder();
    var offset = 0;
    while (true) {
      final chunk = await rust.sftpReadChunk(
        id: s.controller.id!,
        path: path,
        offset: offset,
        length: 4096,
      );
      if (chunk.isEmpty) break;
      downloaded.add(chunk);
      offset += chunk.length;
    }
    expect(downloaded.takeBytes(), data);
    expect(await File(path).readAsBytes(), data);
    await m.loadDirectory(s, directory.id);
    await m.renameRemote(s, s.files.single, "renamed ' 文件.bin");
    expect(s.files.single.name, "renamed ' 文件.bin");
    final occupied = File('${directory.id}/occupied.bin');
    await occupied.writeAsString('keep destination');
    await expectLater(
      m.renameRemote(s, s.files.single, 'occupied.bin'),
      throwsA(anything),
    );
    expect(await occupied.readAsString(), 'keep destination');
    // Recursive deletion must unlink a symlink without traversing its target.
    final outside = File('${server.directory.path}/outside-kept.txt');
    await outside.writeAsString('keep');
    await Link('${directory.id}/outside-link').create(outside.path);
    await m.loadDirectory(s, server.directory.path);
    await m.deleteRemoteFiles(s, [
      s.files.firstWhere((f) => f.name == directory.name),
    ]);
    expect(await Directory(directory.id).exists(), false);
    expect(await outside.readAsString(), 'keep');
    // Layout and sidebar changes never reconnect; disconnect/reconnect are explicit.
    final editedTarget = host.snapshot()..address = 'localhost';
    await m.persistHost(editedTarget);
    expect(
      sessions.every((session) => session.host.address == '127.0.0.1'),
      true,
      reason:
          'saved metadata edits must not rewrite existing transport snapshots',
    );
    m.selectTab(tabs[0].id);
    await layout();
    final generation = s.controller.generation, id = s.controller.id;
    m.setDisconnected(tabs[0].id, true);
    await waitFor(
      () => s.controller.phase == 'Disconnected',
      'explicit disconnect',
    );
    expect(s.controller.id, id);
    expect(s.controller.generation, generation);
    expect(screen(s.controller), contains('WORKBENCH_0'));
    s.directories['/previous-server-only'] = [];
    expectedAddress = 'localhost';
    m.setDisconnected(tabs[0].id, false);
    await waitFor(
      () => s.controller.connected && s.controller.generation == generation + 1,
      'manual reconnect',
    );
    await waitFor(
      () => s.sftpGeneration == s.controller.generation && !s.loadingDirectory,
      'SFTP restore',
    );
    expect(s.sftpError, isNull);
    expect(s.directories.containsKey('/previous-server-only'), false);
    expect(s.directoryCache.estimatedBytes, greaterThan(0));
    expect(
      s.directories,
      hasLength(1),
      reason: 'reconnect drops old directory snapshots',
    );
    expect(s.host.address, 'localhost');
    expect(s.controller.connectionLabel, contains('localhost'));
    expect(
      sessions[2].host.address,
      '127.0.0.1',
      reason: 'another active session keeps its own target',
    );
    m.mergeGroups();
    await layout();
    expect(m.layoutGroups.single.tabs, hasLength(3));
    await m.deleteHosts({
      host.id,
    }); // no forced disconnection of any existing transport
    expect(sessions.every((s) => s.controller.connected), true);
    m.closeTab(tabs[1].id);
    await layout();
    expect(m.sessions, hasLength(2));
    expect(sessions[0].controller.connected, true);
    expect(sessions[2].controller.connected, true);
    // A copied credential remains independently usable after source deletion.
    expectedAddress = '127.0.0.1';
    m.openHost(copy);
    m.focus!.path = browse.path;
    final copySession = m.focus! as LiveTerminalSession;
    await waitFor(
      () => copySession.controller.connected,
      'independent copied credential',
    );
    m.openHost(generatedHost);
    m.focus!.path = browse.path;
    final generatedSession = m.focus! as LiveTerminalSession;
    await waitFor(
      () => generatedSession.controller.connected,
      'Rust-generated encrypted key authenticates OpenSSH',
    );
    nativeIds.add(copySession.controller.id);
    nativeIds.add(generatedSession.controller.id);
    // Application-owned file clipboard survives pane navigation and contains
    // only original source metadata. Actual remote bytes go through Rust jobs.
    final sourceSession = sessions[2];
    final clipboardSource = Directory(
      '${server.directory.path}/clipboard source',
    );
    final clipboardTarget = Directory(
      '${server.directory.path}/clipboard destination',
    );
    await clipboardSource.create();
    await clipboardTarget.create();
    await File('${clipboardSource.path}/中文 source.txt')
        .writeAsString('真实文件剪贴板 中文e\u0301');
    await m.loadDirectory(sourceSession, clipboardSource.path, remember: false);
    m.copyRemoteFileClipboard(sourceSession, [sourceSession.files.single]);
    final revision = m.remoteFileClipboardRevision;
    final sourceNative = sourceSession.controller.id,
        sourceGen = sourceSession.controller.generation;
    await m.loadDirectory(copySession, clipboardTarget.path, remember: false);
    await expectLater(
      m.pasteRemoteFileClipboard(
        copySession,
        clipboardTarget.path,
        copySession.controller.generation,
        allowMemoryRelay: true,
        expectedClipboardRevision: revision + 1,
      ),
      throwsStateError,
    );
    expect(await Directory(clipboardTarget.path).list().isEmpty, true);
    final copiedIds = await m.pasteRemoteFileClipboard(
      copySession,
      clipboardTarget.path,
      copySession.controller.generation,
      allowMemoryRelay: true,
      expectedClipboardRevision: revision,
    );
    await waitFor(
      () => m.transferTasks.any((t) => copiedIds.contains(t.id) && !t.busy),
      'model file clipboard copy',
    );
    final copiedTask = m.transferTasks.singleWhere(
      (t) => t.id == copiedIds.single,
    );
    expect(copiedTask.state, 'Complete', reason: copiedTask.error);
    expect(copiedTask.sourceTerminalId, sourceNative);
    expect(sourceSession.controller.generation, sourceGen);
    expect(
      await File('${clipboardTarget.path}/中文 source.txt').readAsString(),
      '真实文件剪贴板 中文e\u0301',
    );
    await m.clearEndedTasks();
    final movingFile = File('${clipboardSource.path}/move 中文.txt');
    await movingFile.writeAsString('独立会话剪切 e\u0301');
    await m.loadDirectory(sourceSession, clipboardSource.path, remember: false);
    m.copyRemoteFileClipboard(sourceSession, [
      sourceSession.files.singleWhere((f) => f.name == 'move 中文.txt'),
    ], cut: true);
    final cutRevision = m.remoteFileClipboardRevision;
    final movedIds = await m.pasteRemoteFileClipboard(
      copySession,
      clipboardTarget.path,
      copySession.controller.generation,
      allowMemoryRelay: false,
      expectedClipboardRevision: cutRevision,
    );
    expect(
      m.remoteFileClipboardDescription,
      isNull,
      reason: 'accepted cut paths must not be submitted twice',
    );
    await expectLater(
      m.pasteRemoteFileClipboard(
        copySession,
        clipboardTarget.path,
        copySession.controller.generation,
        allowMemoryRelay: false,
        expectedClipboardRevision: cutRevision,
      ),
      throwsStateError,
    );
    await waitFor(
      () => m.transferTasks.any((t) => movedIds.contains(t.id) && !t.busy),
      'model cut/move',
    );
    final movedTask = m.transferTasks.singleWhere(
      (t) => t.id == movedIds.single,
    );
    expect(movedTask.state, 'Complete', reason: movedTask.error);
    expect(movedTask.remoteOperation, 'move');
    expect(await movingFile.exists(), false);
    expect(
      await File('${clipboardTarget.path}/move 中文.txt').readAsString(),
      '独立会话剪切 e\u0301',
    );
    expect(sourceSession.controller.generation, sourceGen);
    await m.clearEndedTasks();
    // Destination actions use an immutable source selection, independent of
    // later navigation and the ordinary file clipboard.
    final direct = File('${clipboardSource.path}/direct 中文.txt');
    await direct.writeAsString('独立目标复制 e\u0301');
    await m.loadDirectory(sourceSession, clipboardSource.path, remember: false);
    m.copyRemoteFileClipboard(sourceSession, [
      sourceSession.files.singleWhere((f) => f.name == '中文 source.txt'),
    ]);
    final clipboardRevision = m.remoteFileClipboardRevision;
    final clipboardDescription = m.remoteFileClipboardDescription;
    final directSelection = m.prepareRemoteFileSelection(sourceSession, [
      sourceSession.files.singleWhere((f) => f.name == 'direct 中文.txt'),
    ]);
    final directDestination = Directory(
      '${server.directory.path}/direct destination',
    );
    await directDestination.create();
    await m.loadDirectory(sourceSession, clipboardTarget.path, remember: false);
    final directIds = await m.enqueueRemoteFileSelection(
      directSelection,
      copySession,
      directDestination.path,
      copySession.controller.generation,
      allowMemoryRelay: true,
    );
    await waitFor(
      () => m.transferTasks.any((t) => directIds.contains(t.id) && !t.busy),
      'fixed source selection after navigation',
    );
    expect(
      m.transferTasks.singleWhere((t) => t.id == directIds.single).state,
      'Complete',
    );
    expect(
      await File('${directDestination.path}/direct 中文.txt').readAsString(),
      '独立目标复制 e\u0301',
    );
    expect(m.remoteFileClipboardRevision, clipboardRevision);
    expect(m.remoteFileClipboardDescription, clipboardDescription);
    final first = File('${clipboardSource.path}/direct move A.txt');
    final second = File('${clipboardSource.path}/direct move B.txt');
    await first.writeAsString('first move');
    await second.writeAsString('second move');
    await m.loadDirectory(sourceSession, clipboardSource.path, remember: false);
    final movingSelection = m.prepareRemoteFileSelection(sourceSession, [
      sourceSession.files.singleWhere((f) => f.name == 'direct move A.txt'),
      sourceSession.files.singleWhere((f) => f.name == 'direct move B.txt'),
    ], cut: true);
    final blockedEditor = rust.reserveEditor(
      id: sourceSession.controller.id!,
      generation: sourceSession.controller.generation,
      path: second.path,
    );
    late final RemoteFileSubmissionFailure partial;
    try {
      await rust.prepareEditor(
        editorId: blockedEditor,
        operation: rust.beginEditorOperation(editorId: blockedEditor),
      );
      try {
        await m.enqueueRemoteFileSelection(
          movingSelection,
          copySession,
          directDestination.path,
          copySession.controller.generation,
          allowMemoryRelay: false,
        );
        fail('the active second editor must reject that source move');
      } on RemoteFileSubmissionFailure catch (error) {
        partial = error;
      }
      expect(partial.acceptedIds, hasLength(1));
      expect(partial.remaining.paths, [second.path]);
      expect(await second.exists(), true);
    } finally {
      await rust.closeEditor(editorId: blockedEditor, keepDraft: false);
    }
    final remainingIds = await m.enqueueRemoteFileSelection(
      partial.remaining,
      copySession,
      directDestination.path,
      copySession.controller.generation,
      allowMemoryRelay: false,
    );
    await waitFor(
      () => [
        ...partial.acceptedIds,
        ...remainingIds,
      ].every((id) => m.transferTasks.any((t) => t.id == id && !t.busy)),
      'partial destination action retry',
    );
    expect(await first.exists(), false);
    expect(await second.exists(), false);
    expect(
      await File('${directDestination.path}/direct move A.txt').readAsString(),
      'first move',
    );
    expect(
      await File('${directDestination.path}/direct move B.txt').readAsString(),
      'second move',
    );
    expect(m.remoteFileClipboardRevision, clipboardRevision);
    expect(m.remoteFileClipboardDescription, clipboardDescription);
    await m.clearEndedTasks();
    await m.shutdown();
    for (final native in nativeIds) {
      await expectLater(rust.terminalMetrics(id: native!), throwsA(anything));
    }
    final onDisk = await File(vault).readAsString(encoding: latin1);
    for (final forbidden in [
      'test-only-passphrase',
      'test-only-generated-key-password',
      'BEGIN OPENSSH PRIVATE KEY',
    ]) {
      expect(
        onDisk.contains(forbidden),
        false,
        reason: 'vault contains plaintext credential material',
      );
    }
  } finally {
    await m.shutdown();
    // Native controllers outlive their views. Unmount GTK views before model
    // disposal, including when a test assertion fails inside afterReady.
    if (detach != null) await detach();
    m.dispose();
    await server.close();
  }
}

void main() {
  test(
    'real encrypted hosts and independent SSH/SFTP sessions survive tab layout operations',
    () => exerciseWorkbench(),
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux,
  );
}
