import 'staging_cleanup.dart';
import 'transfer_connections.dart';

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../prototype/design.dart';

import 'package:url_launcher/url_launcher.dart';

import '../run_log.dart';
import '../src/rust/api.dart' as rust;
import '../src/rust/transfers.dart' as jobs;
import 'local_edit_launch.dart';
import 'model.dart';
import 'move_resolution.dart';
import 'explorer_export.dart';
import 'explorer_cache_cleanup.dart';
import '../app_notice.dart';

class LiveTransferQueue extends StatefulWidget {
  const LiveTransferQueue({super.key, required this.model, this.launchLocal});
  final Future<bool> Function(Uri)? launchLocal;
  final LiveWorkbenchModel model;
  @override
  State<LiveTransferQueue> createState() => _LiveTransferQueueState();
}

class _LiveTransferQueueState extends State<LiveTransferQueue> {
  final selected = <String>{};
  String? expanded, anchor;
  bool completedOpen = false;
  LiveWorkbenchModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    m.localEdits.addListener(_editsChanged);
  }

  @override
  void dispose() {
    m.localEdits.removeListener(_editsChanged);
    super.dispose();
  }

  void _editsChanged() {
    if (mounted) setState(() {});
  }

  /// Queue action "close all local-edit sessions": repeatable, waits for
  /// in-flight uploads, and explains what happens to unsynced drafts.
  Future<void> _closeAllEdits(List<LocalEditSession> edits) async {
    final unsynced = edits
        .where(
          (e) =>
              e.status == LocalEditStatus.conflicted ||
              e.status == LocalEditStatus.failed,
        )
        .length;
    final context = this.context;
    if (unsynced > 0) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: const Text('关闭所有本地编辑会话？'),
          content: Text(
            '将关闭全部 ${edits.length} 个编辑会话；其中 $unsynced 个存在未同步的修改，'
            '对应本地草稿会保留在原位置，不再自动同步。正在上传的任务会先完成或安全停止。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('全部关闭'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await m.localEdits.closeAllActive();
    if (context.mounted) {
      showAppNotice(context, '已关闭全部本地编辑会话', level: AppNoticeLevel.info);
    }
  }

  /// A local-edit task is NOT a download to a user-chosen directory: it is
  /// its own lightweight tile with the edit lifecycle, never the Rust
  /// transfer engine.
  Widget _editTile(LocalEditSession edit) {
    final statusText = switch (edit.status) {
      LocalEditStatus.downloading => '下载中',
      LocalEditStatus.editing => '正在本地编辑 · 保存后自动回传',
      LocalEditStatus.uploading => '正在上传',
      LocalEditStatus.conflicted => '远端已变化 · 未覆盖，请处理后重试',
      LocalEditStatus.failed => '上传失败 · 修改已保留，可重试',
      LocalEditStatus.closed => '已关闭',
    };
    final transferring =
        edit.status == LocalEditStatus.downloading ||
        edit.status == LocalEditStatus.uploading;
    final total = edit.progressTotal;
    final progress = total == null
        ? null
        : total == 0
        ? 1.0
        : (edit.progressDone / total).clamp(0.0, 1.0);
    final failed =
        edit.status == LocalEditStatus.failed ||
        edit.status == LocalEditStatus.conflicted;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.edit_document, size: 18),
      title: Text(
        edit.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      subtitle: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${edit.hostLabel} · $statusText · 远端 ${edit.remotePath}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10),
          ),
          if (transferring) ...[
            const SizedBox(height: 5),
            LinearProgressIndicator(value: progress, minHeight: 3),
            const SizedBox(height: 4),
            Text(
              '${progress == null ? '进度 —' : '${(progress * 100).round()}%'} · '
              '${bytes(edit.progressDone)} / ${total == null ? '未知大小' : bytes(total)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10),
            ),
          ],
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failed) Tool(Icons.refresh, '重试上传', () => run(edit.retry())),
          Tool(
            Icons.open_in_new,
            '打开本地文件',
            () => run(
              launchUrl(
                Uri.file(edit.localFile.absolute.path),
                mode: LaunchMode.externalApplication,
              ).then((ok) {
                if (!ok) throw StateError('系统未打开本地文件');
              }),
            ),
          ),
          Tool(
            Icons.folder_open,
            '打开所在文件夹',
            () => run(_revealFile(edit.localFile)),
          ),
          PopupMenuButton<String>(
            tooltip: '本地编辑任务',
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'open', child: Text('打开本地文件')),
              PopupMenuItem(value: 'folder', child: Text('打开所在文件夹')),
              PopupMenuItem(value: 'close', child: Text('结束编辑会话')),
            ],
            onSelected: (action) {
              switch (action) {
                case 'open':
                  run(
                    launchUrl(
                      Uri.file(edit.localFile.absolute.path),
                      mode: LaunchMode.externalApplication,
                    ),
                  );
                case 'folder':
                  run(_revealFile(edit.localFile));
                case 'close':
                  run(
                    Future<void>(() async {
                      await edit.dispose();
                    }),
                  );
              }
            },
          ),
        ],
      ),
    );
  }

  /// Reveals the temp copy in the OS file manager. On Windows the shell API
  /// (via the runner channel) opens the parent folder with the file
  /// preselected; `explorer /select` is only a fallback because a reused
  /// Explorer process exits non-zero even on success, and a plain folder
  /// open is the last resort when selection cannot be done at all.
  Future<void> _revealFile(File file) async {
    final dir = file.parent.path;
    if (widget.launchLocal != null) {
      await _launchLocal(Uri.directory(dir));
      return;
    }
    if (Platform.isWindows) {
      if (!file.parent.existsSync()) {
        throw StateError('本地编辑目录已不存在，无法打开所在文件夹：$dir');
      }
      if (!file.existsSync()) {
        throw StateError('本地文件已不存在，无法定位：${file.path}');
      }
      final absolute = file.absolute.path;
      try {
        await const MethodChannel('hspterm/prototype_window')
            .invokeMethod<void>('reveal', {'path': absolute});
        return;
      } on MissingPluginException {
        // Older runner or non-standard embedding; fall through to explorer.
      } on PlatformException catch (error) {
        if (error.code == 'reveal') rethrow;
        // reveal_failed: selection was not possible — open the parent.
      }
      try {
        // Explorer hand the request to its existing process and exits with 1
        // even when the window opened fine, so the exit code is ignored.
        await Process.run('explorer.exe', ['/select,$absolute']);
      } catch (_) {
        await launchUrl(
          Uri.directory(dir),
          mode: LaunchMode.externalApplication,
        );
      }
      return;
    }
    await _launchLocal(Uri.directory(dir));
  }

  Future<void> _launchLocal(Uri uri) async {
    final opened =
        await (widget.launchLocal?.call(uri) ??
            launchUrl(uri, mode: LaunchMode.externalApplication));
    if (!opened) throw StateError('系统未打开本地文件或目录');
  }

  bool _canOpenDownload(jobs.TransferTaskView task) =>
      !task.upload &&
      !task.busy &&
      task.sourceRemote == null &&
      task.remoteTransport != 'explorer_snapshot' &&
      (task.state == 'Complete' ||
          task.folder && task.state == 'CompleteWithSkips');

  Future<void> _openDownload(
    jobs.TransferTaskView task, {
    bool reveal = false,
  }) async {
    if (!_canOpenDownload(task)) throw StateError('当前任务尚未完成本地下载');
    final type = await FileSystemEntity.type(task.local, followLinks: false);
    if (task.folder
        ? type != FileSystemEntityType.directory
        : type != FileSystemEntityType.file) {
      throw StateError('下载文件或目录已不存在，或已被替换');
    }
    if (task.folder) {
      await _launchLocal(Uri.directory(Directory(task.local).absolute.path));
    } else if (reveal) {
      await _revealFile(File(task.local));
    } else {
      await _launchLocal(Uri.file(File(task.local).absolute.path));
    }
  }

  final _operations = <String>{};

  /// Task IDs that already had their conflict dialog auto-opened once; a
  /// later task refresh with conflicts resolves through the same dialog.
  final _conflictPrompted = <String>{};
  bool _autoPromptRunning = false;
  List<jobs.TransferTaskView> get tasks {
    final native = (m.focus as LiveTerminalSession?)?.controller.id;
    return m.transferTasks
        .where(
          (t) =>
              m.allTasks ||
              (native != null &&
                  (t.terminalId == native || t.sourceTerminalId == native)),
        )
        .toList();
  }

  bool ended(jobs.TransferTaskView t) =>
      ['Complete', 'CompleteWithSkips', 'Cancelled'].contains(t.state);
  bool uncertainMove(jobs.TransferTaskView t) =>
      t.remoteMovePhase == 'Intent' && !t.busy;
  String label(jobs.TransferTaskView t) {
    if (t.remoteTransport == 'explorer_snapshot') {
      if (t.state == 'ExportReady') return '源快照就绪 · 可拖出';
      if (t.state == 'Complete') return '数据已交付 · 目标由Explorer确认';
    }
    if (t.remoteMovePhase == 'UserEnded') return '已人工结束 · 结果未判定';
    if (uncertainMove(t)) {
      return t.remoteOperation == 'relocate' ? '来源删除结果未确认' : '移动结果未确认';
    }
    return switch (t.state) {
      'Waiting' => '等待',
      'Scanning' => '正在扫描',
      'Running' => '传输中',
      'Paused' => '已暂停',
      'ExportReady' => '源快照就绪',
      'Failed' => '失败',
      'Partial' => '部分完成 / 待处理',
      'Complete' => '已完成',
      'CompleteWithSkips' => '已结束 · 含跳过',
      'Cancelled' => '已取消',
      'Stopping' => '正在停止并保存',
      'Cleaning' => '检查 / 清理暂存',
      'RetiringSource' => '清理已复制来源',
      _ => t.state,
    };
  }

  String bytes(int n) => n < 1024
      ? '$n B'
      : n < 1048576
      ? '${(n / 1024).toStringAsFixed(1)} KiB'
      : '${(n / 1048576).toStringAsFixed(1)} MiB';
  void run(Future<void> work) => unawaited(
    work.catchError((Object error) {
      if (mounted) {
        notice(context, '传输操作失败：$error', level: AppNoticeLevel.error);
      }
    }),
  );
  Future<void> action(
    jobs.TransferTaskView t,
    String command, {
    int? node,
    String? rename,
  }) async {
    if (!_operations.add(t.id)) return;
    if (mounted) setState(() {});
    try {
      await m.controlTransfer(t, command, node: node, rename: rename);
    } finally {
      _operations.remove(t.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> chooseConnections(jobs.TransferTaskView task) async {
    if (!_operations.add(task.id)) return;
    if (mounted) setState(() {});
    try {
      final chosen = await showTransferConnections(context, m, task);
      if (!mounted || chosen == null || m.isClosing) return;
      await m.controlTransfer(
        task,
        'continue',
        sourceConnection: chosen.source,
        targetConnection: chosen.target,
      );
    } finally {
      _operations.remove(task.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> inspectMove(jobs.TransferTaskView task) async {
    if (!_operations.add(task.id)) return;
    if (mounted) setState(() {});
    try {
      await showMoveResolution(context, m, task);
    } finally {
      _operations.remove(task.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> batch(String command) async {
    final list = tasks
        .where(
          (t) =>
              selected.contains(t.id) &&
              !ended(t) &&
              (command == 'cancel' || t.state != 'ExportReady'),
        )
        .toList();
    if (command == 'cancel' &&
        !await confirm(
          context,
          '取消 ${list.length} 个任务？',
          '只停止剩余工作，保留已成功和已写入的数据。跨服务器移动已经确认删除的来源不会恢复；未知删除须单独检查，不能重发。',
          accept: '取消任务',
        )) {
      return;
    }
    var unchecked = 0;
    for (final t in list) {
      if (uncertainMove(t) && (command == 'continue' || command == 'retry')) {
        unchecked++;
        continue;
      }
      if ((command == 'pause' && !t.busy) ||
          (command != 'pause' && command != 'cancel' && t.busy)) {
        continue;
      }
      await action(
        t,
        command == 'retry' &&
                t.remoteOperation == 'relocate' &&
                t.sourceDeletionsTotal != null
            ? 'continue'
            : command,
      );
    }
    if (unchecked > 0 && mounted) {
      notice(
        context,
        '$unchecked 个移动结果未确认，请单独检查；未重发',
        level: AppNoticeLevel.warning,
      );
    }
  }

  void select(jobs.TransferTaskView t) {
    final list = tasks;
    if (HardwareKeyboard.instance.isShiftPressed &&
        list.any((t) => t.id == anchor)) {
      final a = list.indexWhere((t) => t.id == anchor), b = list.indexOf(t);
      selected.addAll(
        list.sublist(a < b ? a : b, (a > b ? a : b) + 1).map((t) => t.id),
      );
    } else if (HardwareKeyboard.instance.isControlPressed) {
      if (!selected.add(t.id)) selected.remove(t.id);
      anchor = t.id;
    } else {
      selected
        ..clear()
        ..add(t.id);
      anchor = t.id;
    }
    setState(() {});
  }

  Future<void> menu(Offset at, jobs.TransferTaskView t) async {
    if (!selected.contains(t.id)) select(t);
    final command = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (_canOpenDownload(t)) ...[
          DeskMenuItem(
            value: 'open-local',
            child: Text(t.folder ? '打开目录' : '打开文件'),
          ),
          if (!t.folder)
            const DeskMenuItem(value: 'reveal-local', child: Text('打开所在文件夹')),
        ],
        if (t.remoteTransport == 'explorer_snapshot' &&
            m.hasPendingExternalDelivery)
          const DeskMenuItem(
            value: 'end-explorer',
            child: Text('结束所有Explorer交付…'),
          ),
        if (uncertainMove(t))
          DeskMenuItem(
            value: 'inspect-move',
            child: Text(
              t.remoteOperation == 'relocate' ? '检查未确认的来源删除…' : '检查未确认移动…',
            ),
          ),
        const DeskMenuItem(value: 'pause', child: Text('暂停选中任务')),
        const DeskMenuItem(value: 'continue', child: Text('继续选中任务')),
        const DeskMenuItem(value: 'retry', child: Text('重试选中任务失败项目')),
        if (!t.busy &&
            !ended(t) &&
            !uncertainMove(t) &&
            t.state != 'ExportReady')
          const DeskMenuItem(
            value: 'choose-connections',
            child: Text('选择连接继续此任务…'),
          ),
        if (t.conflicts > 0 && !t.busy)
          const DeskMenuItem(value: 'conflicts', child: Text('处理本任务同名冲突…')),
        const DeskMenuItem(value: 'cancel', child: Text('取消选中任务')),
      ],
    );
    if (command != null && mounted) {
      if (command == 'open-local' || command == 'reveal-local') {
        await _openDownload(t, reveal: command == 'reveal-local');
      } else if (command == 'end-explorer') {
        if (await confirm(
          context,
          '结束所有当前Explorer交付？',
          '停止源读取，保留未完成源快照和队列检查点。Explorer已写入的目标文件由其自行管理，不删除远端来源。',
          accept: '结束交付',
        )) {
          await m.endExplorerDeliveries();
        }
      } else if (command == 'inspect-move') {
        await inspectMove(t);
      } else if (command == 'choose-connections') {
        await chooseConnections(t);
      } else if (command == 'conflicts') {
        await resolveBatch(t);
      } else {
        await batch(command);
      }
    }
  }

  Future<void> resolveBatch(jobs.TransferTaskView t) async {
    final command = await showAppDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 560),
        scrollable: true,
        title: Text('处理 ${t.conflicts} 个同名冲突？'),
        content: Text(
          '仅对任务“${t.name}”当前等待决定的同名文件生效。'
          '已成功文件和其他失败项不受影响；不修改全局默认策略。'
          '从头覆盖会替换目标内容；批量更名另存会保留旧目标，自动选择未占用名称。',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'skip_conflicts'),
            child: const Text('全部跳过'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'rename_conflicts'),
            child: const Text('全部更名另存'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'overwrite_conflicts'),
            child: const Text('全部明确从头覆盖'),
          ),
        ],
      ),
    );
    if (command != null && mounted) await action(t, command);
  }

  Future<void> resolve(
    jobs.TransferTaskView t,
    jobs.TransferFailure failure,
  ) async {
    if (failure.rescan) {
      if (await confirm(
            context,
            '重新扫描此失败目录？',
            '${failure.path.isEmpty ? t.name : failure.path}\n${failure.error}\n\n'
                '仅重扫此失败子树，合并新发现项目后继续。保留已成功文件和已确认偏移；'
                '扫描中取消将保留原检查点，不删除目标文件。',
            accept: '重扫并继续',
          ) &&
          mounted) {
        await action(t, 'rescan', node: failure.node);
      }
      return;
    }
    final command = await showAppDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: Text(failure.conflict ? '目标已存在' : '文件传输失败'),
        content: SelectableText(
          '${failure.path}\n${failure.error}\n\n普通重试按已确认偏移继续。选择从头覆盖将替换已有目标文件内容。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('返回'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'skip'),
            child: const Text('跳过此项'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'rename'),
            child: const Text('更名另存'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'overwrite'),
            child: const Text('明确从头覆盖'),
          ),
          if (!failure.conflict)
            TextButton(
              onPressed: () => Navigator.pop(c, 'retry'),
              child: const Text('按断点重试'),
            ),
        ],
      ),
    );
    if (command == null || !mounted) return;
    String? name;
    if (command == 'rename') {
      name = await showAppDialog<String>(
        context: context,
        builder: (_) => _DestinationName(initial: failure.path.split('/').last),
      );
      if (name == null || !mounted) return;
    }
    await action(
      t,
      command == 'rename' ? 'retry' : command,
      node: failure.node,
      rename: name,
    );
  }

  Widget details(jobs.TransferTaskView t) => Padding(
    padding: const EdgeInsets.fromLTRB(35, 4, 8, 9),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (t.remoteTransport == 'explorer_snapshot')
          const Text(
            '这是远端下载源快照。暂停/继续保留已确认偏移；就绪后可将任务拖到Explorer。交付结束不等于外部目标已落盘，目标冲突和部分文件由Explorer管理。',
            style: TextStyle(fontSize: 10),
          ),
        if (t.remoteOperation == 'move')
          const Text('服务器直接移动；未扫描内部目录，不统计传输字节', style: TextStyle(fontSize: 10))
        else
          Text(
            '文件 ${t.files} · 目录 ${t.directories} · 完成项目 ${t.completed} · 失败 ${t.failed} · 冲突 ${t.conflicts} · 跳过 ${t.skipped}',
            style: const TextStyle(fontSize: 10),
          ),
        SelectableText(
          t.sourceRemote == null
              ? '${t.local}\n${t.upload ? '↑' : '↓'} ${t.remote}'
              : '${t.remoteOperation == 'move'
                    ? '远端移动'
                    : t.remoteOperation == 'relocate'
                    ? '跨服务器移动'
                    : '远端复制'}：${t.sourceRemote}\n→ ${t.remote}',
          style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
        ),
        if (t.remoteTransport == 'direct' || t.remoteTransport == 'mixed')
          const Text(
            '正文由服务器直接传输，本机不能准确限速；仅在完整远端回执后确认字节。中断结果未知时保留暂存意图，不自动转为中继。',
          ),
        if (t.remoteOperation == 'relocate')
          Text(
            t.sourceDeletionsTotal == null
                ? '仅整树复制确认后删除来源；失败/跳过不开始删除，未结束任务保留来源编辑保护。'
                : '复制已确认；来源清理确认 ${t.sourceDeletionsConfirmed ?? 0} / ${t.sourceDeletionsTotal} 项。暂停/取消不恢复已删除项；未知请求不重发。',
            style: const TextStyle(fontSize: 10),
          ),
        if (t.activeFiles?.isNotEmpty ?? false)
          for (final file in t.activeFiles!)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前文件：${file.path.isEmpty ? t.name : file.path}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10),
                  ),
                  Text(
                    '${bytes(file.acknowledged)} / ${bytes(file.total)}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  LinearProgressIndicator(
                    value: file.total == 0
                        ? null
                        : (file.acknowledged / file.total).clamp(0.0, 1.0),
                    minHeight: 2,
                  ),
                ],
              ),
            )
        else if (t.current != null)
          Text(
            '当前文件：${t.current!.isEmpty ? t.name : t.current}',
            style: const TextStyle(fontSize: 10),
          ),
        if (t.error != null)
          SelectableText(
            t.error!,
            style: const TextStyle(color: Desk.danger, fontSize: 10),
          ),
        if (t.conflicts > 0 && !t.busy)
          TextButton(
            onPressed: () => run(resolveBatch(t)),
            child: const Text('批次处理同名冲突…'),
          ),
        if (t.failed + t.conflicts > 0 && !t.busy)
          _Failures(
            key: ValueKey('${t.id}/${t.state}/${t.failed}/${t.conflicts}'),
            task: t,
            resolve: (failure) => run(resolve(t, failure)),
          ),
      ],
    ),
  );
  Widget item(jobs.TransferTaskView t) {
    final rate = m.transferRates[t.id];
    final speed = rate?.bytesPerSecond;
    final speedLabel = t.remoteTransport == 'direct'
        ? '服务器直传 · 按文件确认'
        : t.remoteTransport == 'mixed'
        ? '直传/中转混合 · 速度 —'
        : speed == null
        ? '速度/剩余 —'
        : '${bytes(speed.round())}/s · ${rate?.remainingSeconds == null ? '—' : '约 ${rate!.remainingSeconds} 秒'}';
    final blocked = _operations.contains(t.id) || t.state == 'Stopping';
    final error = t.state == 'Failed' || t.state == 'Partial';
    final color = error
        ? Desk.danger
        : t.state == 'Complete'
        ? Desk.accent
        : Theme.of(context).colorScheme.primary;
    final progress = t.total == null || t.total == 0
        ? null
        : (t.acknowledged / t.total!).clamp(0.0, 1.0);
    final result = Column(
      children: [
        GestureDetector(
          key: ValueKey('live-transfer-${t.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => select(t),
          onSecondaryTapDown: (d) => run(menu(d.globalPosition, t)),
          child: Container(
            constraints: BoxConstraints(
              minHeight: 42 + MediaQuery.textScalerOf(context).scale(16),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 5),
            color: selected.contains(t.id)
                ? color.withValues(alpha: .08)
                : null,
            child: Column(
              children: [
                Row(
                  children: [
                    Tool(
                      expanded == t.id ? Icons.expand_less : Icons.expand_more,
                      '展开任务详情',
                      () => setState(
                        () => expanded = expanded == t.id ? null : t.id,
                      ),
                      size: 14,
                    ),
                    Icon(
                      (t.remoteOperation == 'move' ||
                              t.remoteOperation == 'relocate')
                          ? Icons.drive_file_move_outlined
                          : t.sourceRemote != null
                          ? Icons.copy
                          : t.upload
                          ? Icons.north_east
                          : Icons.south_west,
                      size: 13,
                      color: color,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        t.name,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(label(t), style: TextStyle(fontSize: 9, color: color)),
                    if (_canOpenDownload(t)) ...[
                      Tool(
                        t.folder ? Icons.folder_open : Icons.open_in_new,
                        t.folder ? '打开目录' : '打开文件',
                        () => run(_openDownload(t)),
                        size: 13,
                      ),
                      if (!t.folder)
                        Tool(
                          Icons.folder_open,
                          '打开所在文件夹',
                          () => run(_openDownload(t, reveal: true)),
                          size: 13,
                        ),
                    ],
                    if (uncertainMove(t))
                      Tool(
                        Icons.fact_check_outlined,
                        t.remoteOperation == 'relocate'
                            ? '检查未确认的来源删除'
                            : '检查未确认移动',
                        blocked ? null : () => run(inspectMove(t)),
                        size: 13,
                      )
                    else if (!ended(t) && t.state != 'ExportReady')
                      Tool(
                        t.busy ? Icons.pause : Icons.play_arrow,
                        t.busy ? '暂停任务' : '继续任务',
                        blocked
                            ? null
                            : () =>
                                  run(action(t, t.busy ? 'pause' : 'continue')),
                        size: 13,
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 33, right: 4),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Text(
                              t.remoteOperation == 'move'
                                  ? '服务器直接移动 · 无正文中转'
                                  : t.remoteOperation == 'relocate' &&
                                        t.sourceDeletionsTotal != null
                                  ? '来源清理 ${t.sourceDeletionsConfirmed ?? 0} / ${t.sourceDeletionsTotal ?? 0} 项 · 副本已确认'
                                  : t.state == 'Scanning'
                                  ? '已发现 ${t.discovered} 项 · 总量未知'
                                  : '${bytes(t.acknowledged)} / ${t.total == null ? '—' : bytes(t.total!)}${progress == null ? '' : ' · ${(progress * 100).round()}%'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 9,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ),
                          Flexible(
                            flex: 2,
                            child: Tooltip(
                              message: speedLabel,
                              child: Text(
                                speedLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                                style: const TextStyle(fontSize: 9),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: t.state == 'RetiringSource'
                            ? (t.sourceDeletionsTotal == null ||
                                      t.sourceDeletionsTotal == 0
                                  ? null
                                  : ((t.sourceDeletionsConfirmed ?? 0) /
                                            t.sourceDeletionsTotal!)
                                        .clamp(0.0, 1.0))
                            : t.remoteOperation == 'move'
                            ? (t.busy
                                  ? null
                                  : t.state == 'Complete'
                                  ? 1
                                  : 0)
                            : progress ?? (t.busy ? null : 0),
                        minHeight: 2,
                        color: color,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded == t.id) details(t),
      ],
    );
    return t.remoteTransport == 'explorer_snapshot' &&
            t.state == 'ExportReady' &&
            !t.busy
        ? ExplorerReadySnapshotDrag(model: m, task: t.id, child: result)
        : result;
  }

  /// A transfer that just hit same-name conflicts asks for a decision by
  /// itself instead of waiting for the user to open its menu. Only one dialog
  /// per task; user-cancelled prompts are not forced open again.
  void _scheduleConflictPrompt(List<jobs.TransferTaskView> list) {
    if (_autoPromptRunning) return;
    final candidate = list
        .where(
          (t) =>
              t.conflicts > 0 &&
              !t.busy &&
              !_conflictPrompted.contains(t.id) &&
              !_operations.contains(t.id),
        )
        .firstOrNull;
    if (candidate == null) return;
    _conflictPrompted.add(candidate.id);
    _autoPromptRunning = true;
    AppRunLog.instance.event(
      AppLogEvent.transferConflictPrompt,
      terminal: candidate.terminalId,
      count: candidate.conflicts,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (mounted) await resolveBatch(candidate);
        AppRunLog.instance.event(
          AppLogEvent.transferConflictResolved,
          terminal: candidate.terminalId,
        );
      } finally {
        _autoPromptRunning = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = tasks;
    selected.removeWhere((id) => !list.any((t) => t.id == id));
    _scheduleConflictPrompt(list);
    final activity = list
        .where((t) => !ended(t) && !['Partial', 'Failed'].contains(t.state))
        .toList();
    final errors = list
        .where((t) => ['Partial', 'Failed'].contains(t.state))
        .toList();
    final done = list.where(ended).toList();
    final edits = m.localEdits.sessions
        .where((s) => s.status != LocalEditStatus.closed)
        .toList();
    final rows = <Object>[
      if (edits.isNotEmpty) ...[
        SectionHeading(
          '本地编辑 · ${edits.length}',
          trailing: Tool(
            Icons.layers_clear,
            '关闭所有本地编辑会话',
            () => run(_closeAllEdits(edits)),
            size: 14,
          ),
        ),
        ...edits,
      ],
      if (activity.isNotEmpty) ...[
        SectionHeading('活动与等待 · ${activity.length}'),
        ...activity,
      ],
      if (errors.isNotEmpty) ...[
        SectionHeading('需要处理 · ${errors.length}'),
        ...errors,
      ],
      if (done.isNotEmpty) ...[
        InkWell(
          onTap: () => setState(() => completedOpen = !completedOpen),
          child: SectionHeading(
            '${completedOpen ? '▾' : '▸'} 已结束 · ${done.length}',
            trailing: Tool(
              Icons.playlist_remove,
              '清理已结束任务',
              () => run(m.clearEndedTasks()),
              size: 14,
            ),
          ),
        ),
        if (completedOpen) ...done,
      ],
    ];
    return Column(
      children: [
        SizedBox(
          height: 33,
          child: Row(
            children: [
              const SizedBox(width: 8),
              const Text(
                '传输队列',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${activity.length} 活动 · ${errors.length} 异常',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: errors.isNotEmpty
                        ? Desk.warning
                        : Theme.of(context).hintColor,
                  ),
                ),
              ),
              Tool(
                Icons.folder_delete_outlined,
                '清理孤立导出副本',
                () => run(showExplorerCacheCleanup(context, m)),
                size: 15,
              ),
              Tool(
                Icons.cleaning_services_outlined,
                '远端暂存清理',
                () => run(showStagingCleanup(context, m)),
                size: 15,
              ),
              Tool(
                m.queueMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
                '队列在侧栏内最大化',
                m.queueToggle,
                size: 15,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 28,
          child: Row(
            children: [
              TextButton(
                onPressed: () {
                  m.allTasks = !m.allTasks;
                  m.changed();
                },
                child: Text(
                  m.allTasks ? '全部会话 ▾' : '当前会话 ▾',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              const Spacer(),
              if (selected.isNotEmpty) ...[
                Tool(Icons.pause, '批量暂停', () => run(batch('pause')), size: 14),
                Tool(
                  Icons.play_arrow,
                  '批量继续',
                  () => run(batch('continue')),
                  size: 14,
                ),
                Tool(Icons.close, '批量取消', () => run(batch('cancel')), size: 14),
              ] else
                Tool(
                  Icons.refresh,
                  '刷新任务',
                  () => run(m.refreshTransfers()),
                  size: 14,
                ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty && edits.isEmpty
              ? Center(
                  child: Text(
                    m.allTasks ? '暂无传输任务' : '当前会话无任务 · 可切换全部任务',
                    style: const TextStyle(fontSize: 10),
                  ),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final row = rows[i];
                    if (row is LocalEditSession) return _editTile(row);
                    return row is jobs.TransferTaskView
                        ? item(row)
                        : row as Widget;
                  },
                ),
        ),
      ],
    );
  }
}

class _Failures extends StatefulWidget {
  const _Failures({super.key, required this.task, required this.resolve});
  final jobs.TransferTaskView task;
  final void Function(jobs.TransferFailure) resolve;
  @override
  State<_Failures> createState() => _FailuresState();
}

class _DestinationName extends StatefulWidget {
  const _DestinationName({required this.initial});
  final String initial;
  @override
  State<_DestinationName> createState() => _DestinationNameState();
}

class _DestinationNameState extends State<_DestinationName> {
  late final name = TextEditingController(text: widget.initial);
  String? error;
  void submit() {
    final value = name.text;
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains('\\') ||
        value.contains('\u0000')) {
      setState(() => error = '请输入单个有效文件名');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('目标新文件名'),
    content: SizedBox(
      width: 330,
      child: TextField(
        autofocus: true,
        controller: name,
        onSubmitted: (_) => submit(),
        decoration: InputDecoration(errorText: error),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('另存为新文件')),
    ],
  );
}

class _FailuresState extends State<_Failures> {
  late final List<jobs.TransferFailure> failures = [];
  String? error;
  bool loading = false, more = true;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      final batch = widget.task.sourceRemote == null
          ? await rust.transferFailures(
              taskId: widget.task.id,
              offset: failures.length,
              limit: 50,
            )
          : await rust.remoteCopyFailures(
              taskId: widget.task.id,
              offset: failures.length,
              limit: 50,
            );
      if (!mounted) return;
      setState(() {
        failures.addAll(batch);
        more = batch.length == 50;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final f in failures)
        InkWell(
          onTap: () => widget.resolve(f),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              '${f.path.isEmpty ? widget.task.name : f.path} · ${f.error}',
              style: const TextStyle(fontSize: 10, color: Desk.danger),
            ),
          ),
        ),
      if (error != null)
        Text(error!, style: const TextStyle(fontSize: 10, color: Desk.danger)),
      if (more)
        TextButton(
          onPressed: loading ? null : load,
          child: Text(
            loading ? '正在读取…' : '加载更多失败项',
            style: const TextStyle(fontSize: 10),
          ),
        ),
    ],
  );
}
