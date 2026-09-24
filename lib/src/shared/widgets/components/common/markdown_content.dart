import 'dart:async';
import 'dart:io';

import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/common/markdown_webview_renderer.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:webview_windows/webview_windows.dart';

/// Markdown / HTML body renderer:
/// Markdown (html allowed) → HTML → sanitized → WebView2 (Windows) or [Html] fallback.
class MarkdownContent extends StatefulWidget {
  const MarkdownContent({
    super.key,
    required this.data,
  });

  final String data;

  @override
  State<MarkdownContent> createState() => _MarkdownContentState();
}

class _MarkdownContentState extends State<MarkdownContent> {
  /// webview_windows dies after hot restart ("Pipe create failed"); prefer Html.
  static bool webviewUnavailable = false;

  /// Large CF/Modrinth bodies spam height IPC and often break the pipe.
  static const _maxWebViewChars = 48000;

  bool? _useWebView;

  @override
  void initState() {
    super.initState();
    unawaited(_detectRenderer());
  }

  Future<void> _detectRenderer() async {
    if (webviewUnavailable || !Platform.isWindows) {
      if (mounted) setState(() => _useWebView = false);
      return;
    }
    final version = await WebviewController.getWebViewVersion();
    if (mounted) setState(() => _useWebView = version != null);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final tokens = context.tokens;
    final tooLarge = widget.data.length > _maxWebViewChars;

    if (_useWebView == null && !tooLarge && !webviewUnavailable) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_useWebView == true && !tooLarge && !webviewUnavailable) {
      return MarkdownWebViewContent(
        key: ValueKey(widget.data),
        data: widget.data,
        tokens: tokens,
        onBroken: () {
          webviewUnavailable = true;
          if (mounted) setState(() => _useWebView = false);
        },
      );
    }

    return MarkdownHtmlFallback(data: widget.data, tokens: tokens);
  }
}


String renderModrinthBodyHtml(String source) {
  if (source.trim().isEmpty) return '';

  // Translated bodies are stored as HTML; skip MD pass to avoid mangling tags.
  final head = source.trimLeft();
  final looksHtml = head.startsWith('<') &&
      RegExp(r'<\/?[a-zA-Z][^>]*>').hasMatch(
        head.length > 500 ? head.substring(0, 500) : head,
      );
  if (looksHtml) {
    return sanitizeModrinthHtml(source);
  }

  final rendered = md.markdownToHtml(
    source,
    extensionSet: md.ExtensionSet.gitHubWeb,
    encodeHtml: true,
  );

  return sanitizeModrinthHtml(rendered);
}

String sanitizeModrinthHtml(String html) {
  var s = html;
  s = s.replaceAll(
    RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false),
    '',
  );
  s = s.replaceAll(
    RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false),
    '',
  );
  s = s.replaceAll(
    RegExp(r'''\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''', caseSensitive: false),
    '',
  );
  s = s.replaceAllMapped(
    RegExp(
      r'''(href|src)\s*=\s*(["'])\s*javascript:[^"']*\2''',
      caseSensitive: false,
    ),
    (m) => '${m[1]}=${m[2]}${m[2]}',
  );
  return s;
}

