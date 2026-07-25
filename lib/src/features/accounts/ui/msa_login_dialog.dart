import 'dart:async';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

/// In-app Microsoft login: watch URL for oauth desktop redirect.
class MsaLoginDialog extends StatefulWidget {
  final String authUrl;

  const MsaLoginDialog({super.key, required this.authUrl});

  /// Shows the dialog and returns the full redirect URL containing `code=`,
  /// or `null` if the user cancelled.
  static Future<String?> show(BuildContext context, {required String authUrl}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MsaLoginDialog(authUrl: authUrl),
    );
  }

  @override
  State<MsaLoginDialog> createState() => _MsaLoginDialogState();
}

class _MsaLoginDialogState extends State<MsaLoginDialog> {
  static const _redirectPrefix = 'https://login.live.com/oauth20_desktop.srf';
  static bool _environmentReady = false;

  final _controller = WebviewController();
  StreamSubscription<String>? _urlSub;
  String? _error;
  bool _ready = false;
  bool _completing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      if (!Platform.isWindows) {
        setState(() => _error = '当前平台不支持应用内微软登录');
        return;
      }

      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        setState(
          () => _error = '未检测到 WebView2 运行时，请安装 Microsoft Edge WebView2',
        );
        return;
      }

      if (!_environmentReady) {
        final appData = getIt<RuntimeState>().appDataDirectory.value;
        if (appData != null && appData.isNotEmpty) {
          await WebviewController.initializeEnvironment(
            userDataPath: p.join(appData, 'webview2_msa'),
          );
        }
        _environmentReady = true;
      }

      await _controller.initialize();
      _urlSub = _controller.url.listen(_onUrl);
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.loadUrl(widget.authUrl);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onUrl(String url) {
    if (_completing) return;
    if (!url.startsWith(_redirectPrefix)) return;

    final uri = Uri.tryParse(url);
    if (uri == null) return;

    if (uri.queryParameters.containsKey('code')) {
      _completing = true;
      Navigator.of(context).pop(url);
      return;
    }

    final err = uri.queryParameters['error'];
    if (err != null) {
      _completing = true;
      Navigator.of(context).pop();
      debugPrint('MSA login redirect error: $err ${uri.queryParameters['error_description']}');
    }
  }

  @override
  void dispose() {
    unawaited(_urlSub?.cancel() ?? Future<void>.value());
    unawaited(_controller.dispose());
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
        width: (size.width * 0.55).clamp(480.0, 720.0),
        height: (size.height * 0.78).clamp(520.0, 780.0),
        child: Column(
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
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color: tokens.colorSecondary.withValues(alpha: 0.25),
            ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: tokens.colorBase),
                        ),
                      ),
                    )
                  : !_ready
                      ? Center(
                          child: CircularProgressIndicator(
                            color: tokens.colorBrand,
                          ),
                        )
                      : ClipRRect(
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          child: Webview(_controller),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
