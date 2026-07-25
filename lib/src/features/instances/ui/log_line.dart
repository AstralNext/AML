/// Minecraft / launcher log level heuristics.
enum LogLevel {
  error,
  warn,
  info,
  debug,
  trace,
}

class ParsedLogLine {
  const ParsedLogLine({
    required this.text,
    required this.level,
    this.repeatCount = 1,
  });

  final String text;
  final LogLevel? level;
  final int repeatCount;

  String get displayText =>
      repeatCount > 1 ? '$text  (重复 $repeatCount 次，已压缩)' : text;
}

final _entryStartRe = RegExp(r'^\[\d{2}:\d{2}:\d{2}\]');

const _errorTriggers = [
  '/ERROR',
  '/FATAL',
  'Exception:',
  ':?]',
  'Error',
  '[thread',
  '\tat',
  '[ERR]',
  'FATAL',
];

LogLevel? detectLogLevel(String lineText) {
  if (lineText.contains('/INFO') || lineText.contains('[System] [CHAT]')) {
    return LogLevel.info;
  }
  if (lineText.contains('/WARN') || lineText.contains('[WARN]')) {
    return LogLevel.warn;
  }
  if (lineText.contains('/DEBUG') || lineText.contains('[DEBUG]')) {
    return LogLevel.debug;
  }
  if (lineText.contains('/TRACE') || lineText.contains('[TRACE]')) {
    return LogLevel.trace;
  }
  for (final trigger in _errorTriggers) {
    if (lineText.contains(trigger)) return LogLevel.error;
  }
  return null;
}

class IncrementalLogParser {
  static const compactionThreshold = 20;

  LogLevel? _lastLevel;
  String? _repeatText;
  int _repeatCount = 0;

  void reset() {
    _lastLevel = null;
    _repeatText = null;
    _repeatCount = 0;
  }

  void appendAll(Iterable<String> raw, List<ParsedLogLine> out) {
    for (final text in raw) {
      if (text.isEmpty && out.isEmpty) continue;
      final line = _parse(text);
      if (_repeatText == text && out.isNotEmpty) {
        _repeatCount++;
        if (_repeatCount < compactionThreshold) {
          out.add(line);
        } else if (_repeatCount == compactionThreshold) {
          out.removeRange(
            out.length - (compactionThreshold - 1),
            out.length,
          );
          out.add(
            ParsedLogLine(
              text: text,
              level: line.level,
              repeatCount: _repeatCount,
            ),
          );
        } else {
          out[out.length - 1] = ParsedLogLine(
            text: text,
            level: line.level,
            repeatCount: _repeatCount,
          );
        }
      } else {
        _repeatText = text;
        _repeatCount = 1;
        out.add(line);
      }
    }
  }

  ParsedLogLine _parse(String text) {
    final detected = detectLogLevel(text);
    final isEntry = _entryStartRe.hasMatch(text);
    final LogLevel? level;
    if (detected != null) {
      level = detected;
      _lastLevel = detected;
    } else if (!isEntry && _lastLevel != null) {
      level = _lastLevel;
    } else {
      level = null;
      if (isEntry) _lastLevel = null;
    }
    return ParsedLogLine(text: text, level: level);
  }
}

/// Parse raw lines, inheriting levels and compacting repeated log spam.
List<ParsedLogLine> parseLogLines(Iterable<String> raw) {
  final out = <ParsedLogLine>[];
  IncrementalLogParser().appendAll(raw, out);
  return out;
}

String logLevelLabel(LogLevel level) {
  switch (level) {
    case LogLevel.error:
      return 'Error';
    case LogLevel.warn:
      return 'Warn';
    case LogLevel.info:
      return 'Info';
    case LogLevel.debug:
      return 'Debug';
    case LogLevel.trace:
      return 'Trace';
  }
}
