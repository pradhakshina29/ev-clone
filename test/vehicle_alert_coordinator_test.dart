import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_application_2/services/vehicle_alert_coordinator.dart';
import 'package:flutter_application_2/services/vehicle_controls_preferences_store.dart';
import 'package:flutter_application_2/widgets/vehicle_alert_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import 'support/fake_api.dart';

const _route = '/v1/vehicles/EV001/controls-preferences';

VehicleStateSnapshot _snapshot(int sequence, VehicleHealthState health) =>
    VehicleStateSnapshot(
      vehicleId: 'EV001',
      sequence: sequence,
      timestampMillis: DateTime(2026, 10, 25, 9).millisecondsSinceEpoch,
      state: VehicleControlState(health: health),
    );

const _overheatingAndFlat = VehicleHealthState(
  motor: MotorHealthState(temperatureC: 112),
  tires: {
    VehicleDoor.frontLeft: TireState(pressurePsi: 24),
    VehicleDoor.frontRight: TireState(),
    VehicleDoor.rearLeft: TireState(),
    VehicleDoor.rearRight: TireState(),
  },
);

class _Harness {
  _Harness({Map<String, Object?>? savedPreferences}) {
    api
      ..on(
        'GET $_route',
        (_) => {
          'preferences':
              savedPreferences ??
              {
                'notificationsEnabled': true,
                'safetyAlertsEnabled': true,
                'batteryAlertsEnabled': true,
                'chargingAlertsEnabled': true,
                'passengerProfiles': <Object>[],
                'selectedProfileId': null,
                'alertHistory': <Object>[],
                'activeAlertKeys': <Object>[],
              },
        },
      )
      ..on('PUT $_route', (request) {
        saved.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['preferences']
              as Map<String, dynamic>,
        );
        return <String, Object>{};
      });
    store = VehicleControlsPreferencesStore(api.dataService());
    coordinator = VehicleAlertCoordinator(
      snapshots: snapshots,
      store: store,
      navigatorKey: navigatorKey,
      messengerKey: messengerKey,
      currentUid: () => uid,
      clock: () => now = now.add(const Duration(seconds: 1)),
    )..start();
  }

  final api = FakeApi();
  final saved = <Map<String, dynamic>>[];
  final snapshots = ValueNotifier<VehicleStateSnapshot?>(null);
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final VehicleControlsPreferencesStore store;
  late final VehicleAlertCoordinator coordinator;
  String? uid = 'alice';
  DateTime now = DateTime(2026, 10, 25, 9);

  List<Map<String, dynamic>> get history =>
      (saved.last['alertHistory'] as List).cast<Map<String, dynamic>>();

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        home: const Scaffold(body: Text('Dashboard')),
      ),
    );
    // Alerts must appear over whichever screen is open.
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Trip planner')),
      ),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'shows queued must-acknowledge dialogs one at a time and records them',
    (tester) async {
      final harness = _Harness();
      addTearDown(harness.coordinator.dispose);
      await harness.pumpApp(tester);

      harness.snapshots.value = _snapshot(1, _overheatingAndFlat);
      await tester.pumpAndSettle();

      expect(find.byType(VehicleAlertDialog), findsOneWidget);
      expect(find.text('Trip planner'), findsOneWidget);
      expect(harness.coordinator.queuedCount, 1);
      expect(find.text('Motor overheating'), findsOneWidget);
      expect(find.text('112 °C'), findsOneWidget);
      expect(find.textContaining('Vehicle EV001'), findsOneWidget);
      expect(find.text('CRITICAL'), findsOneWidget);

      // Neither the barrier nor Back closes it.
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Motor overheating'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Motor overheating'), findsOneWidget);
      expect(find.text('Trip planner'), findsOneWidget);

      await tester.tap(find.text('I understand'));
      await tester.pumpAndSettle();
      expect(find.byType(VehicleAlertDialog), findsOneWidget);
      expect(find.text('Low tyre pressure (front left)'), findsOneWidget);
      expect(find.text('24.0 psi'), findsOneWidget);
      expect(harness.coordinator.queuedCount, 0);

      await tester.tap(find.text('I understand'));
      await tester.pumpAndSettle();
      expect(find.byType(VehicleAlertDialog), findsNothing);
      expect(find.text('Trip planner'), findsOneWidget);

      final records = {
        for (final alert in harness.history) alert['kind'] as String: alert,
      };
      final motor = records['motor_overheating_critical']!;
      final tire = records['tire_pressure_low_frontLeft_critical']!;
      expect(motor['value'], '112 °C');
      expect(motor['vehicleId'], 'EV001');
      for (final alert in [motor, tire]) {
        final shown = DateTime.parse(alert['shownAt'] as String);
        final acknowledged = DateTime.parse(alert['acknowledgedAt'] as String);
        expect(acknowledged.isAfter(shown), isTrue);
      }
      expect(
        (harness.saved.last['activeAlertKeys'] as List),
        containsAll([
          'motor_overheating_critical',
          'tire_pressure_low_frontLeft_critical',
        ]),
      );

      // The same condition does not pop up again.
      harness.snapshots.value = _snapshot(2, _overheatingAndFlat);
      await tester.pumpAndSettle();
      expect(find.byType(VehicleAlertDialog), findsNothing);
    },
  );

  testWidgets('warnings say OK and info alerts are SnackBars', (tester) async {
    final harness = _Harness();
    addTearDown(harness.coordinator.dispose);
    await harness.pumpApp(tester);

    harness.snapshots.value = _snapshot(
      1,
      const VehicleHealthState(
        battery: BatteryHealthState(temperatureC: 48),
        software: SoftwareState(updateAvailable: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Battery temperature high'), findsOneWidget);
    expect(find.text('WARNING'), findsOneWidget);
    expect(find.text('I understand'), findsNothing);
    expect(
      find.textContaining('Software update available'),
      findsOneWidget,
      reason: 'info alerts show as a SnackBar, not a dialog',
    );

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(VehicleAlertDialog), findsNothing);

    final software = harness.history.firstWhere(
      (alert) => alert['kind'] == 'software_update_available',
    );
    expect(software.containsKey('shownAt'), isFalse);
    expect(software['severity'], 'info');
  });

  testWidgets('sign-out closes the dialog without recording an acknowledgement', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.coordinator.dispose);
    await harness.pumpApp(tester);

    harness.snapshots.value = _snapshot(1, _overheatingAndFlat);
    await tester.pumpAndSettle();
    expect(find.byType(VehicleAlertDialog), findsOneWidget);

    harness.uid = null;
    harness.coordinator.reset();
    await tester.pumpAndSettle();

    expect(find.byType(VehicleAlertDialog), findsNothing);
    expect(harness.coordinator.queuedCount, 0);
    expect(
      harness.history.any((alert) => alert.containsKey('acknowledgedAt')),
      isFalse,
    );
  });

  testWidgets('alerts switched off are recorded but not shown', (tester) async {
    final harness = _Harness(
      savedPreferences: {
        'notificationsEnabled': true,
        'safetyAlertsEnabled': false,
        'batteryAlertsEnabled': true,
        'chargingAlertsEnabled': true,
        'passengerProfiles': <Object>[],
        'selectedProfileId': null,
        'alertHistory': <Object>[],
        'activeAlertKeys': <Object>[],
      },
    );
    addTearDown(harness.coordinator.dispose);
    await harness.pumpApp(tester);

    harness.snapshots.value = _snapshot(1, _overheatingAndFlat);
    await tester.pumpAndSettle();

    expect(find.byType(VehicleAlertDialog), findsNothing);
    expect(harness.history, hasLength(2));
  });
}
