import 'dart:convert';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

/// Minecraft `options.txt` language codes shown in settings.
const _kGameLanguages = <(String code, String label)>[
  ('zh_cn', '简体中文'),
  ('zh_tw', '繁體中文'),
  ('en_us', 'English (US)'),
  ('ja_jp', '日本語'),
  ('ko_kr', '한국어'),
  ('ru_ru', 'Русский'),
  ('fr_fr', 'Français'),
  ('de_de', 'Deutsch'),
  ('es_es', 'Español'),
  ('pt_br', 'Português (Brasil)'),
  ('it_it', 'Italiano'),
  ('uk_ua', 'Українська'),
  ('pl_pl', 'Polski'),
  ('tr_tr', 'Türkçe'),
  ('vi_vn', 'Tiếng Việt'),
  ('th_th', 'ไทย'),
  ('id_id', 'Bahasa Indonesia'),
];

class GameInstanceSettingsPage extends StatefulWidget {
  const GameInstanceSettingsPage({super.key});

  @override
  State<GameInstanceSettingsPage> createState() =>
      _GameInstanceSettingsPageState();
}

class _GameInstanceSettingsPageState extends State<GameInstanceSettingsPage> {
  final _store = getIt<InstanceStore>();
  final _jvmArgsController = TextEditingController();
  final _envController = TextEditingController();
  final _preLaunchController = TextEditingController();
  final _wrapperController = TextEditingController();
  final _postExitController = TextEditingController();
  final _widthController = TextEditingController(text: '854');
  final _heightController = TextEditingController(text: '480');

  double _memoryMb = 4096;
  bool _fullscreen = false;
  /// Empty string = do not force language in options.txt.
  String _gameLanguage = 'zh_cn';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _jvmArgsController.dispose();
    _envController.dispose();
    _preLaunchController.dispose();
    _wrapperController.dispose();
    _postExitController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final defaults = await _store.getLaunchDefaults();
      if (!mounted) return;
      final lang = defaults.gameLanguage?.trim() ?? '';
      setState(() {
        _memoryMb = defaults.memoryMb.toDouble();
        _fullscreen = defaults.fullscreen;
        _widthController.text = '${defaults.windowWidth}';
        _heightController.text = '${defaults.windowHeight}';
        _jvmArgsController.text = defaults.extraJvmArgs ?? '';
        _envController.text = _envToDisplay(defaults.environmentVars);
        _preLaunchController.text = defaults.preLaunchCommand ?? '';
        _wrapperController.text = defaults.wrapperCommand ?? '';
        _postExitController.text = defaults.postExitCommand ?? '';
        _gameLanguage = lang.isEmpty ? '' : lang;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showAppSnackBar('加载默认配置失败: $error', isError: true);
    }
  }

  String _envToDisplay(String? json) {
    if (json == null || json.trim().isEmpty) return '';
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.entries.map((e) => '${e.key}=${e.value}').join('\n');
    } catch (_) {
      return json;
    }
  }

  String? _envToJson(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final map = <String, String>{};
    for (final line in trimmed.split('\n')) {
      final item = line.trim();
      if (item.isEmpty) continue;
      final index = item.indexOf('=');
      if (index <= 0) continue;
      map[item.substring(0, index).trim()] = item.substring(index + 1).trim();
    }
    if (map.isEmpty) return null;
    return jsonEncode(map);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _store.setLaunchDefaults(
        memoryMb: _memoryMb.round(),
        extraJvmArgs: _jvmArgsController.text.trim().isEmpty
            ? null
            : _jvmArgsController.text.trim(),
        windowWidth: int.tryParse(_widthController.text) ?? 854,
        windowHeight: int.tryParse(_heightController.text) ?? 480,
        fullscreen: _fullscreen,
        environmentVars: _envToJson(_envController.text),
        preLaunchCommand: _preLaunchController.text.trim().isEmpty
            ? null
            : _preLaunchController.text.trim(),
        wrapperCommand: _wrapperController.text.trim().isEmpty
            ? null
            : _wrapperController.text.trim(),
        postExitCommand: _postExitController.text.trim().isEmpty
            ? null
            : _postExitController.text.trim(),
        gameLanguage:
            _gameLanguage.trim().isEmpty ? null : _gameLanguage.trim(),
      );
      if (mounted) showAppSnackBar('默认配置已保存');
    } catch (error) {
      if (mounted) showAppSnackBar('保存失败: $error', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final languageItems = <DropdownItem>[
      const DropdownItem(display: '不强制（保留游戏内设置）', value: ''),
      for (final entry in _kGameLanguages)
        DropdownItem(display: '${entry.$2} (${entry.$1})', value: entry.$1),
    ];
    // Keep custom codes selectable if somehow stored.
    if (_gameLanguage.isNotEmpty &&
        !_kGameLanguages.any((e) => e.$1 == _gameLanguage)) {
      languageItems.add(
        DropdownItem(display: _gameLanguage, value: _gameLanguage),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '默认游戏实例配置',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: tokens.colorContrast,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '当实例未自定义对应项时，启动将使用这些默认值。',
          style: TextStyle(
            fontSize: 14,
            color: tokens.colorBase.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          '默认游戏语言',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: tokens.colorContrast,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '启动前自动写入实例的 options.txt，免去进游戏再选语言。',
          style: TextStyle(
            fontSize: 13,
            color: tokens.colorBase.withValues(alpha: 0.65),
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonWidget(
          height: 48,
          colorScheme: colorScheme,
          selectedValue: _gameLanguage,
          items: languageItems,
          onChanged: (v) => setState(() => _gameLanguage = v),
        ),
        const SizedBox(height: 22),
        Text(
          '默认内存',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: tokens.colorContrast,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _memoryMb.clamp(512, 32768),
                min: 512,
                max: 32768,
                divisions: 128,
                activeColor: tokens.colorBrand,
                label: '${_memoryMb.round()} MB',
                onChanged: (value) => setState(() => _memoryMb = value),
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(
                '${_memoryMb.round()} MB',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: tokens.colorContrast,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('默认全屏', style: TextStyle(color: tokens.colorContrast)),
          value: _fullscreen,
          activeThumbColor: tokens.colorOnBrand,
          activeTrackColor: tokens.colorBrand,
          onChanged: (value) => setState(() => _fullscreen = value),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _field(label: '默认宽度', controller: _widthController),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _field(label: '默认高度', controller: _heightController),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _field(
          label: '默认 Java 参数',
          controller: _jvmArgsController,
          hint: '输入 Java 参数…',
        ),
        const SizedBox(height: 16),
        _field(
          label: '默认环境变量',
          controller: _envController,
          hint: 'KEY=VALUE',
        ),
        const SizedBox(height: 16),
        _field(label: '默认启动前命令', controller: _preLaunchController),
        const SizedBox(height: 16),
        _field(label: '默认包装器命令', controller: _wrapperController),
        const SizedBox(height: 16),
        _field(label: '默认退出后命令', controller: _postExitController),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: NavRectButton(
            isSelected: true,
            icon: _saving ? Icons.hourglass_top : Icons.save_outlined,
            text: _saving ? '保存中…' : '保存默认配置',
            selectedBackgroundColor: tokens.colorBrand,
            selectedColor: tokens.colorOnBrand,
            onTap: _saving ? () {} : _save,
          ),
        ),
      ],
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? hint,
  }) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: tokens.colorContrast,
          ),
        ),
        const SizedBox(height: 6),
        InputBarWidget(
          colorScheme: Theme.of(context).colorScheme,
          size: InputBarSize.medium,
          controller: controller,
          hintText: hint,
        ),
      ],
    );
  }
}
