import 'dart:ui';

import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:flutter/material.dart';

class AnimatedModalDialog extends StatelessWidget {
  final AnimationController animationController;
  final Animation<double> scaleAnimation;
  final Animation<double> opacityAnimation;
  final Animation<Offset> translateAnimation;
  final Animation<Color?> backgroundColorAnimation;
  final VoidCallback onClose;
  final Widget child;

  const AnimatedModalDialog({
    super.key,
    required this.animationController,
    required this.scaleAnimation,
    required this.opacityAnimation,
    required this.translateAnimation,
    required this.backgroundColorAnimation,
    required this.onClose,
    required this.child,
  });

  factory AnimatedModalDialog.fromMotion({
    Key? key,
    required ModalMotion motion,
    required VoidCallback onClose,
    required Widget child,
  }) {
    return AnimatedModalDialog(
      key: key,
      animationController: motion.controller,
      scaleAnimation: motion.scale,
      opacityAnimation: motion.opacity,
      translateAnimation: motion.translate,
      backgroundColorAnimation: motion.backgroundColor,
      onClose: onClose,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: onClose,
        child: SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: AnimatedBuilder(
            animation: animationController,
            builder: (context, _) {
              return BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: AnimatedBuilder(
                  animation: animationController,
                  builder: (context, _) {
                    return Container(
                      color: backgroundColorAnimation.value,
                      child: Center(
                        child: GestureDetector(
                          onTap: () {}, // Prevent tap-through
                          child: FadeTransition(
                            opacity: opacityAnimation,
                            child: SlideTransition(
                              position: translateAnimation,
                              child: ScaleTransition(
                                scale: scaleAnimation,
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
