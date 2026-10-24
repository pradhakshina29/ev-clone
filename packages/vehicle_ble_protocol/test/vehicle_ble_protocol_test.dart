import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

void main() {
  group('simulator names', () {
    test('match the seeded bluetoothDeviceName for each demo vehicle', () {
      expect(vehicleSimulatorNameFor('EV001'), 'EV-Simulator-01');
      expect(vehicleSimulatorNameFor('EV002'), 'EV-Simulator-02');
      expect(vehicleSimulatorNameFor(' ev004 '), 'EV-Simulator-04');
      expect(demoVehicleIds.map(vehicleSimulatorNameFor), [
        'EV-Simulator-01',
        'EV-Simulator-02',
        'EV-Simulator-03',
        'EV-Simulator-04',
        'EV-Simulator-05',
        'EV-Simulator-06',
      ]);
    });

    test('fall back to the default name for other IDs', () {
      expect(vehicleSimulatorNameFor('vehicle-1'), defaultVehicleSimulatorName);
      expect(vehicleSimulatorNameFor('EV12345'), defaultVehicleSimulatorName);
    });
  });

  group('vehicle snapshot protocol', () {
    test('round-trips a snapshot with exactly four doors and windows', () {
      final snapshot = VehicleStateSnapshot(
        vehicleId: 'vehicle-1',
        sequence: 7,
        timestampMillis: 1234,
        state: const VehicleControlState(),
      );

      final decoded = VehicleStateSnapshot.decode(snapshot.encode());

      expect(decoded.vehicleId, 'vehicle-1');
      expect(decoded.sequence, 7);
      expect(decoded.state.doors.length, 4);
      expect(decoded.state.windows.length, 4);
    });

    test('round-trips the optional health section', () {
      const health = VehicleHealthState(
        battery: BatteryHealthState(
          stateOfHealthPercent: 91.5,
          temperatureC: 38.2,
          capacityKwh: 60,
          chargeCycles: 320,
          ageMonths: 27,
          voltageV: 401.3,
        ),
        motor: MotorHealthState(
          healthPercent: 88,
          temperatureC: 112,
          rpm: 4200,
          efficiencyPercent: 90.5,
          status: MotorOperatingStatus.overheating,
        ),
        tires: {
          VehicleDoor.frontLeft: TireState(pressurePsi: 24, treadPercent: 60),
          VehicleDoor.frontRight: TireState(),
          VehicleDoor.rearLeft: TireState(),
          VehicleDoor.rearRight: TireState(treadPercent: 15),
        },
        brakes: BrakeHealthState(
          frontPadPercent: 12,
          rearPadPercent: 18,
          fluidStatus: BrakeFluidStatus.low,
        ),
        software: SoftwareState(version: '4.3.0-beta', updateAvailable: true),
        odometerKm: 18450.37,
      );
      final decoded = VehicleStateSnapshot.decode(
        const VehicleStateSnapshot(
          vehicleId: 'vehicle-1',
          sequence: 3,
          timestampMillis: 10,
          state: VehicleControlState(health: health),
        ).encode(),
      ).state.health!;

      expect(decoded.battery.stateOfHealthPercent, 91.5);
      expect(decoded.battery.temperatureC, 38.2);
      expect(decoded.battery.chargeCycles, 320);
      expect(decoded.battery.ageMonths, 27);
      expect(decoded.battery.voltageV, 401.3);
      expect(decoded.motor.temperatureC, 112);
      expect(decoded.motor.rpm, 4200);
      expect(decoded.motor.status, MotorOperatingStatus.overheating);
      expect(decoded.tire(VehicleDoor.frontLeft).pressurePsi, 24);
      expect(decoded.tire(VehicleDoor.rearRight).treadPercent, 15);
      expect(decoded.brakes.frontPadPercent, 12);
      expect(decoded.brakes.fluidStatus, BrakeFluidStatus.low);
      expect(decoded.software.version, '4.3.0-beta');
      expect(decoded.software.updateAvailable, isTrue);
      expect(decoded.odometerKm, 18450.37);
    });

    test('accepts snapshots without health from older simulators', () {
      final json =
          jsonDecode(
                const VehicleStateSnapshot(
                  vehicleId: 'vehicle-1',
                  sequence: 1,
                  timestampMillis: 1,
                  state: VehicleControlState(health: VehicleHealthState()),
                ).encode(),
              )
              as Map<String, dynamic>;
      (json['state'] as Map<String, dynamic>).remove('health');

      final decoded = VehicleStateSnapshot.decode(jsonEncode(json));

      expect(decoded.state.health, isNull);
      expect(decoded.state.batteryPercent, 75);
      expect(
        const VehicleControlState().toJson().containsKey('health'),
        isFalse,
      );
    });

    test('rejects invalid health values', () {
      Map<String, dynamic> healthyJson() =>
          jsonDecode(
                const VehicleStateSnapshot(
                  vehicleId: 'vehicle-1',
                  sequence: 1,
                  timestampMillis: 1,
                  state: VehicleControlState(health: VehicleHealthState()),
                ).encode(),
              )
              as Map<String, dynamic>;
      final mutations = <void Function(Map<String, dynamic> health)>[
        (health) => (health['battery'] as Map)['stateOfHealthPercent'] = 101,
        (health) => (health['battery'] as Map)['chargeCycles'] = 1.5,
        (health) => (health['motor'] as Map)['temperatureC'] = 250,
        (health) => (health['motor'] as Map)['status'] = 'flying',
        (health) => (health['tires'] as Map).remove('rearLeft'),
        (health) =>
            ((health['tires'] as Map)['frontLeft'] as Map)['pressurePsi'] = -1,
        (health) => (health['brakes'] as Map)['fluidStatus'] = 'unknown',
        (health) => (health['software'] as Map)['version'] = '',
        (health) => (health['software'] as Map)['updateAvailable'] = 'yes',
        (health) => health['odometerKm'] = -5,
        (health) => health.remove('motor'),
      ];
      for (final mutate in mutations) {
        final json = healthyJson();
        mutate((json['state'] as Map<String, dynamic>)['health']
            as Map<String, dynamic>);
        expect(
          () => VehicleStateSnapshot.decode(jsonEncode(json)),
          throwsFormatException,
        );
      }
    });

    test('commands keep the health section unchanged', () {
      const state = VehicleControlState(
        health: VehicleHealthState(odometerKm: 1234),
      );
      final updated = applyVehicleCommand(
        state,
        const VehicleControlCommand(
          requestId: 'r1',
          action: 'headlights',
          enabled: true,
        ),
      );
      expect(updated.lightsOn, isTrue);
      expect(updated.health?.odometerKm, 1234);
    });

    test('a full snapshot with health stays well within the frame limits', () {
      final bytes = utf8.encode(
        VehicleStateSnapshot(
          vehicleId: 'EV001',
          sequence: 999999,
          timestampMillis: DateTime(2026).millisecondsSinceEpoch,
          state: const VehicleControlState(
            health: VehicleHealthState(odometerKm: 123456.78),
          ),
        ).encode(),
      );
      expect(bytes.length, lessThan(2000));

      final frames = BleFrameCodec.fragment(
        bytes,
        maximumFrameLength: bleDefaultFrameLength,
        messageId: 1,
      );
      expect(frames.length, lessThan(255));
      final assembler = BleFrameAssembler();
      Uint8List? message;
      for (final frame in frames) {
        message = assembler.add(frame) ?? message;
      }
      expect(
        VehicleStateSnapshot.decode(utf8.decode(message!)).state.health,
        isNotNull,
      );
    });

    test('rejects missing doors and out-of-range telemetry', () {
      final json =
          jsonDecode(
                VehicleStateSnapshot(
                  vehicleId: 'vehicle-1',
                  sequence: 0,
                  timestampMillis: 1,
                  state: const VehicleControlState(),
                ).encode(),
              )
              as Map<String, dynamic>;
      final state = json['state'] as Map<String, dynamic>;
      (state['doors'] as Map<String, dynamic>).remove('rearRight');

      expect(
        () => VehicleStateSnapshot.decode(jsonEncode(json)),
        throwsFormatException,
      );
    });

    test('rejects charging while the vehicle is on or moving', () {
      final json =
          jsonDecode(
                VehicleStateSnapshot(
                  vehicleId: 'vehicle-1',
                  sequence: 0,
                  timestampMillis: 1,
                  state: const VehicleControlState(),
                ).encode(),
              )
              as Map<String, dynamic>;
      final state = json['state'] as Map<String, dynamic>;
      state['vehicleOn'] = true;
      state['chargingConnected'] = true;
      state['chargingPowerKw'] = 7.2;

      expect(
        () => VehicleStateSnapshot.decode(jsonEncode(json)),
        throwsFormatException,
      );
    });
  });

  group('vehicle command safety', () {
    test('prevents opening a door while moving', () {
      const state = VehicleControlState(speedKph: 4);
      const command = VehicleControlCommand(
        requestId: 'req-1',
        action: 'doorOpen',
        door: VehicleDoor.frontLeft,
        enabled: true,
      );

      expect(
        () => applyVehicleCommand(state, command),
        throwsA(isA<VehicleSafetyException>()),
      );
    });

    test('opens a parked door and unlocks it', () {
      const command = VehicleControlCommand(
        requestId: 'req-2',
        action: 'doorOpen',
        door: VehicleDoor.frontLeft,
        enabled: true,
      );

      final state = applyVehicleCommand(const VehicleControlState(), command);

      expect(state.doors[VehicleDoor.frontLeft]?.open, isTrue);
      expect(state.doors[VehicleDoor.frontLeft]?.locked, isFalse);
    });

    test('prevents connecting the charger while moving', () {
      const state = VehicleControlState(speedKph: 1);
      const command = VehicleControlCommand(
        requestId: 'req-3',
        action: 'chargingConnected',
        enabled: true,
      );

      expect(
        () => applyVehicleCommand(state, command),
        throwsA(isA<VehicleSafetyException>()),
      );
    });
  });

  group('BLE frame protocol', () {
    test('reassembles a long message when frames arrive out of order', () {
      final message = List<int>.generate(150, (index) => index % 256);
      final frames = BleFrameCodec.fragment(message, messageId: 12);
      final assembler = BleFrameAssembler();

      Uint8List? reassembled;
      for (final frame in frames.reversed) {
        reassembled = assembler.add(frame) ?? reassembled;
      }

      expect(reassembled, message);
    });

    test('rejects invalid frame headers', () {
      final assembler = BleFrameAssembler();

      expect(() => assembler.add([0, 0, 1, 0, 1]), throwsFormatException);
    });
  });
}
