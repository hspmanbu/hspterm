// No SSH, Vault or account access. Measures the real font settings panel using
// a deterministic system-font catalogue; run before/after in separate processes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/terminal/typography.dart';
import 'package:hspterm/workbench/typography_settings.dart';
import 'package:hspterm/workbench/typography_store.dart';

class _Fonts implements TypographyGateway {
  final names = List.generate(
    const int.fromEnvironment('FONT_COUNT', defaultValue: 4096),
    (i) => 'Synthetic Mono ${i.toString().padLeft(4, '0')}',
  );
  int catalogReads = 0;
  @override
  Future<TypographySnapshot> load() async => TypographySnapshot(
    scope: 'memory-fixture',
    revision: '0',
    settings: const TerminalTypography(),
  );
  @override
  Future<List<String>> systemFamilies() async {
    catalogReads++;
    return names;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Memory fixture does not save or read font bodies',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final gateway = _Fonts();
  final controller = TerminalTypographyController(gateway: gateway);
  final reports = <Map<String, Object?>>[];
  final root = GlobalKey();
  Future<void> mount(Widget child, String label) async {
    runApp(
      MaterialApp(
        theme: Desk.theme(false),
        home: Scaffold(
          key: root,
          body: SingleChildScrollView(child: child),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(seconds: 2));
    var paragraphs = 0;
    void count(Element element) {
      if (element.renderObject is RenderParagraph) paragraphs++;
      element.visitChildren(count);
    }

    root.currentContext!.visitChildElements(count);
    reports.add({
      'stage': label,
      'rss_bytes': ProcessInfo.currentRss,
      'peak_rss_bytes': ProcessInfo.maxRss,
      'paragraph_elements': paragraphs,
      'catalog_reads': gateway.catalogReads,
    });
  }

  await mount(const Text('设置内存基准 · 无 SSH 连接'), 'baseline');
  for (var i = 0; i < 4; i++) {
    await mount(TypographySettingsPanel(controller: controller), 'settings-$i');
    await mount(const Text('设置内存基准 · 无 SSH 连接'), 'closed-$i');
  }
  await controller.shutdown();
  controller.dispose();
  final result = {
    'platform': Platform.operatingSystem,
    'release': const bool.fromEnvironment('dart.vm.product'),
    'font_count': gateway.names.length,
    'note': 'Synthetic catalogue; real settings panel; no Vault/SSH. RSS includes engine/graphics/allocator and is not a Windows measurement.',
    'samples': reports,
  };
  const output = String.fromEnvironment('MEMORY_REPORT');
  if (output.isNotEmpty) {
    await File(
      output,
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(result)}\n');
  }
  stdout.writeln(jsonEncode(result));
  exit(0);
}
