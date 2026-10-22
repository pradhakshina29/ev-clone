import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import 'package:flutter_application_2/services/vehicle_ble_client.dart';
import 'package:flutter_application_2/services/vehicle_ble_web_adapter_interface.dart';

void main() {
  group('Web Bluetooth vehicle bridge', () {
    test('does not initiate BLE without an authenticated session', () async {
      final adapter = _FakeWebAdapter();
      final client = VehicleBleClient(
        webAdapter: adapter,
        authenticationCheck: () => false,
      );
      addTearDown(client.dispose);

      await expectLater(
        client.start('vehicle-1'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Sign in before connecting to a vehicle.',
          ),
        ),
      );

      expect(adapter.requestDeviceArguments, isEmpty);
      expect(adapter.connections, isEmpty);
    });

    test(
      'selects a device, validates live state and frames commands',
      () async {
        final adapter = _FakeWebAdapter();
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);

        await client.start('vehicle-1');

        expect(adapter.requestDeviceArguments, [true]);
        expect(client.isConnected, isTrue);
        expect(client.selectedDeviceName, 'EV-Simulator-01');
        expect(client.lastDataUpdate, isNotNull);
        expect(client.snapshot.value?.state.batteryPercent, 75);

        adapter.connections.single.emitSnapshot(
          VehicleStateSnapshot(
            vehicleId: 'vehicle-1',
            sequence: 2,
            timestampMillis: 200,
            state: const VehicleControlState(
              batteryPercent: 43,
              speedKph: 28,
              doors: {
                VehicleDoor.frontLeft: VehicleDoorState(
                  open: true,
                  locked: false,
                ),
                VehicleDoor.frontRight: VehicleDoorState(),
                VehicleDoor.rearLeft: VehicleDoorState(),
                VehicleDoor.rearRight: VehicleDoorState(),
              },
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(client.snapshot.value?.state.batteryPercent, 43);
        expect(client.snapshot.value?.state.speedKph, 28);
        expect(
          client.snapshot.value?.state.doors[VehicleDoor.frontLeft]?.open,
          isTrue,
        );
        expect(client.lastDataUpdate, isNotNull);

        await client.send(
          const VehicleControlCommand(
            requestId: 'web-1',
            action: 'speed',
            level: 12,
          ),
        );
        final assembler = BleFrameAssembler();
        Uint8List? commandBytes;
        for (final frame in adapter.connections.single.writes) {
          commandBytes = assembler.add(frame) ?? commandBytes;
        }
        expect(
          VehicleControlCommand.decode(utf8.decode(commandBytes!)).level,
          12,
        );
      },
    );

    test(
      'reports chooser and connection failures without fake connected state',
      () async {
        final adapter = _FakeWebAdapter()
          ..connectError = StateError('Bluetooth access denied');
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);

        await client.start('vehicle-1');

        expect(client.phase, VehicleBlePhase.error);
        expect(client.error, contains('Bluetooth access denied'));
        expect(client.isConnected, isFalse);
        expect(client.snapshot.value, isNull);
      },
    );

    test(
      'rejects an insecure Web Bluetooth context before requesting a device',
      () async {
        final adapter = _FakeWebAdapter()..secureContext = false;
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);

        await client.start('vehicle-1');

        expect(client.phase, VehicleBlePhase.unsupported);
        expect(client.error, contains('HTTPS or localhost'));
        expect(adapter.requestDeviceArguments, isEmpty);
      },
    );

    test(
      'rejects a missing selected vehicle document ID before BLE access',
      () async {
        final adapter = _FakeWebAdapter();
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);

        await expectLater(client.start('  '), throwsArgumentError);
        expect(adapter.requestDeviceArguments, isEmpty);
      },
    );

    test(
      'reports blocked policy and unavailable Bluetooth during capability check',
      () async {
        final blockedAdapter = _FakeWebAdapter()..policyStatus = 'blocked';
        final blockedClient = VehicleBleClient(webAdapter: blockedAdapter);
        addTearDown(blockedClient.dispose);
        await blockedClient.inspectWebCapabilities();
        expect(blockedClient.phase, VehicleBlePhase.unsupported);
        expect(blockedClient.error, contains('permissions policy'));

        final unavailableAdapter = _FakeWebAdapter()
          ..availabilityStatus = 'unavailable';
        final unavailableClient = VehicleBleClient(
          webAdapter: unavailableAdapter,
        );
        addTearDown(unavailableClient.dispose);
        await unavailableClient.inspectWebCapabilities();
        expect(unavailableClient.phase, VehicleBlePhase.error);
        expect(unavailableClient.error, contains('Bluetooth is unavailable'));
      },
    );

    test(
      'rejects a genuine vehicle document ID mismatch and stops the link',
      () async {
        final adapter = _FakeWebAdapter();
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);
        await client.start('vehicle-1');

        adapter.connections.single.emitSnapshot(
          _snapshot(vehicleId: 'vehicle-1', sequence: 4, battery: 51),
        );
        adapter.connections.single.emitSnapshot(
          _snapshot(vehicleId: 'vehicle-1', sequence: 3, battery: 22),
        );
        await Future<void>.delayed(Duration.zero);
        expect(client.snapshot.value?.state.batteryPercent, 51);

        adapter.connections.single.emitSnapshot(
          _snapshot(vehicleId: 'different-vehicle', sequence: 5, battery: 10),
        );
        await Future<void>.delayed(Duration.zero);
        expect(client.phase, VehicleBlePhase.identityMismatch);
        expect(
          client.error,
          contains('selected vehicle document ID "vehicle-1"'),
        );
        expect(client.error, contains('simulator reports "different-vehicle"'));
        expect(client.snapshot.value, isNull);
        expect(adapter.connections.single.closed, isTrue);
      },
    );

    test(
      'terminates initial connection on identity mismatch without timeout retry',
      () async {
        final adapter = _FakeWebAdapter()..simulatorVehicleId = 'EV002';
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);

        await client.start('EV001');

        expect(client.phase, VehicleBlePhase.identityMismatch);
        expect(client.error, contains('selected vehicle document ID "EV001"'));
        expect(client.error, contains('simulator reports "EV002"'));
        expect(client.lastDataUpdate, isNull);
        expect(client.snapshot.value, isNull);
        expect(adapter.requestDeviceArguments, [true]);
        expect(adapter.connections.single.closed, isTrue);
      },
    );

    test(
      'matches against the vehicle document ID, not the peripheral name',
      () async {
        final adapter = _FakeWebAdapter()..simulatorVehicleId = 'EV001';
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);

        await client.start('EV001');

        expect(client.selectedDeviceName, 'EV-Simulator-01');
        expect(client.phase, VehicleBlePhase.connected);
        expect(client.snapshot.value?.vehicleId, 'EV001');
      },
    );

    test(
      'reports a missing simulator identity as invalid telemetry, not mismatch',
      () async {
        final adapter = _FakeWebAdapter()..simulatorVehicleId = 'EV001';
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);
        await client.start('EV001');
        final lastUpdate = client.lastDataUpdate;

        adapter.connections.single.emitRawMessage(
          '{"v":1,"type":"state","sequence":2,"timestampMillis":200,"state":{}}',
        );
        await Future<void>.delayed(Duration.zero);

        expect(client.phase, VehicleBlePhase.connected);
        expect(client.error, isNull);
        expect(client.lastDataUpdate, lastUpdate);
      },
    );

    test(
      'shows awaiting telemetry until the first delayed valid snapshot arrives',
      () async {
        final adapter = _FakeWebAdapter()
          ..initialTelemetryDelay = const Duration(milliseconds: 40);
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);

        final connecting = client.start('vehicle-1');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(client.phase, VehicleBlePhase.awaitingTelemetry);
        expect(client.snapshot.value, isNull);
        expect(client.lastDataUpdate, isNull);

        await connecting;
        expect(client.phase, VehicleBlePhase.connected);
        expect(client.lastDataUpdate, isNotNull);
      },
    );

    test(
      'reuses no stale vehicle identity when switching selected records',
      () async {
        final adapter = _FakeWebAdapter()..simulatorVehicleId = 'EV001';
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);
        await client.start('EV001');

        await client.start('EV002');

        expect(adapter.requestDeviceArguments, [true, true]);
        expect(client.phase, VehicleBlePhase.identityMismatch);
        expect(client.error, contains('selected vehicle document ID "EV002"'));
        expect(client.error, contains('simulator reports "EV001"'));
      },
    );

    test('expects the simulator name of the selected vehicle', () async {
      final adapter = _FakeWebAdapter()..simulatorVehicleId = 'EV002';
      final client = VehicleBleClient(webAdapter: adapter);
      addTearDown(client.dispose);

      await client.start('EV002');
      expect(client.expectedDeviceName, 'EV-Simulator-02');

      await client.disconnect();
      await client.start('EV002', deviceName: ' Custom-Sim ');
      expect(client.expectedDeviceName, 'Custom-Sim');

      await client.disconnect();
      await client.start('EV002', deviceName: '');
      expect(client.expectedDeviceName, 'EV-Simulator-02');
    });

    test(
      'repeated connect for the same live vehicle does not duplicate connection',
      () async {
        final adapter = _FakeWebAdapter()..simulatorVehicleId = 'EV001';
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);
        await client.start('EV001');

        await client.start('EV001');

        expect(adapter.requestDeviceArguments, [true]);
        expect(adapter.connections, hasLength(1));
      },
    );

    test('reports GATT service discovery failure distinctly', () async {
      final adapter = _FakeWebAdapter()
        ..connectError = StateError(
          'GATT_SERVICE_DISCOVERY: service not found',
        );
      final client = VehicleBleClient(webAdapter: adapter);
      addTearDown(client.dispose);

      await client.start('EV001');

      expect(client.phase, VehicleBlePhase.error);
      expect(client.error, contains('GATT service could not be discovered'));
      expect(client.isConnected, isFalse);
    });

    test('reconnects the previously selected device after link loss', () async {
      final adapter = _FakeWebAdapter();
      final client = VehicleBleClient(webAdapter: adapter);
      addTearDown(client.dispose);
      await client.start('vehicle-1');

      adapter.connections.single.loseConnection();
      await Future<void>.delayed(const Duration(milliseconds: 2200));

      expect(adapter.requestDeviceArguments, [true, false]);
      expect(adapter.connections, hasLength(2));
      expect(client.isConnected, isTrue);
    });

    test(
      'Connect after a manual disconnect or sign-out opens the chooser again',
      () async {
        final adapter = _FakeWebAdapter();
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);
        await client.start('vehicle-1');

        await client.disconnect();
        expect(client.selectedDeviceName, isNull);

        await client.start('vehicle-1');

        expect(adapter.requestDeviceArguments, [true, true]);
        expect(adapter.connections, hasLength(2));
        expect(client.isConnected, isTrue);
      },
    );

    test(
      'cancelling the chooser does not reconnect the previous device',
      () async {
        final adapter = _FakeWebAdapter();
        final client = VehicleBleClient(webAdapter: adapter);
        addTearDown(client.dispose);
        await client.start('vehicle-1');
        await client.disconnect();

        adapter.chooserError = StateError(
          'DEVICE_REQUEST: NotFoundError: User cancelled the requestDevice() chooser.',
        );
        await client.start('vehicle-1');
        await Future<void>.delayed(const Duration(milliseconds: 2200));

        expect(client.phase, VehicleBlePhase.error);
        expect(client.error, contains('did not select a matching device'));
        expect(adapter.connections, hasLength(1));
      },
    );

    test('manual disconnect stops automatic reconnects', () async {
      final adapter = _FakeWebAdapter();
      final client = VehicleBleClient(webAdapter: adapter);
      addTearDown(client.dispose);
      await client.start('vehicle-1');

      await client.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 2200));

      expect(client.phase, VehicleBlePhase.stopped);
      expect(client.isConnected, isFalse);
      expect(adapter.requestDeviceArguments, [true]);
      expect(adapter.connections, hasLength(1));
    });
  });
}

