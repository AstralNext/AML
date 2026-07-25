import 'dart:convert';

import 'package:flutter/material.dart';

/// Parses Minecraft MOTD (legacy `§` codes and JSON chat components) into
/// [InlineSpan] trees — same role as `@sfirew/minecraft-motd-parser` `autoToHTML`.
///
/// Wire format from Rust is always a JSON text fragment (`RawValue`):
/// - `"plain §aMOTD"` (JSON string)
/// - `{"text":"…","extra":[…]}` (chat component)
/// - `[…]` (component array)
class MinecraftMotd {
  MinecraftMotd._();

  static const defaultText = 'A Minecraft Server';

  static const _namedColors = <String, Color>{
    'black': Color(0xFF000000),
    'dark_blue': Color(0xFF0000AA),
    'dark_green': Color(0xFF00AA00),
    'dark_aqua': Color(0xFF00AAAA),
    'dark_red': Color(0xFFAA0000),
    'dark_purple': Color(0xFFAA00AA),
    'gold': Color(0xFFFFAA00),
    'gray': Color(0xFFAAAAAA),
    'dark_gray': Color(0xFF555555),
    'blue': Color(0xFF5555FF),
    'green': Color(0xFF55FF55),
    'aqua': Color(0xFF55FFFF),
    'red': Color(0xFFFF5555),
    'light_purple': Color(0xFFFF55FF),
    'yellow': Color(0xFFFFFF55),
    'white': Color(0xFFFFFFFF),
  };

  static const _legacyColors = <String, Color>{
    '0': Color(0xFF000000),
    '1': Color(0xFF0000AA),
    '2': Color(0xFF00AA00),
    '3': Color(0xFF00AAAA),
    '4': Color(0xFFAA0000),
    '5': Color(0xFFAA00AA),
    '6': Color(0xFFFFAA00),
    '7': Color(0xFFAAAAAA),
    '8': Color(0xFF555555),
    '9': Color(0xFF5555FF),
    'a': Color(0xFF55FF55),
    'b': Color(0xFF55FFFF),
    'c': Color(0xFFFF5555),
    'd': Color(0xFFFF55FF),
    'e': Color(0xFFFFFF55),
    'f': Color(0xFFFFFFFF),
  };

  /// [raw] is either a JSON fragment (from server status) or plain/§ text.
  static InlineSpan toSpan(
    String? raw, {
    Color fallbackColor = const Color(0xFFAAAAAA),
    double fontSize = 12,
  }) {
    final base = TextStyle(color: fallbackColor, fontSize: fontSize, height: 1.25);
    final children = _autoSpans(raw, base);
    if (!_spansHaveText(children)) {
      return TextSpan(text: defaultText, style: base);
    }
    return TextSpan(children: children, style: base);
  }

