import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/directory_reader.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/store.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

/// Store decorator that records saved records so tests can assert exactly
/// which fields a toggle persists (and that nothing else changes).
class _RecordingStore implements HostStore, HostCatalogStore {
  _RecordingStore(this._inner);
  final HostStore _inner;
  final saves = <rust.HostConfig>[];

  @override
  Future<rust.HostCatalogSnapshot> snapshot() =>
      (_inner as HostCatalogStore).snapshot();
  @override
  String newId() => _inner.newId();
  @override
  Future<List<rust.HostConfig>> hosts() => _inner.hosts();
  @override
  Future<List<rust.HostGroupConfig>> groups() => _inner.groups();
  @override
  Future<List<rust.HostConfig>> drafts() => _inner.drafts();
  @override
  Future<rust.HostConfig> save(
    rust.HostConfig host,
    String? secret,
    String? passphrase, {
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    final saved = await _inner.save(
      host,
      secret,
      passphrase,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
    );
    saves.add(saved);
    return saved;
  }

  @override
  Future<void> draft(
    rust.HostConfig host,
    String? secret,
    String? passphrase, {
    String? proxyUsername,
    String? proxyPassword,
  }) => _inner.draft(
    host,
    secret,
    passphrase,
    proxyUsername: proxyUsername,
    proxyPassword: proxyPassword,
  );
  @override
  Future<void> discard(String id) => _inner.discard(id);
  @override
  Future<rust.HostConfig> copy(String id) => _inner.copy(id);
  @override
  Future<void> delete(List<String> ids) => _inner.delete(ids);
  @override
  Future<void> batch(List<String> ids, String? groupId, bool? favorite) =>
      _inner.batch(ids, groupId, favorite);
  @override
  Future<void> createGroup(String name) => _inner.createGroup(name);
  @override
  Future<void> renameGroup(String id, String name) =>
      _inner.renameGroup(id, name);
  @override
  Future<void> deleteGroup(String id) => _inner.deleteGroup(id);
  @override
  Future<rust.HostKeyInfo> generate(rust.HostConfig host, String? passphrase) =>
      _inner.generate(host, passphrase);
  @override
  Future<rust.HostKeyInfo> importKey(
    rust.HostConfig host,
    String path,
    String? passphrase,
  ) => _inner.importKey(host, path, passphrase);
  @override
  Future<rust.HostKeyInfo> publicKey(String id) => _inner.publicKey(id);
  @override
  Future<void> exportKey(String id, String path, String masterPassword) =>
      _inner.exportKey(id, path, masterPassword);
  @override
  Future<void> exportPublicKey(String id, String path) =>
      _inner.exportPublicKey(id, path);
}

void main() {
  test(
    'locate succeeds on cache hits, repeats and survives concurrent navigation',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      var holdPage = false;
      final pageStarted = Completer<void>(), releasePage = Completer<void>();
      final recording = _RecordingStore(const NativeHostStore());
      final m = LiveWorkbenchModel(
        store: recording,
        directoryReader: PagedDirectoryReader(
          page:
              ({
                required id,
                required generation,
                required request,
                required limit,
              }) async {
                if (holdPage) {
                  holdPage = false;
                  pageStarted.complete();
                  await releasePage.future;
                }
                return rust.sftpDirectoryPage(
                  id: id,
                  generation: generation,
                  request: request,
                  limit: limit,
                );
              },
        ),
      );
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/locate.vault',
          password: 'synthetic locate master',
        );
        await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Locate fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        await m.load();
        m.confirmHostKey = (_, _) async => true;
        m.openHost(m.hosts.single);
        final a = m.sessions[0] as LiveTerminalSession;
        await waitFor(() => a.controller.connected, 'locate SSH session');
        await a.controller.setVisible(true);
        final directory = await Directory('${server.directory.path}/locate-dir')
            .create();
        final file = await File('${directory.path}/target.txt')
            .writeAsString('body');

        // First locate: fresh read publishes the directory.
        final initialLocate = m.locateTerminalPath(a, file.path);
        expect(
          a.sftpActivity,
          '正在定位文件…',
          reason: 'feedback precedes native resolution',
        );
        await initialLocate;
        expect(a.sftpActivity, isNull);
        expect(a.path, directory.path);
        expect(a.pendingFileLocation?.file, file.path);

        // Repeat locate on the now-cached directory must succeed too.
        a.pendingFileLocation = null;
        final beforeCached = a.directoryPublishVersion;
        final cachedLocate = m.locateTerminalPath(a, file.path);
        expect(
          a.pendingFileLocation?.file,
          file.path,
          reason: 'a known current file is selected synchronously without remote IO',
        );
        await cachedLocate;
        expect(a.directoryPublishVersion, beforeCached);
        expect(a.sftpActivity, isNull);
        expect(
          a.path,
          directory.path,
          reason: 'cached locate must not fail with StateError',
        );
        expect(
          a.pendingFileLocation?.file,
          file.path,
          reason: 'cached locate still selects the file',
        );

        // Locate the directory itself while already inside it.
        await m.locateTerminalPath(a, directory.path);
        expect(a.path, directory.path);
        expect(a.pendingFileLocation?.directory, directory.path);
        expect(a.pendingFileLocation?.file, isNull);

        // A late locate superseded by explicit navigation must not override.
        final staleDir = await Directory('${server.directory.path}/stale-dir')
            .create();
        await File('${staleDir.path}/stale.txt').writeAsString('stale');
        holdPage = true;
        final stale = m.locateTerminalPath(a, staleDir.path);
        await pageStarted.future.timeout(const Duration(seconds: 10));
        await m.loadDirectory(a, server.directory.path);
        releasePage.complete();
        await stale;
        expect(
          a.path,
          server.directory.path,
          reason: 'newer user navigation wins',
        );
        expect(
          a.pendingFileLocation,
          isNull,
          reason: 'late selection never overrides a newer navigation',
        );

        // Locate must fail loudly when the app is shutting down around it.
        final dead = m.locateTerminalPath(a, file.path);
        await m.shutdown();
        await expectLater(dead, throwsA(anything));
      } finally {
        if (!releasePage.isCompleted) releasePage.complete();
        await m.shutdown();
        m.dispose();
        await server.close();
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'directory follow toggle persists per host and survives reload',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      final recording = _RecordingStore(const NativeHostStore());
      final m = LiveWorkbenchModel(store: recording);
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/follow-persist.vault',
          password: 'synthetic follow persist master',
        );
        await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Follow persist fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        await m.load();
        m.confirmHostKey = (_, _) async => true;
        m.openHost(m.hosts.single);
        final a = m.sessions[0] as LiveTerminalSession;
        await waitFor(() => a.controller.connected, 'follow SSH session');
        expect(m.followsTerminalDirectory(a), isFalse);

