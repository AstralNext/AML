import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_content.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:flutter/material.dart';

class CreateNewInstance extends StatefulWidget {
  const CreateNewInstance({super.key});

  @override
  State<CreateNewInstance> createState() => _CreateNewInstanceState();
}

class _CreateNewInstanceState extends State<CreateNewInstance>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;
  late Animation<Offset> _translateAnimation;
  late Animation<Color?> _backgroundColorAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 0.97, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _translateAnimation = Tween<Offset>(
      begin: const Offset(-0.04, 0.04),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _backgroundColorAnimation = ColorTween(
      begin: Colors.transparent,
      end: const Color.fromARGB(77, 0, 0, 0),
    ).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    try {
      await _animationController.reverse();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedModalDialog(
      animationController: _animationController,
      scaleAnimation: _scaleAnimation,
      opacityAnimation: _opacityAnimation,
      translateAnimation: _translateAnimation,
      backgroundColorAnimation: _backgroundColorAnimation,
      onClose: () => unawaited(_close()),
      child: CreateInstanceContent(
        colorScheme: colorScheme,
        onClose: () => unawaited(_close()),
        onCreated: () => getIt<InstanceStore>().refresh(),
      ),
    );
  }
}
