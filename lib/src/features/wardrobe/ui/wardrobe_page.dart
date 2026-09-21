import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/wardrobe/application/mineskin_api.dart';
import 'package:aml/src/features/wardrobe/application/skin_store.dart';
import 'package:aml/src/features/wardrobe/ui/public_skin_widgets.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// 皮肤库页面：浏览 MineSkin 公开皮肤，可下载或应用到正版账号。
class WardrobePage extends StatefulWidget {
  const WardrobePage({super.key});

  @override
  State<WardrobePage> createState() => _WardrobePageState();
}

class _WardrobePageState extends State<WardrobePage> {
  final _searchController = TextEditingController();
  final List<MineSkinItem> _items = [];
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
      final page = await MineSkinApi.list(
        search: _searchController.text,
        after: reset ? null : _after,
        size: 24,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _items.clear();
          _selected = null;
          _selectedPng = null;
        }
        _items.addAll(page.items);
        _after = page.nextAfter;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(MineSkinItem item) async {
    setState(() {
      _selected = item;
      _selectedPng = null;
    });
    final results = await Future.wait<dynamic>([
      MineSkinApi.pngFor(item),
      MineSkinApi.detailsFor(item),
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
                                      future: MineSkinApi.detailsFor(item),
                                      builder: (context, detailSnapshot) {
                                        final detailed =
                                            detailSnapshot.data ?? item;
                                        return FutureBuilder<Uint8List?>(
                                          future: MineSkinApi.pngFor(item),
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
