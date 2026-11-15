import 'file_size.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_notice.dart';
import '../prototype/design.dart';
import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';

abstract interface class FilePropertiesGateway {
  bool get current;
  Future<rust.RemoteProperties> load(bool includeSize);
  Future<void> save({
    int? permissions,
    int? uid,
    int? gid,
    required bool recursive,
  });

  /// Account names from the remote account databases; null keeps numeric
  /// entry as the fallback and never blocks the dialog.
  Future<rust.RemoteAccountOptions?> accounts();

  /// Starts a progressive directory-size walk; returns its ticket.
  Future<String> sizeBegin();

  /// One bounded page of the walk with cumulative totals.
  Future<rust.DirectorySizePage> sizeStep(String ticket);

  /// Explicitly retires a walk ticket; idempotent.
  Future<void> sizeStop(String ticket);
}

class NativeFilePropertiesGateway implements FilePropertiesGateway {
  NativeFilePropertiesGateway(this.model, this.source, this.file)
    : native = source.controller.id!,
      generation = source.controller.generation;
  final LiveWorkbenchModel model;
  final LiveTerminalSession source;
  final DemoFile file;
  final int native, generation;
  @override
  bool get current =>
      !model.isClosing &&
      model.sessions.contains(source) &&
      source.controller.connected &&
      source.controller.id == native &&
      source.controller.generation == generation;
  @override
  Future<rust.RemoteProperties> load(bool includeSize) {
    if (!current) return Future.error(StateError('原关联会话已改变'));
    return model.runLocalSettings(
      () => rust.sftpProperties(
        id: native,
        generation: generation,
        path: file.id,
        includeDirectorySize: includeSize,
      ),
      reportFailure: false,
    );
  }

  @override
  Future<void> save({
    int? permissions,
    int? uid,
    int? gid,
    required bool recursive,
  }) {
    if (!current) return Future.error(StateError('原关联会话已改变'));
    return model.runLocalSettings(
      () => rust.sftpSetProperties(
        id: native,
        generation: generation,
        path: file.id,
        permissions: permissions,
        uid: uid,
        gid: gid,
        recursive: recursive,
      ),
      reportFailure: false,
    );
  }

  @override
  Future<rust.RemoteAccountOptions?> accounts() {
    if (!current) return Future.error(StateError('原关联会话已改变'));
    return model.runLocalSettings(
      () => rust.sftpAccountOptions(id: native, generation: generation),
      reportFailure: false,
    );
  }

  @override
  Future<String> sizeBegin() {
    if (!current) return Future.error(StateError('原关联会话已改变'));
    return model.runLocalSettings(
      () => rust.sftpDirectorySizeBegin(
        id: native,
        generation: generation,
        path: file.id,
      ),
      reportFailure: false,
    );
  }

  @override
  Future<rust.DirectorySizePage> sizeStep(String ticket) {
    if (!current) return Future.error(StateError('原关联会话已改变'));
    return model.runLocalSettings(
      () => rust.sftpDirectorySizeStep(
        id: native,
        generation: generation,
        ticket: ticket,
      ),
      reportFailure: false,
    );
  }

  @override
  Future<void> sizeStop(String ticket) {
    if (!current) return Future.error(StateError('原关联会话已改变'));
    return model.runLocalSettings(
      () => rust.sftpDirectorySizeStop(id: native, ticket: ticket),
      reportFailure: false,
    );
  }
}

Future<void> showFileProperties(
  BuildContext context,
  LiveWorkbenchModel model,
  LiveTerminalSession source,
  DemoFile file,
) => showAppDialog<void>(
  context: context,
  builder: (_) => FilePropertiesDialog(
    gateway: NativeFilePropertiesGateway(model, source, file),
    file: file,
  ),
);

class FilePropertiesDialog extends StatefulWidget {
  const FilePropertiesDialog({
    super.key,
    required this.gateway,
    required this.file,
  });
  final FilePropertiesGateway gateway;
  final DemoFile file;
  @override
  State<FilePropertiesDialog> createState() => _FilePropertiesState();
}

