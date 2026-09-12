import 'dart:async';

import 'package:aml/src/rust/api/launcher.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Cross-platform Microsoft login via OAuth2 Device Code flow.
///
/// Works uniformly on Windows, Linux and macOS — the user sees a short
/// 8-character code + URL, opens the browser, enters the code, and this
/// dialog polls until Microsoft confirms authorization.
class DeviceCodeLoginDialog extends StatefulWidget {
  /// Returns [AccountDto] on success, `null` on cancel / expire / decline.
  static Future<AccountDto?> show(BuildContext context) {
    return showDialog<AccountDto>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const DeviceCodeLoginDialog._(),
    );
  }

  const DeviceCodeLoginDialog._();

  @override
  State<DeviceCodeLoginDialog> createState() => _DeviceCodeLoginDialogState();
}

class _DeviceCodeLoginDialogState extends State<DeviceCodeLoginDialog> {
  DeviceCodeLoginBeginDto? _begin;
  String? _error;
  Timer? _pollTimer;
  int _pollIntervalSec = 5;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final result = await beginDeviceCodeLogin();
      if (_cancelled || !mounted) return;
      setState(() {
        _begin = result;
        _pollIntervalSec = result.interval.toInt();
      });
      unawaited(_openBrowser(result.verificationUri));
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _openBrowser(String verificationUri) async {
    final uri = Uri.parse(verificationUri);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(Duration(seconds: _pollIntervalSec), (_) {
      if (_cancelled) return;
      _tick();
    });
    // 不立即调用 _tick() — Microsoft 后端可能需要 1-2 秒注册 device_code，
    // 立即 poll 会拿到 bad_verification_code。等第一个 interval 后再查。
  }

  Future<void> _tick() async {
    if (_begin == null) return;
    try {
      final result = await pollDeviceCode(loginId: _begin!.loginId);
      if (_cancelled || !mounted) return;
      switch (result.status) {
        case 'success':
          _pollTimer?.cancel();
          _pollTimer = null;
          _cancelled = true;
          Navigator.of(context).pop(result.account);
        case 'expired':
          _stopPolling();
          if (!mounted) return;
          setState(() => _error = '授权码已过期，请重新登录');
        case 'declined':
          _stopPolling();
          if (!mounted) return;
          setState(() => _error = '你已拒绝授权');
        case 'slow_down':
          // Microsoft asks us to wait longer — double the interval.
          _pollIntervalSec = (_pollIntervalSec * 2).clamp(5, 60);
          _startPolling();
        case 'pending':
        // keep going
        default:
          // Unexpected status with possible error message from backend.
          if (result.error != null && result.error!.isNotEmpty) {
            _stopPolling();
            if (!mounted) return;
            setState(() => _error = result.error);
          }
      }
    } catch (e) {
      if (_cancelled || !mounted) return;
      // transient network error — keep polling, will retry next tick
      debugPrint('device_code poll error: $e');
    }
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _cancel() {
    _cancelled = true;
    _stopPolling();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _cancelled = true;
    _stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      backgroundColor: tokens.colorRaisedBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: (size.width * 0.5).clamp(420.0, 600.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Icon(Icons.login, color: tokens.colorContrast, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '登录 Microsoft 账号',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ),
                  CustomButton(
                    icon: Icons.close,
                    size: ButtonSize.medium,
                    onTap: _cancel,
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color: tokens.colorSecondary.withValues(alpha: 0.25),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: _error != null
                  ? _buildError(tokens)
                  : _begin == null
                      ? _buildLoading(tokens)
                      : _buildReady(tokens),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading(AppThemeTokens tokens) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: tokens.colorBrand),
        const SizedBox(height: 16),
        Text(
          '正在连接 Microsoft 服务...',
          style: TextStyle(color: tokens.colorBase),
        ),
      ],
    );
  }

  Widget _buildError(AppThemeTokens tokens) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: tokens.colorBase),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _cancel,
          style: ElevatedButton.styleFrom(
            backgroundColor: tokens.colorButtonBg,
            foregroundColor: tokens.colorContrast,
          ),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildReady(AppThemeTokens tokens) {
    final begin = _begin!;
    final uri = Uri.parse(begin.verificationUri);
    final code = begin.userCode;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: tokens.colorSuperRaisedBg.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: tokens.colorBrand.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.devices, size: 18, color: tokens.colorBrand),
                  const SizedBox(width: 8),
                  Text(
                    '在浏览器中访问',
                    style: TextStyle(
                      color: tokens.colorBase.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                uri.host + uri.path,
                style: TextStyle(
                  color: tokens.colorContrast,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '然后输入代码',
                style: TextStyle(
                  color: tokens.colorBase.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (!mounted) return;
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: const Text('已复制代码到剪贴板'),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.colorBrand.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: tokens.colorBrand.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        code,
                        style: TextStyle(
                          color: tokens.colorBrand,
                          fontWeight: FontWeight.w800,
                          fontSize: 24,
                          letterSpacing: 4,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.content_copy,
                        size: 14,
                        color: tokens.colorBase.withValues(alpha: 0.5),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _openBrowser(begin.verificationUri),
                icon: const Icon(Icons.open_in_browser, size: 16),
                label: const Text('打开浏览器'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: tokens.colorButtonBg,
                  foregroundColor: tokens.colorContrast,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _cancel,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  foregroundColor: tokens.colorBase,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: tokens.colorSecondary.withValues(alpha: 0.3),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: tokens.colorBrand.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '等待授权中...',
              style: TextStyle(
                color: tokens.colorBase.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
