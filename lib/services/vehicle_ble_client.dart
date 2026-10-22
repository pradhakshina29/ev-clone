import 'dart:async';
import 'dart:convert';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import 'vehicle_ble_web_adapter_interface.dart';
import 'auth_service.dart';
import 'vehicle_ble_web_adapter_stub.dart'
    if (dart.library.js_interop) 'vehicle_ble_web_adapter_web.dart'
    as web_adapter;

enum VehicleBlePhase {
  unsupported,
  authorizing,
  scanning,
  selectingDevice,
  connecting,
  gattConnected,
  discoveringServices,
  discoveringCharacteristics,
  subscribingNotifications,
  awaitingTelemetry,
  identityMismatch,
  connected,
  reconnecting,
  error,
  stopped,
}

class VehicleBleClient extends ChangeNotifier {
  VehicleBleClient({this.webAdapter, this.authenticationCheck});

  static final VehicleBleClient shared = VehicleBleClient._applicationScoped();

  VehicleBleClient._applicationScoped()
    : webAdapter = null,
      authenticationCheck = (() => AuthService().currentUser != null);

  final VehicleBleWebAdapter? webAdapter;
  final bool Function()? authenticationCheck;
  CentralManager? _manager;
  Peripheral? _peripheral;
  GATTCharacteristic? _stateCharacteristic;
  GATTCharacteristic? _commandCharacteristic;
  final BleFrameAssembler _stateAssembler = BleFrameAssembler();
  final ValueNotifier<VehicleStateSnapshot?> snapshot =
      ValueNotifier<VehicleStateSnapshot?>(null);
  StreamSubscription<DiscoveredEventArgs>? _discoveredSubscription;
  StreamSubscription<PeripheralConnectionStateChangedEventArgs>?
  _connectionSubscription;
  StreamSubscription<GATTCharacteristicNotifiedEventArgs>?
  _notificationSubscription;
  Timer? _reconnectTimer;
  Timer? _scanTimeoutTimer;
  String _vehicleId = '';
  // The advertised name to accept on Android, e.g. EV-Simulator-02 for EV002.
  String _expectedDeviceName = defaultVehicleSimulatorName;
  String? _error;
  VehicleBlePhase _phase = VehicleBlePhase.stopped;
  int _lastSequence = -1;
  DateTime? _lastDataUpdate;
  String? _selectedDeviceName;
  bool? _secureContext;
  String? _bluetoothPolicyStatus;
  String? _availabilityStatus;
  String? _availabilityError;
  bool _hasLoggedFirstTelemetry = false;
  int _messageId = 0;
  bool _disposed = false;
  bool _discoveryRunning = false;
  bool _connecting = false;
  bool _manualDisconnect = false;
  // The browser adapter remembers the chosen device for the whole tab. After a
  // manual disconnect, sign-out or vehicle switch the next Connect must open
  // Chrome's chooser again instead of silently reusing the old device.
  bool _requireDeviceSelection = false;
  int _reconnectAttempts = 0;
  Completer<void>? _firstStatePacket;
  Future<void> _writeQueue = Future<void>.value();
  VehicleBleWebAdapter? _resolvedWebAdapter;
  VehicleBleWebConnection? _webConnection;
  StreamSubscription<List<int>>? _webStateSubscription;
  StreamSubscription<void>? _webDisconnectSubscription;
  static const _reconnectDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];
  static const _operationTimeout = Duration(seconds: 15);
  static const _scanTimeout = Duration(seconds: 12);

  VehicleBlePhase get phase => _phase;
  String? get error => _error;
  DateTime? get lastDataUpdate => _lastDataUpdate;
  String? get vehicleId => _vehicleId.isEmpty ? null : _vehicleId;
  String get expectedDeviceName => _expectedDeviceName;
  String? get selectedDeviceName => _isWebMode
      ? (_requireDeviceSelection
            ? null
            : _resolvedWebAdapter?.selectedDeviceName)
      : _selectedDeviceName;
  bool? get secureContext => _secureContext;
  String? get bluetoothPolicyStatus => _bluetoothPolicyStatus;
  String? get availabilityStatus => _availabilityStatus;
  String? get availabilityError => _availabilityError;
  bool get isConnected =>
      _phase == VehicleBlePhase.connected && snapshot.value != null;
  bool get _isAuthenticated => authenticationCheck?.call() ?? true;

  bool get _isWebMode => kIsWeb || webAdapter != null;

  bool get isSupported {
    if (_isWebMode) {
      _resolvedWebAdapter ??=
          webAdapter ?? web_adapter.createVehicleBleWebAdapter();
      return _resolvedWebAdapter!.isSupported;
    }
    return defaultTargetPlatform == TargetPlatform.android;
  }

  Future<void> inspectWebCapabilities() async {
    if (!_isWebMode || _disposed) return;
    _resolvedWebAdapter ??=
        webAdapter ?? web_adapter.createVehicleBleWebAdapter();
    final adapter = _resolvedWebAdapter!;
    _secureContext = adapter.isSecureContext;
    _bluetoothPolicyStatus = adapter.bluetoothPolicyStatus;
    _availabilityStatus = null;
    _availabilityError = null;
    notifyListeners();
    if (!adapter.isSupported) {
      _setPhase(
        VehicleBlePhase.unsupported,
        'Web Bluetooth is unavailable. Use desktop Chrome or Edge on a supported operating system.',
      );
      return;
    }
    if (!_secureContext!) {
      _setPhase(
        VehicleBlePhase.unsupported,
        'Web Bluetooth requires HTTPS or localhost. Open the app from a secure page.',
      );
      return;
    }
    if (_bluetoothPolicyStatus == 'blocked') {
      _setPhase(
        VehicleBlePhase.unsupported,
        'This page or its embedding frame blocks Bluetooth access. Open the app directly or allow Bluetooth in the permissions policy.',
      );
      return;
    }
    try {
      _availabilityStatus = await adapter.getAvailabilityStatus();
    } catch (error) {
      _availabilityError = error.toString();
      debugPrint('[Vehicle BLE Web] Availability check failed: $error');
    }
    if (_disposed) return;
    if (_availabilityStatus == 'unavailable' &&
        _phase == VehicleBlePhase.stopped) {
      _setPhase(
        VehicleBlePhase.error,
        'Chrome reports that Bluetooth is unavailable. Turn on the laptop Bluetooth adapter and retry.',
      );
    } else {
      notifyListeners();
    }
  }

  /// Connects to the simulator for [vehicleId]. [deviceName] is the vehicle's
  /// bluetoothDeviceName from the backend; when empty the name is derived
  /// from the ID with [vehicleSimulatorNameFor].
  Future<void> start(String vehicleId, {String? deviceName}) async {
    if (!_isAuthenticated) {
      throw StateError('Sign in before connecting to a vehicle.');
    }
    final requestedVehicleId = vehicleId.trim();
    if (requestedVehicleId.isEmpty) {
      throw ArgumentError.value(vehicleId, 'vehicleId', 'Cannot be empty.');
    }
    if (_connecting) {
      if (_vehicleId != requestedVehicleId) {
        throw StateError(
          'Disconnect the current BLE attempt before selecting another vehicle.',
        );
      }
      return;
    }
    if (_vehicleId == requestedVehicleId &&
        (_phase == VehicleBlePhase.connected ||
            _phase == VehicleBlePhase.awaitingTelemetry)) {
      return;
    }
    if (_vehicleId.isNotEmpty && _vehicleId != requestedVehicleId) {
      await disconnect();
    }
    _vehicleId = requestedVehicleId;
    final trimmedDeviceName = deviceName?.trim() ?? '';
    _expectedDeviceName = trimmedDeviceName.isNotEmpty
        ? trimmedDeviceName
        : vehicleSimulatorNameFor(requestedVehicleId);
    _lastDataUpdate = null;
    _hasLoggedFirstTelemetry = false;
    snapshot.value = null;
    _logBleEvent('BLE_CONNECTION_REQUESTED');
    if (!isSupported) {
      _setPhase(
        VehicleBlePhase.unsupported,
        _isWebMode
            ? 'Web Bluetooth is not available in this browser. Use current Chrome on HTTPS or localhost.'
            : 'Bluetooth vehicle connection requires a physical Android device.',
      );
      return;
    }
    if (_isWebMode) {
      final adapter = _resolvedWebAdapter!;
      _secureContext = adapter.isSecureContext;
      _bluetoothPolicyStatus = adapter.bluetoothPolicyStatus;
      if (!_secureContext!) {
        _setPhase(
          VehicleBlePhase.unsupported,
          'Web Bluetooth requires HTTPS or localhost. Open the app from a secure page and retry.',
        );
        return;
      }
      if (_bluetoothPolicyStatus == 'blocked') {
        _setPhase(
          VehicleBlePhase.unsupported,
          'This page or its embedding frame blocks Bluetooth access. Open the app directly in Chrome or allow Bluetooth in the page permissions policy.',
        );
        return;
      }
      if (_availabilityStatus == 'unavailable') {
        _setPhase(
          VehicleBlePhase.error,
          'Chrome reports that Bluetooth is unavailable. Turn on the laptop Bluetooth adapter and retry.',
        );
        return;
      }
    }

    _reconnectTimer?.cancel();
    _scanTimeoutTimer?.cancel();
    _reconnectAttempts = 0;
    _manualDisconnect = false;
    await _startAttempt();
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _scanTimeoutTimer?.cancel();
    if (_isWebMode) {
      _requireDeviceSelection = true;
      final connection = _webConnection;
      _webConnection = null;
      await _cancelWebSubscriptions();
      if (connection != null) await connection.close();
    } else {
      await _stopDiscovery();
      final peripheral = _peripheral;
      if (peripheral != null) {
        try {
          await _manager?.disconnect(peripheral);
        } catch (error) {
          debugPrint('[Vehicle BLE] User-requested disconnect failed: $error');
          _onBleError(error, StackTrace.current);
          return;
        }
        _peripheral = null;
        _stateCharacteristic = null;
        _commandCharacteristic = null;
      }
    }
    snapshot.value = null;
    _lastDataUpdate = null;
    _firstStatePacket = null;
    _setPhase(VehicleBlePhase.stopped, null);
  }

  Future<void> _startAttempt() async {
    if (_disposed) return;
    if (!_isAuthenticated) {
      _setPhase(VehicleBlePhase.stopped, null);
      return;
    }
    if (_isWebMode) {
      await _startWebAttempt();
      return;
    }
    _manager ??= CentralManager();
    _discoveredSubscription ??= _manager!.discovered.listen(
      _onDiscovered,
      onError: _onBleError,
    );
    _connectionSubscription ??= _manager!.connectionStateChanged.listen(
      _onConnectionChanged,
      onError: _onBleError,
    );
    _notificationSubscription ??= _manager!.characteristicNotified.listen(
      _onNotification,
      onError: _onBleError,
    );

    _setPhase(VehicleBlePhase.authorizing, null);
    try {
      final authorized = await _manager!.authorize();
      if (!authorized) {
        _setPhase(
          VehicleBlePhase.error,
          'Bluetooth permission is required to connect to the vehicle simulator.',
        );
        return;
      }
      if (!_isAuthenticated) {
        _setPhase(VehicleBlePhase.stopped, null);
        return;
      }
      if (_manager!.state != BluetoothLowEnergyState.poweredOn) {
        _setPhase(
          VehicleBlePhase.error,
          'Turn on Bluetooth to connect to the vehicle simulator.',
        );
        return;
      }
      await _discover();
    } catch (error) {
      _onBleError(error, StackTrace.current);
    }
  }

  Future<void> _startWebAttempt() async {
    final adapter = _resolvedWebAdapter!;
    if (_disposed || _connecting) return;
    if (!_isAuthenticated) {
      _setPhase(VehicleBlePhase.stopped, null);
      return;
    }
    _connecting = true;
    final requestDevice = _requireDeviceSelection || !adapter.hasSelectedDevice;
    _setPhase(
      requestDevice
          ? VehicleBlePhase.selectingDevice
          : VehicleBlePhase.connecting,
      null,
    );
    try {
      if (!_isAuthenticated) {
        _setPhase(VehicleBlePhase.stopped, null);
        return;
      }
      final connection = await adapter.connect(
        requestDevice: requestDevice,
        onConnecting: () => _setPhase(VehicleBlePhase.connecting, null),
        onStage: (stage) {
          _logBleEvent(
            stage,
            'peripheral=${adapter.selectedDeviceName ?? 'unknown'}',
          );
          if (stage == 'DEVICE_SELECTED') _requireDeviceSelection = false;
          switch (stage) {
            case 'DEVICE_SELECTED':
            case 'GATT_CONNECT_STARTED':
              _setPhase(VehicleBlePhase.connecting, null);
            case 'GATT_CONNECTED':
              _setPhase(VehicleBlePhase.gattConnected, null);
            case 'GATT_SERVICE_DISCOVERY_STARTED':
              _setPhase(VehicleBlePhase.discoveringServices, null);
            case 'GATT_SERVICE_DISCOVERY_SUCCEEDED':
              _setPhase(VehicleBlePhase.discoveringCharacteristics, null);
            case 'GATT_CHARACTERISTIC_DISCOVERY_STARTED':
              _setPhase(VehicleBlePhase.discoveringCharacteristics, null);
            case 'GATT_CHARACTERISTIC_DISCOVERY_SUCCEEDED':
              _setPhase(VehicleBlePhase.subscribingNotifications, null);
          }
        },
      );
      if (!_isAuthenticated) {
        await connection.close();
        _setPhase(VehicleBlePhase.stopped, null);
        return;
      }
      _webConnection = connection;
      _firstStatePacket = Completer<void>();
      _lastSequence = -1;
      _stateAssembler.reset();
      _webStateSubscription = connection.stateNotifications.listen(
        _onStateBytes,
        onError: _onBleError,
      );
      _webDisconnectSubscription = connection.disconnected.listen(
        (_) => _onWebDisconnected(connection),
        onError: _onBleError,
      );
      _logBleEvent(
        'NOTIFICATION_SUBSCRIPTION_STARTED',
        'characteristic=$vehicleStateCharacteristicUuid',
      );
      _setPhase(VehicleBlePhase.subscribingNotifications, null);
      await connection.startStateNotifications().timeout(_operationTimeout);
      _logBleEvent(
        'NOTIFICATION_SUBSCRIPTION_SUCCEEDED',
        'characteristic=$vehicleStateCharacteristicUuid',
      );
      if (_phase == VehicleBlePhase.identityMismatch) return;
      if (_phase != VehicleBlePhase.connected) {
        _setPhase(VehicleBlePhase.awaitingTelemetry, null);
      }
      await _firstStatePacket!.future.timeout(_operationTimeout);
      if (_phase == VehicleBlePhase.identityMismatch) return;
      _reconnectAttempts = 0;
    } on TimeoutException catch (error) {
      final connection = _webConnection;
      _webConnection = null;
      await _cancelWebSubscriptions();
      if (connection != null) await connection.close();
      _firstStatePacket = null;
      if (_phase != VehicleBlePhase.identityMismatch) {
        _setPhase(
          VehicleBlePhase.error,
          'No valid vehicle telemetry arrived within 15 seconds after notification subscription. Check the simulator vehicle ID and telemetry status, then retry.',
        );
      }
      debugPrint('[Vehicle BLE Web] Connection timed out: $error');
      if (adapter.hasSelectedDevice &&
          _phase != VehicleBlePhase.identityMismatch) {
        _scheduleReconnect();
      }
    } catch (error) {
      _logBleEvent(
        'BLE_OPERATION_FAILED',
        'stage=web-connection reason=$error',
      );
      final connection = _webConnection;
      _webConnection = null;
      await _cancelWebSubscriptions();
      if (connection != null) await connection.close();
      _firstStatePacket = null;
      _setPhase(VehicleBlePhase.error, _webErrorMessage(error));
      debugPrint('[Vehicle BLE Web] Connection failed: $error');
      // A cancelled chooser must not fall back to the previous device.
      if (adapter.hasSelectedDevice && !_requireDeviceSelection) {
        _scheduleReconnect();
      }
    } finally {
      _connecting = false;
    }
  }

  String _webErrorMessage(Object error) {
    final message = error.toString();
    if (message.contains('GATT_CHARACTERISTIC_DISCOVERY')) {
      return 'The selected peripheral is missing the required vehicle GATT service or characteristic. Confirm the simulator is advertising the project protocol. Details: $message';
    }
    if (message.contains('GATT_SERVICE_DISCOVERY')) {
      return 'The vehicle GATT service could not be discovered. Confirm the simulator registered service $vehicleControlServiceUuid. Details: $message';
    }
    if (message.contains('NOTIFICATION_SUBSCRIPTION')) {
      return 'The state characteristic was found, but telemetry notifications could not be enabled. Details: $message';
    }
    if (message.contains('NotFoundError') ||
        message.contains('cancelled') ||
        message.contains('canceled')) {
      if (message.contains('DEVICE_REQUEST')) {
        return 'Chrome did not select a matching device. Confirm the simulator is advertising $_expectedDeviceName and try again. Details: $message';
      }
      return 'The selected device could not be found. Confirm that it is advertising and retry. Details: $message';
    }
    if (message.contains('SecurityError')) {
      return 'Chrome rejected this Bluetooth operation because of the page security context or permissions policy. Use HTTPS or localhost and open the app outside a restricted iframe. Details: $message';
    }
    if (message.contains('NotAllowedError')) {
      return 'Chrome did not allow this Bluetooth request. Start it with the Connect Vehicle button and choose the simulator in Chrome’s chooser. Details: $message';
    }
    if (message.contains('NetworkError')) {
      return 'The Bluetooth operation failed at ${message.split(':').first}. Keep the simulator advertising and retry. Details: $message';
    }
    if (message.contains('NotFound')) {
      return 'The selected device or required GATT attribute was not found. Confirm the simulator is advertising the project protocol. Details: $message';
    }
    return 'Could not connect to the vehicle over Web Bluetooth: $message';
  }

  void _onWebDisconnected(VehicleBleWebConnection connection) {
    if (_webConnection != connection) return;
    _webConnection = null;
    unawaited(_cancelWebSubscriptions());
    unawaited(connection.close());
    if (_disposed) return;
    snapshot.value = null;
    _lastDataUpdate = null;
    _firstStatePacket = null;
    if (_manualDisconnect) {
      _setPhase(VehicleBlePhase.stopped, null);
      return;
    }
    _setPhase(VehicleBlePhase.reconnecting, null);
    _scheduleReconnect();
  }

  Future<void> _cancelWebSubscriptions() async {
    await _webStateSubscription?.cancel();
    _webStateSubscription = null;
    await _webDisconnectSubscription?.cancel();
    _webDisconnectSubscription = null;
  }

  Future<void> _discover() async {
    if (_disposed || _manager == null || _discoveryRunning || _connecting) {
      return;
    }
    _setPhase(VehicleBlePhase.scanning, null);
    try {
      _discoveryRunning = true;
      await _manager!.startDiscovery(
        serviceUUIDs: [UUID.fromString(vehicleControlServiceUuid)],
      );
      _scanTimeoutTimer?.cancel();
      _scanTimeoutTimer = Timer(_scanTimeout, () {
        if (_disposed || !_discoveryRunning || _connecting) return;
        unawaited(_stopDiscovery());
        _setPhase(
          VehicleBlePhase.reconnecting,
          'No $_expectedDeviceName found. Retrying with a limited backoff.',
        );
        _scheduleReconnect();
      });
    } catch (error) {
      await _stopDiscovery();
      _onBleError(error, StackTrace.current);
      _scheduleReconnect();
    }
  }

  void _onDiscovered(DiscoveredEventArgs event) {
    if (_disposed || _connecting || _peripheral != null) return;
    final serviceFound = event.advertisement.serviceUUIDs.any(
      (uuid) =>
          uuid.toString().toLowerCase() ==
          vehicleControlServiceUuid.toLowerCase(),
    );
    if (!serviceFound ||
        event.advertisement.name != _expectedDeviceName) {
      return;
    }
    _selectedDeviceName = event.advertisement.name;
    _scanTimeoutTimer?.cancel();
    unawaited(_stopDiscovery());
    unawaited(_connect(event.peripheral));
  }

  Future<void> _connect(Peripheral peripheral) async {
    final manager = _manager;
    if (manager == null || _connecting || _disposed) return;
    _connecting = true;
    _peripheral = peripheral;
    _setPhase(VehicleBlePhase.connecting, null);
    try {
      await _stopDiscovery();
      try {
        await manager.connect(peripheral).timeout(_operationTimeout);
      } catch (error) {
        _logBleEvent('GATT_CONNECT_FAILED', 'reason=$error');
        rethrow;
      }
      _logBleEvent('GATT_CONNECTED', 'peripheral=$_selectedDeviceName');
      _setPhase(VehicleBlePhase.gattConnected, null);
      try {
        await manager
            .requestMTU(peripheral, mtu: 247)
            .timeout(_operationTimeout);
      } catch (error) {
        debugPrint('[Vehicle BLE] Continuing with default MTU: $error');
      }
      _setPhase(VehicleBlePhase.discoveringServices, null);
      _logBleEvent('GATT_SERVICE_DISCOVERY_STARTED');
      late final List<GATTService> services;
      try {
        services = await manager
            .discoverGATT(peripheral)
            .timeout(_operationTimeout);
      } catch (error) {
        throw StateError('GATT_SERVICE_DISCOVERY: $error');
      }
      final service = services
          .where(
            (candidate) =>
                candidate.uuid.toString().toLowerCase() ==
                vehicleControlServiceUuid.toLowerCase(),
          )
          .firstOrNull;
      if (service == null) {
        _logBleEvent('GATT_SERVICE_DISCOVERY_FAILED');
        throw StateError(
          'GATT_SERVICE_DISCOVERY: The simulator does not expose the vehicle service.',
        );
      }
      _logBleEvent(
        'GATT_SERVICE_DISCOVERY_SUCCEEDED',
        'service=$vehicleControlServiceUuid',
      );
      _setPhase(VehicleBlePhase.discoveringCharacteristics, null);
      _logBleEvent('GATT_CHARACTERISTIC_DISCOVERY_STARTED');
      _stateCharacteristic = service.characteristics
          .where(
            (characteristic) =>
                characteristic.uuid.toString().toLowerCase() ==
                vehicleStateCharacteristicUuid.toLowerCase(),
          )
          .firstOrNull;
      _commandCharacteristic = service.characteristics
          .where(
            (characteristic) =>
                characteristic.uuid.toString().toLowerCase() ==
                vehicleCommandCharacteristicUuid.toLowerCase(),
          )
          .firstOrNull;
      if (_stateCharacteristic == null || _commandCharacteristic == null) {
        _logBleEvent('GATT_CHARACTERISTIC_DISCOVERY_FAILED');
        throw StateError(
          'GATT_CHARACTERISTIC_DISCOVERY: The simulator is missing a required BLE characteristic.',
        );
      }
      _logBleEvent('GATT_CHARACTERISTIC_DISCOVERY_SUCCEEDED');
      _firstStatePacket = Completer<void>();
      _setPhase(VehicleBlePhase.subscribingNotifications, null);
      _logBleEvent('NOTIFICATION_SUBSCRIPTION_STARTED');
      try {
        await manager
            .setCharacteristicNotifyState(
              peripheral,
              _stateCharacteristic!,
              state: true,
            )
            .timeout(_operationTimeout);
      } catch (error) {
        throw StateError('NOTIFICATION_SUBSCRIPTION: $error');
      }
      _logBleEvent('NOTIFICATION_SUBSCRIPTION_SUCCEEDED');
      if (_phase == VehicleBlePhase.identityMismatch) return;
      if (_phase != VehicleBlePhase.connected) {
        _setPhase(VehicleBlePhase.awaitingTelemetry, null);
      }
      _lastSequence = -1;
      _stateAssembler.reset();
      await _firstStatePacket!.future.timeout(_operationTimeout);
      if (_phase == VehicleBlePhase.identityMismatch) return;
      _reconnectAttempts = 0;
    } catch (error) {
      _firstStatePacket = null;
      _logBleEvent('BLE_OPERATION_FAILED', 'reason=$error');
      await _disconnectPeripheral(peripheral);
      _connecting = false;
      _setPhase(VehicleBlePhase.error, _connectionErrorMessage(error));
      debugPrint('[Vehicle BLE] Connection failed: $error');
      _scheduleReconnect();
    }
  }

  void _onConnectionChanged(PeripheralConnectionStateChangedEventArgs event) {
    if (_peripheral != event.peripheral) return;
    if (event.state == ConnectionState.disconnected) {
      _peripheral = null;
      _stateCharacteristic = null;
      _commandCharacteristic = null;
      _connecting = false;
      if (!_disposed) {
        snapshot.value = null;
        _lastDataUpdate = null;
        if (_phase == VehicleBlePhase.identityMismatch) return;
        if (_manualDisconnect) {
          _setPhase(VehicleBlePhase.stopped, null);
          return;
        }
        _setPhase(VehicleBlePhase.reconnecting, null);
        _scheduleReconnect();
      }
    }
  }

  void _onNotification(GATTCharacteristicNotifiedEventArgs event) {
    if (event.peripheral != _peripheral ||
        event.characteristic.uuid.toString().toLowerCase() !=
            vehicleStateCharacteristicUuid.toLowerCase()) {
      return;
    }
    _onStateBytes(event.value);
  }

  void _onStateBytes(List<int> value) {
    Uint8List? bytes;
    try {
      bytes = _stateAssembler.add(value);
      if (bytes == null) return;
    } catch (error) {
      _logBleEvent('TELEMETRY_FRAME_REJECTED', 'reason=$error');
      return;
    }
    late final VehicleStateSnapshot decoded;
    try {
      decoded = VehicleStateSnapshot.decode(utf8.decode(bytes));
    } catch (error) {
      _logBleEvent('TELEMETRY_PAYLOAD_REJECTED', 'reason=$error');
      return;
    }
    _logBleEvent(
      'SIMULATOR_IDENTITY_RECEIVED',
      'reportedVehicleDocumentId=${decoded.vehicleId}',
    );
    if (decoded.vehicleId != _vehicleId) {
      final message =
          'Vehicle identity mismatch: selected vehicle document ID "$_vehicleId", but simulator reports "${decoded.vehicleId}". Enter the selected vehicle document ID in the simulator and restart advertising.';
      _logBleEvent(
        'VEHICLE_IDENTITY_MISMATCH',
        'selectedVehicleDocumentId=$_vehicleId reportedVehicleDocumentId=${decoded.vehicleId}',
      );
      _manualDisconnect = true;
      snapshot.value = null;
      _lastDataUpdate = null;
      _setPhase(VehicleBlePhase.identityMismatch, message);
      final firstPacket = _firstStatePacket;
      if (firstPacket != null && !firstPacket.isCompleted) {
        firstPacket.complete();
      }
      if (_isWebMode) {
        final connection = _webConnection;
        _webConnection = null;
        unawaited(_cancelWebSubscriptions());
        if (connection != null) unawaited(connection.close());
      } else {
        final peripheral = _peripheral;
        if (peripheral != null) unawaited(_disconnectPeripheral(peripheral));
      }
      return;
    }
    if (decoded.sequence <= _lastSequence) {
      _logBleEvent(
        'STALE_TELEMETRY_IGNORED',
        'sequence=${decoded.sequence} lastSequence=$_lastSequence',
      );
      return;
    }
    _lastSequence = decoded.sequence;
    _lastDataUpdate = DateTime.now();
    snapshot.value = decoded;
    final event = _hasLoggedFirstTelemetry
        ? 'VALID_TELEMETRY_RECEIVED'
        : 'FIRST_VALID_TELEMETRY_RECEIVED';
    _hasLoggedFirstTelemetry = true;
    _logBleEvent(
      event,
      'vehicleDocumentId=${decoded.vehicleId} sequence=${decoded.sequence} '
      'timestamp=${DateTime.now().toIso8601String()}',
    );
    _setPhase(VehicleBlePhase.connected, null);
    if (!(_firstStatePacket?.isCompleted ?? true)) {
      _firstStatePacket!.complete();
    }
  }

  void _logBleEvent(String event, [String details = '']) {
    final suffix = details.isEmpty ? '' : ' $details';
    debugPrint(
      '[Vehicle BLE] ${DateTime.now().toIso8601String()} $event '
      'selectedVehicleDocumentId=$_vehicleId$suffix',
    );
  }

  String _connectionErrorMessage(Object error) {
    final message = error.toString();
    if (message.contains('GATT_SERVICE_DISCOVERY')) {
      return 'The vehicle GATT service could not be discovered. Details: $message';
    }
    if (message.contains('GATT_CHARACTERISTIC_DISCOVERY')) {
      return 'A required vehicle characteristic could not be discovered. Details: $message';
    }
    if (message.contains('NOTIFICATION_SUBSCRIPTION')) {
      return 'The state characteristic was found, but telemetry notifications could not be enabled. Details: $message';
    }
    if (error is TimeoutException) {
      return 'No valid vehicle telemetry arrived within 15 seconds after notification subscription.';
    }
    return 'Could not connect to the vehicle simulator. Check that it is advertising and retry. Details: $message';
  }

  Future<void> send(VehicleControlCommand command) async {
    if (!_isAuthenticated) {
      throw StateError('Sign in before sending vehicle commands.');
    }
    if (_isWebMode) {
      await _sendWeb(command);
      return;
    }
    final manager = _manager;
    final peripheral = _peripheral;
    final characteristic = _commandCharacteristic;
    final current = snapshot.value;
    if (!isConnected ||
        manager == null ||
        peripheral == null ||
        characteristic == null ||
        current == null) {
      throw StateError(
        'Connect to the vehicle simulator before sending controls.',
      );
    }
    applyVehicleCommand(current.state, command);

    final bytes = Uint8List.fromList(utf8.encode(command.encode()));
    final operation = _writeQueue.then((_) async {
      final maximumLength = await manager.getMaximumWriteLength(
        peripheral,
        type: GATTCharacteristicWriteType.withResponse,
      );
      final frames = BleFrameCodec.fragment(
        bytes,
        maximumFrameLength: maximumLength,
        messageId: _messageId++ & 0xff,
      );
      for (final frame in frames) {
        await manager.writeCharacteristic(
          peripheral,
          characteristic,
          value: frame,
          type: GATTCharacteristicWriteType.withResponse,
        );
      }
    });
    _writeQueue = operation.catchError((Object error) {
      _setPhase(
        VehicleBlePhase.error,
        'The vehicle command could not be sent.',
      );
      Error.throwWithStackTrace(error, StackTrace.current);
    });
    await operation;
  }

  Future<void> _sendWeb(VehicleControlCommand command) async {
    final connection = _webConnection;
    final current = snapshot.value;
    if (!isConnected || connection == null || current == null) {
      throw StateError(
        'Connect to the vehicle simulator before sending controls.',
      );
    }
    applyVehicleCommand(current.state, command);
    final bytes = Uint8List.fromList(utf8.encode(command.encode()));
    final operation = _writeQueue.then((_) async {
      final frames = BleFrameCodec.fragment(
        bytes,
        maximumFrameLength: bleDefaultFrameLength,
        messageId: _messageId++ & 0xff,
      );
      for (final frame in frames) {
        await connection.write(frame);
      }
    });
    _writeQueue = operation.catchError((Object error) {
      _setPhase(
        VehicleBlePhase.error,
        'The vehicle command could not be sent.',
      );
      Error.throwWithStackTrace(error, StackTrace.current);
    });
    await operation;
  }

  void _scheduleReconnect() {
    if (_disposed || _vehicleId.isEmpty) return;
    _reconnectTimer?.cancel();
    if (_reconnectAttempts >= _reconnectDelays.length) {
      _setPhase(
        VehicleBlePhase.error,
        'Could not connect after ${_reconnectDelays.length} attempts. Check the simulator and retry.',
      );
      return;
    }
    final delay = _reconnectDelays[_reconnectAttempts++];
    _reconnectTimer = Timer(delay, () {
      if (!_disposed) unawaited(_startAttempt());
    });
  }

  Future<void> _stopDiscovery() async {
    _scanTimeoutTimer?.cancel();
    if (!_discoveryRunning || _manager == null) return;
    _discoveryRunning = false;
    try {
      await _manager!.stopDiscovery();
    } catch (error) {
      debugPrint('[Vehicle BLE] Discovery cleanup failed: $error');
    }
  }

  Future<void> _disconnectPeripheral(Peripheral peripheral) async {
    try {
      await _manager?.disconnect(peripheral);
    } catch (error) {
      debugPrint('[Vehicle BLE] Disconnect cleanup failed: $error');
    }
    if (_peripheral == peripheral) _peripheral = null;
    _stateCharacteristic = null;
    _commandCharacteristic = null;
    if (!_disposed) snapshot.value = null;
  }

  void _onBleError(Object error, StackTrace stackTrace) {
    debugPrint('[Vehicle BLE] Bluetooth operation failed: $error');
    if (!_disposed) {
      _setPhase(
        VehicleBlePhase.error,
        'Bluetooth operation failed. Check Bluetooth permissions and try again.',
      );
    }
  }

  void _setPhase(VehicleBlePhase phase, String? error) {
    if (_disposed) return;
    _phase = phase;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _scanTimeoutTimer?.cancel();
    _discoveredSubscription?.cancel();
    _connectionSubscription?.cancel();
    _notificationSubscription?.cancel();
    unawaited(_cancelWebSubscriptions());
    final peripheral = _peripheral;
    if (peripheral != null) unawaited(_disconnectPeripheral(peripheral));
    final webConnection = _webConnection;
    _webConnection = null;
    if (webConnection != null) unawaited(webConnection.close());
    if (_discoveryRunning) unawaited(_manager?.stopDiscovery());
    snapshot.dispose();
    super.dispose();
  }
}
