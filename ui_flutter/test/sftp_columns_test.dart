//! Round-9: stable-id SFTP columns (permissions/owner), header drag
//! reorder, and per-host persisted layout.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/file_kinds.dart';

import 'support/column_host.dart';

Future<void> mount(WidgetTester tester, WorkbenchModel model) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 700,
          child: AnimatedBuilder(
            animation: model,
            builder: (_, _) => FilesPanel(model: model, pane: model.focus!),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('kind classification is extension + metadata only', () {
    expect(sftpFileKind('a.md', folder: false, symlink: false), 'Markdown');
    expect(sftpFileKind('x.tar.gz', folder: false, symlink: false), '压缩包');
    expect(sftpFileKind('main.rs', folder: false, symlink: false), 'Rust');
    expect(sftpFileKind('Main.PY', folder: false, symlink: false), 'Python');
    expect(sftpFileKind('noext', folder: false, symlink: false), '文件');
    expect(sftpFileKind('link', folder: false, symlink: true), '符号链接');
    expect(sftpFileKind('dir', folder: true, symlink: false), '文件夹');
    expect(sftpFileKind('dir-link', folder: true, symlink: true), '目录链接');
    for (final pair in [
      ('Dockerfile', '配置文件'),
      ('.env.prod', '配置文件'),
      ('app.APK', '安装包'),
      ('server.deb', '安装包'),
      ('font.woff2', '字体'),
      ('Component.vue', '源代码'),
      ('query.sql', 'SQL'),
      ('sample.avif', '图片'),
      ('video.m4v', '视频'),
      ('data.sqlite3', '数据库'),
      ('main.ts', 'TypeScript'),
    ]) {
      expect(sftpFileKind(pair.$1, folder: false, symlink: false), pair.$2);
    }
    // A folder named like an archive stays a folder.
    expect(sftpFileKind('backup.zip', folder: true, symlink: false), '文件夹');
  });

  test('permission string renders ls-style with type prefix', () {
    expect(permissionString(0x1ed, folder: false), '-rwxr-xr-x');
    expect(permissionString(0x1ed, folder: true), 'drwxr-xr-x');
    expect(permissionString(0x81a4), '-rw-r--r--');
    expect(permissionString(0x1ff), '-rwxrwxrwx');
    expect(permissionString(null), '—');
  });

  testWidgets('permission and owner columns display listing metadata', (
    tester,
  ) async {
    final m = ColumnHost();
    await mount(tester, m);
    expect(find.text('-rw-r--r--'), findsOneWidget);
    expect(find.text('drwxr-xr-x'), findsOneWidget);
    expect(find.text('ubuntu'), findsWidgets);
    expect(find.text('1001'), findsOneWidget, reason: 'uid fallback for b');
    m.dispose();
  });

  testWidgets('header drag reorders columns and sorting still works', (
    tester,
  ) async {
    final m = ColumnHost();
    await mount(tester, m);
    // The remembered layout puts owner second; within the remaining
    // defaults 大小 renders right of 修改时间.
    expect(
      tester.getCenter(find.text('修改时间')).dx,
      lessThan(tester.getCenter(find.text('大小')).dx),
      reason: 'precondition order',
    );
    // Drag the 修改时间 header onto 大小 to swap them.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('修改时间')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(kLongPressTimeout);
    await gesture.moveBy(const Offset(60, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    // 修改时间 and 大小 swapped (or 修改时间 moved right past it).
    expect(
      tester.getCenter(find.text('大小')).dx,
      lessThan(tester.getCenter(find.text('修改时间')).dx),
      reason: 'header drag moved 修改时间 after 大小',
    );
    // The reorder persisted through the model (debounced write fires).
    await tester.pump(const Duration(milliseconds: 900));
    expect(m.recorded.isNotEmpty, isTrue, reason: 'drag wrote the layout');
    m.dispose();
  });

  testWidgets('column layout persists per host through the model', (
    tester,
  ) async {
    final m = ColumnHost();
    await mount(tester, m);
    // The panel applied the remembered layout for this host (name first,
    // owner second) — the header proves the remembered order.
    expect(
      tester.getCenter(find.textContaining('名称')).dx,
      lessThan(tester.getCenter(find.textContaining('所有者')).dx),
    );
    m.dispose();
  });
}
