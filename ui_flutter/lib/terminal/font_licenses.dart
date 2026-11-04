import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Lazy asset reads: startup registers notices without loading font binaries
/// or decoding license text on the terminal/frame path.
void registerTerminalFontLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    for (final entry in const {
      'JetBrains Mono': 'assets/fonts/JetBrainsMono-OFL.txt',
      'Noto Sans CJK': 'assets/fonts/NotoSansCJK-LICENSE.txt',
      'HSPTerm Nerd symbol subset': 'assets/fonts/HSPNerdSymbols-LICENSES.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString(entry.value));
    }
  });
}
