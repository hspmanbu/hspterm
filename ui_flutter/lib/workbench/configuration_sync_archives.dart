import '../prototype/design.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import 'model.dart';

class ConfigurationSyncArchive {
  ConfigurationSyncArchive(Map<String, dynamic> value)
    : id = value['id'] as String,
      collection = value['collection'] as String,
      units = value['units'] as int,
      tombstones = value['tombstones'] as int,
      active = value['active'] as bool {
    if (value.length != 5 ||
        !RegExp(r'^local-cloud-sync-ledger-archive-[a-f0-9]{64}$')
            .hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(collection) ||
        units < 0 ||
        units > 24000 ||
        tombstones < 0 ||
        tombstones > units) {
      throw const FormatException('同步基线归档元数据无效');
    }
  }
  final String id, collection;
  final int units, tombstones;
  final bool active;
}

class ConfigurationSyncArchives {
  ConfigurationSyncArchives(Map<String, dynamic> value)
    : scope = value['vault_scope'] as String,
      revision = value['revision'] as String,
      items = List.unmodifiable(
        (value['items'] as List<dynamic>).map(
          (i) => ConfigurationSyncArchive(i as Map<String, dynamic>),
        ),
      ) {
    if (value.length != 3 ||
        scope.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision) ||
        items.length > 8 ||
        items.map((i) => i.id).toSet().length != items.length ||
        items.where((i) => i.active).length > 1) {
      throw const FormatException('同步基线归档列表无效');
    }
  }
  final String scope, revision;
  final List<ConfigurationSyncArchive> items;
}

abstract interface class ConfigurationSyncArchivesGateway {
  Object get owner;
  bool get isClosing;
  Future<ConfigurationSyncArchives> load();
  Future<ConfigurationSyncArchives> remove(
    ConfigurationSyncArchives source,
    List<String> ids,
  );
}

class NativeConfigurationSyncArchivesGateway
    implements ConfigurationSyncArchivesGateway {
  const NativeConfigurationSyncArchivesGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Object get owner => model;
  @override
  bool get isClosing => model.isClosing;
  @override
  Future<ConfigurationSyncArchives> load() => model.runLocalSettings(
    () async => ConfigurationSyncArchives(
      jsonDecode(await rust.loadConfigurationSyncArchives())
          as Map<String, dynamic>,
    ),
  );
  @override
  Future<ConfigurationSyncArchives> remove(
    ConfigurationSyncArchives source,
    List<String> ids,
  ) => model.runLocalSettings(
    () async => ConfigurationSyncArchives(
      jsonDecode(
        await rust.removeConfigurationSyncArchives(
          proposal: jsonEncode({
            'vault_scope': source.scope,
            'revision': source.revision,
            'ids': ids,
            'confirm_local_baseline_loss': true,
          }),
        ),
      ) as Map<String, dynamic>,
    ),
  );
}

class ConfigurationSyncArchivesPanel extends StatefulWidget {
  const ConfigurationSyncArchivesPanel({super.key, required this.gateway});
  final ConfigurationSyncArchivesGateway gateway;
  @override
  State<ConfigurationSyncArchivesPanel> createState() =>
      _ConfigurationSyncArchivesPanelState();
}

class _ConfigurationSyncArchivesPanelState
    extends State<ConfigurationSyncArchivesPanel> {
  ConfigurationSyncArchives? _source;
  final _selected = <String>{};
  bool _loading = true, _saving = false, _confirming = false;
  String? _error, _notice;
  int _request = 0;
  bool get _busy => _loading || _saving || widget.gateway.isClosing;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(ConfigurationSyncArchivesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.gateway.owner, widget.gateway.owner)) {
      _request++;
      _source = null;
      _selected.clear();
      _loading = true;
      _saving = false;
      _confirming = false;
      _error = _notice = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    final gateway = widget.gateway, owner = widget.gateway.owner;
    if (_saving || gateway.isClosing) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _source = null;
      _selected.clear();
      _error = _notice = null;
    });
    try {
      final value = await gateway.load();
      if (mounted &&
          request == _request &&
          identical(owner, widget.gateway.owner) &&
          !gateway.isClosing) {
        setState(() => _source = value);
      }
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '读取归档失败；没有清理任何基线，不能将未知格式作为空列表。');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _remove() async {
    final source = _source,
        gateway = widget.gateway,
        owner = widget.gateway.owner;
    if (_busy || source == null || _selected.isEmpty) return;
    final ids = source.items
        .where((i) => !i.active && _selected.contains(i.id))
        .map((i) => i.id)
        .toList(growable: false);
    if (ids.isEmpty) return;
    final request = ++_request;
    setState(() {
      _saving = true;
      _confirming = true;
      _error = _notice = null;
    });
    try {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text('删除 ${ids.length} 份本机同步基线归档'),
          content: const Text(
            '将永久移除所选旧目标的本机合并基线及其中的删除标记。再次切回该目标时需要重新合并，可能重新出现冲突。当前正式配置和云端文件均不删除。确认仅清理这些本机归档？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除本机归档'),
            ),
          ],
        ),
      );
      if (mounted && request == _request) {
        setState(() => _confirming = false);
      }
      if (confirmed != true ||
          !mounted ||
          request != _request ||
          !identical(owner, widget.gateway.owner) ||
          gateway.isClosing ||
          !identical(source, _source)) {
        return;
      }
      final saved = await gateway.remove(source, ids);
      if (!mounted ||
          request != _request ||
          !identical(owner, widget.gateway.owner)) {
        return;
      }
      setState(() {
        _source = saved;
        _selected.clear();
        _notice = '本机归档已删除；当前配置和云端文件保留。';
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '未收到完整清理回执；来源可能已改变或存储失败，请重新读取归档状态，不重放旧选择。');
      }
    } finally {
      if (mounted && request == _request) {
        setState(() {
          _saving = false;
          _confirming = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('本机同步基线归档', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text(
          '切换同步目标时最多保留八份基线，用于返回旧集合时继续合并。归档不是完整备份，不发送网络请求。当前目标的归档不可清理。',
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_source != null && _source!.items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('没有本机基线归档'),
          ),
        for (final item in _source?.items ?? const <ConfigurationSyncArchive>[])
          CheckboxListTile(
            key: ValueKey(item.id),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: _selected.contains(item.id),
            onChanged: _busy || item.active
                ? null
                : (v) => setState(() {
                    if (v!) {
                      _selected.add(item.id);
                    } else {
                      _selected.remove(item.id);
                    }
                  }),
            title: Text(
              '集合 ${item.collection}',
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${item.units} 项 · ${item.tombstones} 条删除标记${item.active ? ' · 当前目标，保留' : ''}',
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: _busy ? null : _load,
              child: const Text('读取本机归档'),
            ),
            TextButton(
              onPressed: _busy || _selected.isEmpty ? null : _remove,
              child: const Text('清理所选归档'),
            ),
          ],
        ),
        if (_saving && !_confirming) const LinearProgressIndicator(),
        if (_notice != null) Text(_notice!),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
