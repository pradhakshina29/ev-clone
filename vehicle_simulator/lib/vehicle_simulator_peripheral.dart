import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

class VehicleSimulatorPeripheral extends ChangeNotifier {
  static const MethodChannel _diagnosticsChannel = MethodChannel(
    'com.evsmartcompanion.vehicle_simulator/ble_diagnostics',
  );

  VehicleSimulatorPeripheral() {
    _stateCharacteristic = GATTCharacteristic.mutable(
      uuid: UUID.fromString(vehicleStateCharacteristicUuid),
      properties: [GATTCharacteristicProperty.notify],
      permissions: const [],
      descriptors: [],
    );
    _commandCharacteristic = GATTCharacteristic.mutable(
      uuid: UUID.fromString(vehicleCommandCharacteristicUuid),
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    _stateChangedSubscription = _manager.stateChanged.listen(
      _onBluetoothStateChanged,
    );
    _writeSubscription = _manager.characteristicWriteRequested.listen(
      _onWriteRequested,
    );
    _notifySubscription = _manager.characteristicNotifyStateChanged.listen(
      _onNotifyStateChanged,
    );
    _connectionSubscription = _manager.connectionStateChanged.listen(
      _onConnectionChanged,
    );
    unawaited(_logBluetoothDiagnostics('simulator startup'));
  }

  final PeripheralManager _manager = PeripheralManager();
  late final GATTCharacteristic _stateCharacteristic;
  late final GATTCharacteristic _commandCharacteristic;
  final BleFrameAssembler _commandAssembler = BleFrameAssembler();
  final Map<String, Central> _subscribers = {};
  final Queue<String> _eventLog = Queue<String>();

  late final StreamSubscription<BluetoothLowEnergyStateChangedEventArgs>
  _stateChangedSubscription;
  late final StreamSubscription<GATTCharacteristicWriteRequestedEventArgs>
  _writeSubscription;
  late final StreamSubscription<GATTCharacteristicNotifyStateChangedEventArgs>
  _notifySubscription;
  late final StreamSubscription<CentralConnectionStateChangedEventArgs>
  _connectionSubscription;

  VehicleControlState _state = const VehicleControlState();
  String _vehicleId = '';
  String _advertisedName = defaultVehicleSimulatorName;
  String? _error;
  String _status = 'Ready to advertise';
  int _sequence = 0;
  int _messageId = 0;
  bool _advertising = false;
  bool _disposed = false;
  bool _notificationPending = false;
  bool _notificationInFlight = false;
  Timer? _stateNotificationTimer;
  Timer? _chargingProgressTimer;
  Future<void> _notificationQueue = Future<void>.value();

  VehicleControlState get state => _state;
  String get status => _status;
  String get advertisedName => _advertisedName;
  String? get error => _error;
  bool get advertising => _advertising;
  List<String> get eventLog => List.unmodifiable(_eventLog);
  bool get isAuthorizedPlatform =>
      defaultTargetPlatform == TargetPlatform.android;

  Future<BluetoothLowEnergyState> _waitForBluetoothState() async {
    final state = _manager.state;
    if (state != BluetoothLowEnergyState.unknown &&
        state != BluetoothLowEnergyState.unauthorized) {
      return state;
    }
    final event = await _manager.stateChanged
        .firstWhere(
          (event) =>
              event.state != BluetoothLowEnergyState.unknown &&
              event.state != BluetoothLowEnergyState.unauthorized,
        )
        .timeout(const Duration(seconds: 8));
    return event.state;
  }

  Future<void> startAdvertising(String vehicleId) async {
    final normalizedVehicleId = vehicleId.trim();
    if (normalizedVehicleId.isEmpty || normalizedVehicleId.length > 128) {
      throw ArgumentError.value(
        vehicleId,
        'vehicleId',
        'Enter a vehicle ID up to 128 characters.',
      );
    }
    if (!isAuthorizedPlatform) {
      _setStatus(
        'Android is required for BLE simulator advertising.',
        error: true,
      );
      return;
    }
    try {
      await _logBluetoothDiagnostics('before permission request');
      final authorized = await _manager.authorize();
      await _logBluetoothDiagnostics('after permission request');
      if (!authorized) {
        _setStatus(
          'Bluetooth permission is required to advertise.',
          error: true,
        );
        return;
      }
      if (_manager.state != BluetoothLowEnergyState.poweredOn) {
        final state = await _waitForBluetoothState();
        if (state != BluetoothLowEnergyState.poweredOn) {
          _setStatus(switch (state) {
            BluetoothLowEnergyState.unsupported =>
              'This device does not support BLE peripheral advertising.',
            BluetoothLowEnergyState.poweredOff =>
              'Bluetooth is off. Turn it on to advertise.',
            BluetoothLowEnergyState.unauthorized =>
              'Bluetooth advertising permission was not granted.',
            _ => 'Bluetooth is not available for advertising.',
          }, error: true);
          return;
        }
      }
      if (_manager.state != BluetoothLowEnergyState.poweredOn) {
        _setStatus(
          'Bluetooth is not powered on. Turn it on to advertise the simulator.',
          error: true,
        );
        return;
      }
      _vehicleId = normalizedVehicleId;
      _advertisedName = vehicleSimulatorNameFor(normalizedVehicleId);
      debugPrint(
        '[Vehicle Simulator BLE] Registering GATT service '
        '$vehicleControlServiceUuid before advertising.',
      );
      if (_advertising) {
        await _manager.stopAdvertising();
        _advertising = false;
      }
      await _manager.removeAllServices();
      await _manager.addService(
        GATTService(
          uuid: UUID.fromString(vehicleControlServiceUuid),
          isPrimary: true,
          includedServices: const [],
          characteristics: [_stateCharacteristic, _commandCharacteristic],
        ),
      );
      debugPrint(
        '[Vehicle Simulator BLE] GATT service registration completed; '
        'requesting connectable advertisement name=$_advertisedName '
        'service=$vehicleControlServiceUuid.',
      );
      await _manager.startAdvertising(
        Advertisement(
          name: _advertisedName,
          serviceUUIDs: [UUID.fromString(vehicleControlServiceUuid)],
        ),
      );
      debugPrint(
        '[Vehicle Simulator BLE] ${DateTime.now().toIso8601String()} '
        'SIMULATOR_ADVERTISING_SUCCEEDED vehicleDocumentId=$_vehicleId '
        'peripheral=$_advertisedName '
        'service=$vehicleControlServiceUuid.',
      );
      _advertising = true;
      _error = null;
      _setStatus('Advertising vehicle $_vehicleId');
      _recordEvent('Advertising as $_advertisedName');
      await _notifyCurrentState();
    } catch (error, stackTrace) {
      _advertising = false;
      _setStatus('Could not start BLE advertising: $error', error: true);
      debugPrint(
        '[Vehicle Simulator BLE] Advertising setup/start failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _logBluetoothDiagnostics(String stage) async {
    try {
      final diagnostics = await _diagnosticsChannel
          .invokeMapMethod<String, Object?>('inspect');
      debugPrint(
        '[Vehicle Simulator BLE] $stage: '
        'managerState=${_manager.state}, diagnostics=$diagnostics',
      );
    } on PlatformException catch (error, stackTrace) {
      debugPrint(
        '[Vehicle Simulator BLE] $stage diagnostic channel failed: '
        '${error.code}: ${error.message}\n$stackTrace',
      );
      rethrow;
    }
  }

  Future<void> stopAdvertising() async {
    if (!_advertising) return;
    try {
      for (final central in _subscribers.values.toList(growable: false)) {
        await _manager.disconnect(central);
      }
      await _manager.stopAdvertising();
      _advertising = false;
      _subscribers.clear();
      _recordEvent('BLE advertising stopped');
      _setStatus('Advertising stopped');
    } catch (error) {
      _setStatus('Could not stop BLE advertising.', error: true);
      debugPrint('[Vehicle Simulator BLE] Stop advertising failed: $error');
    }
  }

  Future<void> simulateVehicleDisconnected() async {
    _recordEvent('Scenario: vehicle disconnected');
    await stopAdvertising();
    _setStatus(
      'Simulated vehicle disconnection. Start advertising to reconnect.',
    );
  }

  void updateState(VehicleControlState state, {String? event}) {
    final wasCharging = _state.chargingConnected;
    _state = state;
    _sequence++;
    notifyListeners();
    if (event != null) {
      _recordEvent(event);
    } else if (!wasCharging && state.chargingConnected) {
      _recordEvent('Charging started at ${state.batteryPercent.round()}%');
    } else if (wasCharging && !state.chargingConnected) {
      _recordEvent(
        state.chargingInterrupted
            ? 'Charging interrupted at ${state.batteryPercent.round()}%'
            : state.batteryPercent >= state.targetChargePercent
            ? 'Charging completed at ${state.batteryPercent.round()}%'
            : 'Charging stopped by user at ${state.batteryPercent.round()}%',
      );
    }
    if (!wasCharging && state.chargingConnected) {
      _startChargingProgress();
    } else if (wasCharging && !state.chargingConnected) {
      _chargingProgressTimer?.cancel();
    }
    if (_advertising && _subscribers.isNotEmpty) {
      _scheduleStateNotification();
    }
  }

  void _startChargingProgress() {
    _chargingProgressTimer?.cancel();
    _chargingProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || !_state.chargingConnected) return;
      final nextBattery = (_state.batteryPercent + 1)
          .clamp(0, _state.targetChargePercent)
          .toDouble();
      final completed = nextBattery >= _state.targetChargePercent;
      updateState(
        _state.copyWith(
          batteryPercent: nextBattery,
          rangeKm: nextBattery * 3.5,
          chargingConnected: !completed,
          chargingPowerKw: completed ? 0 : _state.chargingPowerKw,
          chargingInterrupted: false,
        ),
        event: completed
            ? 'Charging completed at ${nextBattery.round()}%'
            : null,
      );
    });
  }

