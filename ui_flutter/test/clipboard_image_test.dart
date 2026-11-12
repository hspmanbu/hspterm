import 'package:hspterm/workbench/queue.dart';
import 'package:hspterm/workbench/image_upload_task.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/image_paste_binding.dart';
import 'package:hspterm/terminal/view.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/workbench/clipboard_image.dart';
import 'package:hspterm/workbench/model.dart';

import 'support/fake_backend.dart';
import 'support/terminal_cleanup.dart';
import 'transfer_connection_selection_test.dart' show session;
import 'terminal_paths_send_test.dart' show PathSessions;

class ImageModel extends PathSessions {
  ImageModel(super.items);
  LiveTerminalSession? selected;
  @override
  LiveTerminalSession? get focus => selected;
}

void main() {
  test('image queue uses actual acknowledged progress and remote location', () {
    final task = ImageUploadTask('one', 'fixture');
    task.apply({
      'path': '/tmp/private/clipboard.png',
      'done': 128,
      'total': 1024,
    });
    expect(task.done, 128);
    expect(task.total, 1024);
    expect(task.path, '/tmp/private/clipboard.png');
    expect(
      () => task.apply({'path': '/tmp/x', 'done': 2048, 'total': 1024}),
      throwsFormatException,
    );
    task.ended = true;
    task.apply({'path': '/tmp/stale', 'done': 0, 'total': 5});
    expect(task.path, '/tmp/private/clipboard.png');
  });

  test('PNG stream is bounded and refuses truncated, oversized and cancelled input', () async {
    final directory = await Directory.systemTemp.createTemp(
      'image-stream-test-',
    );
    try {
      final file = File('${directory.path}/image.png');
      await writeClipboardImageStream(
        Stream.fromIterable([List.filled(10, 1), List.filled(20, 2)]),
        file,
        () => true,
        total: 30,
      );
      expect(await file.length(), 30);
      await expectLater(
        writeClipboardImageStream(
          Stream.value([1, 2, 3]),
          file,
          () => true,
          total: 30,
        ),
        throwsStateError,
      );
      await expectLater(
        writeClipboardImageStream(
          const Stream.empty(),
          file,
          () => true,
          total: maxClipboardImageBytes + 1,
        ),
        throwsStateError,
      );
      await expectLater(
        writeClipboardImageStream(
          Stream.value(List.filled(10, 1)),
          file,
          () => false,
        ),
        throwsStateError,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test(
    'image shortcut accepts explicit chords and preserves ordinary copy/paste',
    () {
      expect(
        ImagePasteBinding.parse(const ImagePasteBinding().toJson()).modifiers,
        6,
      );
      for (final key in ['KeyC', 'KeyV', 'KeyF']) {
        expect(
          () => ImagePasteBinding.parse({
            'enabled': true,
            'key': key,
            'modifiers': 5,
          }),
          throwsFormatException,
        );
      }
      expect(
        () => ImagePasteBinding.parse({
          'enabled': true,
          'key': 'F01',
          'modifiers': 6,
        }),
        throwsFormatException,
      );
      expect(
        () => ImagePasteBinding.parse({
          'enabled': true,
          'key': 'KeyV',
          'modifiers': 0,
        }),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'image upload queue updates ACK percentage and remote destination',
    (tester) async {
      final source = session('Image', 1, 4);
      final model = ImageModel([source])..selected = source;
      final task = ImageUploadTask(source.id, 'Image');
      task.apply({
        'path': '/tmp/private/clipboard.png',
        'done': 1024,
        'total': 4096,
      });
      model.publishImageUpload(task);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LiveTransferQueue(model: model)),
        ),
      );
      await tester.pump();
      expect(find.textContaining('/tmp/private/clipboard.png'), findsOneWidget);
      expect(find.textContaining('25%'), findsOneWidget);
      await tester.tap(find.textContaining('图片上传 ·'));
      await tester.pump();
      expect(find.textContaining('25%'), findsNothing);
      expect(model.imageUploads, contains(task));
      await tester.tap(find.textContaining('图片上传 ·'));
      await tester.pump();
      expect(find.textContaining('25%'), findsOneWidget);
      task.apply({
        'path': '/tmp/private/clipboard.png',
        'done': 2048,
        'total': 4096,
      });
      model.publishImageUpload(task);
      await tester.pump();
      expect(find.textContaining('50%'), findsOneWidget);
      task.ended = true;
      model.publishImageUpload(task);
      model.clearFinishedImageUploads();
      await tester.pump();
      expect(find.textContaining('/tmp/private/clipboard.png'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await drainAsync(tester, model.shutdown());
      model.dispose();
    },
  );
  testWidgets(
    'image shortcut runs once without sending keys and keeps text paste intact',
    (tester) async {
      final backend = FakeBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.generation = 1;
      var images = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              controller: c,
              onPasteImage: () async {
                images++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(images, 1);
      expect(backend.pastes, isEmpty);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': 'ordinary text'}
            : null,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(images, 1);
      expect(backend.pastes, [('ordinary text', false)]);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        images,
        2,
        reason: 'ordinary paste falls back to the image clipboard when text is absent',
      );
      expect(backend.pastes, [('ordinary text', false)]);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await tester.pumpWidget(const SizedBox());
      await closeTerminal(tester, c);
    },
  );
  testWidgets(
    'upload completion never redirects an image to a newly focused terminal and deletes local temp',
    (tester) async {
      final original = session('Original', 1, 4),
          other = session('Other', 2, 7);
      final model = ImageModel([original, other]);
      model.selected = original;
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final pasted = <String>[];
      String? local;
      await tester.runAsync(
        () => pasteClipboardImage(
          context,
          model,
          original,
          read: (file, current) async {
            local = file.path;
            await file.writeAsBytes(List.filled(20, 1));
            return true;
          },
          upload: (id, generation, path) async {
            expect((id, generation), (1, 4));
            model.selected = other;
            return '/tmp/private/clipboard.png';
          },
          paste: (_, _, path) async {
            pasted.add(path);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(pasted, isEmpty);
      expect(File(local!).existsSync(), false);
      expect(find.textContaining('未输入路径'), findsOneWidget);
      expect(model.beginImagePaste(original.id), true);
      model.endImagePaste(original.id);
      await tester.pumpWidget(const SizedBox());
      await drainAsync(tester, model.shutdown());
      model.dispose();
    },
  );
}
