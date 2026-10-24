import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/vehicle_controls.dart';

/// A must-acknowledge vehicle alert. It cannot be closed by tapping outside
/// or pressing Back; only the button closes it, returning true.
class VehicleAlertDialog extends StatelessWidget {
  const VehicleAlertDialog({
    super.key,
    required this.alert,
    required this.shownAt,
  });

  final VehicleAlert alert;
  final DateTime shownAt;

  bool get _critical => alert.severity == VehicleAlertSeverity.critical;

  @override
  Widget build(BuildContext context) {
    final color = _critical ? const Color(0xFFCC3445) : const Color(0xFFCC8128);
    final time = TimeOfDay.fromDateTime(alert.timestamp).format(context);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        icon: Icon(
          _critical ? Icons.error_rounded : Icons.warning_amber_rounded,
          color: color,
          size: 40,
        ),
        title: Text(alert.title, textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                _critical ? 'CRITICAL' : 'WARNING',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(alert.message, textAlign: TextAlign.center),
            if (alert.value != null) ...[
              const SizedBox(height: 14),
              Text(
                alert.value!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              [
                if (alert.vehicleId != null) 'Vehicle ${alert.vehicleId}',
                time,
              ].join(' · '),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: color),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(_critical ? 'I understand' : 'OK'),
          ),
        ],
      ),
    );
  }
}