  /// Like `autoToHTML`: detect JSON vs legacy § text (including nested JSON strings).
  static List<InlineSpan> _autoSpans(String? raw, TextStyle base) {
    if (raw == null) return const [];
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];

    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      decoded = null;
    }

    // Re-parse when servers wrap a chat component inside a JSON string.
    if (decoded is String) {
      final inner = decoded.trim();
      if (inner.startsWith('{') || inner.startsWith('[')) {
        try {
          decoded = jsonDecode(inner);
        } catch (_) {
          // keep string — treat as legacy below
        }
      }
    }

    if (decoded is String) {
      return _legacySpans(decoded, base);
    }
    if (decoded is Map) {
      return _chatSpans(decoded, const _ChatStyle(), base);
    }
    if (decoded is List) {
      final children = <InlineSpan>[];
      for (final item in decoded) {
        if (item is Map) {
          children.addAll(_chatSpans(item, const _ChatStyle(), base));
        } else if (item is String) {
          children.addAll(_legacySpans(item, base));
        } else if (item is num) {
          children.addAll(_legacySpans('$item', base));
        }
      }
      return children;
    }

    // Not JSON — legacy § string (strip wrapping quotes if any).
    var text = trimmed;
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        text = jsonDecode(text) as String;
      } catch (_) {}
    }
    return _legacySpans(text, base);
  }

  static bool _spansHaveText(List<InlineSpan> spans) {
    for (final span in spans) {
      if (span is TextSpan) {
        final t = span.text;
        if (t != null && t.trim().isNotEmpty) return true;
        final kids = span.children;
        if (kids != null && _spansHaveText(kids)) return true;
      }
    }
    return false;
  }

  static List<InlineSpan> _legacySpans(String input, TextStyle base) {
    final out = <InlineSpan>[];
    var color = base.color ?? const Color(0xFFAAAAAA);
    var bold = false;
    var italic = false;
    var underline = false;
    var strike = false;
    final buf = StringBuffer();

    void flush() {
      if (buf.isEmpty) return;
      out.add(TextSpan(
        text: buf.toString(),
        style: base.copyWith(
          color: color,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          decoration: TextDecoration.combine([
            if (underline) TextDecoration.underline,
            if (strike) TextDecoration.lineThrough,
          ]),
        ),
      ));
      buf.clear();
    }

    // Normalize newlines the way the HTML MOTD parser maps `\n` → `<br/>`.
    final chars = input.replaceAll('\r\n', '\n').split('');
    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      if ((c == '§' || c == '&') && i + 1 < chars.length) {
        flush();
        final code = chars[++i].toLowerCase();
        if (_legacyColors.containsKey(code)) {
          color = _legacyColors[code]!;
          // Color codes reset formatting (vanilla 1.16+).
          bold = italic = underline = strike = false;
        } else if (code == 'l') {
          bold = true;
        } else if (code == 'o') {
          italic = true;
        } else if (code == 'n') {
          underline = true;
        } else if (code == 'm') {
          strike = true;
        } else if (code == 'r') {
          color = base.color ?? const Color(0xFFAAAAAA);
          bold = italic = underline = strike = false;
        }
        // §k obfuscated — ignore (show following text normally)
        continue;
      }
      buf.write(c);
    }
    flush();
    return out;
  }

  static List<InlineSpan> _chatSpans(
    Map raw,
    _ChatStyle parent,
    TextStyle base,
  ) {
    final style = parent.merge(raw);
    final out = <InlineSpan>[];

    final text = _componentText(raw);
    if (text.isNotEmpty) {
      final styledBase = base.copyWith(
        color: style.color ?? base.color,
        fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
        decoration: TextDecoration.combine([
          if (style.underlined) TextDecoration.underline,
          if (style.strikethrough) TextDecoration.lineThrough,
        ]),
      );
      // Nested § inside JSON text is common (same as textToHTML inside JSONToHTML).
      if (text.contains('§') || text.contains('&')) {
        out.addAll(_legacySpans(text, styledBase));
      } else {
        out.add(TextSpan(
          text: text.replaceAll('\r\n', '\n'),
          style: styledBase,
        ));
      }
    }

    final extra = raw['extra'];
    if (extra is List) {
      for (final child in extra) {
        if (child is Map) {
          out.addAll(_chatSpans(child, style, base));
        } else if (child is String) {
          out.addAll(_legacySpans(
            child,
            base.copyWith(color: style.color ?? base.color),
          ));
        } else if (child is num) {
          out.addAll(_legacySpans(
            '$child',
            base.copyWith(color: style.color ?? base.color),
          ));
        }
      }
    }
    return out;
  }

  static String _componentText(Map raw) {
    final text = raw['text'];
    if (text is String) return text;
    if (text is num) return '$text';
    final translate = raw['translate'];
    if (translate is String) return translate;
    return '';
  }

  static Color? resolveColor(dynamic value) {
    if (value is! String) return null;
    final v = value.toLowerCase();
    if (_namedColors.containsKey(v)) return _namedColors[v];
    // Also accept legacy single-letter codes used by some servers.
    if (v.length == 1 && _legacyColors.containsKey(v)) {
      return _legacyColors[v];
    }
    if (v.startsWith('#') && (v.length == 7 || v.length == 9)) {
      final hex = v.substring(1);
      final n = int.tryParse(hex, radix: 16);
      if (n == null) return null;
      if (hex.length == 6) return Color(0xFF000000 | n);
      return Color(n);
    }
    return null;
  }

  static bool? _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is String) {
      final v = value.toLowerCase();
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return null;
  }
}

class _ChatStyle {
  const _ChatStyle({
    this.color,
    this.bold = false,
    this.italic = false,
    this.underlined = false,
    this.strikethrough = false,
  });

  final Color? color;
  final bool bold;
  final bool italic;
  final bool underlined;
  final bool strikethrough;

  _ChatStyle merge(Map raw) {
    return _ChatStyle(
      color: MinecraftMotd.resolveColor(raw['color']) ?? color,
      bold: MinecraftMotd._asBool(raw['bold']) ?? bold,
      italic: MinecraftMotd._asBool(raw['italic']) ?? italic,
      underlined: MinecraftMotd._asBool(raw['underlined']) ?? underlined,
      strikethrough:
          MinecraftMotd._asBool(raw['strikethrough']) ?? strikethrough,
    );
  }
}
