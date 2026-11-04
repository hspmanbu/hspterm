import 'terminal/font_licenses.dart';

import 'package:flutter/material.dart';

import 'prototype/app.dart';

/// Independent Phase 3A mock entry. main.dart remains the real SSH application.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerTerminalFontLicenses();
  runApp(const PrototypeApp());
}
