import 'package:flutter/material.dart';

/// Shared entrance choreography for full-screen modals (settings, create, etc.).
class ModalMotion {
  ModalMotion(TickerProvider vsync)
      : controller = AnimationController(duration: duration, vsync: vsync) {
    final curved = CurvedAnimation(parent: controller, curve: curve);
    scale = Tween<double>(begin: 0.97, end: 1.0).animate(curved);
    opacity = Tween<double>(begin: 0.0, end: 1.0).animate(curved);
    translate = Tween<Offset>(
      begin: const Offset(-0.04, 0.04),
      end: Offset.zero,
    ).animate(curved);
    backgroundColor = ColorTween(
      begin: Colors.transparent,
      end: const Color.fromARGB(77, 0, 0, 0),
    ).animate(curved);
  }

  static const Duration duration = Duration(milliseconds: 200);
  static const Curve curve = Curves.easeOut;

  final AnimationController controller;
  late final Animation<double> scale;
  late final Animation<double> opacity;
  late final Animation<Offset> translate;
  late final Animation<Color?> backgroundColor;

  void forward() => controller.forward();

  Future<void> reverse() => controller.reverse();

  void dispose() => controller.dispose();
}
