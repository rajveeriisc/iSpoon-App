// in_app_alert_service.dart — transient in-app (foreground) alert overlays.
//
// Shows lightweight banner/toast overlays while the app is in the foreground —
// the counterpart to OS notifications used when the user is actively looking at
// the screen (e.g. "Eating too fast", "Food very hot"). Defines InAppAlert
// (title, body, AlertSeverity, duration) and a service with throttling so the
// same alert key can't spam the UI. Provided app-wide via ChangeNotifier.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:smartspoon/core/theme/app_theme.dart';

enum AlertSeverity { info, warning, danger, success }

class InAppAlert {
  final String title;
  final String body;
  final AlertSeverity severity;
  final Duration duration;

  const InAppAlert({
    required this.title,
    required this.body,
    this.severity = AlertSeverity.info,
    this.duration = const Duration(seconds: 4),
  });
}

class InAppAlertService extends ChangeNotifier {
  static final InAppAlertService _instance = InAppAlertService._internal();
  factory InAppAlertService() => _instance;
  InAppAlertService._internal();

  OverlayEntry? _overlayEntry;
  Timer? _dismissTimer;

  // Throttle: same alert type max once per 30 seconds
  final Map<String, DateTime> _lastShown = {};

  void show(BuildContext context, InAppAlert alert, {String? throttleKey}) {
    final key = throttleKey ?? alert.title;
    final last = _lastShown[key];
    if (last != null && DateTime.now().difference(last).inSeconds < 30) return;
    _lastShown[key] = DateTime.now();

    _dismiss();

    _overlayEntry = OverlayEntry(
      builder: (_) => _AlertBanner(
        alert: alert,
        onDismiss: _dismiss,
      ),
    );

    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      debugPrint('[InAppAlert] Cannot show alert: No overlay found in context.');
      return;
    }
    overlay.insert(_overlayEntry!);

    _dismissTimer = Timer(alert.duration, _dismiss);
  }

  void _dismiss() {
    _dismissTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  void dispose() {
    _dismiss();
    super.dispose();
  }
}

class _AlertBanner extends StatefulWidget {
  final InAppAlert alert;
  final VoidCallback onDismiss;
  const _AlertBanner({required this.alert, required this.onDismiss});

  @override
  State<_AlertBanner> createState() => _AlertBannerState();
}

class _AlertBannerState extends State<_AlertBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _color {
    switch (widget.alert.severity) {
      case AlertSeverity.danger:  return AppTheme.paprika;
      case AlertSeverity.warning: return AppTheme.honey;
      case AlertSeverity.success: return AppTheme.sageDeep;
      case AlertSeverity.info:    return AppTheme.caramel;
    }
  }

  IconData get _icon {
    switch (widget.alert.severity) {
      case AlertSeverity.danger:  return Icons.warning_rounded;
      case AlertSeverity.warning: return Icons.speed_rounded;
      case AlertSeverity.success: return Icons.check_circle_rounded;
      case AlertSeverity.info:    return Icons.info_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slide,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(14),
          color: _color,
          child: InkWell(
            onTap: widget.onDismiss,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(_icon, color: Colors.white, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.alert.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.alert.body,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.close, color: Colors.white70, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
