import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import 'design.dart';
import '../workbench/model.dart';
import '../workbench/forwarding_dialog.dart';
import '../workbench/openssh_import.dart';
import '../workbench/host_ordering.dart';
import '../workbench/host_bulk.dart';
import '../workbench/host_catalog_drag.dart';
import '../workbench/typography_settings.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';
import 'host_connection_test_dialog.dart';

class HostManager extends StatefulWidget {
  const HostManager({super.key, required this.model});
  final WorkbenchModel model;
  @override
  State<HostManager> createState() => HostManagerState();
}

class HostManagerState extends State<HostManager> {
  final _form = GlobalKey<FormState>();
  final _networkForm = GlobalKey<FormState>();
  final timeout = TextEditingController(),
      keepalive = TextEditingController(),
      keepaliveFailures = TextEditingController(),
      keepaliveResponse = TextEditingController();
  final _timeoutFocus = FocusNode(),
      _keepaliveFocus = FocusNode(),
      _keepaliveFailuresFocus = FocusNode(),
      _keepaliveResponseFocus = FocusNode();
  final proxyAddress = TextEditingController(),
      proxyPort = TextEditingController(),
      proxyUser = TextEditingController(),
      proxyPassword = TextEditingController();
  final _proxyAddressFocus = FocusNode(),
      _proxyPortFocus = FocusNode(),
      _proxyUserFocus = FocusNode(),
      _proxyPasswordFocus = FocusNode();
  String proxyKind = '无代理';
  String? jumpHostId;
  final _jumpFocus = FocusNode();
  bool proxyAuthenticate = false,
      _proxyCredentialSet = false,
      _proxySecretEdited = false;
  final name = TextEditingController(),
      address = TextEditingController(),
      user = TextEditingController(),
      port = TextEditingController(),
      note = TextEditingController(),
      search = TextEditingController(),
      secret = TextEditingController(),
      passphrase = TextEditingController();
  final _nameFocus = FocusNode(),
      _addressFocus = FocusNode(),
      _userFocus = FocusNode(),
      _portFocus = FocusNode();
  String? editingId;
  int _formEpoch = 0;
  String? saveError;
  Timer? _draftTimer;
  Future<void> _draftTail = Future.value();
  bool _saving = false, _secretEdited = false, _credentialSet = false;
  bool _preparingSave = false, _importOpen = false, _orderingOpen = false;
  bool _bulkOpen = false;
  bool _directDropping = false;
  bool get _newRecord => !m.hosts.any((h) => h.id == editingId);