VehicleStateSnapshot _snapshot({
  required String vehicleId,
  required int sequence,
  required double battery,
}) => VehicleStateSnapshot(
  vehicleId: vehicleId,
  sequence: sequence,
  timestampMillis: sequence + 100,
  state: VehicleControlState(batteryPercent: battery, rangeKm: battery * 3.5),
);

class _FakeWebAdapter implements VehicleBleWebAdapter {
  final List<_FakeWebConnection> connections = [];
  final List<bool> requestDeviceArguments = [];
  Object? connectError;
  Object? chooserError;
  bool _hasSelectedDevice = false;
  bool secureContext = true;
  String policyStatus = 'allowed';
  String availabilityStatus = 'available';
  String simulatorVehicleId = 'vehicle-1';
  Duration initialTelemetryDelay = Duration.zero;

  @override
  bool get isSupported => true;

  @override
  bool get isSecureContext => secureContext;

  @override
  String get bluetoothPolicyStatus => policyStatus;

  @override
  bool get hasSelectedDevice => _hasSelectedDevice;

  @override
  String? get selectedDeviceName =>
      _hasSelectedDevice ? 'EV-Simulator-01' : null;

  @override
  Future<String> getAvailabilityStatus() async => availabilityStatus;

  @override
  Future<VehicleBleWebConnection> connect({
    required bool requestDevice,
    void Function()? onConnecting,
    void Function(String stage)? onStage,
  }) async {
    requestDeviceArguments.add(requestDevice);
    if (requestDevice) {
      final cancellation = chooserError;
      if (cancellation != null) throw cancellation;
      _hasSelectedDevice = true;
      onStage?.call('DEVICE_SELECTED');
    }
    onConnecting?.call();
    final error = connectError;
    if (error != null) throw error;
    final connection = _FakeWebConnection();
    connection._vehicleId = simulatorVehicleId;
    connection.initialTelemetryDelay = initialTelemetryDelay;
    connections.add(connection);
    return connection;
  }
}

