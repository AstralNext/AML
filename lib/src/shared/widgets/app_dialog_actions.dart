import 'package:flutter/material.dart';

/// Shared [TextButton] styles for [AlertDialog] actions.
///
/// Default text buttons use the brand color via [ThemeData.textButtonTheme].
/// Destructive confirms (删除) should use [destructive].
abstract final class AppDialogActions {
  static ButtonStyle destructive(BuildContext context) => TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
      );
}
