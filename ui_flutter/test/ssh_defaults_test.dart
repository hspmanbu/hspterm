import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/network_settings.dart';
import 'package:hspterm/workbench/ssh_network_defaults.dart';

class DefaultsFixture implements SshDefaultsGateway {
  bool fail = false;
  int writes = 0;
  SshNetworkDefaults value = const SshNetworkDefaults(
    timeoutSeconds: 30,
    keepaliveSeconds: 30,
    responseTimeoutSeconds: 10,
    autoReconnect: false,
    tmuxLocalSelection: true,
    tmuxShiftEnterLf: false,
    keepaliveFailures: 3,
  );
  @override
  Future<SshNetworkDefaults> load() async {
    if (fail) throw StateError('synthetic defaults read failure');
    return value;
  }

  @override
  Future<SshNetworkDefaults> save(SshNetworkDefaults next) async {
    writes++;
    return value = next;
  }
}

void main() {
  testWidgets(
    'tmux settings apply only after Save and restore encrypted choices',
    (tester) async {
      final fixture = DefaultsFixture();
      SshNetworkDefaults? applied;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SshNetworkDefaultsPanel(
                gateway: fixture,
                onSaved: (v) => applied = v,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final shift = find.byKey(const ValueKey('ssh-tmux-shift-enter'));
      await tester.ensureVisible(shift);
      await tester.tap(shift);
      await tester.pumpAndSettle();
      expect(fixture.writes, 0);
      expect(applied, isNull);
      final save = find.text('保存 SSH 默认参数');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(fixture.writes, 1);
      expect(applied!.tmuxShiftEnterLf, true);
      expect(applied!.tmuxLocalSelection, true);
      await tester.ensureVisible(find.text('重新载入'));
      await tester.tap(find.text('重新载入'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(shift).value, true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'read failure prevents overwriting unknown defaults, validation and explicit Save remain local',
    (tester) async {
      final fixture = DefaultsFixture()..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SshNetworkDefaultsPanel(gateway: fixture),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '保存 SSH 默认参数'),
            )
            .onPressed,
        isNull,
      );
      fixture.fail = false;
      await tester.ensureVisible(find.text('重新载入'));
      await tester.tap(find.text('重新载入'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ssh-default-response')),
        '0',
      );
      await tester.ensureVisible(find.text('保存 SSH 默认参数'));
      await tester.tap(find.text('保存 SSH 默认参数'));
      await tester.pumpAndSettle();
      expect(fixture.writes, 0);
      expect(find.text('请输入 1–3600'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('ssh-default-response')),
        '7',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ssh-default-interval')),
        '0',
      );
      await tester.ensureVisible(find.text('保存 SSH 默认参数'));
      await tester.tap(find.text('保存 SSH 默认参数'));
      await tester.pumpAndSettle();
      expect(fixture.writes, 1);
      expect(fixture.value.responseTimeoutSeconds, 7);
      expect(fixture.value.keepaliveSeconds, 0);
      expect(find.textContaining('只在下次明确连接时使用'), findsOneWidget);
    },
  );
}
