import 'package:flutter/material.dart';

/// Root [ScaffoldMessenger] for toasts that outlive the calling page.
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void showAppSnackBar(
  String message, {
  bool isError = false,
  Duration? duration,
}) {
  final messenger = appMessengerKey.currentState;
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ??
            (isError
                ? const Duration(seconds: 12)
                : const Duration(seconds: 4)),
        backgroundColor: isError ? const Color(0xFFB3261E) : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
}
