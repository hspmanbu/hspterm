import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/shortcut_settings.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/application_keys.dart';
import 'package:hspterm/workbench/model.dart';

PaletteShortcutView change(PaletteShortcutView v) => PaletteShortcutView(
  vaultScope: v.vaultScope,
  revision: v.revision,
  enabled: true,
  key: 'F8',
  modifiers: 5,
  applicationInTerminal: true,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real encrypted binding applies after ACK and stale/foreign/reopened views cannot overwrite', () async {
    final dir = await Directory.systemTemp.createTemp(
      'hspterm-palette-settings-native-',
    );
    final model = LiveWorkbenchModel();
    final path = '${dir.path}/shortcut.vault';
    try {
      await rust.unlockVault(
        path: path,
        password: 'synthetic-palette-settings-master',
      );
      await model.load();
      final source = await model.reloadPaletteShortcut();
      expect(source.applicationInTerminal, false);
      final saved = await model.savePaletteShortcut(change(source));
      expect(model.paletteBinding.key, PaletteBinding.keys['F8']);
      expect(model.paletteBinding.applicationInTerminal, true);
      expect((await rust.commandPaletteShortcut()).revision, saved.revision);
      await expectLater(
        rust.saveCommandPaletteShortcut(value: change(source)),
        throwsA(anything),
      );
      await expectLater(
        rust.unlockVault(path: path, password: 'synthetic-wrong-password'),
        throwsA(anything),
      );
      expect((await model.reloadPaletteShortcut()).revision, saved.revision);
      await rust.unlockVault(
        path: '${dir.path}/other-shortcut.vault',
        password: 'synthetic-other-palette-master',
      );
      await expectLater(
        rust.saveCommandPaletteShortcut(value: change(saved)),
        throwsA(anything),
      );
      expect(
        (await rust.commandPaletteShortcut()).applicationInTerminal,
        false,
      );
      await rust.unlockVault(
        path: path,
        password: 'synthetic-palette-settings-master',
      );
      await expectLater(
        rust.saveCommandPaletteShortcut(value: change(saved)),
        throwsA(anything),
      );
      final reopened = await model.reloadPaletteShortcut();
      expect(reopened.key, 'F8');
      expect(reopened.applicationInTerminal, true);
      expect(model.sessions, isEmpty);
      expect(model.tabs, isEmpty);
    } finally {
      await model.shutdown();
      model.dispose();
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isLinux);
}
