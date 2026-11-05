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
}

Future<void> showFileProperties(
  BuildContext context,
  LiveWorkbenchModel model,
  LiveTerminalSession source,
  DemoFile file,
) => showDialog<void>(
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
  final mode = TextEditingController(),
      owner = TextEditingController(),
      group = TextEditingController();
  rust.RemoteProperties? data, baseline;
  String? error;
  bool busy = true, recursive = false, calculating = false;
  bool get current => widget.gateway.current;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      if (!current) throw StateError('原关联会话已改变');
      final value = await widget.gateway.load(false);
      if (!mounted || !current) return;
      setState(() {
        data = baseline = value;
        busy = false;
        mode.text = value.permissions == null
            ? ''
            : (value.permissions! & 4095).toRadixString(8).padLeft(4, '0');
        owner.text = value.uid?.toString() ?? '';
        group.text = value.gid?.toString() ?? '';
        calculating = !value.sizeComplete;
      });
      if (!value.sizeComplete) {
        try {
          final size = await widget.gateway.load(true);
          if (mounted && current) setState(() => data = size);
        } catch (failure) {
          if (mounted) {
            setState(
              () => error = '内容大小未计算：${appMessage(failure)}。仍可修改已读取的权限。',
            );
          }
        } finally {
          if (mounted) setState(() => calculating = false);
        }
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

  Future<void> _save() async {
    final permissions = int.tryParse(mode.text, radix: 8),
        uid = int.tryParse(owner.text),
        gid = int.tryParse(group.text);
    if (permissions == null ||
        permissions < 0 ||
        permissions > 4095 ||
        uid == null ||
        uid < 0 ||
        uid > 4294967295 ||
        gid == null ||
        gid < 0 ||
        gid > 4294967295) {
      setState(() => error = '请输入有效的八进制权限与数字 UID/GID');
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
                permissions !=
                    (baseline!.permissions == null
                        ? null
                        : baseline!.permissions! & 4095)
            ? permissions
            : null,
        uid: uid != baseline!.uid ? uid : null,
        gid: gid != baseline!.gid ? gid : null,
        recursive: recursive,
      );
      if (!mounted) return;
      showAppNotice(context, '远端属性已保存');
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
    Widget field(String label, TextEditingController controller) => Expanded(
      child: TextField(
        controller: controller,
        enabled: !busy && data != null && !widget.file.symlink,
        decoration: InputDecoration(labelText: label),
      ),
    );
    return AlertDialog(
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
                detail(
                  widget.file.folder ? '内容大小' : '文件大小',
                  value.sizeComplete
                      ? '${remoteFileSize(value.size)} · ${value.size} B'
                      : calculating
                      ? '正在查询远端目录内容…'
                      : '未计算',
                ),
                if (widget.file.folder && value.sizeComplete)
                  detail(
                    '项目',
                    '${value.files} 个文件 · ${value.directories} 个目录（含本目录，不跟随链接）',
                  ),
                if (value.linkTarget != null) detail('链接指向', value.linkTarget!),
              ],
              detail('修改时间', widget.file.modified),
              const Divider(height: 28),
              const Text(
                '所有权与权限',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  field('八进制权限', mode),
                  const SizedBox(width: 12),
                  field('所有者 UID', owner),
                  const SizedBox(width: 12),
                  field('所有组 GID', group),
                ],
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
    mode.dispose();
    owner.dispose();
    group.dispose();
    super.dispose();
  }
}
