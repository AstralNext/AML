import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/common/image_lightbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_html_table/flutter_html_table.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
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
      return _MarkdownWebViewContent(
        key: ValueKey(widget.data),
        data: widget.data,
        tokens: tokens,
        onBroken: () {
          webviewUnavailable = true;
          if (mounted) setState(() => _useWebView = false);
        },
      );
    }

    return _MarkdownHtmlFallback(data: widget.data, tokens: tokens);
  }
}

class _MarkdownWebViewContent extends StatefulWidget {
  const _MarkdownWebViewContent({
    super.key,
    required this.data,
    required this.tokens,
    required this.onBroken,
  });

  final String data;
  final AppThemeTokens tokens;
  final VoidCallback onBroken;

  @override
  State<_MarkdownWebViewContent> createState() =>
      _MarkdownWebViewContentState();
}

class _MarkdownWebViewContentState extends State<_MarkdownWebViewContent> {
  static bool _environmentReady = false;

  final _controller = WebviewController();
  StreamSubscription<dynamic>? _messageSub;
  StreamSubscription<String>? _urlSub;

  bool _ready = false;
  String? _error;
  double _height = 200;
  bool _handlingNavigation = false;
  bool _hasMeasuredHeight = false;
  bool _brokenNotified = false;
  Timer? _heightDebounce;
  double _pendingHeight = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void didUpdateWidget(covariant _MarkdownWebViewContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data && _ready && _error == null) {
      unawaited(_loadDocument());
    }
    if (oldWidget.tokens.colorBg != widget.tokens.colorBg && _error == null) {
      unawaited(_applyChrome());
    }
  }

  void _markBroken(Object e) {
    debugPrint('Markdown WebView broken: $e');
    if (!_brokenNotified) {
      _brokenNotified = true;
      widget.onBroken();
    }
    if (mounted) setState(() => _error = '$e');
  }

  Future<void> _init() async {
    try {
      await _ensureEnvironment();
      await _controller.initialize();
      _messageSub = _controller.webMessage.listen(
        _onWebMessage,
        onError: (_) {},
      );
      _urlSub = _controller.url.listen(_onUrlChanged, onError: (_) {});
      await _applyChrome();
      await _loadDocument();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      _markBroken(e);
    }
  }

  Future<void> _ensureEnvironment() async {
    if (_environmentReady) return;

    final appData = getIt<RuntimeState>().appDataDirectory.value;
    if (appData != null && appData.isNotEmpty) {
      try {
        await WebviewController.initializeEnvironment(
          userDataPath: p.join(appData, 'webview2_markdown'),
        );
      } on PlatformException catch (e) {
        if (e.code != 'environment_already_initialized') rethrow;
      }
    }
    _environmentReady = true;
  }

  Future<void> _applyChrome() async {
    await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    await _controller.setBackgroundColor(widget.tokens.colorBg);
  }

  Future<void> _loadDocument() async {
    try {
      _heightDebounce?.cancel();
      _pendingHeight = 0;
      _hasMeasuredHeight = false;
      final html = buildMarkdownWebDocument(
        bodyHtml: renderModrinthBodyHtml(widget.data),
        tokens: widget.tokens,
      );
      await _controller.loadStringContent(html);
    } catch (e) {
      _markBroken(e);
    }
  }

  void _onWebMessage(dynamic message) {
    if (message is! Map) return;
    final type = message['type'];
    if (type == 'height') {
      final raw = message['value'];
      final next = switch (raw) {
        num v => v.toDouble(),
        _ => null,
      };
      if (next == null || next <= 0) return;
      final clamped = next.clamp(40.0, 20000.0);
      _pendingHeight = math.max(_pendingHeight, clamped);
      _heightDebounce?.cancel();
      _heightDebounce = Timer(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        final target = _pendingHeight;
        _pendingHeight = 0;
        // Height only grows while loading to avoid image/layout oscillation.
        final grown = math.max(_height, target);
        if (!_hasMeasuredHeight || grown - _height >= 8) {
          setState(() {
            _height = grown;
            _hasMeasuredHeight = true;
          });
        }
      });
      return;
    }
    if (type == 'link') {
      final href = message['value']?.toString();
      if (href != null && href.isNotEmpty) {
        unawaited(_openLink(href));
      }
      return;
    }
    if (type == 'image') {
      final src = message['value']?.toString();
      if (src != null && src.isNotEmpty && mounted) {
        showImageLightbox(context, urls: [src]);
      }
    }
  }

  void _onUrlChanged(String url) {
    if (_handlingNavigation || !_ready) return;
    if (url.isEmpty || url.startsWith('about:')) return;

    _handlingNavigation = true;
    unawaited(() async {
      await _openLink(url);
      await _controller.goBack();
      _handlingNavigation = false;
    }());
  }

  Future<void> _openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _heightDebounce?.cancel();
    unawaited(_messageSub?.cancel() ?? Future<void>.value());
    unawaited(_urlSub?.cancel() ?? Future<void>.value());
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _MarkdownHtmlFallback(
        data: widget.data,
        tokens: widget.tokens,
      );
    }

    return SizedBox(
      height: _height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_ready) Webview(_controller),
          if (!_ready || !_hasMeasuredHeight)
            Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: widget.tokens.colorBrand,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MarkdownHtmlFallback extends StatelessWidget {
  const _MarkdownHtmlFallback({
    required this.data,
    required this.tokens,
  });

  final String data;
  final AppThemeTokens tokens;

  Future<void> _openLink(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final html = renderModrinthBodyHtml(data);

    return Html(
      data: html,
      shrinkWrap: true,
      style: _htmlStyles(tokens),
      onLinkTap: (url, attributes, element) => _openLink(url),
      extensions: [
        const TableHtmlExtension(),
        TagExtension(
          tagsToExtend: {'img'},
          builder: (ext) => _MarkdownImage(
            attributes: ext.attributes,
            tokens: tokens,
          ),
        ),
      ],
    );
  }
}