  String group = '开发环境', auth = '私钥', category = '连接', filterGroup = 'all';
  bool dirty = false, advanced = true, favorite = false;
  bool agentForwarding = false, tmuxEnabled = false, shellIntegration = false;
  bool useNetworkDefaults = false, responseEnabled = false;
  final selected = <String>{};
  final options = <String, bool>{
    '压缩': false,
    '打开 SFTP': true,
    'OSC7 跟随': false,
  };
  WorkbenchModel get m => widget.model;
  @override
  void initState() {
    super.initState();
    load(m.hosts.firstOrNull ?? m.recoverableDrafts.firstOrNull);
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (dirty && !m.isMock) _queueDraft();
    for (final c in [
      name,
      address,
      user,
      port,
      note,
      search,
      secret,
      passphrase,
      proxyAddress,
      proxyPort,
      proxyUser,
      proxyPassword,
      timeout,
      keepalive,
      keepaliveFailures,
      keepaliveResponse,
    ]) {
      c.dispose();
    }
    for (final f in [
      _nameFocus,
      _addressFocus,
      _userFocus,
      _portFocus,
      _proxyAddressFocus,
      _proxyPortFocus,
      _proxyUserFocus,
      _proxyPasswordFocus,
      _timeoutFocus,
      _keepaliveFocus,
      _keepaliveFailuresFocus,
      _keepaliveResponseFocus,
      _jumpFocus,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  void load(DemoHost? h) {
    _formEpoch++;
    _draftTimer?.cancel();
    h = h == null ? null : m.recoveredDraft(h.id) ?? h;
    editingId = h?.id ?? m.nextId();
    _credentialSet = h?.credentialSet ?? false;
    _secretEdited = false;
    saveError = null;
    secret.clear();
    passphrase.clear();
    name.text = h?.name ?? '';
    address.text = h?.address ?? '';
    user.text = h?.user ?? 'ubuntu';
    port.text = '${h?.port ?? 22}';
    note.text = h?.note ?? '';
    group =
        h?.group ??
        (m.hostGroups.contains('开发环境') ? '开发环境' : m.hostGroups.first);
    auth = h?.auth ?? '私钥';
    favorite = h?.favorite ?? false;
    options['打开 SFTP'] = h?.openSftp ?? true;
    options['OSC7 跟随'] = h?.followOsc7 ?? false;
    final proxy = h?.proxy;
    jumpHostId = h?.jumpHostId;
    proxyKind = proxy == null
        ? '无代理'
        : proxy.socks5
        ? 'SOCKS5'
        : 'HTTP CONNECT';
    proxyAddress.text = proxy?.address ?? '';
    proxyPort.text = '${proxy?.port ?? 1080}';
    proxyAuthenticate = proxy?.authenticate ?? false;
    _proxyCredentialSet = proxy?.credentialSet ?? false;
    _proxySecretEdited = false;
    proxyUser.clear();
    proxyPassword.clear();
    timeout.text = '${h?.timeoutSeconds ?? 30}';
    agentForwarding = h?.agentForwarding ?? false;
    tmuxEnabled = h?.tmuxEnabled ?? false;
    shellIntegration = h?.shellIntegration ?? false;
    keepalive.text = '${h?.keepaliveSeconds ?? 30}';
    keepaliveFailures.text = '${h?.keepaliveFailures ?? 3}';
    keepaliveResponse.text = '${h?.keepaliveResponseSeconds ?? 10}';
    useNetworkDefaults = h?.useNetworkDefaults ?? true;
    responseEnabled = h == null || h.keepaliveResponseSeconds != null;
    dirty = h != null && m.recoveredDraft(h.id) != null;
    category = '连接';
    advanced = h != null;
  }

  DemoHost snapshot() => DemoHost(
    editingId ?? m.nextId(),
    name.text.trim(),
    address.text.trim(),
    group,
    favorite: favorite,
    user: user.text.trim(),
    port: int.tryParse(port.text) ?? 0,
    auth: auth,
    note: note.text,
    credentialSet: _credentialSet,
    openSftp: options['打开 SFTP']!,
    followOsc7: options['OSC7 跟随']!,
    jumpHostId: jumpHostId,
    timeoutSeconds: int.tryParse(timeout.text) ?? 0,
    agentForwarding: agentForwarding,
    tmuxEnabled: tmuxEnabled,
    shellIntegration: shellIntegration,
    keepaliveSeconds: int.tryParse(keepalive.text) ?? 86401,
    keepaliveFailures: int.tryParse(keepaliveFailures.text) ?? 0,
    useNetworkDefaults: useNetworkDefaults,
    keepaliveResponseSeconds: responseEnabled
        ? int.tryParse(keepaliveResponse.text) ?? 0
        : null,
    proxy: proxyKind == '无代理'
        ? null
        : DemoProxy(
            socks5: proxyKind == 'SOCKS5',
            address: proxyAddress.text.trim(),
            port: int.tryParse(proxyPort.text) ?? 0,
            authenticate: proxyAuthenticate,
            credentialSet: _proxyCredentialSet,
          ),
  );
  String? get _secret =>
      _secretEdited || (!_credentialSet && !m.isMock) ? secret.text : null;
  void changeAuth(String value) {
    auth = value;
    secret.clear();
    passphrase.clear();
    _secretEdited = false;
    final previous =
        m.recoveredDraft(editingId!) ??
        m.hosts.where((h) => h.id == editingId).firstOrNull;
    _credentialSet = previous?.auth == value && previous!.credentialSet;
    mark();
  }

  void _queueDraft() {
    final host = snapshot(),
        value = _secret,
        phrase = passphrase.text.isEmpty ? null : passphrase.text;
    final proxyUsername = _proxyUsername, proxyPass = _proxyPassword;
    _draftTail = _draftTail
        .then(
          (_) => m.persistDraft(
            host,
            secret: value,
            passphrase: phrase,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPass,
          ),
        )
        .catchError((Object error) {
          if (mounted) setState(() => saveError = '草稿保存失败：$error');
        });
  }

  void mark() {
    setState(() => dirty = true);
    if (!m.isMock) {
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(milliseconds: 300), _queueDraft);
    }
  }

  Future<bool> save() async {
    if (_saving || _preparingSave) return false;
    if (_networkErrors.isNotEmpty) {
      _preparingSave = true;
      final invalidField = _networkErrors.keys.first;
      setState(() {
        advanced = true;
        category = '网络';
      });
      await WidgetsBinding.instance.endOfFrame;
      _preparingSave = false;
      if (!mounted) return false;
      setState(() {});
      _networkForm.currentState?.validate();
      final fields = [
        _proxyAddressFocus,
        _proxyPortFocus,
        _proxyUserFocus,
        _proxyPasswordFocus,
        _timeoutFocus,
        _keepaliveFocus,
        _keepaliveFailuresFocus,
        _jumpFocus,
        _keepaliveResponseFocus,
      ];
      fields[invalidField].requestFocus();
      return false;
    }
    if (category != '连接') {
      _preparingSave = true;
      try {
        setState(() => category = '连接');
        // The shared basic-field Form must be mounted before validation.
        await WidgetsBinding.instance.endOfFrame;
      } finally {
        if (mounted) {
          setState(() => _preparingSave = false);
        } else {
          _preparingSave = false;
        }
      }
      if (!mounted) return false;
    }
    if (!m.isMock &&
        auth == '私钥' &&
        passphrase.text.isNotEmpty &&
        secret.text.isEmpty) {
      setState(() => saveError = '修改私钥口令时请重新提供私钥内容；原有凭据尚未修改。');
      return false;
    }
    if (!(_form.currentState?.validate() ?? false)) {
      if (name.text.trim().isEmpty) {
        _nameFocus.requestFocus();
      } else if (address.text.trim().isEmpty ||
          address.text.contains(RegExp(r'\s'))) {
        _addressFocus.requestFocus();
      } else if (user.text.trim().isEmpty) {
        _userFocus.requestFocus();
      } else {
        _portFocus.requestFocus();
      }
      return false;
    }
    _draftTimer?.cancel();
    setState(() {
      _saving = true;
      saveError = null;
    });
    try {
      await _draftTail;
      final saved = await m.persistHost(
        snapshot(),
        secret: _secret,
        passphrase: passphrase.text.isEmpty ? null : passphrase.text,
        proxyUsername: _proxyUsername,
        proxyPassword: _proxyPassword,
      );
      if (mounted) setState(() => load(saved));
      return true;
    } catch (error) {
      if (mounted) setState(() => saveError = '保存失败：$error');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _importConfig() async {
    if (m is! LiveWorkbenchModel || !await canLeave() || !mounted) return;
    setState(() => _importOpen = true);
    try {
      final imported = await showDialog<List<rust.HostConfig>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const OpenSshImportDialog(),
      );
      if (imported == null || imported.isEmpty) return;
      // Import already committed. A refresh failure cannot be described as a failed import.
      try {
        await (m as LiveWorkbenchModel).load();
        if (mounted) {
          final host = m.hosts
              .where((h) => h.id == imported.first.id)
              .firstOrNull;
          if (host != null) setState(() => load(host));
          notice(context, '已加密导入${imported.length}台主机；请配置凭据后连接。');
        }
      } catch (_) {
        if (mounted) notice(context, '导入已保存，但列表刷新失败；请重新打开主机管理，勿重复导入。');
      }
    } finally {
      if (mounted) setState(() => _importOpen = false);
    }
  }

  HostCatalogDrag _catalogDrag({List<String> ids = const [], String? groupId}) {
    final model = m;
    return HostCatalogDrag(
      owner: model,
      ids: ids,
      groupId: groupId,
      load: () {
        if (model is! LiveWorkbenchModel) throw StateError('Mock不访问加密目录');
        return model.runLocalSettings(rust.loadHostOrdering);
      },
    );
  }

  Future<void> _catalogDrop(
    HostCatalogDrag drag,
    HostCatalogIntent intent,
  ) async {
    final model = m;
    if (_directDropping ||
        model is! LiveWorkbenchModel ||
        !identical(drag.owner, model)) {
      return;
    }
    _directDropping = true;
    var admitted = false, saved = false;
    try {
      final draft = await drag.proposal(intent);
      if (!mounted ||
          !identical(model, m) ||
          !draft.dirty ||
          !await canLeave() ||
          !mounted) {
        return;
      }
      setState(() => _orderingOpen = true);
      admitted = true;
      try {
        await NativeHostOrderingGateway(model).save(draft);
        saved = true;
      } on HostOrderingRefreshFailure {
        saved = true;
        if (mounted) notice(context, '拖放顺序已保存，但主机列表刷新失败；请重新打开主机管理，不要重复操作。');
        return;
      }
      if (mounted) {
        setState(
          () => load(m.hosts.where((h) => h.id == editingId).firstOrNull),
        );
      }
    } catch (error) {
      if (mounted) {
        notice(
          context,
          '${saved ? '拖放已保存，但页面刷新失败' : '拖放未保存，请重新拖动；原配置可能已改变'}：$error',
        );
      }
    } finally {
      _directDropping = false;
      if (admitted && mounted) setState(() => _orderingOpen = false);
    }
  }

  Widget _catalogHost(DemoHost host, String filter, Widget child) {
    if (m is! LiveWorkbenchModel) return child;
    final ids = selected.contains(host.id)
        ? m.hosts
              .where((h) => selected.contains(h.id))
              .map((h) => h.id)
              .toList()
        : [host.id];
    return HostCatalogDrop(
      owner: m,
      insertion: true,
      accept: (d) =>
          !_directDropping && d.groupId == null && !d.ids.contains(host.id),
      onDrop: (d, after) => _catalogDrop(
        d,
        HostCatalogIntent(
          hostId: host.id,
          groupId: search.text.isEmpty && !['all', 'favorites'].contains(filter)
              ? filter
              : null,
          favorite: search.text.isEmpty && filter == 'favorites',
          after: after,
        ),
      ),
      child: HostCatalogDragSource(
        key: ValueKey('host-drag-${host.id}'),
        drag: _catalogDrag(ids: ids),
        label: ids.length == 1 ? host.name : '移动 ${ids.length} 台主机',
        child: child,
      ),
    );
  }

  Widget _catalogTargets() {
    Widget target(String? id, String label) {
      final body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        child: Text(label, style: const TextStyle(fontSize: 10)),
      );
      final drop = HostCatalogDrop(
        key: ValueKey('host-drop-${id ?? 'favorites'}'),
        owner: m,
        accept: (d) =>
            !_directDropping &&
            (id != null ? d.groupId != id : d.groupId == null),
        onDrop: (d, after) => _catalogDrop(
          d,
          HostCatalogIntent(groupId: id, favorite: id == null, after: after),
        ),
        child: body,
      );
      return id == null
          ? drop
          : HostCatalogDragSource(
              drag: _catalogDrag(groupId: id),
              label: label,
              child: drop,
            );
    }

    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 6, 2, 0),
            child: Text('拖放：', style: TextStyle(fontSize: 10)),
          ),
          target(null, '★ 收藏'),
          for (final entry in m.hostGroupEntries) target(entry.$1, entry.$2),
        ],
      ),
    );
  }

  Future<void> _orderHosts() async {
    final model = m;
    if (model is! LiveWorkbenchModel || !await canLeave() || !mounted) return;
    setState(() => _orderingOpen = true);
    var saved = false;
    try {
      final result = await showHostOrdering(context, model);
      if (!mounted || result == null) return;
      saved = true;
      if (result.refreshRequired) await model.load();
      if (mounted) {
        setState(
          () => load(m.hosts.where((h) => h.id == editingId).firstOrNull),
        );
      }
    } catch (error) {
      if (mounted) {
        notice(context, '${saved ? '排序已保存，但列表刷新失败' : '无法打开排序'}：$error');
      }
    } finally {
      if (mounted) setState(() => _orderingOpen = false);
    }
  }

  Future<bool> canLeave() async {
    if (_saving ||
        _preparingSave ||
        _importOpen ||
        _orderingOpen ||
        _bulkOpen) {
      notice(context, '正在处理主机配置，请稍候再切换或退出。');
      return false;
    }
    if (!dirty) return true;
    final answer = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('保留未保存的修改？'),
        content: SizedBox(
          width: 370,
          child: Text(
            m.isMock
                ? '切换主机或离开页面前，请保存或丢弃修改。\n这里只保存到原型内存，重启后不会保留。'
                : '未保存的草稿已在本机加密暂存。正式配置只有点击保存才会生效，丢弃将删除此草稿。',
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(c, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'discard'),
            child: const Text('丢弃'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (answer == 'discard') {
      _draftTimer?.cancel();
      await _draftTail;
      await m.discardDraft(editingId!);
      if (!mounted) return false;
      setState(() => load(m.hosts.where((h) => h.id == editingId).firstOrNull));
      return true;
    }
    if (answer == 'save') {
      // Build the basic form before validating when leaving an advanced tab.
      setState(() => category = '连接');
      await WidgetsBinding.instance.endOfFrame;
      return mounted && await save();
    }
    return false;
  }

  Future<void> choose(DemoHost? host) async {
    final id = host?.id;
    if (!await canLeave() || !mounted) return;
    // Saving while confirming the switch replaces the catalog object.
    // Resolve again after the ACK instead of restoring the pre-save fields.
    final current = id == null
        ? null
        : m.recoveredDraft(id) ?? m.hosts.where((h) => h.id == id).firstOrNull;
    if (id != null && current == null) {
      notice(context, '目标主机或草稿已不存在，请重新选择。');
      return;
    }
    setState(() => load(current));
  }

  Future<void> connect(DemoHost host) async {
    if (await canLeave() && mounted) m.openHost(host);
  }

  Future<void> copy() async {
    final host = m.hosts.where((h) => h.id == editingId).firstOrNull;
    if (host == null || !await canLeave() || !mounted) return;
    if (await confirm(
          context,
          '复制主机配置',
          m.isMock
              ? '正式版会复制认证配置并创建独立凭据，请确认凭据使用范围。\n原型只复制模拟字段，不接触真实凭据；副本仍需显式保存。'
              : '复制配置及认证凭据到独立的加密草稿。请核对凭据使用范围；副本仍需点击保存才可连接。',
          accept: '创建副本',
        ) &&
        mounted) {
      try {
        final copied = await m.copyHost(host);
        if (mounted) {
          setState(() {
            load(copied);
            dirty = true;
            advanced = false;
          });
        }
      } catch (error) {
        if (mounted) notice(context, '复制失败：$error');
      }
    }
  }

  Future<void> delete() async {
    if (selected.isEmpty || !await canLeave() || !mounted) return;
    if (await confirm(
          context,
          m.isMock
              ? '删除 ${selected.length} 台模拟主机？'
              : '删除 ${selected.length} 台主机？',
          m.isMock
              ? '只移除原型内存配置，不强制断开已有模拟会话。正式凭据删除和重新认证行为留待业务集成。'
              : '将删除所选主机的配置、凭据和草稿。已有SSH会话继续运行，但不能再使用被删除的凭据重新认证。',
          accept: '删除',
          danger: true,
        ) &&
        mounted) {
      try {
        await m.deleteHosts(Set.of(selected));
      } catch (error) {
        if (mounted) notice(context, '删除失败：$error');
        return;
      }
      if (!mounted) return;
      selected.clear();
      setState(() => load(m.hosts.firstOrNull));
      m.changed();
    }
  }

  Future<void> batch() async {
    if (selected.isEmpty || !await canLeave() || !mounted) return;
    final model = m;
    if (model is LiveWorkbenchModel) {
      setState(() => _bulkOpen = true);
      var saved = false;
      try {
        final result = await showHostBulk(context, model, Set.of(selected));
        if (!mounted || result == null) return;
        saved = true;
        if (result.refreshRequired) await model.load();
        if (mounted) {
          setState(
            () => load(m.hosts.where((h) => h.id == editingId).firstOrNull),
          );
        }
      } catch (error) {
        if (mounted) {
          notice(context, '${saved ? '批量修改已保存，但列表刷新失败' : '无法打开批量编辑'}：$error');
        }
      } finally {
        if (mounted) setState(() => _bulkOpen = false);
      }
      return;
    }
    var applyGroup = true, applyFavorite = false, targetFavorite = true;
    var targetGroup = m.hostGroups.contains('开发环境')
        ? '开发环境'
        : m.hostGroups.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text('批量编辑 ${selected.length} 台主机'),
          content: SizedBox(
            width: 410,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('仅允许修改明确选择的非敏感属性。地址、用户名、认证、代理和转发不参与批量编辑。'),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('修改分组'),
                  value: applyGroup,
                  onChanged: (v) => update(() => applyGroup = v!),
                ),
                DropdownButtonFormField<String>(
                  initialValue: targetGroup,
                  items: [
                    for (final g in m.hostGroups)
                      DropdownMenuItem(value: g, child: Text(g)),
                  ],
                  onChanged: (v) => update(() => targetGroup = v!),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('修改收藏状态'),
                  value: applyFavorite,
                  onChanged: (v) => update(() => applyFavorite = v!),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('设为收藏'),
                  value: targetFavorite,
                  onChanged: applyFavorite
                      ? (v) => update(() => targetFavorite = v)
                      : null,
                ),
                Text(
                  '影响预览：${m.hosts.where((h) => selected.contains(h.id)).map((h) => h.name).join('、')}',
                  style: TextStyle(fontSize: 11, color: Theme.of(c).hintColor),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: applyGroup || applyFavorite
                  ? () => Navigator.pop(c, true)
                  : null,
              child: Text(m.isMock ? '应用到模拟主机' : '应用修改'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      try {
        await m.batchHosts(
          Set.of(selected),
          group: applyGroup ? targetGroup : null,
          favorite: applyFavorite ? targetFavorite : null,
        );
      } catch (error) {
        if (mounted) notice(context, '批量修改失败：$error');
        return;
      }
      if (!mounted) return;
      setState(() => load(m.hosts.where((h) => h.id == editingId).firstOrNull));
      m.changed();
    }
  }

  Widget field(
    String label,
    TextEditingController controller, {
    FocusNode? focus,
    String? Function(String?)? validator,
    bool password = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: TextFormField(
      key: ValueKey('host-$label'),
      controller: controller,
      focusNode: focus,
      obscureText: password,
      onChanged: (_) => mark(),
      validator: validator,
      decoration: InputDecoration(labelText: label),
    ),
  );
  Widget connection() => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field(
          '主机名称',
          name,
          focus: _nameFocus,
          validator: (s) => s == null || s.trim().isEmpty ? '请输入主机名称' : null,
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: field(
                '主机地址',
                address,
                focus: _addressFocus,
                validator: (s) =>
                    s == null || s.trim().isEmpty || s.contains(RegExp(r'\s'))
                    ? '请输入有效地址（不含空白）'
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 95,
              child: field(
                '端口',
                port,
                focus: _portFocus,
                validator: (s) {
                  final n = int.tryParse(s ?? '');
                  return n == null || n < 1 || n > 65535 ? '1–65535' : null;
                },
              ),
            ),
          ],
        ),
        field(
          '用户名',
          user,
          focus: _userFocus,
          validator: (s) => s == null || s.trim().isEmpty ? '请输入用户名' : null,
        ),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('host-group-$editingId'),
                initialValue: group,
                decoration: const InputDecoration(labelText: '分组'),
                items: [
                  for (final g in m.hostGroups)
                    DropdownMenuItem(value: g, child: Text(g)),
                ],
                onChanged: (v) {
                  group = v!;
                  mark();
                },
              ),
            ),
            const SizedBox(width: 16),
            Row(
              children: [
                Checkbox(
                  value: favorite,
                  onChanged: (v) {
                    favorite = v!;
                    mark();
                  },
                ),
                const Text('收藏'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 15),
        field('备注', note),
        if (!advanced) ...[
          DropdownButtonFormField<String>(
            key: const ValueKey('host-auth'),
            initialValue: auth,
            decoration: const InputDecoration(labelText: '认证方式（只选一种）'),
            items: const [
              DropdownMenuItem(value: '私钥', child: Text('私钥')),
              DropdownMenuItem(value: '密码', child: Text('密码')),
            ],
            onChanged: (v) {
              changeAuth(v!);
            },
          ),
          if (!m.isMock) ...credentialFields(),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => setState(() => advanced = true),
            child: const Text('更多设置 →'),
          ),
        ],
      ],
    ),
  );
  Future<void> _flushDraft() async {
    _draftTimer?.cancel();
    if (dirty) _queueDraft();
    await _draftTail;
  }

  Future<void> _showPublicKey(KeyDetails key) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('${key.algorithm} 公钥'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(key.fingerprint),
            const SizedBox(height: 12),
            SelectableText(
              key.publicKey,
              style: const TextStyle(fontFamily: Desk.mono, fontSize: 11),
            ),
            const SizedBox(height: 12),
            const Text(
              '将公钥配置到目标服务器后才可用于认证。私钥保存在本机加密库；本窗口不显示私钥。',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
        FilledButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: key.publicKey));
            if (c.mounted) notice(c, '公钥已复制');
          },
          child: const Text('复制公钥'),
        ),
        TextButton(
          onPressed: () async {
            final target = await _saveKeyLocation(
              suggestedName: 'id_ssh.pub',
              confirmButtonText: '导出公钥',
            );
            if (target == null || !c.mounted) return;
            try {
              await m.exportPublicKey(editingId!, target.path);
              if (c.mounted) notice(c, '公钥已导出');
            } catch (error) {
              if (c.mounted) notice(c, '公钥导出失败：$error');
            }
          },
          child: const Text('导出公钥文件'),
        ),
      ],
    ),
  );

  Future<FileSaveLocation?> _saveKeyLocation({
    required String suggestedName,
    required String confirmButtonText,
  }) async {
    try {
      return await getSaveLocation(
        suggestedName: suggestedName,
        confirmButtonText: confirmButtonText,
      );
    } catch (error) {
      if (mounted) notice(context, '文件选择器不可用：$error');
      return null;
    }
  }

  Future<void> _prepareKey({required bool generate}) async {
    if (_saving) return;
    if ((_credentialSet || secret.text.isNotEmpty) &&
        !await confirm(
          context,
          '替换当前编辑中的私钥？',
          '新密钥只写入加密草稿。正式配置和运行中的连接不变；点击保存后才替换主机凭据。',
          accept: generate ? '生成新密钥' : '导入密钥',
        )) {
      return;
    }
    if (!mounted) return;
    String? path;
    if (!generate) {
      XFile? selected;
      try {
        selected = await openFile(confirmButtonText: '导入私钥');
      } catch (error) {
        if (mounted) notice(context, '文件选择器不可用：$error');
        return;
      }
      if (selected == null || !mounted) return;
      path = selected.path;
    }
    setState(() {
      _saving = true;
      saveError = null;
    });
    KeyDetails? result;
    try {
      await _flushDraft();
      try {
        result = await m.prepareKey(
          snapshot(),
          path: path,
          passphrase: passphrase.text.isEmpty ? null : passphrase.text,
        );
      } on KeyPreparationRefreshFailure catch (error) {
        result = error.saved;
        if (mounted) saveError = '$error';
      }
      if (mounted) {
        setState(() {
          _credentialSet = true;
          _secretEdited = false;
          secret.clear();
          passphrase.clear();
          dirty = true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => saveError = '密钥处理失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (mounted && result != null) await _showPublicKey(result);
  }

  Future<void> _publicKey() async {
    if (_saving) return;
    setState(() => _saving = true);
    KeyDetails? result;
    try {
      await _flushDraft();
      result = await m.publicKey(editingId!);
    } catch (error) {
      if (mounted) notice(context, '无法读取公钥：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (mounted && result != null) await _showPublicKey(result);
  }

  Future<void> _exportKey() async {
    if (_saving) return;
    final entered = await showDialog<String>(
      context: context,
      builder: (_) => const _KeyExportPasswordDialog(),
    );
    if (entered == null || !mounted) return;
    var password = entered;
    if (password.isEmpty) {
      if (mounted) notice(context, '请输入主密码');
      return;
    }
    final location = await _saveKeyLocation(
      suggestedName: 'id_ssh',
      confirmButtonText: '导出私钥',
    );
    if (location == null || !mounted) {
      password = '';
      return;
    }
    setState(() => _saving = true);
    try {
      await _flushDraft();
      await m.exportKey(editingId!, location.path, password);
      if (mounted) notice(context, '私钥已保存到所选新文件；未写入剪贴板');
    } catch (error) {
      if (mounted) notice(context, '私钥导出失败：$error');
    } finally {
      password = '';
      if (mounted) setState(() => _saving = false);
    }
  }

  List<Widget> credentialFields() => [
    const SizedBox(height: 12),
    Text(
      _credentialSet ? '已保存加密凭据；留空保留。输入新内容可替换。' : '凭据将仅保存到加密配置库。',
      style: const TextStyle(fontSize: 11),
    ),
    const SizedBox(height: 10),
    TextField(
      key: const ValueKey('host-secret'),
      controller: secret,
      obscureText: auth != '私钥',
      maxLines: auth == '私钥' ? 5 : 1,
      decoration: InputDecoration(
        labelText: auth == '私钥' ? 'OpenSSH 私钥内容' : '密码',
      ),
      onChanged: (_) {
        _secretEdited = true;
        mark();
      },
    ),
    if (auth == '私钥') ...[
      const SizedBox(height: 10),
      TextField(
        key: const ValueKey('host-passphrase'),
        controller: passphrase,
        obscureText: true,
        decoration: const InputDecoration(labelText: '私钥口令（可空）'),
        onChanged: (_) {
          mark();
        },
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            key: const ValueKey('generate-host-key'),
            onPressed: () => _prepareKey(generate: true),
            child: const Text('生成 Ed25519'),
          ),
          OutlinedButton(
            key: const ValueKey('import-host-key'),
            onPressed: () => _prepareKey(generate: false),
            child: const Text('导入私钥文件'),
          ),
          TextButton(onPressed: _publicKey, child: const Text('显示 / 复制公钥')),
          TextButton(onPressed: _exportKey, child: const Text('导出私钥…')),
        ],
      ),
    ],
  ];

  bool get _proxyNeedsInput =>
      proxyKind != '无代理' &&
      proxyAuthenticate &&
      (_proxySecretEdited || !_proxyCredentialSet);
  String? get _proxyUsername => _proxyNeedsInput ? proxyUser.text : null;
  String? get _proxyPassword => _proxyNeedsInput ? proxyPassword.text : null;
  bool _validProxyHost(String value) {
    if (value.startsWith('[') || value.endsWith(']')) {
      if (!value.startsWith('[') || !value.endsWith(']')) return false;
      final inner = value.substring(1, value.length - 1);
      return inner.contains(':') && InternetAddress.tryParse(inner) != null;
    }
    return InternetAddress.tryParse(value) != null ||
        (value.isNotEmpty &&
            value.length <= 253 &&
            RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value) &&
            RegExp(r'[A-Za-z0-9]').hasMatch(value));
  }

  Map<int, String> get _networkErrors {
    final errors = <int, String>{};
    if (jumpHostId != null) {
      final jump = m.hosts.where((h) => h.id == jumpHostId).firstOrNull;
      if (jump == null) {
        errors[7] = '跳板主机已删除或未保存，请重新选择';
      } else if (jump.id == editingId || jump.jumpHostId != null) {
        errors[7] = '仅支持一级跳板，不能选择自身或含跳板的主机';
      } else if (proxyKind != '无代理' && jump.proxy != null) {
        errors[7] = '目标与跳板只允许配置一个代理';
      }
    }
    final dependents = m.hosts.where(
      (h) => h.jumpHostId == editingId && h.id != editingId,
    );
    if (dependents.isNotEmpty && jumpHostId != null) {
      errors[7] = '此主机已被用作跳板，不能再设置跳板';
    }
    if (proxyKind != '无代理' && dependents.any((h) => h.proxy != null)) {
      errors[7] = '关联目标已有代理，不能再为此跳板配置第二个代理';
    }
    final timeoutSeconds = int.tryParse(timeout.text),
        heartbeatSeconds = int.tryParse(keepalive.text),
        failures = int.tryParse(keepaliveFailures.text);
    if (timeoutSeconds == null || timeoutSeconds < 1 || timeoutSeconds > 3600) {
      errors[4] = '总超时须为 1–3600 秒';
    }
    if (heartbeatSeconds == null ||
        heartbeatSeconds < 0 ||
        heartbeatSeconds > 86400) {
      errors[5] = '心跳间隔须为 0–86400 秒';
    }
    if (failures == null || failures < 1 || failures > 100) {
      errors[6] = '心跳失败阈值须为 1–100';
    }
    final response = int.tryParse(keepaliveResponse.text);
    if (responseEnabled &&
        (response == null || response < 1 || response > 3600)) {
      errors[8] = '心跳响应超时须为 1–3600 秒';
    }
    if (proxyKind == '无代理') return errors;
    if (!_validProxyHost(proxyAddress.text.trim())) {
      errors[0] = '请输入代理域名或 IP，不含协议、路径或端口';
    }
    final number = int.tryParse(proxyPort.text);
    if (number == null || number < 1 || number > 65535) {
      errors[1] = '请输入 1–65535 的端口';
    }
    if (_proxyNeedsInput) {
      final user = proxyUser.text, password = proxyPassword.text;
      if (user.isEmpty) errors[2] = '请输入代理用户名';
      if (proxyKind == 'SOCKS5') {
        if (utf8.encode(user).length > 255) {
          errors[2] = 'SOCKS5 用户名不能超过 255 UTF-8 字节';
        }
        if (password.isEmpty || utf8.encode(password).length > 255) {
          errors[3] = 'SOCKS5 密码须为 1–255 UTF-8 字节';
        }
      } else {
        bool control(String text) =>
            text.runes.any((r) => r < 32 || (r >= 127 && r <= 159));
        if (user.contains(':') || control(user)) {
          errors[2] = 'HTTP 用户名不能含冒号或控制字符';
        }
        if (control(password) ||
            utf8.encode(user).length + utf8.encode(password).length > 4096) {
          errors[3] = 'HTTP 代理凭据无效或过长';
        }
      }
    }
    return errors;
  }

  Widget connectionTimingFields() {
    final fields = [
      TextFormField(
        key: const ValueKey('host-timeout'),
        controller: timeout,
        focusNode: _timeoutFocus,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: '总超时（秒）',
          helperText: '1–3600',
        ),
        validator: (_) => _networkErrors[4],
        onChanged: (_) => mark(),
      ),
      TextFormField(
        key: const ValueKey('host-keepalive'),
        controller: keepalive,
        focusNode: _keepaliveFocus,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: '心跳间隔（秒）',
          helperText: '0 关闭心跳',
        ),
        validator: (_) => _networkErrors[5],
        onChanged: (_) => mark(),
      ),
      TextFormField(
        key: const ValueKey('host-keepalive-failures'),
        controller: keepaliveFailures,
        focusNode: _keepaliveFailuresFocus,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: '心跳失败阈值',
          helperText: '1–100',
        ),
        validator: (_) => _networkErrors[6],
        onChanged: (_) => mark(),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          key: const ValueKey('host-use-network-defaults'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('使用全局 SSH 网络默认参数'),
          subtitle: const Text('下次连接生效，当前连接不改变。下方覆盖值仅在关闭继承后使用。'),
          value: useNetworkDefaults,
          onChanged: (value) {
            setState(() => useNetworkDefaults = value ?? false);
            mark();
          },
        ),
        LayoutBuilder(
          builder: (_, bounds) => bounds.maxWidth < 420
              ? Column(
                  children: [
                    for (final field in fields)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: field,
                      ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < fields.length; i++) ...[
                      if (i != 0) const SizedBox(width: 12),
                      Expanded(child: fields[i]),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('host-response-enabled'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('主机覆盖：独立等待心跳响应'),
          subtitle: const Text(
            '开启后仅真实 SSH 心跳 ACK 算响应；关闭保留旧主机的兼容检测。心跳间隔 0 仍完全关闭心跳。',
          ),
          value: responseEnabled,
          onChanged: (value) {
            setState(() => responseEnabled = value);
            mark();
          },
        ),
        if (responseEnabled)
          TextFormField(
            key: const ValueKey('host-keepalive-response'),
            controller: keepaliveResponse,
            focusNode: _keepaliveResponseFocus,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '响应超时（秒）',
              helperText: '1–3600，仅在未继承全局参数时使用',
            ),
            validator: (_) => _networkErrors[8],
            onChanged: (_) => mark(),
          ),
        const Text(
          '总超时包含 TCP、唯一代理、跳板认证及目标 SSH 建连，安全确认等待不计时。心跳只检测当前连接，断线后仍需手动重连。',
          style: TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget proxyFields() => Form(
    key: _networkForm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        connectionTimingFields(),
        DropdownButtonFormField<String>(
          key: const ValueKey('host-proxy-kind'),
          initialValue: proxyKind,
          decoration: const InputDecoration(labelText: '连接代理'),
          items: [
            for (final s in ['无代理', 'HTTP CONNECT', 'SOCKS5'])
              DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (value) {
            proxyKind = value!;
            if (value == '无代理') {
              proxyUser.clear();
              proxyPassword.clear();
              _proxySecretEdited = false;
              _proxyCredentialSet = false;
            }
            mark();
          },
        ),
        if (proxyKind != '无代理') ...[
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('host-proxy-address'),
            controller: proxyAddress,
            focusNode: _proxyAddressFocus,
            decoration: const InputDecoration(labelText: '代理地址'),
            validator: (_) => _networkErrors[0],
            onChanged: (_) => mark(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('host-proxy-port'),
            controller: proxyPort,
            focusNode: _proxyPortFocus,
            decoration: const InputDecoration(labelText: '代理端口'),
            keyboardType: TextInputType.number,
            validator: (_) => _networkErrors[1],
            onChanged: (_) => mark(),
          ),
          SwitchListTile(
            key: const ValueKey('host-proxy-authenticate'),
            contentPadding: EdgeInsets.zero,
            title: const Text('代理用户名与密码认证'),
            subtitle: const Text('独立于 SSH 登录认证'),
            value: proxyAuthenticate,
            onChanged: (value) {
              proxyAuthenticate = value;
              if (!value) {
                proxyUser.clear();
                proxyPassword.clear();
                _proxySecretEdited = false;
                _proxyCredentialSet = false;
              }
              mark();
            },
          ),
          if (proxyAuthenticate) ...[
            Text(
              _proxyCredentialSet
                  ? '代理认证已设置；不修改这两项将保留原值。'
                  : '尚未设置代理认证，请填写用户名和密码。',
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: const ValueKey('host-proxy-username'),
              controller: proxyUser,
              focusNode: _proxyUserFocus,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '代理用户名',
                hintText: _proxyCredentialSet ? '已设置；修改时重新填写两项' : null,
              ),
              validator: (_) => _networkErrors[2],
              onChanged: (_) {
                _proxySecretEdited = true;
                mark();
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('host-proxy-password'),
              controller: proxyPassword,
              focusNode: _proxyPasswordFocus,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '代理密码',
                hintText: _proxyCredentialSet ? '已设置；留空且不修改时保留' : null,
              ),
              validator: (_) => _networkErrors[3],
              onChanged: (_) {
                _proxySecretEdited = true;
                mark();
              },
            ),
            const SizedBox(height: 10),
            const Text(
              'HTTP Basic / SOCKS5 认证在到代理的 TCP 链路中不加密，请使用可信代理与网络。',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ],
        const SizedBox(height: 16),
        jumpField(),
        const SizedBox(height: 16),
        if (m.isMock) const Text('原型只保存当前进程的模拟配置，不发起网络请求。'),
        if (!m.isMock)
          const Text(
            '代理与跳板配置加密保存，下一次明确连接或重连生效；不探测网络、不影响已连接会话。跳板使用所选主机的认证；若目标没有代理，使用跳板的代理。端口转发请在进阶页单独管理。',
            style: TextStyle(fontSize: 11),
          ),
      ],
    ),
  );

  Widget jumpField() {
    final candidates = m.hosts
        .where((h) => h.id != editingId && h.jumpHostId == null)
        .toList();
    return DropdownButtonFormField<String>(
      key: ValueKey('host-jump-$editingId'),
      focusNode: _jumpFocus,
      initialValue: jumpHostId ?? '',
      isExpanded: true,
      decoration: const InputDecoration(labelText: '跳板机（最多一级）'),
      items: [
        const DropdownMenuItem(value: '', child: Text('无跳板机')),
        for (final h in candidates)
          DropdownMenuItem(
            value: h.id,
            child: Text(
              '${h.name} · ${h.user}@${h.address}:${h.port}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (jumpHostId != null && !candidates.any((h) => h.id == jumpHostId))
          DropdownMenuItem(
            value: jumpHostId,
            child: const Text('失效的跳板配置 · 请重新选择'),
          ),
      ],
      validator: (_) => _networkErrors[7],
      onChanged: (v) {
        jumpHostId = v == '' ? null : v;
        mark();
      },
    );
  }

  Widget advancedFields() => switch (category) {
    '认证' => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('host-agent-forwarding'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('申请应用内 Agent socket'),
          subtitle: const Text(
            '下一次明确连接生效；不自动授权密钥。连接后从终端菜单逐次选择密钥并限时确认。修改所用密钥或删除其主机将撤销相关授权。',
          ),
          value: agentForwarding,
          onChanged: (value) {
            setState(() => agentForwarding = value);
            mark();
          },
        ),

        DropdownButtonFormField<String>(
          key: const ValueKey('host-auth'),
          initialValue: auth,
          decoration: const InputDecoration(labelText: '认证方式（不自动回退）'),
          items: const [
            DropdownMenuItem(value: '私钥', child: Text('私钥')),
            DropdownMenuItem(value: '密码', child: Text('密码')),
          ],
          onChanged: (v) {
            changeAuth(v!);
          },
        ),
        if (!m.isMock)
          ...credentialFields()
        else ...[
          const SizedBox(height: 18),
          Text(
            auth == '私钥' ? '模拟凭据 · Ed25519' : '密码凭据仅展示原型',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => notice(context, '原型不读取私钥或真实凭据'),
            child: const Text('选择模拟凭据'),
          ),
          const SizedBox(height: 12),
          const Text('正式版使用本机加密凭据；不依赖系统 SSH Agent。不在原型中输入真实密码。'),
        ],
      ],
    ),
    '网络' => proxyFields(),
    'SFTP' => Column(
      children: [
        toggle('打开 SFTP', '连接后初始化关联 SFTP，默认不改变终端焦点'),
        toggle('OSC7 跟随', '仅可信工作目录报告可驱动目录跟随'),
        const SizedBox(height: 16),
        if (m.isMock)
          TextFormField(
            initialValue: '/home/ubuntu',
            onChanged: (_) => mark(),
            decoration: const InputDecoration(labelText: '初始远端目录'),
          )
        else
          const ListTile(
            key: ValueKey('host-sftp-default'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('初始目录：远端 SFTP 的“.”目录'),
            subtitle: Text('首次打开时由服务器解析；SFTP 导航与终端工作目录各自独立。'),
          ),
      ],
    ),
    '终端' => Column(
      children: [
        OutlinedButton(
          key: const ValueKey('host-typography'),
          onPressed: _saving || _preparingSave
              ? null
              : () async {
                  if (m.isMock) {
                    notice(context, '原型不保存主机字体；请使用正式工作台。');
                  } else if (_newRecord || dirty) {
                    notice(context, '请先正式保存主机；字体设置不会自动保存当前修改。');
                  } else if (m case final LiveWorkbenchModel live) {
                    final host = live.hosts
                        .firstWhere((h) => h.id == editingId)
                        .snapshot();
                    await showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('本机主机字体与排版'),
                        content: SizedBox(
                          width: 620,
                          child: SingleChildScrollView(
                            child: TypographySettingsPanel(
                              controller: live.typography,
                              hostId: host.id,
                              hostLabel: host.name,
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  }
                },
          child: const Text('本机字体与排版覆盖'),
        ),
        const SizedBox(height: 16),
        if (!m.isMock)
          TextFormField(
            key: const ValueKey('host-term-static'),
            initialValue: 'xterm-256color',
            readOnly: true,
            decoration: const InputDecoration(
              labelText: 'TERM',
              helperText: 'SSH PTY 申明的终端类型',
            ),
          )
        else
          DropdownButtonFormField<String>(
            initialValue: 'xterm-256color',
            decoration: const InputDecoration(labelText: 'TERM'),
            items: const [
              DropdownMenuItem(
                value: 'xterm-256color',
                child: Text('xterm-256color'),
              ),
              DropdownMenuItem(value: 'xterm', child: Text('xterm')),
            ],
            onChanged: (_) => mark(),
          ),
        const SizedBox(height: 16),
        SwitchListTile.adaptive(
          key: const ValueKey('host-shell-integration'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('可选 Bash Shell 集成'),
          subtitle: const Text(
            '默认关闭。仅在此主机正式保存后、下次明确连接时使用；用于可靠输入识别、历史联想及受控路径填入。不支持或无法确认状态时保持普通输入和安全复制。',
          ),
          value: shellIntegration,
          onChanged: _saving || _preparingSave
              ? null
              : (value) async {
                  final epoch = _formEpoch, originalId = editingId;
                  if (value &&
                      !await confirm(
                        context,
                        '为此主机启用可选 Shell 集成？',
                        '此选项仅属于当前主机。将采用远端 Bash 5.1+ 交互及有限输入钩子，不修改启动文件，不保存任意启动命令；不支持的 Shell、tmux 内层、复杂TUI或输入状态不可靠时禁用联想及直接路径填入。合格单行命令受历史记录开关控制，可能包含敏感信息并参与已启用的加密同步。现有连接不改变，复制主机后需重新启用。',
                        accept: '允许此主机使用',
                      )) {
                    return;
                  }
                  if (!mounted ||
                      _saving ||
                      _preparingSave ||
                      epoch != _formEpoch ||
                      originalId != editingId) {
                    return;
                  }
                  setState(() => shellIntegration = value);
                  mark();
                },
        ),
        SwitchListTile.adaptive(
          key: const ValueKey('host-tmux'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('连接时选择 tmux'),
          subtitle: const Text(
            '下一次明确连接后读取远端会话并选择新建、只读观看或接管；不向普通Shell注入命令。取消则结束本次连接。',
          ),
          value: tmuxEnabled,
          onChanged: (value) {
            setState(() => tmuxEnabled = value);
            mark();
          },
        ),
      ],
    ),
    _ => Column(
      children: [
        if (m.isMock)
          toggle('压缩', '模拟 SSH 压缩设置')
        else
          const ListTile(
            key: ValueKey('host-compression-static'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('SSH 压缩'),
            trailing: Text('未启用'),
          ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const ValueKey('host-forwardings'),
          onPressed: _saving || _preparingSave
              ? null
              : () async {
                  if (m.isMock) {
                    notice(context, '原型不启动真实转发；请从正式工作台管理已保存规则');
                  } else if (_newRecord || dirty) {
                    notice(context, '请先正式保存主机；打开转发管理不会自动保存当前修改。');
                  } else if (m case final LiveWorkbenchModel live) {
                    final host = live.hosts
                        .firstWhere((h) => h.id == editingId)
                        .snapshot();
                    await showSavedForwardings(context, live, host);
                  }
                },
          child: const Text('端口转发配置'),
        ),
        const SizedBox(height: 16),
        Text(
          m.isMock
              ? 'Agent 转发需显式、限时授权；本原型不启用任何转发。'
              : '端口转发在原SSH会话上显式启动或停止。Agent需先在认证页允许请求，再在原会话中明确、限时授权；不依赖系统Agent。',
        ),
      ],
    ),
  };
  Widget toggle(String key, String subtitle) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(key, style: const TextStyle(fontSize: 13)),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    value: options[key]!,
    onChanged: (v) {
      options[key] = v;
      mark();
    },
  );

  Widget hostFooter() {
    final test = TextButton(
      onPressed: () async {
        if (m.isMock) {
          notice(context, '模拟连接测试：不会进行真实 TCP、SSH 或 DNS 探测');
        } else if (_newRecord || dirty) {
          notice(context, '请先点击保存；连接测试仅使用正式保存的配置，不会自动保存修改。');
        } else {
          final host = m.hosts.firstWhere((h) => h.id == editingId).snapshot();
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => HostConnectionTestDialog(model: m, host: host),
          );
        }
      },
      child: Text(m.isMock ? '测试连接 · 模拟' : '测试连接'),
    );
    final temporary = TextButton(
      key: const ValueKey('temporary-host-connect'),
      onPressed: () async {
        if (m.isMock) {
          notice(context, '模拟模式：临时覆盖入口不建立真实连接');
          return;
        }
        if (_newRecord) {
          notice(context, '请先正式保存主机，再使用本次临时覆盖');
          return;
        }
        if (!await canLeave() || !mounted) return;
        final host = m.hosts.where((h) => h.id == editingId).firstOrNull;
        if (host != null) await m.openTemporaryHost(host);
      },
      child: const Text('临时覆盖'),
    );
    final saveButton = OutlinedButton(
      key: const ValueKey('save-host'),
      onPressed: () async {
        if (await save() && mounted) {
          notice(context, m.isMock ? '模拟配置已保存至内存' : '配置已加密保存');
        }
      },
      child: const Text('保存'),
    );
    final connect = FilledButton(
      onPressed: () async {
        if (await save() && mounted) {
          m.openHost(m.hosts.firstWhere((h) => h.id == editingId));
        }
      },
      child: const Text('保存并连接'),
    );
    return LayoutBuilder(
      builder: (_, bounds) => bounds.maxWidth < 400
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(children: [test, temporary]),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [saveButton, const SizedBox(width: 8), connect],
                ),
              ],
            )
          : Row(
              children: [
                test,
                temporary,
                const Spacer(),
                saveButton,
                const SizedBox(width: 8),
                connect,
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: _saving || _preparingSave || _orderingOpen || _bulkOpen,
    child: AbsorbPointer(
      absorbing: _saving || _preparingSave || _orderingOpen || _bulkOpen,
      child: LayoutBuilder(
        builder: (context, bounds) {
          final listWidth = m.hostListWidth
              .clamp(190, bounds.maxWidth * .43)
              .toDouble();
          final entries = m.hostGroupEntries;
          final filter =
              [
                'all',
                'favorites',
                ...entries.map((e) => e.$1),
              ].contains(filterGroup)
              ? filterGroup
              : 'all';
          final groupName = entries
              .where((e) => e.$1 == filter)
              .firstOrNull
              ?.$2;
          final query = search.text.toLowerCase();
          // A search deliberately flattens all groups; navigation buckets use
          // private IDs rather than colliding with a user's saved group name.
          final filtered = m.hosts
              .where(
                (h) => query.isNotEmpty
                    ? '${h.name} ${h.address} ${h.user}'.toLowerCase().contains(
                        query,
                      )
                    : filter == 'all' ||
                          filter == 'favorites' && h.favorite ||
                          h.group == groupName,
              )
              .toList();
          return Column(
            children: [
              Container(
                height: 49,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text(
                      '主机管理',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (m.isMock || bounds.maxWidth >= 550)
                      DeskBadge(m.isMock ? '模拟配置 · 仅内存' : '本机加密配置'),
                    const Spacer(),
                    if (!m.isMock && m.recoverableDrafts.isNotEmpty)
                      PopupMenuButton<String>(
                        key: const ValueKey('recover-host-draft'),
                        tooltip: '恢复未保存的加密草稿',
                        onSelected: (id) {
                          if (id != editingId) {
                            unawaited(
                              choose(
                                m.recoverableDrafts.firstWhere(
                                  (h) => h.id == id,
                                ),
                              ),
                            );
                          }
                        },
                        itemBuilder: (_) => [
                          for (final draft in m.recoverableDrafts)
                            PopupMenuItem(
                              value: draft.id,
                              child: Text(
                                draft.name.isEmpty ? '未命名主机' : draft.name,
                              ),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              const Icon(Icons.restore_page_outlined, size: 16),
                              const SizedBox(width: 5),
                              Text(
                                '草稿 ${m.recoverableDrafts.length}',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (!m.isMock)
                      IconButton(
                        key: const ValueKey('import-openssh-config'),
                        tooltip: '导入 OpenSSH Config',
                        onPressed: _saving || _preparingSave || _importOpen
                            ? null
                            : _importConfig,
                        icon: const Icon(Icons.file_open_outlined, size: 18),
                      ),
                    if (!m.isMock && m is LiveWorkbenchModel)
                      IconButton(
                        key: const ValueKey('host-ordering'),
                        tooltip: '主机排序、分组与收藏',
                        onPressed: _orderHosts,
                        icon: const Icon(Icons.swap_vert, size: 18),
                      ),
                    if (!m.isMock && bounds.maxWidth < 420)
                      IconButton(
                        key: const ValueKey('new-host'),
                        tooltip: '新建主机',
                        onPressed: () => choose(null),
                        icon: const Icon(Icons.add, size: 18),
                      )
                    else
                      OutlinedButton.icon(
                        key: const ValueKey('new-host'),
                        onPressed: () => choose(null),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('新建主机'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: listWidth,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: TextField(
                              key: const ValueKey('host-search'),
                              controller: search,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                hintText: '搜索名称、地址、用户',
                                prefixIcon: Icon(Icons.search, size: 16),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: DropdownButton<String>(
                              isExpanded: true,
                              key: const ValueKey('host-group-filter'),
                              value: filter,
                              underline: const SizedBox(),
                              style: Theme.of(context).textTheme.bodySmall,
                              items: [
                                const DropdownMenuItem(
                                  value: 'all',
                                  child: Text('全部主机'),
                                ),
                                const DropdownMenuItem(
                                  value: 'favorites',
                                  child: Text('★ 收藏'),
                                ),
                                for (final e in entries)
                                  DropdownMenuItem(
                                    value: e.$1,
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.folder_outlined,
                                          size: 14,
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            e.$2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => filterGroup = v!),
                            ),
                          ),
                          if (m is LiveWorkbenchModel) _catalogTargets(),
                          if (selected.isNotEmpty)
                            Wrap(
                              children: [
                                TextButton(
                                  onPressed: batch,
                                  child: Text('批量编辑 ${selected.length}'),
                                ),
                                Tool(Icons.delete_outline, '批量删除', delete),
                                Tool(Icons.open_in_new, '分别连接选中主机', () async {
                                  if (!await canLeave() || !mounted) return;
                                  for (final h in m.hosts.where(
                                    (h) => selected.contains(h.id),
                                  )) {
                                    m.openHost(h);
                                  }
                                }),
                              ],
                            ),
                          Expanded(
                            child: ListView(
                              children: [
                                for (final h in filtered)
                                  _catalogHost(
                                    h,
                                    filter,
                                    GestureDetector(
                                      key: ValueKey('host-row-${h.id}'),
                                      onDoubleTap: () => connect(h),
                                      child: Material(
                                        color: editingId == h.id
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: .1)
                                            : Colors.transparent,
                                        child: InkWell(
                                          onTap: () => choose(h),
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              5,
                                              5,
                                              8,
                                              5,
                                            ),
                                            child: Row(
                                              children: [
                                                Checkbox(
                                                  value: selected.contains(
                                                    h.id,
                                                  ),
                                                  onChanged: (v) =>
                                                      setState(() {
                                                        v!
                                                            ? selected.add(h.id)
                                                            : selected.remove(
                                                                h.id,
                                                              );
                                                      }),
                                                ),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        h.name,
                                                        style: const TextStyle(
                                                          fontSize: 12,
                                                        ),
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                      const SizedBox(height: 3),
                                                      Text(
                                                        '${h.user}@${h.address}:${h.port}',
                                                        style: TextStyle(
                                                          fontSize: 10,
                                                          color: Theme.of(
                                                            context,
                                                          ).hintColor,
                                                        ),
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                Tool(
                                                  h.favorite
                                                      ? Icons.star
                                                      : Icons.star_border,
                                                  '切换收藏',
                                                  () async {
                                                    final value = !h.favorite;
                                                    try {
                                                      await m.batchHosts({
                                                        h.id,
                                                      }, favorite: value);
                                                      if (mounted &&
                                                          editingId == h.id) {
                                                        setState(
                                                          () =>
                                                              favorite = value,
                                                        );
                                                        if (dirty) mark();
                                                      }
                                                    } catch (error) {
                                                      if (context.mounted) {
                                                        notice(
                                                          context,
                                                          '收藏保存失败：$error',
                                                        );
                                                      }
                                                    }
                                                  },
                                                  size: 14,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    ResizeGrip(
                      key: const ValueKey('host-list-grip'),
                      horizontal: true,
                      onDelta: (d) {
                        m.hostListWidth = (listWidth + d).clamp(
                          190,
                          bounds.maxWidth * .43,
                        );
                        m.changed();
                      },
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 16, 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _newRecord ? '新建主机' : name.text,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (dirty)
                                  const DeskBadge('未保存', color: Desk.warning),
                                const SizedBox(width: 6),
                                Tool(
                                  Icons.copy_outlined,
                                  '复制主机',
                                  _newRecord ? null : copy,
                                ),
                              ],
                            ),
                          ),
                          if (advanced)
                            SizedBox(
                              height: 34,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                children: [
                                  for (final c in [
                                    '连接',
                                    '认证',
                                    '网络',
                                    'SFTP',
                                    '终端',
                                    '进阶',
                                  ])
                                    TextButton(
                                      onPressed: () =>
                                          setState(() => category = c),
                                      child: Text(
                                        c,
                                        style: TextStyle(
                                          color: category == c
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                              : Theme.of(context).hintColor,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          const Divider(height: 1),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(22),
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 560,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        category == '连接' ? '连接信息' : category,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        m.isMock
                                            ? '所有配置为模拟数据，不写入加密库或发起 SSH 连接。'
                                            : '请显式保存主机配置；未保存内容仅作为本机草稿保留。',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context).hintColor,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      if (saveError != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 10,
                                          ),
                                          child: Text(
                                            saveError!,
                                            key: const ValueKey(
                                              'host-save-error',
                                            ),
                                            style: const TextStyle(
                                              color: Desk.danger,
                                            ),
                                          ),
                                        ),
                                      category == '连接'
                                          ? connection()
                                          : advancedFields(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const Divider(height: 1),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 11,
                            ),
                            child: hostFooter(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// The route owns the controller through its closing animation. Clearing the
/// field before pop removes the displayed secret without disposing live input.
class _KeyExportPasswordDialog extends StatefulWidget {
  const _KeyExportPasswordDialog();
  @override
  State<_KeyExportPasswordDialog> createState() =>
      _KeyExportPasswordDialogState();
}

class _KeyExportPasswordDialogState extends State<_KeyExportPasswordDialog> {
  final master = TextEditingController();
  @override
  void dispose() {
    master.clear();
    master.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导出私钥：重新验证主密码'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('导出文件可能包含未加密私钥。请妥善保护文件，不要通过剪贴板传递；已有文件不会被覆盖。'),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('key-export-master'),
            controller: master,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: '本机配置库主密码'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          master.clear();
          Navigator.pop(context);
        },
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final password = master.text;
          master.clear();
          Navigator.pop(context, password);
        },
        child: const Text('选择文件并导出'),
      ),
    ],
  );
}
