import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/log_line.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// 实例详情页「日志」标签页：实时日志 / 启动器日志文件查看。
class InstanceLogsTab extends StatefulWidget {
  const InstanceLogsTab({super.key, required this.instanceId});

  final String instanceId;

  @override
  State<InstanceLogsTab> createState() => _InstanceLogsTabState();
}

class _InstanceLogsTabState extends State<InstanceLogsTab> {
  static const _logLineExtent = 17.0;

  final ScrollController _logScroll = ScrollController();
  String _fileLog = '';
  VoidCallback? _disposeRunningEffect;
  VoidCallback? _disposeLogEffect;
  int _lastLiveLogCount = 0;
  String? _lastLiveLogTail;

  String _logFilter = 'all'; // all | error | warn | info | debug | trace
  String _logQuery = '';
  Timer? _logSearchDebounce;
  final IncrementalLogParser _liveLogParser = IncrementalLogParser();
  List<ParsedLogLine> _parsedLogs = [];
  int _parsedRawLogCount = 0;
  String? _parsedLastRawLine;
  bool _parsedFromLiveLogs = false;
  String _parsedFileLogKey = '';
  Set<LogLevel> _presentLogLevels = {};
  String _filteredLogsKey = '';
  List<ParsedLogLine> _filteredLogs = const [];
  bool _logFollowTail = true;

  InstanceStore get _store => getIt<InstanceStore>();

