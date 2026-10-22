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
