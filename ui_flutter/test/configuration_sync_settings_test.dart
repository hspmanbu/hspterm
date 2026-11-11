import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/configuration_sync_settings.dart';

Map<String, dynamic> _metadata({
  bool configured = true,
  String endpoint = 'https://fixture.invalid/object',
  String revision = 'a',
}) => {
  'vault_scope': 'synthetic-sync-vault',
  'revision': revision * 64,
  'target': configured
      ? {
          'enabled': true,
          'endpoint': endpoint,
          'collection': '0123456789abcdef0123456789abcdef',
          'authenticate': false,
          'timeout_seconds': 60,
          'proxy': null,
        }
      : null,
  'sync_password_set': configured,
  'webdav_credential_set': false,
  'proxy_credential_set': false,
  'suggested_collection': '0123456789abcdef0123456789abcdef',
};

class _Gateway implements ConfigurationSyncSettingsGateway {
  _Gateway({Object? owner, Map<String, dynamic>? value})
    : owner = owner ?? Object(),
      value = value ?? _metadata();
  @override
  final Object owner;
  @override
  bool isClosing = false;
  Map<String, dynamic> value;
  Object? loadError;
  Completer<ConfigurationSyncSettings>? loading, saving;
  int loads = 0;
  final writes = <Map<String, dynamic>>[];
  final submittedPasswords = <String?>[];
  @override
  Future<ConfigurationSyncSettings> load() async {
    loads++;
    if (loadError != null) throw loadError!;
    final pending = loading;
    if (pending != null) return await pending.future;
    return ConfigurationSyncSettings(value);
  }

  @override
  Future<ConfigurationSyncSettings> save(Map<String, dynamic> proposal) async {
    writes.add(proposal);
    submittedPasswords.add(
      (proposal['secrets'] as Map<String, dynamic>)['sync_password'] as String?,
    );
    value = {
      ...value,
      'target': proposal['target'],
      'sync_password_set': true,
      'revision': 'b' * 64,
    };
    final pending = saving;
    if (pending != null) return await pending.future;
    return ConfigurationSyncSettings(value);
  }
}

Finder _field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
Widget _app(_Gateway gateway, {double scale = 1}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        child: ConfigurationSyncSettingsPanel(gateway: gateway),
      ),
    ),
  ),
);
Future<void> _save(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('sync-settings-save'));
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
}