  void _recordEvent(String message) {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    _eventLog.addFirst('$time  $message');
    while (_eventLog.length > 40) {
      _eventLog.removeLast();
    }
    notifyListeners();
  }

  void _scheduleStateNotification() {
    _notificationPending = true;
    if (_notificationInFlight || _stateNotificationTimer?.isActive == true) {
      return;
    }
    _stateNotificationTimer = Timer(const Duration(milliseconds: 80), () {
      _stateNotificationTimer = null;
      unawaited(_drainStateNotifications());
    });
  }

  Future<void> _drainStateNotifications() async {
    if (_disposed || !_notificationPending || _notificationInFlight) return;
    _notificationPending = false;
    _notificationInFlight = true;
    try {
      await _notifyCurrentState();
    } finally {
      _notificationInFlight = false;
      if (_notificationPending) _scheduleStateNotification();
    }
  }

  void _onBluetoothStateChanged(BluetoothLowEnergyStateChangedEventArgs event) {
    debugPrint(
      '[Vehicle Simulator BLE] Adapter state changed: ${event.state}.',
    );
    if (event.state == BluetoothLowEnergyState.poweredOff) {
      _advertising = false;
      _subscribers.clear();
      _setStatus('Bluetooth is turned off', error: true);
    } else if (event.state == BluetoothLowEnergyState.unsupported) {
      _advertising = false;
      _subscribers.clear();
      _setStatus('This device does not support BLE advertising.', error: true);
    } else if (event.state == BluetoothLowEnergyState.unauthorized) {
      _advertising = false;
      _subscribers.clear();
      _setStatus('Bluetooth advertising permission is required.', error: true);
    } else if (event.state == BluetoothLowEnergyState.poweredOn &&
        !_advertising) {
      _setStatus('Bluetooth ready. Start advertising to connect.');
    }
  }

