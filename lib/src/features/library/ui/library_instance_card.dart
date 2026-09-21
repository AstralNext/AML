import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:flutter/material.dart';

class LibraryInstanceCard extends StatefulWidget {
  final rust.InstanceDto instance;
  final bool installing;
  final String? operationLabel;
  final bool installFailed;
  final bool running;
  final String loaderLabel;
  final String lastPlayedLabel;
  final VoidCallback onTap;
  final VoidCallback onPlayOrStop;
  final VoidCallback onRename;
  final void Function(Offset globalPosition) onContextMenu;

  const LibraryInstanceCard({
    super.key,
    required this.instance,
    required this.installing,
    this.operationLabel,
    required this.installFailed,
    required this.running,
    required this.loaderLabel,
    required this.lastPlayedLabel,
    required this.onTap,
    required this.onPlayOrStop,
    required this.onRename,
    required this.onContextMenu,
  });

  @override
  State<LibraryInstanceCard> createState() => _LibraryInstanceCardState();
}

class _LibraryInstanceCardState extends State<LibraryInstanceCard> {
  bool _hover = false;
  final GlobalKey _moreKey = GlobalKey();

  void _openMoreMenu() {
    final box = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final offset = box.localToGlobal(Offset(0, box.size.height));
    widget.onContextMenu(offset);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final installing = widget.installing;
    final operationLabel = widget.operationLabel;
    final operating = operationLabel != null;
    final failed = widget.installFailed;
    final running = widget.running;
    final busy = installing || operating;
    final dimIcon = busy || running;
    final subtitle = busy
        ? (operationLabel ?? '安装中…')
        : running
            ? '运行中'
            : '${widget.loaderLabel} · ${widget.lastPlayedLabel}';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            widget.onContextMenu(details.globalPosition),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(14),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 76,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color:
                    _hover ? tokens.colorSuperRaisedBg : tokens.colorRaisedBg,
                borderRadius: BorderRadius.circular(14),
                border: failed
                    ? Border.all(
                        color: const Color(0xFFB3261E).withValues(alpha: 0.55),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: dimIcon ? 0.28 : (_hover ? 0.75 : 1),
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 150),
                            scale: busy ? 0.85 : 1,
                            child: InstanceIcon(
                              instanceId: widget.instance.id,
                              iconPath: widget.instance.icon,
                              size: 48,
                              borderRadius: 8,
                            ),
                          ),
                        ),
                        if (busy)
                          SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: tokens.colorBrand,
                            ),
                          )
                        else if (failed)
                          const Icon(
                            Icons.error_outline,
                            color: Color(0xFFB3261E),
                            size: 28,
                          )
                        else if (running || _hover)
                          Material(
                            color: running
                                ? const Color(0xFFB3261E)
                                : tokens.colorBrand,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: busy
                                  ? null
                                  : () {
                                      widget.onPlayOrStop();
                                    },
                              child: SizedBox(
                                width: 32,
                                height: 32,
                                child: Icon(
                                  running
                                      ? Icons.stop_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.instance.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: tokens.colorContrast,
                                ),
                              ),
                            ),
                            if (_hover) ...[
                              const SizedBox(width: 4),
                              InkWell(
                                onTap: widget.onRename,
                                borderRadius: BorderRadius.circular(6),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                    color: tokens.colorBase
                                        .withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              busy
                                  ? Icons.downloading_outlined
                                  : running
                                      ? Icons.circle
                                      : Icons.sports_esports_outlined,
                              size: running && !busy ? 10 : 14,
                              color: running && !busy
                                  ? const Color(0xFF3BA55D)
                                  : tokens.colorBase.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color:
                                      tokens.colorBase.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    key: _moreKey,
                    onTap: _openMoreMenu,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: tokens.colorBase.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