void main() {
  test('WebDAV metadata accepts explicitly configured HTTP object URLs', () {
    final parsed = ConfigurationSyncSettings(
      _metadata(endpoint: 'http://dav.internal/config.enc'),
    );
    expect(parsed, isNotNull);
  });

  testWidgets(
    'a Drive target cannot be silently overwritten through the WebDAV form',
    (tester) async {
      final value = _metadata(
        endpoint: 'https://www.googleapis.com/drive/v3/files/synthetic-file',
      );
      (value['target'] as Map<String, dynamic>)['drive'] = {
        'file_id': 'synthetic-file',
        'client_id': 'synthetic-client.apps.googleusercontent.com',
        'authorization_id': 'a' * 32,
      };
      final gateway = _Gateway(value: value);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConfigurationSyncSettingsPanel(gateway: gateway),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('当前唯一同步目标为 Google Drive'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'WebDAV 文件地址（HTTP / HTTPS）'),
        findsNothing,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('sync-settings-save')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.widgetWithText(TextFormField, 'Drive 对象地址（只读）'),
                matching: find.byType(TextField),
              ),
            )
            .readOnly,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.widgetWithText(TextFormField, '集合标识'),
                matching: find.byType(TextField),
              ),
            )
            .readOnly,
        isTrue,
      );
      expect(gateway.writes, isEmpty);
      await tester.tap(find.text('改为配置 WebDAV 目标'));
      await tester.pump();
      expect(
        find.widgetWithText(TextFormField, 'WebDAV 文件地址（HTTP / HTTPS）'),
        findsOneWidget,
      );
      expect(gateway.writes, isEmpty);
    },
  );
  test('Drive metadata rejects arbitrary origins, wrong ids and mixed HTTP authentication', () {
    Map<String, dynamic> metadata() {
      final raw = _metadata(
        endpoint: 'https://www.googleapis.com/drive/v3/files/synthetic-file',
      );
      (raw['target'] as Map<String, dynamic>)['drive'] = {
        'file_id': 'synthetic-file',
        'client_id': 'synthetic-client.apps.googleusercontent.com',
        'authorization_id': 'a' * 32,
      };
      return raw;
    }

    ConfigurationSyncSettings(metadata());
    final bad = metadata();
    (bad['target'] as Map<String, dynamic>)['endpoint'] =
        'https://attacker.invalid/object';
    expect(() => ConfigurationSyncSettings(bad), throwsFormatException);
    final mixed = metadata();
    (mixed['target'] as Map<String, dynamic>)['authenticate'] = true;
    expect(() => ConfigurationSyncSettings(mixed), throwsFormatException);
    final invalid = metadata();
    ((invalid['target'] as Map<String, dynamic>)['drive']
            as Map<String, dynamic>)['file_id'] =
        '../escape';
    expect(() => ConfigurationSyncSettings(invalid), throwsFormatException);
  });
  testWidgets(
    'first explicit setup passes original scope and write-only password then clears its controller',
    (tester) async {
      final gateway = _Gateway(value: _metadata(configured: false));
      await tester.pumpWidget(_app(gateway));
      await tester.pumpAndSettle();
      await tester.enterText(
        _field('WebDAV 文件地址（HTTP / HTTPS）'),
        'https://new-fixture.invalid/object',
      );
      await tester.ensureVisible(_field('同步密码'));
      await tester.enterText(_field('同步密码'), 'synthetic-ui-sync-password');
      final password = tester.widget<TextField>(_field('同步密码')).controller!;
      await _save(tester);
      await tester.pumpAndSettle();
      expect(gateway.writes, hasLength(1));
      final proposal = gateway.writes.single;
      expect(proposal['vault_scope'], 'synthetic-sync-vault');
      expect(proposal['revision'], 'a' * 64);
      // The Fake deliberately inspects only this synthetic input. Native storage
      // and public views are separately tested not to return secret contents.
      expect(
        proposal['target'],
        containsPair('endpoint', 'https://new-fixture.invalid/object'),
      );
      expect(gateway.submittedPasswords, ['synthetic-ui-sync-password']);
      expect(password.text, isEmpty);
      expect(find.text('同步设置已加密保存；启用后配置变更会合并触发同步。'), findsOneWidget);
    },
  );
  testWidgets('load failure cannot fall back to a writable default target', (
    tester,
  ) async {
    final gateway = _Gateway()
      ..loadError = StateError('synthetic read failure');
    await tester.pumpWidget(_app(gateway));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('sync-settings-save')),
          )
          .onPressed,
      isNull,
    );
    expect(_field('WebDAV 文件地址（HTTP / HTTPS）'), findsNothing);
    expect(gateway.writes, isEmpty);
    expect(find.textContaining('读取同步配置失败'), findsOneWidget);
  });
  testWidgets(
    'switch cancellation is local and later confirmation preserves original proposal identity',
    (tester) async {
      final gateway = _Gateway();
      await tester.pumpWidget(_app(gateway));
      await tester.pumpAndSettle();
      await tester.enterText(
        _field('WebDAV 文件地址（HTTP / HTTPS）'),
        'https://other-fixture.invalid/object',
      );
      await _save(tester);
      await tester.pumpAndSettle();
      expect(find.text('更换同步目标'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.writes, isEmpty);
      await _save(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认更换'));
      await tester.pumpAndSettle();
      expect(gateway.writes, hasLength(1));
      expect(gateway.writes.single['confirm_target_change'], isTrue);
      expect(gateway.writes.single['revision'], 'a' * 64);
    },
  );
  testWidgets(
    'a completed write after page disposal cannot read disposed text controllers or update another page',
    (tester) async {
      final gateway = _Gateway()
        ..saving = Completer<ConfigurationSyncSettings>();
      await tester.pumpWidget(_app(gateway));
      await tester.pumpAndSettle();
      await _save(tester);
      expect(gateway.writes, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      gateway.saving!.complete(ConfigurationSyncSettings(gateway.value));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'late load from an old owner cannot overwrite the new owner form',
    (tester) async {
      final old = _Gateway()..loading = Completer<ConfigurationSyncSettings>();
      await tester.pumpWidget(_app(old));
      await tester.pump();
      final current = _Gateway(
        value: _metadata(
          endpoint: 'https://current-fixture.invalid/object',
          revision: 'b',
        ),
      );
      await tester.pumpWidget(_app(current));
      await tester.pumpAndSettle();
      old.loading!.complete(ConfigurationSyncSettings(old.value));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(_field('WebDAV 文件地址（HTTP / HTTPS）'))
            .controller!
            .text,
        'https://current-fixture.invalid/object',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'same owner rebuild preserves edits instead of reloading on terminal redraw',
    (tester) async {
      final owner = Object();
      final initial = _Gateway(owner: owner);
      await tester.pumpWidget(_app(initial));
      await tester.pumpAndSettle();
      await tester.enterText(
        _field('WebDAV 文件地址（HTTP / HTTPS）'),
        'https://edited-fixture.invalid/object',
      );
      final replacement = _Gateway(owner: owner);
      await tester.pumpWidget(_app(replacement));
      await tester.pumpAndSettle();
      expect(initial.loads, 1);
      expect(replacement.loads, 0);
      expect(
        tester
            .widget<TextField>(_field('WebDAV 文件地址（HTTP / HTTPS）'))
            .controller!
            .text,
        'https://edited-fixture.invalid/object',
      );
    },
  );
  testWidgets(
    'IME preedit cannot submit and compact scaled layout scrolls without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = _Gateway();
      await tester.pumpWidget(_app(gateway, scale: 1.25));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<TextField>(_field('WebDAV 文件地址（HTTP / HTTPS）'))
          .controller!;
      final text = controller.text;
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: TextRange(start: 0, end: text.length),
      );
      final button = find.byKey(const ValueKey('sync-settings-save'));
      await tester.ensureVisible(button);
      await tester.pump();
      tester.widget<FilledButton>(button).onPressed!();
      await tester.pump();
      expect(gateway.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
