import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';

class YggdrasilSettingsPage extends StatefulWidget {
  const YggdrasilSettingsPage({super.key});

  @override
  State<YggdrasilSettingsPage> createState() => _YggdrasilSettingsPageState();
}

class _YggdrasilSettingsPageState extends State<YggdrasilSettingsPage> {
  final _nameController = TextEditingController();
  final _apiUrlController = TextEditingController();
  List<rust.YggdrasilServiceDto> _services = const [];
  String? _editingId;
  String? _message;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _apiUrlController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final services = await rust.listYggdrasilServices();
      if (!mounted) return;
      setState(() {
        _services = services;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = '$error';
        _loading = false;
      });
    }
  }

  void _edit(rust.YggdrasilServiceDto service) {
    setState(() {
      _editingId = service.id;
      _nameController.text = service.name;
      _apiUrlController.text = service.apiUrl;
      _message = null;
    });
  }

  void _clearEditor() {
    setState(() {
      _editingId = null;
      _nameController.clear();
      _apiUrlController.clear();
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final apiUrl = _apiUrlController.text.trim();
    if (name.isEmpty || apiUrl.isEmpty) {
      setState(() => _message = '请输入服务名称和 API 地址');
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await rust.saveYggdrasilService(
        id: _editingId,
        name: name,
        apiUrl: apiUrl,
      );
      _clearEditor();
      await _reload();
      if (!mounted) return;
      setState(() => _message = '外置登录服务已保存');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove(rust.YggdrasilServiceDto service) async {
    try {
      await rust.removeYggdrasilService(id: service.id);
      await _reload();
      if (!mounted) return;
      setState(() => _message = '已删除 ${service.name}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      children: [
        Text(
          '外置登录',
          style: TextStyle(
            color: tokens.colorContrast,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '配置 Yggdrasil 验证服务器。添加账号时可以选择这里的服务；'
          '外置账号只能进入使用相同验证源的服务器，不能替代正版账号。',
          style: TextStyle(
            color: tokens.colorBase.withValues(alpha: 0.72),
            height: 1.45,
          ),
        ),
        const SizedBox(height: 18),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          for (final service in _services)
            Card(
              color: tokens.colorButtonBg,
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  service.builtin
                      ? Icons.verified_outlined
                      : Icons.dns_outlined,
                  color: tokens.colorBrand,
                ),
                title: Text(service.name),
                subtitle: Text(
                  service.apiUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '编辑',
                      onPressed: () => _edit(service),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: service.builtin ? '内置服务不能删除' : '删除',
                      onPressed:
                          service.builtin ? null : () => _remove(service),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 16),
        Text(
          _editingId == null ? '添加验证服务器' : '编辑验证服务器',
          style: TextStyle(
            color: tokens.colorContrast,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: '服务名称',
            hintText: '例如：LittleSkin',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _apiUrlController,
          decoration: const InputDecoration(
            labelText: 'Yggdrasil API 地址',
            hintText: 'https://example.com/api/yggdrasil',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? '保存中…' : '保存'),
            ),
            if (_editingId != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _saving ? null : _clearEditor,
                child: const Text('取消'),
              ),
            ],
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 10),
          Text(
            _message!,
            style: TextStyle(
              color: tokens.colorBase.withValues(alpha: 0.82),
            ),
          ),
        ],
      ],
    );
  }
}
