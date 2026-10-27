import 'dart:async';

import 'package:flutter/material.dart';

/// 顶部悬浮提示
enum AppToastKind { info, download, success, error }

class AppToast {
  AppToast._();

  static OverlayEntry? _entry;

  static void show(
    BuildContext context,
    String message, {
    AppToastKind kind = AppToastKind.info,
  }) {
    final text = message.trim();
    if (text.isEmpty || !context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    dismiss();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AppToastView(
        message: text,
        kind: kind,
        onDismissed: () {
          if (identical(_entry, entry)) _entry = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void dismiss() {
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

class _AppToastView extends StatefulWidget {
  const _AppToastView({
    required this.message,
    required this.kind,
    required this.onDismissed,
  });

  final String message;
  final AppToastKind kind;
  final VoidCallback onDismissed;

  @override
  State<_AppToastView> createState() => _AppToastViewState();
}

class _AppToastViewState extends State<_AppToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.18),
      end: Offset.zero,
    ).animate(_fade);
    _controller.forward();
    _timer = Timer(_durationFor(widget.kind), _dismiss);
  }

  Duration _durationFor(AppToastKind kind) => switch (kind) {
    AppToastKind.download => const Duration(milliseconds: 2200),
    AppToastKind.success => const Duration(milliseconds: 2200),
    AppToastKind.error => const Duration(milliseconds: 3200),
    AppToastKind.info => const Duration(milliseconds: 2400),
  };

  Future<void> _dismiss() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    await _controller.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onInverseSurface,
      fontWeight: FontWeight.w500,
      height: 1.35,
    );
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        minimum: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: Semantics(
                  liveRegion: true,
                  child: Material(
                    color: scheme.inverseSurface,
                    elevation: 10,
                    shadowColor: Colors.black.withValues(alpha: 0.28),
                    shape: const StadiumBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _dismiss,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _icon(scheme),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                widget.message,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: textStyle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon(ColorScheme scheme) {
    if (widget.kind == AppToastKind.info) {
      return Icon(
        Icons.info_outline_rounded,
        size: 20,
        color: scheme.onInverseSurface,
      );
    }
    final failed = widget.kind == AppToastKind.error;
    final downloading = widget.kind == AppToastKind.download;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: failed ? scheme.error : scheme.primary,
        shape: BoxShape.circle,
      ),
      child: Icon(
        failed
            ? Icons.close_rounded
            : downloading
            ? Icons.download_rounded
            : Icons.check_rounded,
        size: 17,
        color: failed ? scheme.onError : scheme.onPrimary,
      ),
    );
  }
}
