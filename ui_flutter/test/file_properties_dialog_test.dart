import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/file_properties.dart';

class Gateway implements FilePropertiesGateway {
  @override
  bool current = true;
  final calls = <(int?, int?, int?, bool)>[];
  @override
  Future<rust.RemoteProperties> load(bool includeSize) async {
    if (includeSize) throw StateError('synthetic denied subtree');
    return const rust.RemoteProperties(
      path: '/folder',
      size: 4096,
      files: 0,
      directories: 1,
      permissions: 493,
      uid: 1000,
      gid: 1000,
      sizeComplete: false,
    );
  }

  @override
  Future<void> save({
    int? permissions,
    int? uid,
    int? gid,
    required bool recursive,
  }) async {
    calls.add((permissions, uid, gid, recursive));
  }
}

void main() {
  testWidgets(
    'failed folder size retains editable metadata and preserves untouched ownership',
    (tester) async {
      final gateway = Gateway();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => FilePropertiesDialog(
                    gateway: gateway,
                    file: DemoFile(
                      '/folder',
                      'folder',
                      folder: true,
                      kind: '文件夹',
                    ),
                  ),
                ),
                child: const Text('properties'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('properties'));
      await tester.pumpAndSettle();
      expect(find.textContaining('内容大小未计算'), findsOneWidget);
      expect(find.text('未计算'), findsOneWidget);
      expect(find.textContaining('4.0 KB'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, '八进制权限'), '0700');
      await tester.tap(find.text('保存属性'));
      await tester.pumpAndSettle();
      expect(gateway.calls, [(448, null, null, false)]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'properties layout remains scrollable in a small window with large text',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: FilePropertiesDialog(
              gateway: Gateway(),
              file: DemoFile('/folder', 'folder', folder: true, kind: '文件夹'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('关闭'), findsOneWidget);
    },
  );
}