class _FilePropertiesState extends State<FilePropertiesDialog> {
  final owner = TextEditingController(), group = TextEditingController();
  rust.RemoteProperties? data, baseline;
  String? error;
  bool busy = true, recursive = false;
  // Progressive directory size state; totals grow page by page.
  String? _sizeTicket;
  bool calculating = false, _sizeStopped = false;
  int shownSize = 0, shownFiles = 0, shownDirectories = 0;
  bool sizeComplete = false;
  rust.RemoteAccountOptions? _accounts;
  int? _permissionBits, _uid, _gid;
  bool get current => widget.gateway.current;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      if (!current) throw StateError('原关联会话已改变');
      final results = await Future.wait([
        widget.gateway.load(false),
        widget.gateway.accounts().catchError((_) => null),
      ]);
      if (!mounted || !current) return;
      final value = results[0] as rust.RemoteProperties;
      setState(() {
        data = baseline = value;
        busy = false;
        _accounts = results[1] as rust.RemoteAccountOptions?;
        _permissionBits = value.permissions == null
            ? null
            : value.permissions! & 511;
        _uid = value.uid;
        _gid = value.gid;
        owner.text = value.uid?.toString() ?? '';
        group.text = value.gid?.toString() ?? '';
        shownSize = value.size;
        shownFiles = value.files;
        shownDirectories = value.directories;
        sizeComplete = value.sizeComplete;
        calculating = widget.file.folder && !value.sizeComplete;
      });
      if (widget.file.folder && !value.sizeComplete) {
        unawaited(_walkSize());
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = appMessage(failure);
          busy = false;
        });
      }
    }
  }

  /// Drives the page-wise walk: each step appends its totals so the displayed
  /// size grows in real time. Any failure or explicit stop keeps the totals of
  /// the last completed page and retires the ticket.
  Future<void> _walkSize() async {
    String? ticket;
    try {
      if (!current) throw StateError('原关联会话已改变');
      ticket = await widget.gateway.sizeBegin();
      if (!mounted || !current) {
        await widget.gateway.sizeStop(ticket);
        return;
      }
      setState(() => _sizeTicket = ticket);
      while (mounted && current && !_sizeStopped) {
        final page = await widget.gateway.sizeStep(ticket);
        if (!mounted || !current || _sizeStopped) return;
        setState(() {
          shownSize = page.size;
          shownFiles = page.files;
          shownDirectories = page.directories;
          sizeComplete = page.complete;
        });
        if (page.complete) break;
        // Yield between progressive pages, including a temporarily busy
        // shared inspector. Never spin FRB calls while tmux owns the slot.
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = '内容大小统计未完成：${appMessage(failure)}。已显示数值截至最近完整分页。',
        );
      }
    } finally {
      if (mounted) setState(() => calculating = false);
      _sizeTicket = null;
      // The ticket is already retired by completion or error; an explicit stop
      // covers the remaining user-cancel path.
      if (ticket != null) {
        unawaited(widget.gateway.sizeStop(ticket).catchError((_) {}));
      }
    }
  }

  Future<void> _stopSizeCalculation() async {
    final ticket = _sizeTicket;
    setState(() {
      _sizeStopped = true;
      calculating = false;
    });
    if (ticket != null) {
      unawaited(widget.gateway.sizeStop(ticket).catchError((_) {}));
    }
  }

  Future<void> _save() async {
    final uid = _accounts != null && _accounts!.users.isNotEmpty
        ? _uid
        : int.tryParse(owner.text);
    final gid = _accounts != null && _accounts!.groups.isNotEmpty
        ? _gid
        : int.tryParse(group.text);
    if (uid == null || uid < 0 || uid > 4294967295) {
      setState(() => error = '请选择或输入有效的所有者 UID');
      return;
    }
    if (gid == null || gid < 0 || gid > 4294967295) {
      setState(() => error = '请选择或输入有效的所有组 GID');
      return;
    }
    if (recursive &&
        !await confirm(
          context,
          '递归修改目录属性？',
          '目录：${widget.file.id}\n将修改目录及内部文件，不跟随符号链接。部分失败不会回滚，请避免其他程序同时更改目录。',
          accept: '确认修改',
          danger: true,
        )) {
      return;
    }
    if (!mounted || !current) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.gateway.save(
        permissions:
            recursive ||
                _permissionBits !=
                    (baseline!.permissions == null
                        ? null
                        : baseline!.permissions! & 511)
            ? _permissionBits
            : null,
        uid: uid != baseline!.uid ? uid : null,
        gid: gid != baseline!.gid ? gid : null,
        recursive: recursive,
      );
      if (!mounted) return;
      showAppNotice(context, '远端属性已保存', level: AppNoticeLevel.success);
      Navigator.pop(context);
    } catch (failure) {
      if (mounted) setState(() => error = appMessage(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget detail(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
    final accountsKnown =
        _accounts != null &&
        (_accounts!.users.isNotEmpty || _accounts!.groups.isNotEmpty);
    Widget ownerPicker(bool isGroup) {
      final accounts = _accounts;
      final options = accounts == null
          ? const <rust.RemoteIdName>[]
          : (isGroup ? accounts.groups : accounts.users);
      final selected = isGroup ? _gid : _uid;
      final controller = isGroup ? group : owner;
      if (options.isEmpty) {
        return TextField(
          key: ValueKey(isGroup ? 'group-uid-fallback' : 'owner-uid-fallback'),
          controller: controller,
          enabled: !busy && data != null && !widget.file.symlink,
          decoration: InputDecoration(
            labelText: isGroup ? '所有组 GID' : '所有者 UID',
          ),
        );
      }
      final items = <DropdownMenuItem<int>>[
        for (final option in options)
          DropdownMenuItem(
            value: option.id,
            child: Text('${option.name} (${option.id})'),
          ),
      ];
      if (selected != null && !options.any((option) => option.id == selected)) {
        items.insert(
          0,
          DropdownMenuItem(
            value: selected,
            child: Text(isGroup ? 'GID $selected' : 'UID $selected'),
          ),
        );
      }
      return DropdownButtonFormField<int>(
        key: ValueKey(isGroup ? 'group-owner-dropdown' : 'file-owner-dropdown'),
        initialValue: selected,
        items: items,
        isExpanded: true,
        decoration: InputDecoration(labelText: isGroup ? '所有组' : '所有者'),
        onChanged: busy || data == null || widget.file.symlink
            ? null
            : (value) => setState(() => isGroup ? _gid = value : _uid = value),
      );
    }

    Widget permissionCell(String label, int mask, int shift, String key) {
      final bits = _permissionBits;
      final value = bits != null && (bits >> shift) & mask != 0;
      final disabled =
          busy || data == null || widget.file.symlink || bits == null;
      void toggle(bool? checked) {
        if (disabled) return;
        setState(() {
          _permissionBits = (checked ?? false)
              ? bits | (mask << shift)
              : bits & ~(mask << shift);
        });
      }

      return Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            key: ValueKey(key),
            onTap: disabled ? null : () => toggle(!value),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: Checkbox(
                      value: value,
                      onChanged: disabled ? null : toggle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(label, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget permissionGrid() {
      // Row shifts keep the 9-grid on the plain rwx bits of chmod.
      const rows = [('所有者', 6, 'owner'), ('组', 3, 'group'), ('其他', 0, 'other')];
      const columns = [('读', 4, 'read'), ('写', 2, 'write'), ('执行', 1, 'exec')];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (row, shift, rowKey) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(row, style: const TextStyle(fontSize: 12)),
                  ),
                  for (final (column, mask, columnKey) in columns)
                    permissionCell(
                      column,
                      mask,
                      shift,
                      'permission-$rowKey-$columnKey',
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            _permissionBits == null
                ? '权限未知或不可用'
                : '当前权限：0${_permissionBits!.toRadixString(8).padLeft(3, '0')}',
            key: const ValueKey('permission-octal'),
            style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
          ),
        ],
      );
    }

    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          Icon(
            widget.file.folder
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(widget.file.name, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              detail('位置', widget.file.id),
              detail('类型', widget.file.kind),
              if (busy || calculating)
                const LinearProgressIndicator(minHeight: 2),
              if (data case final value?) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 82,
                        child: Text(
                          widget.file.folder ? '内容大小' : '文件大小',
                          style: TextStyle(color: Theme.of(context).hintColor),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              sizeComplete
                                  ? '${remoteFileSize(shownSize)} · $shownSize B'
                                  : calculating
                                  ? '${remoteFileSize(shownSize)} · $shownSize B（统计中…）'
                                  : shownFiles + shownDirectories > 0
                                  ? '${remoteFileSize(shownSize)} · $shownSize B（已停止，未统计完整）'
                                  : '未计算',
                              key: const ValueKey('directory-size-value'),
                            ),
                            if (calculating)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: OutlinedButton(
                                    key: const ValueKey('stop-size-calc'),
                                    onPressed: _stopSizeCalculation,
                                    child: const Text('停止统计'),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.file.folder &&
                    (sizeComplete ||
                        calculating && shownFiles + shownDirectories > 0))
                  detail(
                    '项目',
                    '$shownFiles 个文件 · $shownDirectories 个目录'
                        '${sizeComplete ? '（含本目录，不跟随链接）' : '（已统计部分）'}',
                  ),
                if (value.linkTarget != null) detail('链接指向', value.linkTarget!),
              ],
              detail('修改时间', widget.file.modified),
              const Divider(height: 28),
              const Text(
                '所有权与权限',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              permissionGrid(),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: ownerPicker(false)),
                  const SizedBox(width: 12),
                  Expanded(child: ownerPicker(true)),
                ],
              ),
              if (!accountsKnown)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '远端账户列表不可用，UID/GID 手动输入。',
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontSize: 11,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (widget.file.folder)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: recursive,
                  onChanged: busy
                      ? null
                      : (value) => setState(() => recursive = value!),
                  title: const Text('递归应用到目录内容'),
                ),
              if (widget.file.symlink) const Text('链接目标仅展示；不通过链接修改其他文件权限。'),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: busy || data == null || widget.file.symlink ? null : _save,
          child: const Text('保存属性'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    final ticket = _sizeTicket;
    if (ticket != null) {
      unawaited(widget.gateway.sizeStop(ticket).catchError((_) {}));
    }
    owner.dispose();
    group.dispose();
    super.dispose();
  }
}
