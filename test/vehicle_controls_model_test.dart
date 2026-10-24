import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import 'package:flutter_application_2/models/vehicle_controls.dart';

void main() {
  group('VehicleAlertEngine', () {
    test('deduplicates an active alert and rearms after recovery', () {
      final engine = VehicleAlertEngine();
      VehicleStateSnapshot snapshot(int sequence, double battery) =>
          VehicleStateSnapshot(
            vehicleId: 'ev-1',
            sequence: sequence,
            timestampMillis: sequence * 1000,
            state: VehicleControlState(batteryPercent: battery),
          );

      expect(engine.evaluate(snapshot(1, 8)), hasLength(1));
      expect(engine.evaluate(snapshot(2, 7)), isEmpty);
      expect(engine.evaluate(snapshot(3, 25)), isEmpty);
      expect(engine.evaluate(snapshot(4, 8)), hasLength(1));
    });

    test('raises a critical alert when a door is open while moving', () {
      const state = VehicleControlState(
        speedKph: 12,
        doors: {
          VehicleDoor.frontLeft: VehicleDoorState(open: true, locked: false),
          VehicleDoor.frontRight: VehicleDoorState(),
          VehicleDoor.rearLeft: VehicleDoorState(),
          VehicleDoor.rearRight: VehicleDoorState(),
        },
      );
      const snapshot = VehicleStateSnapshot(
        vehicleId: 'ev-1',
        sequence: 1,
        timestampMillis: 1000,
        state: state,
      );

      final alerts = VehicleAlertEngine().evaluate(snapshot);

      expect(alerts.single.kind, 'door_open_moving_frontLeft');
      expect(alerts.single.title, 'Front left door open while moving');
      expect(alerts.single.severity, VehicleAlertSeverity.critical);
    });

    test('identifies an unlocked door while moving', () {
      const snapshot = VehicleStateSnapshot(
        vehicleId: 'ev-1',
        sequence: 1,
        timestampMillis: 1000,
        state: VehicleControlState(
          speedKph: 12,
          doors: {
            VehicleDoor.frontLeft: VehicleDoorState(),
            VehicleDoor.frontRight: VehicleDoorState(),
            VehicleDoor.rearLeft: VehicleDoorState(),
            VehicleDoor.rearRight: VehicleDoorState(locked: false),
          },
        ),
      );

      final alerts = VehicleAlertEngine().evaluate(snapshot);

      expect(alerts.single.kind, 'door_unlocked_moving_rearRight');
      expect(alerts.single.title, 'Rear right door unlocked while moving');
      expect(alerts.single.severity, VehicleAlertSeverity.critical);
      expect(alerts.single.requiresAcknowledgement, isTrue);
      expect(alerts.single.value, '12 km/h');
      expect(alerts.single.vehicleId, 'ev-1');
    });

    test('reports open and unlocked doors while parked as info', () {
      const snapshot = VehicleStateSnapshot(
        vehicleId: 'ev-1',
        sequence: 1,
        timestampMillis: 1000,
        state: VehicleControlState(
          doors: {
            VehicleDoor.frontLeft: VehicleDoorState(open: true, locked: false),
            VehicleDoor.frontRight: VehicleDoorState(locked: false),
            VehicleDoor.rearLeft: VehicleDoorState(),
            VehicleDoor.rearRight: VehicleDoorState(),
          },
        ),
      );

      final alerts = VehicleAlertEngine().evaluate(snapshot);

      expect(alerts.map((alert) => alert.kind), [
        'door_open_parked_frontLeft',
        'door_unlocked_parked_frontRight',
      ]);
      expect(
        alerts.every((alert) => alert.severity == VehicleAlertSeverity.info),
        isTrue,
      );
      expect(alerts.any((alert) => alert.requiresAcknowledgement), isFalse);
    });

    test('raises every health alert with its live value', () {
      const snapshot = VehicleStateSnapshot(
        vehicleId: 'EV001',
        sequence: 5,
        timestampMillis: 1000,
        state: VehicleControlState(
          health: VehicleHealthState(
            battery: BatteryHealthState(temperatureC: 58),
            motor: MotorHealthState(temperatureC: 112),
            tires: {
              VehicleDoor.frontLeft: TireState(pressurePsi: 24),
              VehicleDoor.frontRight: TireState(pressurePsi: 28),
              VehicleDoor.rearLeft: TireState(pressurePsi: 44),
              VehicleDoor.rearRight: TireState(treadPercent: 15),
            },
            brakes: BrakeHealthState(
              frontPadPercent: 12,
              rearPadPercent: 25,
              fluidStatus: BrakeFluidStatus.low,
            ),
            software: SoftwareState(updateAvailable: true),
          ),
        ),
      );

      final alerts = {
        for (final alert in VehicleAlertEngine().evaluate(snapshot))
          alert.kind: alert,
      };

      expect(alerts['motor_overheating_critical']!.title, 'Motor overheating');
      expect(alerts['motor_overheating_critical']!.value, '112 °C');
      expect(
        alerts['battery_overheating_critical']!.severity,
        VehicleAlertSeverity.critical,
      );
      expect(alerts['battery_overheating_critical']!.value, '58 °C');
      expect(
        alerts['tire_pressure_low_frontLeft_critical']!.title,
        'Low tyre pressure (front left)',
      );
      expect(alerts['tire_pressure_low_frontLeft_critical']!.value, '24.0 psi');
      expect(
        alerts['tire_pressure_low_frontRight_warning']!.severity,
        VehicleAlertSeverity.warning,
      );
      expect(alerts, contains('tire_pressure_high_rearLeft_warning'));
      expect(alerts, contains('tire_tread_low_rearRight_warning'));
      expect(
        alerts['brake_pads_worn_front_critical']!.severity,
        VehicleAlertSeverity.critical,
      );
      expect(alerts['brake_pads_worn_front_critical']!.value, '12%');
      expect(
        alerts['brake_pads_worn_rear_warning']!.severity,
        VehicleAlertSeverity.warning,
      );
      expect(alerts, contains('brake_fluid_warning'));
      expect(
        alerts['software_update_available']!.severity,
        VehicleAlertSeverity.info,
      );
    });

    test('a healthy health section raises nothing', () {
      const snapshot = VehicleStateSnapshot(
        vehicleId: 'EV001',
        sequence: 1,
        timestampMillis: 1000,
        state: VehicleControlState(health: VehicleHealthState()),
      );
      expect(VehicleAlertEngine().evaluate(snapshot), isEmpty);
    });

    test('escalates from warning to critical but stays quiet cooling down', () {
      final engine = VehicleAlertEngine();
      VehicleStateSnapshot motorAt(int sequence, double celsius) =>
          VehicleStateSnapshot(
            vehicleId: 'EV001',
            sequence: sequence,
            timestampMillis: sequence * 1000,
            state: VehicleControlState(
              health: VehicleHealthState(
                motor: MotorHealthState(temperatureC: celsius),
              ),
            ),
          );

      expect(
        engine.evaluate(motorAt(1, 100)).single.kind,
        'motor_overheating_warning',
      );
      expect(engine.evaluate(motorAt(2, 101)), isEmpty);
      expect(
        engine.evaluate(motorAt(3, 112)).single.kind,
        'motor_overheating_critical',
      );
      expect(engine.evaluate(motorAt(4, 100)), isEmpty);
      expect(engine.evaluate(motorAt(5, 60)), isEmpty);
      expect(
        engine.evaluate(motorAt(6, 112)).single.kind,
        'motor_overheating_critical',
      );
    });

    test('reports charging start and interruption once per transition', () {
      final engine = VehicleAlertEngine();
      VehicleStateSnapshot snapshot(int sequence, VehicleControlState state) =>
          VehicleStateSnapshot(
            vehicleId: 'ev-1',
            sequence: sequence,
            timestampMillis: sequence * 1000,
            state: state,
          );

      expect(
        engine
            .evaluate(
              snapshot(
                1,
                const VehicleControlState(
                  chargingConnected: true,
                  chargingPowerKw: 7.2,
                ),
              ),
            )
            .single
            .kind,
        'charging_active',
      );
      final stopped = const VehicleControlState(chargingInterrupted: true);
      expect(
        engine.evaluate(snapshot(2, stopped)).single.kind,
        'charging_interrupted',
      );
      expect(engine.evaluate(snapshot(3, stopped)), isEmpty);
    });
  });

  test('passenger preferences and alert history round-trip', () {
    final preferences = VehicleControlsPreferences(
      notificationsEnabled: false,
      passengerProfiles: [
        PassengerProfile(
          id: 'profile-1',
          name: 'Sam',
          role: 'driver',
          seatPosition: 'frontLeft',
          preferredTemperatureC: 22,
          fanLevel: 2,
          seatHeating: true,
          leftMirrorHorizontal: -4,
          leftMirrorVertical: 3,
          rightMirrorHorizontal: 5,
          rightMirrorVertical: -2,
          lastUsedAt: DateTime.utc(2025, 1, 2, 3, 4),
        ),
      ],
      selectedProfileId: 'profile-1',
      activeAlertKeys: ['battery_low', 'charging_active'],
    );

    final decoded = VehicleControlsPreferences.fromMap(preferences.toMap());

    expect(decoded.notificationsEnabled, isFalse);
    expect(decoded.passengerProfiles.single.name, 'Sam');
    expect(decoded.passengerProfiles.single.seatHeating, isTrue);
    expect(decoded.passengerProfiles.single.role, 'driver');
    expect(decoded.passengerProfiles.single.seatPosition, 'frontLeft');
    expect(decoded.passengerProfiles.single.leftMirrorHorizontal, -4);
    expect(
      decoded.passengerProfiles.single.lastUsedAt?.toUtc(),
      DateTime.utc(2025, 1, 2, 3, 4),
    );
    expect(decoded.selectedProfileId, 'profile-1');
    expect(decoded.activeAlertKeys, ['battery_low', 'charging_active']);
  });

  test('alert acknowledgements round-trip and older records still load', () {
    final alert = VehicleAlert(
      id: 'EV001_motor_overheating_critical_9',
      kind: 'motor_overheating_critical',
      title: 'Motor overheating',
      message: 'Stop safely.',
      severity: VehicleAlertSeverity.critical,
      timestamp: DateTime.utc(2026, 10, 25, 9),
      value: '112 °C',
      vehicleId: 'EV001',
      shownAt: DateTime.utc(2026, 10, 25, 9, 0, 1),
      acknowledgedAt: DateTime.utc(2026, 10, 25, 9, 0, 7),
    );

    final decoded = VehicleAlert.fromMap(alert.toMap());

    expect(decoded.value, '112 °C');
    expect(decoded.vehicleId, 'EV001');
    expect(decoded.shownAt?.toUtc(), DateTime.utc(2026, 10, 25, 9, 0, 1));
    expect(
      decoded.acknowledgedAt?.toUtc(),
      DateTime.utc(2026, 10, 25, 9, 0, 7),
    );

    final legacy = VehicleAlert.fromMap({
      'id': 'a1',
      'kind': 'battery_low',
      'title': 'Battery running low',
      'message': 'Below 20%.',
      'severity': 'warning',
      'timestamp': '2026-10-01T00:00:00.000Z',
    });
    expect(legacy.shownAt, isNull);
    expect(legacy.acknowledgedAt, isNull);
    expect(legacy.toMap().containsKey('acknowledgedAt'), isFalse);
  });
}