  Future<void> _onWriteRequested(
    GATTCharacteristicWriteRequestedEventArgs event,
  ) async {
    var responseSent = false;
    if (event.characteristic.uuid.toString().toLowerCase() !=
        vehicleCommandCharacteristicUuid.toLowerCase()) {
      await _manager.respondWriteRequestWithError(
        event.request,
        error: GATTError.writeNotPermitted,
      );
      return;
    }
    if (event.request.offset != 0) {
      await _manager.respondWriteRequestWithError(
        event.request,
        error: GATTError.invalidOffset,
      );
      return;
    }
    try {
      final bytes = _commandAssembler.add(event.request.value);
      if (bytes == null) {
        await _manager.respondWriteRequest(event.request);
        return;
      }
      final command = VehicleControlCommand.decode(utf8.decode(bytes));
      final updatedState = applyVehicleCommand(_state, command);
      await _manager.respondWriteRequest(event.request);
      responseSent = true;
      updateState(
        updatedState,
        event: updatedState.chargingConnected != _state.chargingConnected
            ? null
            : 'Received ${command.action} from EV Smart Companion',
      );
      _setStatus('Received ${command.action} from the EV app');
    } catch (error) {
      _commandAssembler.reset();
      if (!responseSent) {
        try {
          await _manager.respondWriteRequestWithError(
            event.request,
            error: GATTError.invalidPDU,
          );
        } catch (responseError) {
          debugPrint(
            '[Vehicle Simulator BLE] Could not reject command: $responseError',
          );
        }
      }
      _setStatus('Rejected an invalid or unsafe vehicle command.', error: true);
      debugPrint('[Vehicle Simulator BLE] Command rejected: $error');
    }
  }

