import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_controller.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_custom_stage.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_external_stage.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_import_preview_stage.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_modpack_stage.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_type_stage.dart';
import 'package:flutter/material.dart';

class CreateInstanceContent extends StatefulWidget {
  final ColorScheme colorScheme;
  final VoidCallback onClose;
  final Future<void> Function()? onCreated;

  const CreateInstanceContent({
    super.key,
    required this.colorScheme,
    required this.onClose,
    this.onCreated,
  });

  @override
  State<CreateInstanceContent> createState() => _CreateInstanceContentState();
}

class _CreateInstanceContentState extends State<CreateInstanceContent> {
  late final CreateInstanceController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CreateInstanceController(
      onCreated: widget.onCreated,
      onClose: widget.onClose,
    );
    _controller.loadVersions();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  AppThemeTokens get _tokens => AppThemeTokens.fallback(widget.colorScheme);

  @override
  Widget build(BuildContext context) {
    final tokens = _tokens;
    final maxH = MediaQuery.sizeOf(context).height * 0.82;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: 520,
        maxWidth: 520,
        maxHeight: maxH,
      ),
      child: Material(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(tokens),
            Divider(
              height: 1,
              thickness: 1,
              color: tokens.colorSecondary.withAlpha(35),
            ),
            ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => _buildBody(tokens),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppThemeTokens tokens) {
    return SizedBox(
      height: 64,
      width: double.infinity,
      child: Row(
        children: [
          const SizedBox(width: 30),
          const Text(
            '创建实例',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          CustomButton(
            icon: Icons.close,
            size: ButtonSize.medium,
            backgroundColor: tokens.colorButtonBg.withAlpha(80),
            onTap: widget.onClose,
          ),
          const SizedBox(width: 30),
        ],
      ),
    );
  }

  Widget _buildBody(AppThemeTokens tokens) {
    switch (_controller.stage) {
      case CreateInstanceStage.type:
        return CreateInstanceTypeStage(
          tokens: tokens,
          controller: _controller,
        );
      case CreateInstanceStage.custom:
        return CreateInstanceCustomStage(
          tokens: tokens,
          controller: _controller,
          colorScheme: widget.colorScheme,
        );
      case CreateInstanceStage.modpack:
        return CreateInstanceModpackStage(
          tokens: tokens,
          controller: _controller,
          colorScheme: widget.colorScheme,
        );
      case CreateInstanceStage.importPreview:
        return CreateInstanceImportPreviewStage(
          tokens: tokens,
          controller: _controller,
          colorScheme: widget.colorScheme,
        );
      case CreateInstanceStage.externalImport:
        return CreateInstanceExternalStage(
          tokens: tokens,
          controller: _controller,
          colorScheme: widget.colorScheme,
        );
    }
  }
}