        await m.setTerminalDirectoryFollow(a, true);
        expect(m.followsTerminalDirectory(a), isTrue);
        final saved = recording.saves.single;
        final hostId = (await recording.hosts())
            .singleWhere((h) => h.name == 'Follow persist fixture')
            .id;
        expect(saved.id, hostId);
        expect(
          saved.followOsc7,
          isTrue,
          reason: 'toggle must persist followOsc7 on the host record',
        );
        // Only the flag changed; the rest of the record is untouched.
        final original = (await recording.hosts()).singleWhere(
          (h) => h.id == hostId,
        );
        expect(saved.name, original.name);
        expect(saved.address, original.address);
        expect(saved.port, original.port);
        expect(saved.username, original.username);
        expect(saved.note, original.note);

        // Same host in a second tab agrees without touching it.
        m.openHost(m.hosts.single);
        final b = m.sessions[1] as LiveTerminalSession;
        await waitFor(() => b.controller.connected, 'second tab session');
        expect(m.followsTerminalDirectory(b), isTrue);

        // A fresh model (restart) reads the persisted state.
        final m2 = LiveWorkbenchModel(store: recording);
        await m2.load();
        m2.openHost(m2.hosts.single);
        final c = m2.sessions[0] as LiveTerminalSession;
        await waitFor(() => c.controller.connected, 'restart session');
        expect(
          m2.followsTerminalDirectory(c),
          isTrue,
          reason: 'follow state must survive a restart via the host record',
        );

        // Turning it off persists false.
        await m2.setTerminalDirectoryFollow(c, false);
        expect(m2.followsTerminalDirectory(c), isFalse);
        expect(recording.saves.last.followOsc7, isFalse);
        await m2.shutdown();
        m2.dispose();
      } finally {
        await m.shutdown();
        m.dispose();
        await server.close();
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