  void _onNotifyStateChanged(
    GATTCharacteristicNotifyStateChangedEventArgs event,
  ) {
    if (event.characteristic.uuid.toString().toLowerCase() !=
        vehicleStateCharacteristicUuid.toLowerCase()) {
      return;
    }
    final key = event.central.uuid.toString();
    if (event.state) {
      _subscribers[key] = event.central;
      debugPrint(
        '[Vehicle Simulator BLE] ${DateTime.now().toIso8601String()} '
        'TELEMETRY_SUBSCRIPTION_ENABLED vehicleDocumentId=$_vehicleId '
        'characteristic=$vehicleStateCharacteristicUuid',
      );
      unawaited(_notifyCurrentState(event.central));
      _recordEvent('EV Smart Companion connected');
      _setStatus('EV Smart Companion connected');
    } else {
      _subscribers.remove(key);
      debugPrint(
        '[Vehicle Simulator BLE] ${DateTime.now().toIso8601String()} '
        'TELEMETRY_SUBSCRIPTION_DISABLED vehicleDocumentId=$_vehicleId',
      );
      _recordEvent('EV Smart Companion disconnected');
      _setStatus('Connected app paused state updates');
    }
  }

  void _onConnectionChanged(CentralConnectionStateChangedEventArgs event) {
    if (event.state == ConnectionState.disconnected) {
      _subscribers.remove(event.central.uuid.toString());
      _recordEvent('BLE central disconnected');
      if (_subscribers.isEmpty && _advertising) {
        _setStatus('Advertising vehicle $_vehicleId');
      }
    }
  }

  Future<void> _notifyCurrentState([Central? onlyCentral]) async {
    final operation = _notificationQueue.then((_) async {
      final snapshot = VehicleStateSnapshot(
        vehicleId: _vehicleId,
        sequence: _sequence,
        timestampMillis: DateTime.now().millisecondsSinceEpoch,
        state: _state,
      );
      final bytes = Uint8List.fromList(utf8.encode(snapshot.encode()));
      final centrals = onlyCentral == null
          ? _subscribers.values.toList(growable: false)
          : [onlyCentral];
      for (final central in centrals) {
        final maximumLength = await _manager.getMaximumNotifyLength(central);
        final frames = BleFrameCodec.fragment(
          bytes,
          maximumFrameLength: maximumLength,
          messageId: _messageId++ & 0xff,
        );
        for (final frame in frames) {
          await _manager.notifyCharacteristic(
            central,
            _stateCharacteristic,
            value: frame,
          );
        }
      }
    });
    _notificationQueue = operation.catchError((Object error) {
      debugPrint('[Vehicle Simulator BLE] State notification failed: $error');
      if (!_disposed) {
        _setStatus(
          'The vehicle state could not be sent over Bluetooth.',
          error: true,
        );
      }
    });
    await _notificationQueue;
  }

  void _setStatus(String status, {bool error = false}) {
    if (_disposed) return;
    _status = status;
    _error = error ? status : null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stateChangedSubscription.cancel();
    _writeSubscription.cancel();
    _notifySubscription.cancel();
    _connectionSubscription.cancel();
    _stateNotificationTimer?.cancel();
    _chargingProgressTimer?.cancel();
    if (_advertising) unawaited(_manager.stopAdvertising());
    unawaited(_manager.removeAllServices());
    super.dispose();
  }
}
