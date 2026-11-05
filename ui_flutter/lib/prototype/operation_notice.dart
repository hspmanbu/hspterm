import 'package:flutter/material.dart';

import '../app_notice.dart';
import 'model.dart';

/// Global operation feedback shares the terminal/SFTP transient notification.
class OperationNotice extends StatefulWidget {
  const OperationNotice({super.key, required this.model});
  final WorkbenchModel model;
  @override
  State<OperationNotice> createState() => _OperationNoticeState();
}

class _OperationNoticeState extends State<OperationNotice> {
  String? _queued;
  @override
  Widget build(BuildContext context) {
    final message = widget.model.operationError;
    if (message != null && message != _queued) {
      _queued = message;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.model.operationError != message) return;
        showAppNotice(context, message);
        widget.model.operationError = null;
        _queued = null;
        widget.model.changed();
      });
    }
    return const SizedBox.shrink();
  }
}