class _MarkdownImage extends StatelessWidget {
  const _MarkdownImage({
    required this.attributes,
    required this.tokens,
  });

  final Map<String, String> attributes;
  final AppThemeTokens tokens;

  static double? _parseCssSize(String? raw) {
    if (raw == null) return null;
    final t = raw.trim().toLowerCase();
    if (t.isEmpty || t == 'auto') return null;
    final m = RegExp(r'^(\d+(?:\.\d+)?)\s*(px)?$').firstMatch(t);
    if (m == null) return null;
    return double.tryParse(m.group(1)!);
  }

  static double? _sizeFromStyle(String? style, String prop) {
    if (style == null || style.isEmpty) return null;
    final m = RegExp(
      '$prop\\s*:\\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(style);
    return _parseCssSize(m?.group(1));
  }

  @override
  Widget build(BuildContext context) {
    final src = attributes['src']?.trim() ?? '';
    if (src.isEmpty) return const SizedBox.shrink();

    final style = attributes['style'];
    final width = _parseCssSize(attributes['width']) ??
        _sizeFromStyle(style, 'width');
    final height = _parseCssSize(attributes['height']) ??
        _sizeFromStyle(style, 'height');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final targetW =
              (width != null ? width.clamp(0, maxW) : maxW).toDouble();
          return Align(
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: targetW,
                maxHeight: height ?? 420,
              ),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => showImageLightbox(context, urls: [src]),
                  child: CachedRemoteImage(
                    url: src,
                    width: targetW,
                    height: height,
                    fit: BoxFit.contain,
                    borderRadius: BorderRadius.circular(8),
                    placeholder: Container(
                      width: targetW,
                      height: height ?? 120,
                      color: tokens.colorSuperRaisedBg,
                      alignment: Alignment.center,
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    error: Icon(
                      Icons.broken_image_outlined,
                      color: tokens.colorBase,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
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

String buildMarkdownWebDocument({
  required String bodyHtml,
  required AppThemeTokens tokens,
}) {
  final css = _markdownBodyCss(tokens);
  final script = _markdownBridgeScript();

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>$css</style>
</head>
<body>
<div class="markdown-body">$bodyHtml</div>
<script>$script</script>
</body>
</html>
''';
}

String _cssColor(Color color) {
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  return '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

String _markdownBodyCss(AppThemeTokens tokens) {
  final bg = _cssColor(tokens.colorBg);
  final base = _cssColor(tokens.colorBase);
  final contrast = _cssColor(tokens.colorContrast);
  final brand = _cssColor(tokens.colorBrand);
  final buttonBg = _cssColor(tokens.colorButtonBg);
  final surface1 = _cssColor(tokens.colorRaisedBg);
  final surface2 = _cssColor(tokens.colorSuperRaisedBg);
  final divider = _cssColor(tokens.colorSecondary.withValues(alpha: 0.35));

  return '''
html, body {
  margin: 0;
  padding: 0;
  overflow: hidden;
  background: $bg;
  color: $base;
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  font-size: 14px;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}
.markdown-body {
  box-sizing: border-box;
  padding: 0;
  color: $base;
  word-wrap: break-word;
  overflow-wrap: anywhere;
}
.markdown-body h1:first-child {
  margin-block-start: 0;
  padding-block-start: 0;
}
.markdown-body blockquote,
.markdown-body details,
.markdown-body dl,
.markdown-body ol,
.markdown-body p,
.markdown-body code,
.markdown-body pre,
.markdown-body table,
.markdown-body ul {
  margin-top: 0;
  margin-bottom: 16px;
}
.markdown-body li,
.markdown-body p {
  padding: 0;
  line-height: 1.5;
}
.markdown-body h1,
.markdown-body h2,
.markdown-body h3 {
  color: $contrast;
}
.markdown-body h1,
.markdown-body h2 {
  padding: 10px 0 5px;
  border-bottom: 1px solid $divider;
}
.markdown-body h1 { font-size: 1.6em; font-weight: 800; }
.markdown-body h2 { font-size: 1.35em; font-weight: 800; }
.markdown-body h3 { font-size: 1.15em; font-weight: 700; }
.markdown-body h4,
.markdown-body h5,
.markdown-body h6 {
  color: $contrast;
  font-weight: 700;
}
.markdown-body blockquote {
  padding: 0 1em;
  color: $base;
  border-left: 0.25em solid $buttonBg;
  margin-inline: 0;
}
.markdown-body a {
  cursor: pointer;
  color: $brand;
  text-decoration: underline;
}
.markdown-body a:hover {
  filter: brightness(1.15);
}
.markdown-body img {
  max-width: 100%;
  height: auto;
  display: inline-block;
}
.markdown-body pre {
  margin-top: 1rem;
  padding: 14px;
  border-radius: 8px;
  background-color: $buttonBg;
  overflow-x: auto;
}
.markdown-body pre code {
  font-size: 80%;
  padding: 0;
  border-radius: 0;
  background: transparent;
}
.markdown-body code {
  padding: 0.2em 0.4em;
  font-size: 80%;
  border-radius: 6px;
  background-color: $buttonBg;
  color: $contrast;
  font-family: Consolas, "Courier New", monospace;
}
.markdown-body hr {
  margin: 20px 0;
  border: none;
  border-top: 1px solid $buttonBg;
}
.markdown-body table {
  display: block;
  width: max-content;
  max-width: 100%;
  overflow: auto;
  border-collapse: separate;
  border-spacing: 0;
  line-height: 1.5;
  border: 1px solid $buttonBg;
  border-radius: 12px;
}
.markdown-body th {
  font-weight: 600;
  background-color: $surface2;
}
.markdown-body tr {
  background-color: $surface1;
}
.markdown-body td,
.markdown-body th {
  padding: 6px 12px;
}
.markdown-body tr:nth-child(2n) {
  background-color: $bg;
}
.markdown-body td:not(:last-of-type),
.markdown-body th:not(:last-of-type) {
  border-right: 1px solid $buttonBg;
}
.markdown-body tr:not(:last-of-type) td,
.markdown-body th {
  border-bottom: 1px solid $buttonBg;
}
.markdown-body ul,
.markdown-body ol {
  padding-left: 1.5em;
}
.markdown-body > :last-child {
  margin-bottom: 0 !important;
}
''';
}

String _markdownBridgeScript() {
  return '''
(function () {
  var lastH = 0;
  var debounceTimer = null;
  var settleTimer = null;
  var observer = null;

  function post(msg) {
    if (window.chrome && window.chrome.webview) {
      window.chrome.webview.postMessage(msg);
    }
  }
  function measureHeight() {
    var root = document.querySelector('.markdown-body');
    if (!root) return 0;
    return Math.ceil(root.getBoundingClientRect().height);
  }
  function reportHeight() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(function () {
      var h = measureHeight();
      if (h <= 0 || h < lastH - 2) return;
      if (Math.abs(h - lastH) < 8) return;
      lastH = h;
      post({ type: 'height', value: h });
      if (settleTimer) clearTimeout(settleTimer);
      settleTimer = setTimeout(function () {
        if (observer) {
          observer.disconnect();
          observer = null;
        }
      }, 800);
    }, 180);
  }
  function setupLinks() {
    document.addEventListener('click', function (e) {
      var anchor = e.target.closest('a[href]');
      if (anchor) {
        var href = anchor.getAttribute('href');
        if (href && !href.startsWith('#')) {
          e.preventDefault();
          post({ type: 'link', value: anchor.href || href });
        }
        return;
      }
      var img = e.target.closest('img[src]');
      if (img) {
        e.preventDefault();
        post({ type: 'image', value: img.currentSrc || img.src });
      }
    }, true);
  }
  function setupObserver() {
    var root = document.querySelector('.markdown-body') || document.body;
    if (typeof ResizeObserver !== 'undefined') {
      observer = new ResizeObserver(reportHeight);
      observer.observe(root);
    }
    window.addEventListener('load', reportHeight);
    Array.from(document.images || []).forEach(function (img) {
      if (!img.complete) {
        img.addEventListener('load', reportHeight);
        img.addEventListener('error', reportHeight);
      }
    });
    reportHeight();
  }
  setupLinks();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', setupObserver);
  } else {
    setupObserver();
  }
})();
''';
}

Map<String, Style> _htmlStyles(AppThemeTokens tokens) {
  final baseColor = tokens.colorBase.withValues(alpha: 0.92);
  final contrast = tokens.colorContrast;

  Style text(
    double size, {
    FontWeight? weight,
    Color? color,
    FontStyle? style,
  }) {
    return Style(
      fontSize: FontSize(size),
      fontFamily: 'MiSans',
      color: color ?? baseColor,
      fontWeight: weight,
      fontStyle: style,
      lineHeight: LineHeight.number(1.5),
      margin: Margins.zero,
      padding: HtmlPaddings.zero,
    );
  }

  final center = Style(
    textAlign: TextAlign.center,
    width: Width.auto(),
    display: Display.block,
  );

  final cellBorder = Border.all(
    color: tokens.colorSecondary.withValues(alpha: 0.28),
  );

  return {
    'body': text(14),
    'p': Style(
      fontSize: FontSize(14),
      fontFamily: 'MiSans',
      color: baseColor,
      lineHeight: LineHeight.number(1.5),
      margin: Margins.only(bottom: 10),
      padding: HtmlPaddings.zero,
    ),
    'p[align=center]': center,
    'div[align=center]': center,
    'center': center,
    'br': Style(height: Height(8)),
    'a': Style(
      color: tokens.colorBrand,
      textDecoration: TextDecoration.underline,
      textDecorationColor: tokens.colorBrand.withValues(alpha: 0.5),
    ),
    'h1': text(22, weight: FontWeight.w800, color: contrast).copyWith(
      margin: Margins.only(top: 12, bottom: 8),
    ),
    'h2': text(18, weight: FontWeight.w800, color: contrast).copyWith(
      margin: Margins.only(top: 10, bottom: 6),
    ),
    'h3': text(16, weight: FontWeight.w700, color: contrast).copyWith(
      margin: Margins.only(top: 8, bottom: 4),
    ),
    'h4': text(15, weight: FontWeight.w700, color: contrast),
    'h5': text(14, weight: FontWeight.w700, color: contrast),
    'h6': text(13, weight: FontWeight.w700, color: contrast),
    'strong': text(14, weight: FontWeight.w800, color: contrast),
    'b': text(14, weight: FontWeight.w800, color: contrast),
    'em': text(14, style: FontStyle.italic),
    'i': text(14, style: FontStyle.italic),
    'del': text(14, color: tokens.colorBase.withValues(alpha: 0.55)).copyWith(
      textDecoration: TextDecoration.lineThrough,
    ),
    'blockquote': Style(
      fontSize: FontSize(14),
      color: tokens.colorBase.withValues(alpha: 0.75),
      backgroundColor: tokens.colorSuperRaisedBg,
      padding: HtmlPaddings.symmetric(horizontal: 12, vertical: 8),
      margin: Margins.only(bottom: 10),
      border: Border(
        left: BorderSide(color: tokens.colorBrand, width: 3),
      ),
    ),
    'code': Style(
      fontSize: FontSize(13),
      fontFamily: 'Consolas',
      color: tokens.colorBrand,
      backgroundColor: tokens.colorSuperRaisedBg,
      padding: HtmlPaddings.symmetric(horizontal: 4, vertical: 1),
    ),
    'pre': Style(
      backgroundColor: tokens.colorSuperRaisedBg,
      padding: HtmlPaddings.all(12),
      margin: Margins.only(bottom: 12),
      border: Border.all(
        color: tokens.colorSecondary.withValues(alpha: 0.2),
      ),
    ),
    'pre code': Style(
      backgroundColor: Colors.transparent,
      padding: HtmlPaddings.zero,
    ),
    'ul': Style(
      margin: Margins.only(bottom: 10, left: 8),
      padding: HtmlPaddings.only(left: 16),
    ),
    'ol': Style(
      margin: Margins.only(bottom: 10, left: 8),
      padding: HtmlPaddings.only(left: 16),
    ),
    'li': Style(
      fontSize: FontSize(14),
      color: baseColor,
      lineHeight: LineHeight.number(1.5),
      margin: Margins.only(bottom: 4),
    ),
    'hr': Style(
      margin: Margins.symmetric(vertical: 12),
      border: Border(
        top: BorderSide(
          color: tokens.colorSecondary.withValues(alpha: 0.35),
        ),
      ),
    ),
    'table': Style(
      backgroundColor: tokens.colorRaisedBg,
      margin: Margins.only(bottom: 14, top: 4),
      width: Width.auto(),
    ),
    'th': Style(
      fontSize: FontSize(13),
      fontWeight: FontWeight.w700,
      color: contrast,
      backgroundColor: tokens.colorSuperRaisedBg,
      padding: HtmlPaddings.symmetric(horizontal: 10, vertical: 8),
      border: cellBorder,
    ),
    'td': Style(
      fontSize: FontSize(13),
      color: baseColor,
      padding: HtmlPaddings.symmetric(horizontal: 10, vertical: 8),
      border: cellBorder,
    ),
  };
}