  @override
  void initState() {
    super.initState();
    _store.ensureLiveLogsLoaded(widget.instanceId);
    _refreshFileLog();
    final initialLogs = _store.liveLogsFor(widget.instanceId);
    _lastLiveLogCount = initialLogs.length;
    _lastLiveLogTail = initialLogs.isEmpty ? null : initialLogs.last;
    _logScroll.addListener(() {
      if (!_logScroll.hasClients) return;
      final follow = _logScroll.position.extentAfter < 48;
      if (follow != _logFollowTail && mounted) {
        setState(() => _logFollowTail = follow);
      }
    });

    var wasRunning = _store.isRunning(widget.instanceId);
    _disposeRunningEffect = effect(() {
      final running = _store.isRunning(widget.instanceId);
      if (wasRunning && !running) {
        _refreshFileLog();
      }
      wasRunning = running;
    });

    _disposeLogEffect = effect(() {
      final logs = _store.liveLogsFor(widget.instanceId);
      final count = logs.length;
      final tail = logs.isEmpty ? null : logs.last;
      final hasNewOutput =
          count > _lastLiveLogCount || tail != _lastLiveLogTail;
      if (hasNewOutput && _logFollowTail) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_logScroll.hasClients) return;
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        });
      }
      _lastLiveLogCount = count;
      _lastLiveLogTail = tail;
    });
  }

  @override
  void dispose() {
    _disposeRunningEffect?.call();
    _disposeLogEffect?.call();
    _logSearchDebounce?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _refreshFileLog() async {
    try {
      final file = await _store.readLauncherLogFile(widget.instanceId);
      if (!mounted) return;
      setState(() => _fileLog = file);
    } catch (e) {
      if (mounted) showAppSnackBar('$e', isError: true);
    }
  }

  Future<void> _refreshLogs({bool silent = false}) async {
    try {
      await _store.refreshLiveLogs(widget.instanceId);
      await _refreshFileLog();
    } catch (e) {
      if (!silent && mounted) {
        showAppSnackBar('$e', isError: true);
      }
    }
  }

  List<ParsedLogLine> _logsForDisplay(List<String> liveLogs) {
    final usingLiveLogs = liveLogs.isNotEmpty;
    final raw = usingLiveLogs
        ? liveLogs
        : (_fileLog.isEmpty
            ? const <String>['暂无日志。启动游戏后会显示在这里。']
            : _fileLog.split('\n'));
    var parseChanged = false;

    if (usingLiveLogs) {
      final canAppend = _parsedFromLiveLogs &&
          _parsedRawLogCount <= raw.length &&
          (_parsedRawLogCount == 0 ||
              (_parsedRawLogCount - 1 < raw.length &&
                  raw[_parsedRawLogCount - 1] == _parsedLastRawLine));
      if (canAppend) {
        if (raw.length > _parsedRawLogCount) {
          final appended = raw.sublist(_parsedRawLogCount);
          _liveLogParser.appendAll(appended, _parsedLogs);
          for (final text in appended) {
            final level = detectLogLevel(text);
            if (level != null) _presentLogLevels.add(level);
          }
          parseChanged = true;
        }
      } else {
        _liveLogParser.reset();
        _parsedLogs = [];
        _liveLogParser.appendAll(raw, _parsedLogs);
        _presentLogLevels = {
          for (final line in _parsedLogs)
            if (line.level != null) line.level!,
        };
        parseChanged = true;
      }
      _parsedFromLiveLogs = true;
      _parsedRawLogCount = raw.length;
      _parsedLastRawLine = raw.isEmpty ? null : raw.last;
    } else {
      final fileKey = '${_fileLog.length}:${_fileLog.hashCode}';
      if (_parsedFromLiveLogs || fileKey != _parsedFileLogKey) {
        _parsedFromLiveLogs = false;
        _parsedFileLogKey = fileKey;
        _parsedRawLogCount = raw.length;
        _parsedLastRawLine = raw.isEmpty ? null : raw.last;
        _parsedLogs = parseLogLines(raw);
        _presentLogLevels = {
          for (final line in _parsedLogs)
            if (line.level != null) line.level!,
        };
        parseChanged = true;
      }
    }

    if (parseChanged) _filteredLogsKey = '';
    final query = _logQuery.trim().toLowerCase();
    if (_logFilter == 'all' && query.isEmpty) {
      _filteredLogs = _parsedLogs;
      _filteredLogsKey = 'unfiltered:${_parsedLogs.length}';
      return _filteredLogs;
    }

    final sourceKey =
        '${_parsedLogs.length}:${_parsedLogs.isEmpty ? 0 : _parsedLogs.last.hashCode}';
    final filterKey = '$sourceKey|$_logFilter|$query';
    if (filterKey != _filteredLogsKey) {
      _filteredLogsKey = filterKey;
      _filteredLogs = _parsedLogs.where((line) {
        if (query.isNotEmpty && !line.text.toLowerCase().contains(query)) {
          return false;
        }
        if (_logFilter == 'all') return true;
        final level = line.level ?? LogLevel.info;
        return level.name == _logFilter;
      }).toList(growable: false);
    }
    return _filteredLogs;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Watch((context) {
      final liveLogs = _store.liveLogs.value[widget.instanceId] ?? const [];
      final filtered = _logsForDisplay(liveLogs);
      final present = _presentLogLevels;

      Color colorFor(LogLevel? level) {
        switch (level) {
          case LogLevel.error:
            return const Color(0xFFFF6B6B);
          case LogLevel.warn:
            return const Color(0xFFFFD166);
          case LogLevel.debug:
          case LogLevel.trace:
            return const Color(0xFF8B949E);
          case LogLevel.info:
          case null:
            return const Color(0xFFD7E0E8);
        }
      }

      Widget logChip(String id, String label) {
        final selected = _logFilter == id;
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: FilterChip(
            label: Text(label),
            selected: selected,
            onSelected: (_) => setState(() => _logFilter = id),
            selectedColor: tokens.colorBrand.withValues(alpha: 0.28),
            checkmarkColor: tokens.colorBrand,
            labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? tokens.colorContrast : tokens.colorBase,
            ),
            backgroundColor: tokens.colorRaisedBg,
            side: BorderSide(
              color: selected
                  ? tokens.colorBrand.withValues(alpha: 0.55)
                  : tokens.colorSecondary.withValues(alpha: 0.35),
            ),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                liveLogs.isNotEmpty ? '实时日志' : '启动器日志文件',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: tokens.colorContrast,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text: filtered.map((e) => e.displayText).join('\n'),
                    ),
                  );
                  if (!mounted) return;
                  showAppSnackBar('已复制日志');
                },
                style:
                    TextButton.styleFrom(foregroundColor: tokens.colorContrast),
                child: const Text('复制'),
              ),
              IconButton(
                tooltip: _logFollowTail ? '停止自动滚动' : '跟随最新日志',
                onPressed: () {
                  setState(() => _logFollowTail = !_logFollowTail);
                  if (_logFollowTail && _logScroll.hasClients) {
                    _logScroll.animateTo(
                      _logScroll.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                    );
                  }
                },
                icon: Icon(
                  _logFollowTail
                      ? Icons.vertical_align_bottom
                      : Icons.vertical_align_center,
                  color: _logFollowTail
                      ? tokens.colorBrand
                      : tokens.colorBase.withValues(alpha: 0.65),
                ),
              ),
              TextButton(
                onPressed: () => _refreshLogs(),
                style:
                    TextButton.styleFrom(foregroundColor: tokens.colorContrast),
                child: const Text('刷新'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (value) {
                    _logSearchDebounce?.cancel();
                    _logSearchDebounce = Timer(
                      const Duration(milliseconds: 200),
                      () {
                        if (mounted) setState(() => _logQuery = value);
                      },
                    );
                  },
                  style: TextStyle(color: tokens.colorContrast, fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索日志…',
                    hintStyle: TextStyle(
                      color: tokens.colorBase.withValues(alpha: 0.55),
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                    filled: true,
                    fillColor: tokens.colorRaisedBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                logChip('all', 'All'),
                logChip('error', 'Error'),
                logChip('warn', 'Warn'),
                logChip('info', 'Info'),
                if (present.contains(LogLevel.debug) || _logFilter == 'debug')
                  logChip('debug', 'Debug'),
                if (present.contains(LogLevel.trace) || _logFilter == 'trace')
                  logChip('trace', 'Trace'),
                const SizedBox(width: 8),
                Text(
                  '${filtered.length} / ${_parsedLogs.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.colorBase.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: tokens.colorSecondary.withValues(alpha: 0.25),
                ),
              ),
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的日志行',
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.6),
                        ),
                      ),
                    )
                  : SelectionArea(
                      child: ListView.builder(
                        controller: _logScroll,
                        itemCount: filtered.length,
                        // Fixed extent = true virtualization (skip layout measure).
                        itemExtent: _logLineExtent,
                        scrollCacheExtent: const ScrollCacheExtent.pixels(400),
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: true,
                        itemBuilder: (context, index) {
                          final line = filtered[index];
                          final bg = switch (line.level) {
                            LogLevel.error => const Color(0x22FF6B6B),
                            LogLevel.warn => const Color(0x22FFD166),
                            _ => null,
                          };
                          return ColoredBox(
                            color: bg ?? Colors.transparent,
                            child: Text(
                              line.text.isEmpty ? ' ' : line.displayText,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.fade,
                              style: TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 12,
                                height: _logLineExtent / 12,
                                color: colorFor(line.level),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      );
    });
  }
}
