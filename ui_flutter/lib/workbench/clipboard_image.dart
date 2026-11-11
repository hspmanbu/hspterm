import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart' as clipboard;
import 'package:super_native_extensions/raw_clipboard.dart' as raw;

import '../app_notice.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';
import 'terminal_paths.dart' show quoteRemotePath;

const maxClipboardImageBytes = 64 * 1024 * 1024;

/// Bounded encoded PNG stream, without decoding or keeping a Dart image/cache.
/// Exposed for deterministic stream/error/cancellation tests without an OS clipboard.
Future<void> writeClipboardImageStream(
  Stream<List<int>> stream,
  File target,
  bool Function() current, {
  int? total,
}) async {
  if (total != null && (total < 8 || total > maxClipboardImageBytes)) {
    throw StateError('剪贴板图片须不超过64MiB');
  }
  final sink = target.openWrite();
  var done = 0;
  try {
    await for (final chunk in stream) {
      if (!current()) throw StateError('原终端已改变，图片粘贴已取消');
      done += chunk.length;
      if (done > maxClipboardImageBytes) throw StateError('剪贴板图片超过64MiB，未上传');
      sink.add(chunk);
      await sink.flush();
    }
    if (done < 8 || total != null && done != total) {
      throw StateError('剪贴板图片内容不完整，未上传');
    }
  } finally {
    await sink.close();
  }
}

Future<bool> readClipboardPng(File target, bool Function() current) async {
  // Explicit ownership is important: SystemClipboard.read() leaves disposal
  // to finalizers, retaining native DIB/PNG snapshots during allocation bursts.
  final reader = await raw.ClipboardReader.instance.newClipboardReader();
  try {
    final items = await reader.getItems();
    final info = await raw.DataReaderItem.getItemInfo(items);
    for (final item in info) {
      final data = clipboard.DataReader.forItemInfo(item);
      if (!data.canProvide(clipboard.Formats.png)) continue;
      final result = Completer<bool>();
      final progress = data.getFile(
        clipboard.Formats.png,
        (file) async {
          try {
            await writeClipboardImageStream(
              file.getStream(),
              target,
              current,
              total: file.fileSize,
            );
            result.complete(true);
          } catch (error, stack) {
            file.close();
            result.completeError(error, stack);
          }
        },
        onError: (error) {
          if (!result.isCompleted) result.completeError(error);
        },
      );
      if (progress == null && !result.isCompleted) result.complete(false);
      return await result.future;
    }
    return false;
  } finally {
    await reader.dispose();
  }
}

typedef ClipboardImageReader = Future<bool> Function(File, bool Function());
typedef ClipboardImageUploader = Future<String> Function(int, int, String);
typedef ClipboardImagePaster = Future<void> Function(int, int, String);

/// Original focus/id/generation stay pinned over clipboard and network awaits.
/// No ordinary text clipboard path is changed by adding this separate action.
Future<void> pasteClipboardImage(
  BuildContext context,
  LiveWorkbenchModel model,
  LiveTerminalSession source, {
  ClipboardImageReader? read,
  ClipboardImageUploader? upload,
  ClipboardImagePaster? paste,
}) async {
  final controller = source.controller;
  final id = controller.id, generation = controller.generation;
  bool current() =>
      !model.isClosing &&
      model.focus == source &&
      model.sessions.contains(source) &&
      controller.connected &&
      controller.id == id &&
      controller.generation == generation;
  if (id == null || !current()) throw StateError('请先聚焦已连接的SSH终端');
  if (!model.beginImagePaste(source.id)) return;
  Directory? directory;
  try {
    await model.runTransferSubmission(() async {
      directory = await Directory.systemTemp.createTemp(
        'hspterm-clipboard-image-',
      );
      final file = File(
        '${directory!.path}${Platform.pathSeparator}clipboard.png',
      );
      if (!await (read ?? readClipboardPng)(file, current)) {
        if (context.mounted) showAppNotice(context, '剪贴板中没有可读取的图片');
        return;
      }
      if (!current()) throw StateError('原终端已改变，未上传图片');
      final path =
          await (upload?.call(id, generation, file.path) ??
              rust.uploadClipboardImage(
                id: id,
                generation: generation,
                localPath: file.path,
              ));
      if (!path.startsWith('/') ||
          path.contains('\u0000') ||
          path.contains('\n') ||
          path.contains('\r')) {
        throw StateError('远端返回的图片路径无效，未输入');
      }
      if (!current()) {
        if (context.mounted) {
          showAppNotice(
            context,
            '图片已上传，原终端焦点或连接已改变，未输入路径。',
            level: AppNoticeLevel.warning,
            action: SnackBarAction(
              label: '复制图片路径',
              onPressed: () {
                unawaited(
                  Clipboard.setData(ClipboardData(text: quoteRemotePath(path))),
                );
              },
            ),
          );
        }
        return;
      }
      await controller.enqueueImagePath(generation, () async {
        if (!current()) throw StateError('原终端焦点已改变，未输入图片路径');
        await (paste?.call(id, generation, path) ??
            rust.pasteClipboardImagePath(
              id: id,
              generation: generation,
              path: path,
            ));
      });
      if (context.mounted) {
        showAppNotice(
          context,
          '图片已上传，已填入绝对路径；未按回车。',
          level: AppNoticeLevel.success,
        );
      }
    });
  } finally {
    try {
      if (directory != null) await directory!.delete(recursive: true);
    } finally {
      model.endImagePaste(source.id);
    }
  }
}
