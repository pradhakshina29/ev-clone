import 'package:flutter/material.dart';
import 'package:flutter_application_2/models/vehicle.dart';
import 'package:flutter_application_2/screens/vehicle_health_page.dart';
import 'package:flutter_application_2/services/vehicle_ble_client.dart';
import 'package:flutter_application_2/services/vehicle_health_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import 'support/fake_api.dart';

void main() {
  testWidgets('shows responsive health sections and opens component details', (
    tester,
  ) async {
    final ble = VehicleBleClient.shared;
    ble.snapshot.value = const VehicleStateSnapshot(
      vehicleId: 'health-page-test-ev',
      sequence: 1,
      timestampMillis: 1,
      state: VehicleControlState(batteryPercent: 42, rangeKm: 141),
    );
    addTearDown(() => ble.snapshot.value = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const vehicle = Vehicle(
      id: 'health-page-test-ev',
      model: 'EV Smart X1',
      registrationNumber: 'TEST',
      ownerName: 'Driver',
      vin: 'TEST-VIN',
      batteryCapacityKwh: 60,
    );
    // The backend has no telemetry endpoint: live values come only from BLE.
    final api = FakeApi()
      ..on(
        'GET /v1/vehicles/${vehicle.id}/maintenance',
        (_) => {
          'records': [
            {
              'id': 'r1',
              'serviceType': 'Brake inspection',
              'serviceDate': DateTime(2026, 9, 12).toUtc().toIso8601String(),
              'nextServiceDate': DateTime(
                2026,
                10,
                15,
              ).toUtc().toIso8601String(),
              'status': 'Completed',
            },
          ],
        },
      );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: VehicleHealthPage(
          vehicle: vehicle,
          dataService: api.dataService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('VEHICLE HEALTH SCORE'), findsOneWidget);
    expect(find.text('Component health'), findsOneWidget);
    expect(
      find.textContaining('Battery health history is not available yet.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No trip efficiency data available yet.'),
      findsOneWidget,
    );
    expect(find.text('Charging simulator'), findsNothing);
    expect(find.text('Predictive maintenance'), findsNothing);
    expect(find.text('Brake inspection'), findsOneWidget);
    expect(find.text('42%'), findsWidgets);
    expect(find.text('72%'), findsNothing);
    expect(find.text('87'), findsNothing);
    expect(tester.takeException(), isNull);

    final batteryCard = find.text('Battery').last;
    await tester.ensureVisible(batteryCard);
    await tester.tap(batteryCard);
    await tester.pumpAndSettle();
    expect(find.text('Current charge'), findsWidgets);
    expect(find.text('42%'), findsWidgets);
    expect(find.text('72%'), findsNothing);
    expect(find.text('Charging cycles'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows live health values, updates them and clears them', (
    tester,
  ) async {
    final ble = VehicleBleClient.shared;
    addTearDown(() => ble.snapshot.value = null);
    final history = VehicleHealthHistory(
      snapshots: ble.snapshot,
      interval: Duration.zero,
    )..start();
    addTearDown(history.dispose);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const vehicle = Vehicle(
      id: 'EV001',
      model: 'EV Smart X1',
      registrationNumber: 'TN01AB1234',
      ownerName: 'Driver',
      vin: 'EVVIN001',
    );
    final api = FakeApi()
      ..on(
        'GET /v1/vehicles/${vehicle.id}/maintenance',
        (_) => {'records': <Object>[]},
      );
    VehicleStateSnapshot live(int sequence, VehicleHealthState health) =>
        VehicleStateSnapshot(
          vehicleId: vehicle.id,
          sequence: sequence,
          timestampMillis: sequence * 1000,
          state: VehicleControlState(
            batteryPercent: 64,
            rangeKm: 224,
            health: health,
          ),
        );
    ble.snapshot.value = live(1, const VehicleHealthState());

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: VehicleHealthPage(
          vehicle: vehicle,
          dataService: api.dataService(),
          healthHistory: history,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GOOD HEALTH'), findsOneWidget);
    expect(find.text('Battery · GOOD'), findsOneWidget);
    expect(find.text('v4.2.1'), findsWidgets);
    expect(find.text('397.5 V'), findsOneWidget);
    expect(find.text('312'), findsWidgets);
    expect(find.text('2 years 2 months'), findsOneWidget);
    expect(find.text('Off'), findsWidgets);
    expect(find.text('Up to date'), findsWidgets);
    expect(find.textContaining('35.0 PSI'), findsWidgets);
    expect(find.textContaining('1 readings this session'), findsOneWidget);
    expect(
      find.textContaining('Battery health history is not available yet.'),
      findsNothing,
    );

    ble.snapshot.value = live(
      2,
      const VehicleHealthState(
        motor: MotorHealthState(
          temperatureC: 112,
          rpm: 4200,
          status: MotorOperatingStatus.overheating,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('REQUIRES SERVICE'), findsOneWidget);
    expect(find.text('Motor · CRITICAL'), findsOneWidget);
    expect(find.text('112°C'), findsWidgets);
    expect(find.text('4200 rpm'), findsOneWidget);
    expect(find.text('Overheating'), findsOneWidget);
    expect(find.textContaining('2 readings this session'), findsOneWidget);

    final motorCard = find.text('Motor · CRITICAL');
    await tester.ensureVisible(motorCard);
    await tester.tap(motorCard);
    await tester.pumpAndSettle();
    expect(find.text('CRITICAL'), findsWidgets);
    expect(find.text('Arrange a professional service inspection.'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    ble.snapshot.value = null;
    await tester.pumpAndSettle();
    expect(find.text('STATUS UNAVAILABLE'), findsOneWidget);
    expect(find.text('Not reported'), findsWidgets);
    expect(find.text('112°C'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders data unavailable states without fake sensor values', (
    tester,
  ) async {
    const vehicle = Vehicle(
      id: 'health-empty-test-ev',
      model: 'EV Smart',
      registrationNumber: 'TEST',
      ownerName: 'Driver',
      vin: 'TEST-VIN',
    );
    final api = FakeApi()
      ..on(
        'GET /v1/vehicles/${vehicle.id}/maintenance',
        (_) => {'records': <Object>[]},
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: VehicleHealthPage(
          vehicle: vehicle,
          dataService: api.dataService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not reported'), findsWidgets);
    expect(find.text('No service records yet.'), findsOneWidget);
    expect(
      find.textContaining('No trip efficiency data available yet.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
