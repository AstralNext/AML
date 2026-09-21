import 'dart:convert';
import 'dart:typed_data';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/wardrobe/application/mineskin_api.dart';
import 'package:aml/src/features/wardrobe/application/skin_store.dart';
import 'package:aml/src/features/wardrobe/ui/public_skin_widgets.dart';
import 'package:aml/src/features/wardrobe/ui/skin_editor_panes.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// 弹出指定账号的皮肤编辑对话框（已保存皮肤 + MineSkin 公开皮肤）。
Future<void> showSkinEditorDialog(
  BuildContext context, {
  required rust.AccountDto account,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final tokens = dialogContext.tokens;
      return Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 940,
          height: 650,
          decoration: BoxDecoration(
            color: tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: tokens.colorSecondary.withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 10, 6),
                child: Row(
                  children: [
                    Icon(Icons.checkroom, color: tokens.colorBrand),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '修改皮肤 · ${account.username}',
                        style: TextStyle(
                          color: tokens.colorContrast,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: tokens.colorSecondary.withValues(alpha: 0.22),
              ),
              Expanded(
                child: _SkinEditorContent(
                  account: account,
                  onClose: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SkinEditorContent extends StatefulWidget {
  const _SkinEditorContent({
    required this.account,
    required this.onClose,
  });

  final rust.AccountDto account;
  final VoidCallback onClose;

  @override
  State<_SkinEditorContent> createState() => _SkinEditorContentState();
}

class _SkinEditorContentState extends State<_SkinEditorContent> {
  final Set<String> _openSections = {'saved', 'mineskin'};
  final _mineSearch = TextEditingController();
  final List<MineSkinItem> _mineItems = [];
  String? _mineAfter;
  bool _mineLoading = false;
  String? _mineError;
  rust.SkinDto? _previewSkin;
  rust.SkinDto? _originalSkin;

  SkinStore get _skins => getIt<SkinStore>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final eq = _skins.equipped;
      if (eq != null) {
        setState(() {
          _originalSkin = eq;
          _previewSkin = eq;
        });
      }
      _skins.ensureLoaded().then((_) {
        if (!mounted) return;
        final next = _skins.equipped;
        setState(() {
          _originalSkin = next;
          _previewSkin ??= next;
          if (_previewSkin != null &&
              !_skins.skins.value
                  .any((s) => s.textureKey == _previewSkin!.textureKey) &&
              _previewSkin!.source != 'mineskin') {
            _previewSkin = next;
          }
        });
      });
      _loadMineSkins(reset: true);
    });
  }

  @override
  void dispose() {
    _mineSearch.dispose();
    super.dispose();
  }

  Future<void> _loadMineSkins({required bool reset}) async {
    if (_mineLoading) return;
    setState(() {
      _mineLoading = true;
      _mineError = null;
    });
    try {
      final page = await MineSkinApi.list(
        search: _mineSearch.text,
        after: reset ? null : _mineAfter,
        size: 18,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _mineItems.clear();
        _mineItems.addAll(page.items);
        _mineAfter = page.nextAfter;
      });
    } catch (error) {
      if (mounted) setState(() => _mineError = '$error');
    } finally {
      if (mounted) setState(() => _mineLoading = false);
    }
  }

  bool get _hasPending {
    final p = _previewSkin;
    final o = _originalSkin;
    if (p == null || o == null) return false;
    return p.textureKey != o.textureKey || p.variant != o.variant;
  }

  void _select(rust.SkinDto skin) {
    setState(() => _previewSkin = skin);
  }

  Future<void> _selectMineSkin(MineSkinItem item) async {
    final png = await MineSkinApi.pngFor(item);
    if (png == null || !mounted) return;
    final variant =
        item.variant ?? await rust.detectSkinVariant(pngBytes: png);
    if (!mounted) return;
    setState(() {
      _previewSkin = rust.SkinDto(
        textureKey: item.texture,
        name: item.displayName,
        section: 'MineSkin',
        variant: variant,
        capeId: null,
        textureDataUrl: 'data:image/png;base64,${base64Encode(png)}',
        source: 'mineskin',
        isEquipped: false,
      );
    });
  }

  Future<void> _apply() async {
    final skin = _previewSkin;
    if (skin == null) return;
    try {
      await _skins.apply(skin);
      if (!mounted) return;
      setState(() {
        _originalSkin = _skins.equipped;
        _previewSkin = _originalSkin;
      });
      showAppSnackBar('皮肤已应用');
      widget.onClose();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('应用失败: $e', isError: true);
    }
  }

  void _reset() {
    setState(() => _previewSkin = _originalSkin);
    widget.onClose();
  }

  Future<void> _addSkin() async {
    try {
      final saved = await _skins.pickAndAddSkin();
      if (saved != null && mounted) {
        _select(saved);
        showAppSnackBar('已添加 ${saved.name ?? '皮肤'}');
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('$e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final loading = _skins.loading.value;
      final preview = _previewSkin ?? _skins.equipped;
      final applying = _skins.applying.value;
      final Uint8List? previewPng =
          preview == null ? null : _skins.pngBytesFor(preview);

      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: loading && _skins.skins.value.isEmpty && _mineItems.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  final previewPane = SkinEditorPreviewPane(
                    username: widget.account.username,
                    skin: preview,
                    skinPng: previewPng,
                    hasPending: _hasPending,
                    applying: applying,
                    onApply: _apply,
                    onReset: _reset,
                  );
                  final listPane = SkinEditorSectionList(
                    saved: _skins.savedSkins,
                    mineItems: _mineItems,
                    mineLoading: _mineLoading,
                    mineError: _mineError,
                    mineHasMore: _mineAfter != null,
                    mineSearch: _mineSearch,
                    openSections: _openSections,
                    previewKey: preview?.textureKey,
                    equippedKey:
                        _originalSkin?.textureKey ?? _skins.equipped?.textureKey,
                    pngFor: _skins.pngBytesFor,
                    minePngFor: MineSkinApi.pngFor,
                    onToggle: (key) {
                      setState(() {
                        if (_openSections.contains(key)) {
                          _openSections.remove(key);
                        } else {
                          _openSections.add(key);
                        }
                      });
                    },
                    onSelect: _select,
                    onSelectMine: _selectMineSkin,
                    onMineSearch: () => _loadMineSkins(reset: true),
                    onMineMore: () => _loadMineSkins(reset: false),
                    onAdd: _addSkin,
                    onDelete: (skin) async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('删除皮肤'),
                          content: Text(
                            "确定删除皮肤「${(skin.name != null && skin.name!.isNotEmpty) ? skin.name! : '未命名皮肤'}」？",
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              style: AppDialogActions.destructive(ctx),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (ok != true) return;
                      await _skins.remove(skin);
                      if (!mounted) return;
                      setState(() {});
                    },
                  );

                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 10, child: previewPane),
                        const SizedBox(width: 24),
                        Expanded(flex: 25, child: listPane),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      SizedBox(
                        height: constraints.maxHeight * 0.42,
                        child: previewPane,
                      ),
                      const SizedBox(height: 12),
                      Expanded(child: listPane),
                    ],
                  );
                },
              ),
      );
    });
  }
}
