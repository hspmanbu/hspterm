import '../src/rust/api.dart' as rust;

/// Only non-secret metadata crosses back from the encrypted Rust repository.
abstract interface class HostStore {
  String newId();
  Future<List<rust.HostConfig>> hosts();
  Future<List<rust.HostGroupConfig>> groups();
  Future<List<rust.HostConfig>> drafts();
  Future<rust.HostConfig> save(
    rust.HostConfig host,
    String? secret,
    String? passphrase, {
    String? proxyUsername,
    String? proxyPassword,
  });
  Future<void> draft(
    rust.HostConfig host,
    String? secret,
    String? passphrase, {
    String? proxyUsername,
    String? proxyPassword,
  });
  Future<void> discard(String id);
  Future<rust.HostConfig> copy(String id);
  Future<void> delete(List<String> ids);
  Future<void> batch(List<String> ids, String? groupId, bool? favorite);
  Future<void> createGroup(String name);
  Future<void> renameGroup(String id, String name);
  Future<void> deleteGroup(String id);
  Future<rust.HostKeyInfo> generate(rust.HostConfig host, String? passphrase);
  Future<rust.HostKeyInfo> importKey(
    rust.HostConfig host,
    String path,
    String? passphrase,
  );
  Future<rust.HostKeyInfo> publicKey(String id);
  Future<void> exportKey(String id, String path, String masterPassword);
  Future<void> exportPublicKey(String id, String path);
}

/// Optional coherent-read capability; old fixtures can retain the small store
/// interface. Formal UI never assembles three independently timed snapshots.
abstract interface class HostCatalogStore {
  Future<rust.HostCatalogSnapshot> snapshot();
}

class NativeHostStore implements HostStore, HostCatalogStore {
  const NativeHostStore();
  @override
  Future<rust.HostCatalogSnapshot> snapshot() => rust.hostCatalogSnapshot();
  @override
  String newId() => rust.newHostId();
  @override
  Future<List<rust.HostConfig>> hosts() => rust.listHosts();
  @override
  Future<List<rust.HostGroupConfig>> groups() => rust.hostGroups();
  @override
  Future<List<rust.HostConfig>> drafts() => rust.hostDrafts();
  @override
  Future<rust.HostConfig> save(
    rust.HostConfig host,
    String? secret,
    String? passphrase, {
    String? proxyUsername,
    String? proxyPassword,
  }) => rust.saveHost(
    host: host,
    secret: secret,
    passphrase: passphrase,
    proxyAuthentication: _proxy(proxyUsername, proxyPassword),
  );
  @override
  Future<void> draft(
    rust.HostConfig host,
    String? secret,
    String? passphrase, {
    String? proxyUsername,
    String? proxyPassword,
  }) => rust.saveHostDraft(
    host: host,
    secret: secret,
    passphrase: passphrase,
    proxyAuthentication: _proxy(proxyUsername, proxyPassword),
  );
  rust.ProxyAuthenticationInput? _proxy(String? user, String? password) {
    if (user == null && password == null) return null;
    if (user == null || password == null) throw ArgumentError('请同时填写代理用户名和密码');
    return rust.ProxyAuthenticationInput(username: user, password: password);
  }

  @override
  Future<void> discard(String id) => rust.discardHostDraft(id: id);
  @override
  Future<rust.HostConfig> copy(String id) => rust.copyHostToDraft(id: id);
  @override
  Future<void> delete(List<String> ids) => rust.deleteHosts(ids: ids);
  @override
  Future<void> batch(List<String> ids, String? groupId, bool? favorite) =>
      rust.batchHostsMetadata(ids: ids, groupId: groupId, favorite: favorite);
  @override
  Future<void> createGroup(String name) async {
    await rust.createHostGroup(name: name);
  }

  @override
  Future<void> renameGroup(String id, String name) =>
      rust.renameHostGroup(id: id, name: name);
  @override
  Future<void> deleteGroup(String id) => rust.deleteHostGroup(id: id);
  @override
  Future<rust.HostKeyInfo> generate(rust.HostConfig host, String? passphrase) =>
      rust.generateHostKey(host: host, passphrase: passphrase);
  @override
  Future<rust.HostKeyInfo> importKey(
    rust.HostConfig host,
    String path,
    String? passphrase,
  ) => rust.importHostKey(host: host, path: path, passphrase: passphrase);
  @override
  Future<rust.HostKeyInfo> publicKey(String id) => rust.hostPublicKey(id: id);
  @override
  Future<void> exportKey(String id, String path, String masterPassword) => rust
      .exportHostPrivateKey(id: id, path: path, masterPassword: masterPassword);
  @override
  Future<void> exportPublicKey(String id, String path) =>
      rust.exportHostPublicKey(id: id, path: path);
}
