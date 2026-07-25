import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

class GameBackHoverCard extends StatefulWidget {
  final double height;
  final double? width;
  final Color? normalColor;
  final Color? hoverColor;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;
  final String title;
  final String subtitle;
  /// When set, drawn instead of [subtitle] (e.g. colored MOTD).
  final InlineSpan? subtitleSpan;
  final String meta;
  final String playLabel;
  final VoidCallback? onPlay;
  final VoidCallback? onMore;
  final ImageProvider? leadingImage;
  final IconData? leadingIcon;
  /// Optional status chip on the title row (players / ping).
  final Widget? titleTrailing;

  const GameBackHoverCard({
    super.key,
    this.height = 72,
    this.width,
    this.normalColor,
    this.hoverColor,
    this.borderRadius,
    this.onTap,
    this.title = '游戏标题',
    this.subtitle = '单人模式',
    this.subtitleSpan,
    this.meta = '',
    this.playLabel = '开始游戏',
    this.onPlay,
    this.onMore,
    this.leadingImage,
    this.leadingIcon,
    this.titleTrailing,
  });

  @override
  State<GameBackHoverCard> createState() => _GameBackHoverCardState();
}

class _GameBackHoverCardState extends State<GameBackHoverCard>
    with SingleTickerProviderStateMixin {
  bool isHovered = false;
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => isHovered = true),
      onExit: (_) => setState(() => isHovered = false),
      child: AnimatedBuilder(
        animation: _animationController,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              height: widget.height,
              width: widget.width ?? double.infinity,
              decoration: BoxDecoration(
                borderRadius: widget.borderRadius ?? BorderRadius.circular(15),
                color: isHovered
                    ? (widget.hoverColor ?? tokens.colorSuperRaisedBg)
                    : (widget.normalColor ?? tokens.colorRaisedBg),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(15),
                        onTap: widget.onTap,
                        overlayColor: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.pressed)) {
                            return tokens.colorBrand.withValues(alpha: 0.10);
                          }
                          return Colors.transparent;
                        }),
                        onHighlightChanged: (v) {
                          if (v) {
                            _animationController.forward();
                          } else {
                            _animationController.reverse();
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16.0),
                          child: Row(
                            children: [
                              Container(
                                width: 47,
                                height: 47,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                    color: tokens.colorSecondary
                                        .withValues(alpha: 0.45),
                                    width: 1,
                                  ),
                                  color: tokens.colorSuperRaisedBg,
                                  image: widget.leadingImage != null
                                      ? DecorationImage(
                                          image: widget.leadingImage!,
                                          fit: BoxFit.cover,
                                        )
                                      : (widget.leadingIcon == null
                                          ? const DecorationImage(
                                              image:
                                                  AssetImage('assets/2.webp'),
                                              fit: BoxFit.cover,
                                            )
                                          : null),
                                ),
                                child: widget.leadingImage == null &&
                                        widget.leadingIcon != null
                                    ? Icon(
                                        widget.leadingIcon,
                                        color: tokens.colorBrand,
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Row(
                                      children: [
                                        // Flexible (not Expanded) so [titleTrailing]
                                        // sits right after the name, matching
                                        // instance server rows.
                                        Flexible(
                                          child: Text(
                                            widget.title,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w800,
                                              color: tokens.colorContrast,
                                            ),
                                          ),
                                        ),
                                        if (widget.titleTrailing != null) ...[
                                          const SizedBox(width: 8),
                                          widget.titleTrailing!,
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    if (widget.subtitleSpan != null)
                                      Text.rich(
                                        widget.subtitleSpan!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      )
                                    else
                                      Text(
                                        widget.meta.isEmpty
                                            ? widget.subtitle
                                            : '${widget.subtitle} · ${widget.meta}',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: tokens.colorBase
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    if (widget.subtitleSpan != null &&
                                        widget.meta.isNotEmpty) ...[
                                      const SizedBox(height: 1),
                                      Text(
                                        widget.meta,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: tokens.colorBase
                                              .withValues(alpha: 0.55),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NavRectButton(
                          text: widget.playLabel,
                          defaultBackgroundColor: tokens.colorBrand,
                          defaultColor: tokens.colorOnBrand,
                          hoverTextColor: tokens.colorOnBrand,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          icon: widget.playLabel == '停止'
                              ? Icons.stop
                              : Icons.play_arrow,
                          isSelected: false,
                          width: 140,
                          onTap: widget.onPlay ?? () {},
                        ),
                        const SizedBox(width: 4),
                        CustomButton(
                          icon: Icons.more_vert,
                          onTap: widget.onMore ?? () {},
                          size: ButtonSize.medium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
