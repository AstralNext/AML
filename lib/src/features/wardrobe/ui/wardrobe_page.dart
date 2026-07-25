import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/wardrobe/application/skin_store.dart';
import 'package:aml/src/features/wardrobe/ui/skin_2d_thumbnail.dart';
import 'package:aml/src/features/wardrobe/ui/skin_3d_viewer.dart';
import 'package:aml/src/features/wardrobe/ui/public_skin_widgets.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:signals_flutter/signals_flutter.dart';

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

class WardrobePage extends StatefulWidget {
  const WardrobePage({super.key});

  @override
  State<WardrobePage> createState() => _WardrobePageState();
}

class _WardrobePageState extends State<WardrobePage> {
  final _searchController = TextEditingController();
  final List<MineSkinItem> _items = [];
  final Map<String, Future<Uint8List?>> _imageFutures = {};
  final Map<String, Future<MineSkinItem>> _detailFutures = {};
  String? _after;
  String? _error;
  String? _selectedMsaAccountId;
  bool _loading = false;
  MineSkinItem? _selected;
  Uint8List? _selectedPng;
  String _selectedVariant = 'classic';

  AccountStore get _accounts => getIt<AccountStore>();
  SkinStore get _skins => getIt<SkinStore>();

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final query = <String, String>{'size': '24'};
      final search = _searchController.text.trim();
      if (search.isNotEmpty) query['search'] = search;
      if (!reset && _after != null) query['after'] = _after!;
      final uri = Uri.https('api.mineskin.org', '/v2/skins', query);
      final response = await http.get(
        uri,
        headers: const {'User-Agent': 'AML/1.0'},
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('MineSkin 返回 HTTP ${response.statusCode}');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final skins = (json['skins'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MineSkinItem.fromJson)
          .toList();
      final pagination = json['pagination'] as Map<String, dynamic>?;
      final next = pagination?['next'] as Map<String, dynamic>?;
      if (!mounted) return;
      setState(() {
        if (reset) {
          _items.clear();
          _selected = null;
          _selectedPng = null;
        }
        _items.addAll(skins);
        _after = next?['after'] as String?;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Uint8List?> _skinPng(MineSkinItem item) {
    return _imageFutures.putIfAbsent(item.texture, () async {
      try {
        final response = await http
            .get(Uri.parse(item.textureUrl))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            response.bodyBytes.length > 4 * 1024 * 1024) {
          return null;
        }
        return response.bodyBytes;
      } catch (_) {
        return null;
      }
    });
  }

  Future<MineSkinItem> _skinDetails(MineSkinItem item) {
    if (item.hasDetails) return Future.value(item);
    return _detailFutures.putIfAbsent(item.uuid, () async {
      try {
        final response = await http.get(
          Uri.https('api.mineskin.org', '/v2/skins/${item.uuid}'),
          headers: const {'User-Agent': 'AML/1.0'},
        ).timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return item;
        }
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final skin = json['skin'];
        if (skin is! Map<String, dynamic>) return item;
        return item.withDetails(skin);
      } catch (_) {
        return item;
      }
    });
  }

  Future<void> _select(MineSkinItem item) async {
    setState(() {
      _selected = item;
      _selectedPng = null;
    });
    final results = await Future.wait<dynamic>([
      _skinPng(item),
      _skinDetails(item),
    ]);
    final png = results[0] as Uint8List?;
    final detailed = results[1] as MineSkinItem;
    if (png == null) return;
    final variant =
        detailed.variant ?? await rust.detectSkinVariant(pngBytes: png);
    if (!mounted || _selected?.uuid != item.uuid) return;
    setState(() {
      _selected = detailed;
      _selectedPng = png;
      _selectedVariant = variant;
      final index = _items.indexWhere((entry) => entry.uuid == detailed.uuid);
      if (index >= 0) _items[index] = detailed;
    });
  }

  Future<void> _downloadSelected() async {
    final item = _selected;
    final png = _selectedPng;
    if (item == null || png == null) return;
    final safeName =
        item.displayName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '下载 MineSkin 皮肤',
      fileName: '${safeName.isEmpty ? item.shortId : safeName}.png',
      type: FileType.image,
    );
    if (path == null) return;
    final output = path.toLowerCase().endsWith('.png') ? path : '$path.png';
    await File(output).writeAsBytes(png, flush: true);
    if (mounted) {
      showAppSnackBar('皮肤已保存到 $output');
    }
  }

  Future<void> _applySelected() async {
    final msaAccounts = _accounts.accounts.value
        .where((account) => account.kind == 'msa')
        .toList();
    final activeMsaAccounts =
        msaAccounts.where((account) => account.active).toList();
    final targetId = _selectedMsaAccountId ??
        (activeMsaAccounts.isNotEmpty
            ? activeMsaAccounts.first.id
            : msaAccounts.isEmpty
                ? null
                : msaAccounts.first.id);
    rust.AccountDto? target;
    for (final account in msaAccounts) {
      if (account.id == targetId) {
        target = account;
        break;
      }
    }
    final item = _selected;
    final png = _selectedPng;
    if (target == null || item == null || png == null) return;
    try {
      if (!target.active) {
        await _accounts.setActive(target.id);
      }
      await _skins.apply(
        rust.SkinDto(
          textureKey: item.texture,
          name: item.displayName,
          section: 'MineSkin',
          variant: _selectedVariant,
          capeId: null,
          textureDataUrl: 'data:image/png;base64,${base64Encode(png)}',
          source: 'mineskin',
          isEquipped: false,
        ),
      );
      if (mounted) {
        showAppSnackBar('皮肤已应用');
      }
    } catch (error) {
      if (mounted) {
        showAppSnackBar('应用失败：$error', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final tokens = context.tokens;
      final msaAccounts = _accounts.accounts.value
          .where((account) => account.kind == 'msa')
          .toList();
      final activeMsaAccounts =
          msaAccounts.where((account) => account.active).toList();
      final fallbackAccountId = activeMsaAccounts.isNotEmpty
          ? activeMsaAccounts.first.id
          : msaAccounts.isEmpty
              ? ''
              : msaAccounts.first.id;
      final selectedMsaAccountId = msaAccounts.any(
        (account) => account.id == _selectedMsaAccountId,
      )
          ? _selectedMsaAccountId!
          : fallbackAccountId;
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '皮肤库',
                        style: TextStyle(
                          color: tokens.colorContrast,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '浏览 MineSkin 公开皮肤，可应用到正版账号',
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 300,
                  child: TextField(
                    controller: _searchController,
                    onSubmitted: (_) => _load(reset: true),
                    decoration: InputDecoration(
                      hintText: '搜索皮肤',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        onPressed: () => _load(reset: true),
                        icon: const Icon(Icons.arrow_forward),
                      ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: _items.isEmpty && _loading
                              ? const Center(child: CircularProgressIndicator())
                              : GridView.builder(
                                  gridDelegate:
                                      const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 180,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 0.78,
                                  ),
                                  itemCount: _items.length,
                                  itemBuilder: (context, index) {
                                    final item = _items[index];
                                    return FutureBuilder<MineSkinItem>(
                                      future: _skinDetails(item),
                                      builder: (context, detailSnapshot) {
                                        final detailed =
                                            detailSnapshot.data ?? item;
                                        return FutureBuilder<Uint8List?>(
                                          future: _skinPng(item),
                                          builder: (context, imageSnapshot) {
                                            return PublicSkinCard(
                                              item: detailed,
                                              png: imageSnapshot.data,
                                              selected:
                                                  _selected?.uuid == item.uuid,
                                              onTap: () => _select(detailed),
                                            );
                                          },
                                        );
                                      },
                                    );
                                  },
                                ),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Center(
                          child: OutlinedButton.icon(
                            onPressed: _loading || _after == null
                                ? null
                                : () => _load(reset: false),
                            style: ButtonStyle(
                              backgroundColor:
                                  WidgetStateProperty.resolveWith((states) {
                                if (states.contains(WidgetState.disabled)) {
                                  return tokens.colorButtonBg
                                      .withValues(alpha: 0.55);
                                }
                                if (states.contains(WidgetState.hovered)) {
                                  return tokens.colorButtonBgSelected;
                                }
                                return tokens.colorButtonBg;
                              }),
                              foregroundColor:
                                  WidgetStateProperty.resolveWith((states) {
                                if (states.contains(WidgetState.disabled)) {
                                  return tokens.colorBase
                                      .withValues(alpha: 0.45);
                                }
                                if (states.contains(WidgetState.hovered)) {
                                  return tokens.colorButtonTextSelected;
                                }
                                return tokens.colorContrast;
                              }),
                              side: const WidgetStatePropertyAll(
                                BorderSide.none,
                              ),
                            ),
                            icon: _loading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.expand_more),
                            label: const Text('加载更多'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 22),
                  SizedBox(
                    width: 290,
                    child: PublicSkinPreview(
                      item: _selected,
                      png: _selectedPng,
                      variant: _selectedVariant,
                      msaAccounts: msaAccounts,
                      selectedMsaAccountId: selectedMsaAccountId,
                      applying: _skins.applying.value,
                      onAccountChanged: (value) {
                        setState(() => _selectedMsaAccountId = value);
                      },
                      onDownload: _downloadSelected,
                      onApply: _applySelected,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
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
  final Map<String, Future<Uint8List?>> _minePngFutures = {};
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
      final query = <String, String>{'size': '18'};
      final search = _mineSearch.text.trim();
      if (search.isNotEmpty) query['search'] = search;
      if (!reset && _mineAfter != null) query['after'] = _mineAfter!;
      final uri = Uri.https('api.mineskin.org', '/v2/skins', query);
      final response = await http.get(
        uri,
        headers: const {'User-Agent': 'AML/1.0'},
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('MineSkin 返回 HTTP ${response.statusCode}');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final skins = (json['skins'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MineSkinItem.fromJson)
          .toList();
      final pagination = json['pagination'] as Map<String, dynamic>?;
      final next = pagination?['next'] as Map<String, dynamic>?;
      if (!mounted) return;
      setState(() {
        if (reset) _mineItems.clear();
        _mineItems.addAll(skins);
        _mineAfter = next?['after'] as String?;
      });
    } catch (error) {
      if (mounted) setState(() => _mineError = '$error');
    } finally {
      if (mounted) setState(() => _mineLoading = false);
    }
  }

  Future<Uint8List?> _minePng(MineSkinItem item) {
    return _minePngFutures.putIfAbsent(item.texture, () async {
      try {
        final response = await http
            .get(Uri.parse(item.textureUrl))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            response.bodyBytes.length > 4 * 1024 * 1024) {
          return null;
        }
        return response.bodyBytes;
      } catch (_) {
        return null;
      }
    });
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
    final png = await _minePng(item);
    if (png == null || !mounted) return;
    final variant = item.variant ?? await rust.detectSkinVariant(pngBytes: png);
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
      final previewPng = preview == null ? null : _skins.pngBytesFor(preview);

      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: loading && _skins.skins.value.isEmpty && _mineItems.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 720;
                  final previewPane = _PreviewPane(
                    username: widget.account.username,
                    skin: preview,
                    skinPng: previewPng,
                    hasPending: _hasPending,
                    applying: applying,
                    onApply: _apply,
                    onReset: _reset,
                  );
                  final listPane = _SectionList(
                    saved: _skins.savedSkins,
                    mineItems: _mineItems,
                    mineLoading: _mineLoading,
                    mineError: _mineError,
                    mineHasMore: _mineAfter != null,
                    mineSearch: _mineSearch,
                    openSections: _openSections,
                    previewKey: preview?.textureKey,
                    equippedKey: _originalSkin?.textureKey ??
                        _skins.equipped?.textureKey,
                    pngFor: _skins.pngBytesFor,
                    minePngFor: _minePng,
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

class _PreviewPane extends StatelessWidget {
  final String username;
  final rust.SkinDto? skin;
  final Uint8List? skinPng;
  final bool hasPending;
  final bool applying;
  final VoidCallback onApply;
  final VoidCallback onReset;

  const _PreviewPane({
    required this.username,
    required this.skin,
    required this.skinPng,
    required this.hasPending,
    required this.applying,
    required this.onApply,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final slim = skin?.variant.toLowerCase() == 'slim';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '皮肤选择器',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: tokens.colorContrast,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Column(
            children: [
              if (hasPending)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.colorBrand.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.visibility_outlined,
                          size: 16,
                          color: tokens.colorBrand,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '预览中',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: tokens.colorBrand,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xE6000000),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  username,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: skinPng != null
                    ? Skin3DViewer(
                        key: ValueKey(skin?.textureKey ?? 'skin'),
                        skinPng: skinPng!,
                        slim: slim,
                      )
                    : Center(
                        child: Icon(
                          Icons.person_outline,
                          size: 96,
                          color: tokens.colorBrand,
                        ),
                      ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.open_with,
                    size: 14,
                    color: tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '拖动旋转',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
              if (hasPending) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: NavRectButton(
                        isSelected: false,
                        icon: Icons.close,
                        text: '取消',
                        defaultBackgroundColor: tokens.colorButtonBg,
                        onTap: applying ? () {} : onReset,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NavRectButton(
                        isSelected: true,
                        icon: applying ? Icons.hourglass_top : Icons.check,
                        text: applying ? '应用中…' : '应用',
                        selectedBackgroundColor: tokens.colorBrand,
                        selectedColor: tokens.colorOnBrand,
                        onTap: applying ? () {} : onApply,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionList extends StatelessWidget {
  final List<rust.SkinDto> saved;
  final List<MineSkinItem> mineItems;
  final bool mineLoading;
  final String? mineError;
  final bool mineHasMore;
  final TextEditingController mineSearch;
  final Set<String> openSections;
  final String? previewKey;
  final String? equippedKey;
  final Uint8List? Function(rust.SkinDto skin) pngFor;
  final Future<Uint8List?> Function(MineSkinItem item) minePngFor;
  final ValueChanged<String> onToggle;
  final ValueChanged<rust.SkinDto> onSelect;
  final ValueChanged<MineSkinItem> onSelectMine;
  final VoidCallback onMineSearch;
  final VoidCallback onMineMore;
  final VoidCallback onAdd;
  final ValueChanged<rust.SkinDto> onDelete;

  const _SectionList({
    required this.saved,
    required this.mineItems,
    required this.mineLoading,
    required this.mineError,
    required this.mineHasMore,
    required this.mineSearch,
    required this.openSections,
    required this.previewKey,
    required this.equippedKey,
    required this.pngFor,
    required this.minePngFor,
    required this.onToggle,
    required this.onSelect,
    required this.onSelectMine,
    required this.onMineSearch,
    required this.onMineMore,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    Widget sectionHeader(String key, String title) {
      return InkWell(
        onTap: () => onToggle(key),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(
                openSections.contains(key)
                    ? Icons.expand_more
                    : Icons.chevron_right,
                color: tokens.colorBase,
              ),
              const SizedBox(width: 4),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: tokens.colorContrast,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      children: [
        sectionHeader('saved', '已保存皮肤'),
        if (openSections.contains('saved'))
          LayoutBuilder(
            builder: (context, constraints) {
              final maxW = constraints.maxWidth;
              final cols = maxW > 980
                  ? 5
                  : maxW > 760
                      ? 4
                      : maxW > 480
                          ? 3
                          : 2;
              const gap = 12.0;
              final cardW = (maxW - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  SizedBox(
                    width: cardW,
                    child: _AddTile(onTap: onAdd),
                  ),
                  for (final skin in saved)
                    SizedBox(
                      width: cardW,
                      child: _SkinTile(
                        skin: skin,
                        pngBytes: pngFor(skin),
                        selected: skin.textureKey == previewKey,
                        equipped: skin.textureKey == equippedKey,
                        onTap: () => onSelect(skin),
                        onDelete: skin.source == 'custom'
                            ? () => onDelete(skin)
                            : null,
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 12),
        sectionHeader('mineskin', 'MineSkin'),
        if (openSections.contains('mineskin')) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: mineSearch,
                  onSubmitted: (_) => onMineSearch(),
                  decoration: InputDecoration(
                    hintText: '搜索 MineSkin',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              NavRectButton(
                isSelected: false,
                icon: Icons.refresh,
                text: '刷新',
                defaultBackgroundColor: tokens.colorButtonBg,
                defaultColor: tokens.colorContrast,
                onTap: onMineSearch,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (mineError != null)
            Text(
              mineError!,
              style: TextStyle(color: tokens.colorBase.withValues(alpha: 0.75)),
            )
          else if (mineLoading && mineItems.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final maxW = constraints.maxWidth;
                final cols = maxW > 980
                    ? 5
                    : maxW > 760
                        ? 4
                        : maxW > 480
                            ? 3
                            : 2;
                const gap = 12.0;
                final cardW = (maxW - gap * (cols - 1)) / cols;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final item in mineItems)
                          SizedBox(
                            width: cardW,
                            child: FutureBuilder<Uint8List?>(
                              future: minePngFor(item),
                              builder: (context, snapshot) {
                                return _MineSkinEditorTile(
                                  item: item,
                                  png: snapshot.data,
                                  selected: item.texture == previewKey,
                                  onTap: () => onSelectMine(item),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                    if (mineHasMore || mineLoading) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.center,
                        child: TextButton(
                          onPressed: mineLoading ? null : onMineMore,
                          child: Text(mineLoading ? '加载中…' : '加载更多'),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
        ],
        const SizedBox(height: 20),
      ],
    );
  }
}

class _MineSkinEditorTile extends StatelessWidget {
  const _MineSkinEditorTile({
    required this.item,
    required this.png,
    required this.selected,
    required this.onTap,
  });

  final MineSkinItem item;
  final Uint8List? png;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final slim = item.variant?.toLowerCase() == 'slim';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: selected
                ? tokens.colorBrand.withValues(alpha: 0.14)
                : tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? tokens.colorBrand
                  : tokens.colorSecondary.withValues(alpha: 0.22),
              width: selected ? 2 : 1,
            ),
          ),
          child: AspectRatio(
            aspectRatio: 31 / 40,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
              child: Column(
                children: [
                  Expanded(
                    child: png != null
                        ? Skin2DThumbnail(skinPng: png!, slim: slim)
                        : Icon(Icons.person, color: tokens.colorBrand),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: tokens.colorContrast,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SkinTile extends StatelessWidget {
  final rust.SkinDto skin;
  final Uint8List? pngBytes;
  final bool selected;
  final bool equipped;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _SkinTile({
    required this.skin,
    required this.pngBytes,
    required this.selected,
    required this.equipped,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final slim = skin.variant.toLowerCase() == 'slim';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: selected
                ? tokens.colorBrand.withValues(alpha: 0.14)
                : tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? tokens.colorBrand
                  : equipped
                      ? tokens.colorBrand.withValues(alpha: 0.35)
                      : tokens.colorSecondary.withValues(alpha: 0.22),
              width: selected ? 2 : 1,
            ),
          ),
          child: AspectRatio(
            aspectRatio: 31 / 40,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                  child: Column(
                    children: [
                      Expanded(
                        child: pngBytes != null
                            ? Skin2DThumbnail(skinPng: pngBytes!, slim: slim)
                            : Icon(Icons.person, color: tokens.colorBrand),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        skin.name ?? '皮肤',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: tokens.colorContrast,
                        ),
                      ),
                      if (equipped)
                        Text(
                          '使用中',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: tokens.colorBrand,
                          ),
                        ),
                    ],
                  ),
                ),
                if (onDelete != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IconButton(
                      tooltip: '删除皮肤',
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: onDelete,
                      icon: Icon(
                        Icons.delete_outline,
                        color: tokens.colorBase.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  final VoidCallback onTap;

  const _AddTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: CustomPaint(
          painter: _DashedRRectPainter(
            color: tokens.colorSecondary.withValues(alpha: 0.45),
            radius: 20,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: tokens.colorRaisedBg.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: AspectRatio(
              aspectRatio: 31 / 40,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add,
                    size: 40,
                    color: tokens.colorBase.withValues(alpha: 0.75),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '添加皮肤',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: tokens.colorContrast,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '拖放',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;

  _DashedRRectPainter({required this.color, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 6.0;
      const gap = 4.0;
      while (distance < metric.length) {
        final next = (distance + dash).clamp(0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
