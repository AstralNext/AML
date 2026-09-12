import 'dart:async';

import 'package:flutter/material.dart';

/// Shared timing for shell tab / overlay transitions (aligned with modals ~200ms).
abstract final class ShellTransitions {
  static const Duration overlay = Duration(milliseconds: 220);
  static const Duration tab = Duration(milliseconds: 160);
  static const Curve inCurve = Curves.easeOutCubic;
  static const Curve outCurve = Curves.easeInCubic;

  /// Enter from slightly right; exit reverses (slides back right while fading).
  static const Offset overlaySlideBegin = Offset(0.025, 0);

  static Widget overlayTransition(Widget child, Animation<double> animation) {
    // AnimatedSwitcher already drives 0→1 / 1→0; apply forward/reverse curves here.
    final curved = CurvedAnimation(
      parent: animation,
      curve: inCurve,
      reverseCurve: outCurve,
    );
    final slide = Tween<Offset>(
      begin: overlaySlideBegin,
      end: Offset.zero,
    ).animate(curved);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(position: slide, child: child),
    );
  }

  /// Stack outgoing + incoming full-bleed so crossfades do not collapse layout.
  static Widget overlayLayout(Widget? current, List<Widget> previous) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ...previous,
        if (current != null) current,
      ],
    );
  }
}

/// Fade + slight slide for shell overlays (project / author / instance / world).
///
/// Keeps a permanent slot in the parent [Stack] so the tree shape stays stable.
/// Pass `null` to play the exit animation on the previous child.
///
/// [onCoveringChanged] is true while an overlay is shown **or** exiting, so the
/// parent can keep the tab stack offstage until the exit finishes.
class ShellOverlayHost extends StatefulWidget {
  const ShellOverlayHost({
    super.key,
    required this.overlay,
    this.onCoveringChanged,
  });

  final Widget? overlay;
  final ValueChanged<bool>? onCoveringChanged;

  @override
  State<ShellOverlayHost> createState() => _ShellOverlayHostState();
}

class _ShellOverlayHostState extends State<ShellOverlayHost> {
  bool _covering = false;
  Timer? _exitTimer;

  void _setCovering(bool value) {
    if (_covering == value) return;
    _covering = value;
    widget.onCoveringChanged?.call(value);
  }

  @override
  void initState() {
    super.initState();
    _covering = widget.overlay != null;
    if (_covering) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onCoveringChanged?.call(true);
      });
    }
  }

  @override
  void dispose() {
    _exitTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ShellOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.overlay != null) {
      _exitTimer?.cancel();
      _exitTimer = null;
      _setCovering(true);
    } else if (oldWidget.overlay != null && widget.overlay == null) {
      // Ensure parent stays covered even if it only used `overlay != null` so far.
      _setCovering(true);
      _exitTimer?.cancel();
      _exitTimer = Timer(ShellTransitions.overlay, () {
        if (!mounted) return;
        if (widget.overlay == null) {
          _setCovering(false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final overlay = widget.overlay;
    final child = overlay == null
        ? null
        : KeyedSubtree(
            key: overlay.key ?? ValueKey(identityHashCode(overlay)),
            child: SizedBox.expand(child: overlay),
          );

    return AnimatedSwitcher(
      duration: ShellTransitions.overlay,
      // Curves applied inside [overlayTransition] (with reverseCurve).
      switchInCurve: Curves.linear,
      switchOutCurve: Curves.linear,
      layoutBuilder: ShellTransitions.overlayLayout,
      transitionBuilder: ShellTransitions.overlayTransition,
      child: child,
    );
  }
}
