import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Horizontal weighted carousel for project gallery images.
class ProjectGalleryCarousel extends StatefulWidget {
  const ProjectGalleryCarousel({
    super.key,
    required this.gallery,
    required this.onTap,
  });

  final List<ModrinthGalleryImage> gallery;
  final ValueChanged<int> onTap;

  @override
  State<ProjectGalleryCarousel> createState() => _ProjectGalleryCarouselState();
}

class _ProjectGalleryCarouselState extends State<ProjectGalleryCarousel> {
  final CarouselController _controller = CarouselController();
  int _currentIndex = 0;

  bool get _canScroll => widget.gallery.length > 3;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ProjectGalleryCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentIndex >= widget.gallery.length) {
      _currentIndex = widget.gallery.isEmpty ? 0 : widget.gallery.length - 1;
    }
  }

  void _move(int direction) {
    if (!_canScroll) return;
    final target =
        (_currentIndex + direction).clamp(0, widget.gallery.length - 1);
    if (target == _currentIndex) return;
    _controller.animateToItem(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!_canScroll ||
        event is! PointerScrollEvent ||
        !_controller.hasClients) {
      return;
    }
    final delta = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _move(delta > 0 ? 1 : -1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      height: 180,
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: Stack(
          children: [
            Positioned.fill(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: const {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.invertedStylus,
                  },
                ),
                child: CarouselView.weighted(
                  controller: _controller,
                  flexWeights: const [3, 2, 1],
                  itemSnapping: true,
                  consumeMaxWeight: false,
                  shrinkExtent: 76,
                  padding: const EdgeInsets.all(4),
                  backgroundColor: tokens.colorRaisedBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  overlayColor: WidgetStatePropertyAll(
                    tokens.colorBrand.withValues(alpha: 0.12),
                  ),
                  onTap: widget.onTap,
                  onIndexChanged: (index) {
                    if (_currentIndex != index) {
                      setState(() => _currentIndex = index);
                    }
                  },
                  children: [
                    for (final image in widget.gallery)
                      Stack(
                        fit: StackFit.expand,
                        children: [
                          CachedRemoteImage(
                            url: image.url,
                            fit: BoxFit.cover,
                          ),
                          if (image.title != null &&
                              image.title!.trim().isNotEmpty)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 24, 12, 9),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Color(0xB3000000),
                                    ],
                                  ),
                                ),
                                child: Text(
                                  image.title!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _GalleryArrowButton(
                  icon: Icons.chevron_left,
                  enabled: _canScroll && _currentIndex > 0,
                  onPressed: () => _move(-1),
                ),
              ),
            ),
            Positioned(
              right: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _GalleryArrowButton(
                  icon: Icons.chevron_right,
                  enabled:
                      _canScroll && _currentIndex < widget.gallery.length - 1,
                  onPressed: () => _move(1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GalleryArrowButton extends StatelessWidget {
  const _GalleryArrowButton({
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? const Color(0xCC1B1B1B) : const Color(0x551B1B1B),
      shape: const CircleBorder(),
      elevation: enabled ? 3 : 0,
      child: IconButton(
        tooltip: icon == Icons.chevron_left ? '上一张' : '下一张',
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, color: enabled ? Colors.white : Colors.white38),
      ),
    );
  }
}
