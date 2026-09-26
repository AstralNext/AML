import 'dart:io';

import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/format.dart';
import 'package:aml/src/shared/utils/reveal_in_explorer.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class _FsEntry {
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? modified;
  final String absolutePath;

  const _FsEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
    required this.absolutePath,
  });
}

/// 实例详情页「文件」标签页：实例目录文件浏览。
class InstanceFilesTab extends StatefulWidget {
  const InstanceFilesTab({super.key, required this.instanceId});

  final String instanceId;

  @override
  State<InstanceFilesTab> createState() => _InstanceFilesTabState();
}

class _InstanceFilesTabState extends State<InstanceFilesTab> {
  String? _instanceRoot;
  String _filesRel = '';
  List<_FsEntry> _fileEntries = [];
  bool _filesLoading = false;

  @override
  void initState() {
    super.initState();
    _refreshFiles();
  }

  Future<void> _refreshFiles({String? rel}) async {
    final nextRel = rel ?? _filesRel;
    setState(() => _filesLoading = true);
    try {
      final root = _instanceRoot ??
          await rust.openInstanceFolder(instanceId: widget.instanceId);
      final dir = Directory(nextRel.isEmpty ? root : p.join(root, nextRel));
      if (!await dir.exists()) {
        if (!mounted) return;
        setState(() {
          _instanceRoot = root;
          _filesRel = nextRel;
          _fileEntries = [];
          _filesLoading = false;
        });
        return;
      }
      final entries = <_FsEntry>[];
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name == '.' || name == '..') continue;
        final isDir = entity is Directory;
        int size = 0;
        DateTime? modified;
        try {
          final stat = await entity.stat();
          size = isDir ? 0 : stat.size;
          modified = stat.modified;
        } catch (_) {}
        entries.add(
          _FsEntry(
            name: name,
            isDirectory: isDir,
            size: size,
            modified: modified,
            absolutePath: entity.path,
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _instanceRoot = root;
        _filesRel = nextRel;
        _fileEntries = entries;
        _filesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _filesLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final crumbs = _filesRel.isEmpty
        ? <String>[]
        : _filesRel
            .split(RegExp(r'[\\/]+'))
            .where((s) => s.isNotEmpty)
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '文件',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: tokens.colorContrast,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () async {
                final root = _instanceRoot ??
                    await rust.openInstanceFolder(
                        instanceId: widget.instanceId);
                if (!context.mounted) return;
                final path = _filesRel.isEmpty ? root : p.join(root, _filesRel);
                await revealInExplorer(context, path);
              },
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('在资源管理器中打开'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
            TextButton.icon(
              onPressed: () => _refreshFiles(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              TextButton(
                onPressed:
                    _filesRel.isEmpty ? null : () => _refreshFiles(rel: ''),
                child: const Text('实例根目录'),
              ),
              for (var i = 0; i < crumbs.length; i++) ...[
                Icon(Icons.chevron_right, size: 16, color: tokens.colorBase),
                TextButton(
                  onPressed: () {
                    final rel = crumbs.sublist(0, i + 1).join('/');
                    _refreshFiles(rel: rel);
                  },
                  child: Text(crumbs[i]),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _filesLoading
              ? const Center(child: CircularProgressIndicator())
              : _fileEntries.isEmpty
                  ? Center(
                      child: Text(
                        '此文件夹为空',
                        style: TextStyle(color: tokens.colorBase),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _fileEntries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final e = _fileEntries[index];
                        return Material(
                          color: tokens.colorRaisedBg,
                          borderRadius: BorderRadius.circular(10),
                          child: ListTile(
                            leading: Icon(
                              e.isDirectory
                                  ? Icons.folder
                                  : Icons.insert_drive_file_outlined,
                              color: e.isDirectory
                                  ? tokens.colorBrand
                                  : tokens.colorContrast,
                            ),
                            title: Text(
                              e.name,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: tokens.colorContrast,
                              ),
                            ),
                            subtitle: Text(
                              e.isDirectory ? '文件夹' : formatBytes(e.size),
                              style: TextStyle(
                                color: tokens.colorBase.withValues(alpha: 0.65),
                              ),
                            ),
                            onTap: () {
                              if (e.isDirectory) {
                                final next = _filesRel.isEmpty
                                    ? e.name
                                    : '$_filesRel/${e.name}';
                                _refreshFiles(rel: next);
                              } else {
                                revealInExplorer(context, e.absolutePath);
                              }
                            },
                            trailing: IconButton(
                              tooltip: '打开位置',
                              icon: const Icon(Icons.open_in_new, size: 18),
                              onPressed: () =>
                                  revealInExplorer(context, e.absolutePath),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
