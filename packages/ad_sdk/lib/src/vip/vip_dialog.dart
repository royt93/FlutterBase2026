import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;

import 'vip_dialog_strings.dart';
import 'vip_entry.dart';

/// Show the non-dismissable "verifying" Cupertino dialog.
/// Caller closes it via `Navigator.of(context, rootNavigator: true).pop()`.
Future<void> showVipVerifyingDialog(
  BuildContext context,
  VipDialogStrings s,
) {
  return showCupertinoDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: CupertinoAlertDialog(
        title: Text(s.verifyingTitle),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CupertinoActivityIndicator(radius: 14),
              const SizedBox(height: 12),
              Text(s.verifyingMessage),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Show the success dialog with the formatted "valid until" date.
Future<void> showVipSuccessDialog(
  BuildContext context,
  VipDialogStrings s,
  VipEntry entry,
) {
  final until = _formatDateTime(entry.expiresAt);
  return showCupertinoDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => CupertinoAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_circle,
            color: CupertinoColors.activeGreen,
            size: 22,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(s.successTitle)),
        ],
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(s.successMessage(until)),
      ),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
          child: Text(s.confirmButton),
        ),
      ],
    ),
  );
}

/// Show the failure dialog. [message] overrides the default failed-message.
Future<void> showVipFailedDialog(
  BuildContext context,
  VipDialogStrings s,
  String message,
) {
  return showCupertinoDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => CupertinoAlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.cancel,
            color: CupertinoColors.systemRed,
            size: 22,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(s.failedTitle)),
        ],
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(message),
      ),
      actions: [
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
          child: Text(s.confirmButton),
        ),
      ],
    ),
  );
}

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
