import 'dart:typed_data';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/accounts/application/account_avatar_cache.dart';
import 'package:aml/src/features/accounts/ui/account_avatar.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class YggdrasilProfileOption extends StatefulWidget {
  const YggdrasilProfileOption({
    super.key,
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final rust.YggdrasilProfileDto profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<YggdrasilProfileOption> createState() => _YggdrasilProfileOptionState();
}

class _YggdrasilProfileOptionState extends State<YggdrasilProfileOption> {
  Uint8List? _head;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadHead();
  }

  @override
  void didUpdateWidget(covariant YggdrasilProfileOption oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.profile.skinUrl != widget.profile.skinUrl) {
      _head = null;
      _loadHead();
    }
  }

  Future<void> _loadHead() async {
    final skinUrl = widget.profile.skinUrl;
    if (skinUrl == null || skinUrl.isEmpty || _loading) return;
    _loading = true;
    try {
      final response = await http
          .get(Uri.parse(skinUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.length > 4 * 1024 * 1024) {
        return;
      }
      final head = await getIt<AccountAvatarCache>().ensureFromSkinPng(
        widget.profile.id,
        response.bodyBytes,
        force: true,
      );
      if (mounted && head != null) {
        setState(() => _head = head);
      }
    } catch (_) {
      // A missing or unreachable skin uses the deterministic initials fallback.
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final profile = widget.profile;
    final head = _head;
    return Material(
      color:
          widget.selected ? tokens.colorBrandHighlight : tokens.colorButtonBg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected
                  ? tokens.colorBrand
                  : tokens.colorSecondary.withValues(alpha: 0.22),
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: head != null
                    ? Image.memory(
                        head,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.none,
                        gaplessPlayback: true,
                      )
                    : Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        color: AccountAvatar.accentFor(
                          profile.name,
                          Theme.of(context).colorScheme,
                        ),
                        child: Text(
                          AccountAvatar.initialFor(profile.name),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.colorContrast,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                widget.selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: widget.selected
                    ? tokens.colorBrand
                    : tokens.colorBase.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
