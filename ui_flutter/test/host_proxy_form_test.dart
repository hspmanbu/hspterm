import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';

class _Hosts extends WorkbenchModel {
  _Hosts() {
    groups.add('未分组');
    hosts
      ..clear()
      ..add(
        DemoHost(
          'fixture',
          'Proxy fixture',
          'ssh.invalid',
          '未分组',
          credentialSet: true,
        ),
      );
  }
  @override
  bool get isMock => false;
  DemoHost? saved;
  String? proxyUser, proxyPass;
  int writes = 0;
  @override
  Future<DemoHost> persistHost(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    writes++;
    proxyUser = proxyUsername;
    proxyPass = proxyPassword;
    saved = host.snapshot();
    if (host.proxy case final p?) {
      saved!.proxy = DemoProxy(
        socks5: p.socks5,
        address: p.address,
        port: p.port,
        authenticate: p.authenticate,
        credentialSet: p.authenticate,
      );
    }
    return saved!;
  }
}

void main() {
  testWidgets(
    'network form saves validated proxy once and never reads stored secrets',
    (tester) async {
      final model = _Hosts();
      final key = GlobalKey<HostManagerState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostManager(key: key, model: model),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('网络'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('host-proxy-kind')));
      await tester.tap(find.byKey(const ValueKey('host-proxy-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SOCKS5').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('host-proxy-address')),
        '127.0.0.1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('host-proxy-port')),
        '1080',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('host-proxy-authenticate')),
      );
      await tester.tap(find.byKey(const ValueKey('host-proxy-authenticate')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('host-proxy-username')),
        'synthetic-user',
      );
      await tester.enterText(
        find.byKey(const ValueKey('host-proxy-password')),
        'synthetic-password',
      );
      final save = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await save, true);
      expect(model.writes, 1);
      expect(model.saved!.proxy!.socks5, true);
      expect(model.saved!.proxy!.port, 1080);
      expect(model.proxyUser, 'synthetic-user');
      expect(model.proxyPass, 'synthetic-password');
      await tester.tap(find.text('网络'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('host-proxy-username')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('host-proxy-password')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(find.textContaining('已设置'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('host-proxy-port')),
        '0',
      );
      final invalid = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await invalid, false);
      expect(model.writes, 1);
      expect(find.text('请输入 1–65535 的端口'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'incomplete proxy draft is not represented as saved authentication',
    (tester) async {
      final model = _Hosts();
      model.hosts.single.proxy = const DemoProxy(
        socks5: false,
        address: 'proxy.invalid',
        port: 8080,
        authenticate: true,
      );
      final key = GlobalKey<HostManagerState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostManager(key: key, model: model),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final save = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await save, false);
      expect(model.writes, 0);
      expect(find.byKey(const ValueKey('host-proxy-username')), findsOneWidget);
      expect(find.text('请输入代理用户名'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
