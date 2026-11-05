import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show AnyhowException;

String appMessage(Object value) {
  var text = value is AnyhowException ? value.message : value.toString();
  for (final prefix in ['Bad state: ', 'Exception: ']) {
    if (text.startsWith(prefix)) text = text.substring(prefix.length);
  }
  return text.replaceAllMapped(
    RegExp(r'AnyhowException\((.*)\)', dotAll: true),
    (m) => m[1]!,
  );
}

void showAppNotice(
  BuildContext context,
  Object message, {
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(appMessage(message)),
      duration: const Duration(seconds: 6),
      showCloseIcon: true,
      persist: false,
      behavior: SnackBarBehavior.floating,
      action: action,
    ),
  );
}
