import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';

/// Section title used across instance settings tabs.
Widget instanceSettingsSectionHeader(
  BuildContext context,
  String title, {
  String? description,
}) {
  final tokens = context.tokens;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: tokens.colorContrast,
        ),
      ),
      if (description != null) ...[
        const SizedBox(height: 6),
        Text(
          description,
          style: TextStyle(
            fontSize: 13,
            color: tokens.colorBase.withValues(alpha: 0.7),
          ),
        ),
      ],
    ],
  );
}

/// Checkbox + child row for optional override settings.
Widget instanceSettingsOverrideRow(
  BuildContext context, {
  required String label,
  required bool value,
  required ValueChanged<bool> onChanged,
  required Widget child,
  bool saving = false,
}) {
  final tokens = context.tokens;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Checkbox(
            value: value,
            activeColor: tokens.colorBrand,
            onChanged: saving ? null : (checked) => onChanged(checked ?? false),
          ),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: tokens.colorContrast,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Opacity(
        opacity: value ? 1 : 0.45,
        child: IgnorePointer(
          ignoring: !value || saving,
          child: child,
        ),
      ),
    ],
  );
}

/// Label / value row for read-only install info.
Widget instanceSettingsInfoRow(
  BuildContext context,
  String label,
  String value,
) {
  final tokens = context.tokens;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: tokens.colorBase.withValues(alpha: 0.75)),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: tokens.colorContrast,
          ),
        ),
      ],
    ),
  );
}