class _FakeWebConnection implements VehicleBleWebConnection {
  final StreamController<List<int>> _notifications =
      StreamController<List<int>>.broadcast();
  final StreamController<void> _disconnects =
      StreamController<void>.broadcast();
  final List<List<int>> writes = [];
  int _messageId = 0;
  bool closed = false;
  Duration initialTelemetryDelay = Duration.zero;

  @override
  Stream<List<int>> get stateNotifications => _notifications.stream;

  @override
  Stream<void> get disconnected => _disconnects.stream;

  @override
  Future<void> startStateNotifications() async {
    if (initialTelemetryDelay > Duration.zero) {
      Timer(
        initialTelemetryDelay,
        () => emitSnapshot(
          _snapshot(vehicleId: _vehicleId, sequence: 0, battery: 75),
        ),
      );
      return;
    }
    emitSnapshot(_snapshot(vehicleId: _vehicleId, sequence: 0, battery: 75));
  }

  String _vehicleId = 'vehicle-1';

  void emitSnapshot(VehicleStateSnapshot snapshot) {
    final bytes = utf8.encode(snapshot.encode());
    for (final frame in BleFrameCodec.fragment(
      bytes,
      messageId: _messageId++,
    )) {
      _notifications.add(frame);
    }
  }

  void emitRawMessage(String message) {
    for (final frame in BleFrameCodec.fragment(
      utf8.encode(message),
      messageId: _messageId++,
    )) {
      _notifications.add(frame);
    }
  }

  void loseConnection() => _disconnects.add(null);

  @override
  Future<void> write(List<int> value) async => writes.add(value);

  @override
  Future<void> close() async {
    closed = true;
    await _notifications.close();
    await _disconnects.close();
  }
}
