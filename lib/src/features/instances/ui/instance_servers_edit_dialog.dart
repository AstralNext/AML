import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';

Future<bool?> showInstanceServerEditDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required TextEditingController nameController,
  required TextEditingController addressController,
  String? nameHintText,
  String? addressHintText,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final tokens = ctx.tokens;
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '名称',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: tokens.colorContrast,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: nameHintText,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '地址',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: tokens.colorContrast,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: addressController,
                decoration: InputDecoration(
                  hintText: addressHintText,
                  isDense: true,
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
}
