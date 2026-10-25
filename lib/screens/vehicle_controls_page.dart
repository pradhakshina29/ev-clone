import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import '../services/auth_service.dart';
import '../app_theme.dart';
import '../models/vehicle.dart';
import '../models/vehicle_controls.dart';
import '../services/api/api_client.dart';
import '../services/data_service.dart';
import '../services/vehicle_ble_client.dart';
import '../services/vehicle_controls_preferences_error.dart';
import '../services/vehicle_controls_preferences_store.dart';

class VehicleControlsPage extends StatefulWidget {
  const VehicleControlsPage({
    super.key,
    required this.vehicle,
    this.dataService,
    this.currentUid,
    this.preferencesStore,
  });

  final Vehicle vehicle;
  final DataService? dataService;

  /// Defaults to the app-wide store (or one built on [dataService] in tests).
  final VehicleControlsPreferencesStore? preferencesStore;

  /// The signed-in user's ID. Defaults to the app session; injectable for tests.
  final String? Function()? currentUid;

  @override
  State<VehicleControlsPage> createState() => _VehicleControlsPageState();
}

class _VehicleControlsPageState extends State<VehicleControlsPage> {
  late final VehicleControlsPreferencesStore _store =
      widget.preferencesStore ??
      (widget.dataService == null
          ? VehicleControlsPreferencesStore.shared
          : VehicleControlsPreferencesStore(widget.dataService!));
  final VehicleBleClient _ble = VehicleBleClient.shared;

  String? _currentUid() =>
      widget.currentUid?.call() ?? AuthService().currentUser?.uid;

  VehicleControlsPreferences _preferences = const VehicleControlsPreferences();
  bool _preferencesLoading = true;
  bool _preferencesSaving = false;
  String? _preferencesError;
  String? _preferencesSaveError;
  double? _pendingTemperature;
  final Map<VehicleDoor, double> _pendingWindowLevels = {};

  @override
  void initState() {
    super.initState();
    _ble.addListener(_onBleChanged);
    _store.addListener(_onStoreChanged);
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ble.inspectWebCapabilities());
      });
    }
    unawaited(_initialize());
  }

  Future<void> _initialize({bool refresh = false}) async {
    if (mounted) {
      setState(() {
        _preferencesLoading = true;
        _preferencesError = null;
      });
    }
    final uid = _currentUid();
    if (uid == null) {
      if (mounted) {
        setState(() {
          _preferencesLoading = false;
          _preferencesError = 'Sign in to use vehicle controls.';
        });
      }
      debugPrint(
        '[Vehicle Controls] Preferences read blocked: no signed-in user.',
      );
      return;
    }
    try {
      final preferences = await _store.load(
        uid,
        widget.vehicle.id,
        refresh: refresh,
      );
      if (!mounted) return;
      if (_currentUid() != uid) {
        await _ble.disconnect();
        return;
      }
      setState(() {
        _preferences = preferences;
        _preferencesLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint(
        '[Vehicle Controls] Preferences read failed '
        '${error is ApiException ? 'code=${error.code}' : 'errorType=${error.runtimeType}'}',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _preferencesLoading = false;
        _preferencesError = vehicleControlsPreferencesErrorMessage(error);
      });
      return;
    }
  }

  void _onBleChanged() {
    if (mounted) setState(() {});
  }

  /// Alerts are raised app-wide by VehicleAlertCoordinator; this keeps the
  /// history shown here in step with what it records.
  void _onStoreChanged() {
    final uid = _currentUid();
    if (uid == null || !mounted || _preferencesLoading) return;
    final stored = _store.cached(uid, widget.vehicle.id);
    if (stored == null ||
        (identical(stored.alertHistory, _preferences.alertHistory) &&
            identical(stored.activeAlertKeys, _preferences.activeAlertKeys))) {
      return;
    }
    setState(() {
      _preferences = _preferences.copyWith(
        alertHistory: stored.alertHistory,
        activeAlertKeys: stored.activeAlertKeys,
      );
    });
  }

  Future<void> _savePreferences({bool showError = true}) async {
    final uid = _currentUid();
    if (uid == null) {
      if (showError) _showMessage('Sign in again before saving preferences.');
      return;
    }
    final savedPreferences = _preferences;
    setState(() {
      _preferencesSaving = true;
      _preferencesSaveError = null;
    });
    try {
      await _store.saveSettings(uid, widget.vehicle.id, savedPreferences);
    } catch (error) {
      debugPrint(
        '[Vehicle Controls] Preference write failed '
        '${error is ApiException ? 'code=${error.code}' : 'errorType=${error.runtimeType}'}',
      );
      if (!mounted) return;
      setState(
        () => _preferencesSaveError =
            'Preferences could not be saved. Check your connection and retry.',
      );
      if (showError) _showMessage('Could not save controls preferences.');
    } finally {
      if (mounted) setState(() => _preferencesSaving = false);
    }
  }

  void _updatePreferences(VehicleControlsPreferences value) {
    setState(() => _preferences = value);
    unawaited(_savePreferences());
  }

  Future<void> _send(
    String action, {
    VehicleDoor? door,
    bool? enabled,
    int? level,
    double? temperatureC,
  }) async {
    if (!_ble.isConnected || _ble.vehicleId != widget.vehicle.id) {
      _showMessage('Connect this vehicle before sending a command.');
      return;
    }
    try {
      await _ble.send(
        VehicleControlCommand(
          requestId: DateTime.now().microsecondsSinceEpoch.toString(),
          action: action,
          door: door,
          enabled: enabled,
          level: level,
          temperatureC: temperatureC,
        ),
      );
    } on VehicleSafetyException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      _showMessage('The vehicle command failed: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addPassengerProfile() async {
    if (_preferences.passengerProfiles.length >= 20) {
      _showMessage(
        'A maximum of 20 passenger profiles can be saved per vehicle.',
      );
      return;
    }
    final profile = await showDialog<PassengerProfile>(
      context: context,
      builder: (context) => const _PassengerProfileDialog(),
    );
    if (profile == null) return;
    final selectedProfile = profile.copyWith(lastUsedAt: DateTime.now());
    final profiles = [..._preferences.passengerProfiles, selectedProfile];
    setState(() {
      _preferences = _preferences.copyWith(
        passengerProfiles: profiles,
        selectedProfileId: selectedProfile.id,
      );
    });
    await _savePreferences();
    await _applyProfile(selectedProfile);
  }

  Future<void> _editPassengerProfile(PassengerProfile profile) async {
    final updatedProfile = await showDialog<PassengerProfile>(
      context: context,
      builder: (context) => _PassengerProfileDialog(initialProfile: profile),
    );
    if (updatedProfile == null) return;
    setState(() {
      _preferences = _preferences.copyWith(
        passengerProfiles: [
          for (final item in _preferences.passengerProfiles)
            if (item.id == profile.id) updatedProfile else item,
        ],
      );
    });
    await _savePreferences();
    if (_preferences.selectedProfileId == profile.id) {
      await _applyProfile(updatedProfile);
    }
  }

  Future<void> _selectPassengerProfile(PassengerProfile profile) async {
    final selectedProfile = profile.copyWith(lastUsedAt: DateTime.now());
    setState(() {
      _preferences = _preferences.copyWith(
        passengerProfiles: [
          for (final item in _preferences.passengerProfiles)
            if (item.id == profile.id) selectedProfile else item,
        ],
        selectedProfileId: profile.id,
      );
    });
    await _savePreferences();
    await _applyProfile(selectedProfile);
  }

  Future<void> _applyProfile(PassengerProfile profile) async {
    if (!_ble.isConnected || _ble.vehicleId != widget.vehicle.id) return;
    await _send('climate', enabled: true);
    await _send(
      'targetTemperature',
      temperatureC: profile.preferredTemperatureC.toDouble(),
    );
    await _send('fanLevel', level: profile.fanLevel);
    await _send('seatHeating', enabled: profile.seatHeating);
  }

  Future<void> _deletePassengerProfile(PassengerProfile profile) async {
    final profiles = _preferences.passengerProfiles
        .where((item) => item.id != profile.id)
        .toList(growable: false);
    setState(() {
      _preferences = _preferences.copyWith(
        passengerProfiles: profiles,
        clearSelectedProfileId: _preferences.selectedProfileId == profile.id,
      );
    });
    await _savePreferences();
  }

  Future<void> _showNotificationSettings() async {
    final result = await showModalBottomSheet<VehicleControlsPreferences>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _NotificationSettingsSheet(preferences: _preferences),
    );
    if (result != null) _updatePreferences(result);
  }

  @override
  void dispose() {
    _ble.removeListener(_onBleChanged);
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTheme.background,
    appBar: AppBar(
      title: const Text('Vehicle controls'),
      backgroundColor: AppTheme.background,
      actions: [
        IconButton(
          tooltip: 'Alert settings',
          onPressed: _showNotificationSettings,
          icon: const Icon(Icons.notifications_active_outlined),
        ),
      ],
    ),
    body: _preferencesLoading
        ? const Center(child: CircularProgressIndicator())
        : _preferencesError != null
        ? _PageError(
            message: _preferencesError!,
            onRetry: () => _initialize(refresh: true),
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 920;
              final content = _buildDashboard(wide);
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: content,
                ),
              );
            },
          ),
  );

  Widget _buildDashboard(bool wide) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 16, wide ? 28 : 16, 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PageHeading(vehicle: widget.vehicle, saving: _preferencesSaving),
        if (_preferencesSaveError != null) ...[
          const SizedBox(height: 8),
          _InlineError(message: _preferencesSaveError!),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _savePreferences(),
              child: const Text('Retry saving'),
            ),
          ),
        ],
        const SizedBox(height: 14),
        AnimatedBuilder(
          animation: _ble,
          builder: (context, _) {
            final matchesVehicle = _ble.vehicleId == widget.vehicle.id;
            return _BleStatusCard(
              phase: matchesVehicle ? _ble.phase : VehicleBlePhase.stopped,
              error: matchesVehicle ? _ble.error : null,
              recoveryAction: matchesVehicle ? _ble.recoveryAction : null,
              onRecover: () => unawaited(_ble.performRecoveryAction()),
              onRetry: () => _ble.start(
                widget.vehicle.id,
                deviceName: widget.vehicle.bluetoothDeviceName,
              ),
              onConnect: () => _ble.start(
                widget.vehicle.id,
                deviceName: widget.vehicle.bluetoothDeviceName,
              ),
              onDisconnect: () => unawaited(_ble.disconnect()),
              isWeb: kIsWeb,
              webBluetoothSupported: kIsWeb && _ble.isSupported,
              secureContext: _ble.secureContext,
              policyStatus: _ble.bluetoothPolicyStatus,
              availabilityStatus: _ble.availabilityStatus,
              availabilityError: _ble.availabilityError,
              deviceName: matchesVehicle ? _ble.selectedDeviceName : null,
              lastDataUpdate: matchesVehicle ? _ble.lastDataUpdate : null,
            );
          },
        ),
        if (kIsWeb) ...[const SizedBox(height: 8), const _WebBleNotice()],
        const SizedBox(height: 14),
        ValueListenableBuilder<VehicleStateSnapshot?>(
          valueListenable: _ble.snapshot,
          builder: (context, liveSnapshot, _) {
            final connected =
                _ble.isConnected && _ble.vehicleId == widget.vehicle.id;
            final matchingSnapshot =
                liveSnapshot?.vehicleId == widget.vehicle.id
                ? liveSnapshot
                : null;
            final state = matchingSnapshot?.state;
            final statusPanel = _VehicleStatusPanel(state: state);
            final vehiclePanel = _VehicleDoorPanel(
              state: state,
              enabled: connected,
              speedKph: state?.speedKph ?? 0,
              pendingWindowLevels: _pendingWindowLevels,
              onDoorOpenChanged: (door, open) =>
                  _send('doorOpen', door: door, enabled: open),
              onDoorLockChanged: (door, locked) =>
                  _send('doorLock', door: door, enabled: locked),
              onWindowChanged: (door, level) =>
                  setState(() => _pendingWindowLevels[door] = level),
              onWindowChangeEnd: (door, level) {
                setState(() => _pendingWindowLevels.remove(door));
                unawaited(
                  _send('windowLevel', door: door, level: level.round()),
                );
              },
            );
            final quickControls = _VehicleActionsPanel(
              state: state,
              enabled: connected,
              onVehicleOnChanged: (value) => _send('vehicleOn', enabled: value),
              onHeadlightsChanged: (value) =>
                  _send('headlights', enabled: value),
            );
            final climatePanel = _ClimatePanel(
              state: state,
              enabled: connected,
              pendingTemperature: _pendingTemperature,
              onTemperatureChanged: (value) =>
                  setState(() => _pendingTemperature = value),
              onTemperatureChangeEnd: (value) {
                setState(() => _pendingTemperature = null);
                unawaited(_send('targetTemperature', temperatureC: value));
              },
              onClimateChanged: (enabled) => _send('climate', enabled: enabled),
              onFanChanged: (level) => _send('fanLevel', level: level),
              onSeatHeatingChanged: (enabled) =>
                  _send('seatHeating', enabled: enabled),
            );
            final chargingPanel = _ChargingPanel(
              state: state,
              enabled: connected,
              onChargingChanged: (connected) =>
                  _send('chargingConnected', enabled: connected),
              onTargetChanged: (value) => _send('targetCharge', level: value),
            );

            return Column(
              children: [
                statusPanel,
                const SizedBox(height: 14),
                quickControls,
                const SizedBox(height: 14),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: vehiclePanel),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          children: [
                            climatePanel,
                            const SizedBox(height: 14),
                            chargingPanel,
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  vehiclePanel,
                  const SizedBox(height: 14),
                  climatePanel,
                  const SizedBox(height: 14),
                  chargingPanel,
                ],
                const SizedBox(height: 14),
                _PassengerProfilesPanel(
                  preferences: _preferences,
                  enabled: connected,
                  onAdd: _addPassengerProfile,
                  onEdit: _editPassengerProfile,
                  onSelected: _selectPassengerProfile,
                  onDelete: _deletePassengerProfile,
                ),
                const SizedBox(height: 14),
                _AlertsPanel(
                  preferences: _preferences,
                  onSettings: _showNotificationSettings,
                ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.vehicle, required this.saving});

  final Vehicle vehicle;
  final bool saving;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              vehicle.model.isEmpty ? 'Your vehicle' : vehicle.model,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppTheme.navy,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              vehicle.registrationNumber,
              style: const TextStyle(color: AppTheme.mutedBlue),
            ),
            const SizedBox(height: 4),
            SelectableText(
              'Vehicle ID for simulator: ${vehicle.id}',
              style: const TextStyle(color: AppTheme.mutedBlue, fontSize: 11),
            ),
          ],
        ),
      ),
      if (saving)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
    ],
  );
}

class _BleStatusCard extends StatelessWidget {
  const _BleStatusCard({
    required this.phase,
    required this.error,
    required this.recoveryAction,
    required this.onRecover,
    required this.onRetry,
    required this.onConnect,
    required this.onDisconnect,
    required this.isWeb,
    required this.webBluetoothSupported,
    required this.secureContext,
    required this.policyStatus,
    required this.availabilityStatus,
    required this.availabilityError,
    required this.deviceName,
    required this.lastDataUpdate,
  });

  final VehicleBlePhase phase;
  final String? error;
  final VehicleBleRecoveryAction? recoveryAction;
  final VoidCallback onRecover;
  final VoidCallback onRetry;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final bool isWeb;
  final bool webBluetoothSupported;
  final bool? secureContext;
  final String? policyStatus;
  final String? availabilityStatus;
  final String? availabilityError;
  final String? deviceName;
  final DateTime? lastDataUpdate;

  @override
  Widget build(BuildContext context) {
    final connected = phase == VehicleBlePhase.connected;
    final message = switch (phase) {
      VehicleBlePhase.unsupported =>
        isWeb
            ? !webBluetoothSupported
                  ? 'Web Bluetooth API is unavailable. Use desktop Chrome or Edge on a supported operating system.'
                  : secureContext == false
                  ? 'Web Bluetooth requires HTTPS or localhost.'
                  : policyStatus == 'blocked'
                  ? 'This page is blocked from using Bluetooth by its permissions policy.'
                  : error ??
                        'Web Bluetooth is unavailable in this page context.'
            : 'Bluetooth vehicle connection requires a physical Android device.',
      VehicleBlePhase.authorizing => 'Requesting Bluetooth permission…',
      VehicleBlePhase.scanning =>
        isWeb
            ? 'Searching for the vehicle…'
            : 'Looking for the EV Vehicle Simulator…',
      VehicleBlePhase.selectingDevice =>
        'Select the EV simulator in Chrome’s Bluetooth device chooser…',
      VehicleBlePhase.connecting => 'Connecting to the vehicle simulator…',
      VehicleBlePhase.gattConnected =>
        'GATT connected · preparing service discovery…',
      VehicleBlePhase.discoveringServices =>
        'GATT connected · discovering vehicle service…',
      VehicleBlePhase.discoveringCharacteristics =>
        'Vehicle service found · discovering characteristics…',
      VehicleBlePhase.subscribingNotifications =>
        'Characteristics found · subscribing to telemetry…',
      VehicleBlePhase.awaitingTelemetry =>
        'Connected — waiting for vehicle data',
      VehicleBlePhase.identityMismatch =>
        error ??
            'Simulator vehicle identity does not match the selected vehicle.',
      VehicleBlePhase.connected => 'Connected · receiving live vehicle state',
      VehicleBlePhase.reconnecting => 'Connection interrupted · reconnecting…',
      VehicleBlePhase.error => error ?? 'Bluetooth connection failed.',
      VehicleBlePhase.stopped => 'Vehicle simulator is not connected.',
    };
    final color = connected
        ? const Color(0xFF13845A)
        : phase == VehicleBlePhase.awaitingTelemetry
        ? const Color(0xFFB26A00)
        : phase == VehicleBlePhase.identityMismatch
        ? Colors.red.shade700
        : AppTheme.mutedBlue;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(
              connected
                  ? Icons.bluetooth_connected_rounded
                  : Icons.bluetooth_searching_rounded,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      color: error != null
                          ? Colors.red.shade700
                          : AppTheme.navy,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (recoveryAction != null)
                    TextButton.icon(
                      onPressed: onRecover,
                      icon: const Icon(Icons.settings, size: 18),
                      label: Text(
                        recoveryAction ==
                                VehicleBleRecoveryAction.openLocationSettings
                            ? 'Turn on Location'
                            : 'Open settings',
                      ),
                    ),
                  if (deviceName != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      'Selected device: $deviceName',
                      style: const TextStyle(
                        color: AppTheme.mutedBlue,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  Text(
                    lastDataUpdate == null
                        ? 'Last BLE update: none received'
                        : 'Last BLE update: ${_formatDataTime(lastDataUpdate!)}',
                    style: const TextStyle(
                      color: AppTheme.mutedBlue,
                      fontSize: 12,
                    ),
                  ),
                  if (isWeb) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Web Bluetooth API: ${webBluetoothSupported ? 'available' : 'missing'} · '
                      'Secure context: ${secureContext == null
                          ? 'checking'
                          : secureContext!
                          ? 'yes'
                          : 'no'} · '
                      'Bluetooth: ${availabilityStatus ?? (availabilityError == null ? 'checking' : 'unknown')} · '
                      'Page policy: ${policyStatus ?? 'checking'}',
                      style: const TextStyle(
                        color: AppTheme.mutedBlue,
                        fontSize: 11,
                      ),
                    ),
                    if (availabilityError != null)
                      Text(
                        'Availability check error: $availabilityError',
                        style: TextStyle(
                          color: Colors.orange.shade900,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ],
              ),
            ),
            if (connected)
              TextButton(
                onPressed: onDisconnect,
                child: const Text('Disconnect'),
              )
            else if (isWeb &&
                phase != VehicleBlePhase.unsupported &&
                phase != VehicleBlePhase.selectingDevice &&
                phase != VehicleBlePhase.connecting &&
                phase != VehicleBlePhase.gattConnected &&
                phase != VehicleBlePhase.discoveringServices &&
                phase != VehicleBlePhase.discoveringCharacteristics &&
                phase != VehicleBlePhase.subscribingNotifications &&
                phase != VehicleBlePhase.awaitingTelemetry)
              FilledButton(
                onPressed: onConnect,
                child: Text(
                  phase == VehicleBlePhase.identityMismatch
                      ? 'Retry after correcting ID'
                      : phase == VehicleBlePhase.reconnecting
                      ? 'Reconnect'
                      : 'Connect Vehicle',
                ),
              )
            else if (phase == VehicleBlePhase.error ||
                phase == VehicleBlePhase.stopped ||
                phase == VehicleBlePhase.reconnecting)
              TextButton(
                onPressed: onRetry,
                child: Text(
                  phase == VehicleBlePhase.reconnecting
                      ? 'Reconnect now'
                      : phase == VehicleBlePhase.stopped
                      ? 'Connect Vehicle'
                      : 'Retry',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _formatDataTime(DateTime timestamp) {
  final local = timestamp.toLocal();
  final time = TimeOfDay.fromDateTime(local);
  final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
  return '$hour:${time.minute.toString().padLeft(2, '0')} '
      '${time.period == DayPeriod.am ? 'AM' : 'PM'}';
}

class _WebBleNotice extends StatelessWidget {
  const _WebBleNotice();

  @override
  Widget build(BuildContext context) => const Text(
    'Use current desktop Chrome or Edge on HTTPS or localhost, with Bluetooth enabled. Open the app directly if an embedded page blocks Bluetooth. Connection starts only when you click Connect Vehicle and choose the simulator.',
    style: TextStyle(color: AppTheme.mutedBlue, height: 1.4),
  );
}

class _VehicleStatusPanel extends StatelessWidget {
  const _VehicleStatusPanel({required this.state});

  final VehicleControlState? state;

  @override
  Widget build(BuildContext context) {
    final values = [
      _Metric(
        'Battery',
        state == null ? '—' : '${state!.batteryPercent.round()}%',
        Icons.battery_charging_full_rounded,
      ),
      _Metric(
        'Range',
        state == null ? '—' : '${state!.rangeKm.round()} km',
        Icons.route_rounded,
      ),
      _Metric(
        'Speed',
        state == null ? '—' : '${state!.speedKph.round()} km/h',
        Icons.speed_rounded,
      ),
      _Metric(
        'Charging',
        state == null
            ? '—'
            : state!.chargingConnected
            ? 'Charging'
            : 'Not charging',
        Icons.ev_station_rounded,
      ),
    ];
    return _Panel(
      title: 'Vehicle status',
      subtitle: state == null
          ? 'Awaiting a validated BLE state notification from the simulator.'
          : 'Simulator-generated live values · received over BLE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth < 440 ? 2 : 4;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final metric in values)
                    SizedBox(
                      width:
                          (constraints.maxWidth - (columns - 1) * 8) / columns,
                      child: _MetricTile(metric: metric),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Metric {
  const _Metric(this.label, this.value, this.icon);

  final String label;
  final String value;
  final IconData icon;
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric});

  final _Metric metric;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFF3F7FA),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Icon(metric.icon, size: 19, color: AppTheme.blue),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                metric.label,
                style: const TextStyle(fontSize: 11, color: AppTheme.mutedBlue),
              ),
              const SizedBox(height: 3),
              Text(
                metric.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _VehicleActionsPanel extends StatelessWidget {
  const _VehicleActionsPanel({
    required this.state,
    required this.enabled,
    required this.onVehicleOnChanged,
    required this.onHeadlightsChanged,
  });

  final VehicleControlState? state;
  final bool enabled;
  final ValueChanged<bool> onVehicleOnChanged;
  final ValueChanged<bool> onHeadlightsChanged;

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Vehicle',
    subtitle: 'Power and exterior lighting',
    child: Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Vehicle power'),
          subtitle: Text(state?.vehicleOn == true ? 'Ready' : 'Off'),
          value: state?.vehicleOn ?? false,
          onChanged: enabled ? onVehicleOnChanged : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Headlights'),
          value: state?.lightsOn ?? false,
          onChanged: enabled ? onHeadlightsChanged : null,
        ),
      ],
    ),
  );
}

class _VehicleDoorPanel extends StatelessWidget {
  const _VehicleDoorPanel({
    required this.state,
    required this.enabled,
    required this.speedKph,
    required this.pendingWindowLevels,
    required this.onDoorOpenChanged,
    required this.onDoorLockChanged,
    required this.onWindowChanged,
    required this.onWindowChangeEnd,
  });

  final VehicleControlState? state;
  final bool enabled;
  final double speedKph;
  final Map<VehicleDoor, double> pendingWindowLevels;
  final void Function(VehicleDoor door, bool open) onDoorOpenChanged;
  final void Function(VehicleDoor door, bool locked) onDoorLockChanged;
  final void Function(VehicleDoor door, double level) onWindowChanged;
  final void Function(VehicleDoor door, double level) onWindowChangeEnd;

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Doors and windows',
    subtitle:
        'Four individually controlled doors · opening is disabled while moving',
    child: Column(
      children: [
        _VehicleDoorDiagram(
          state: state,
          enabled: enabled,
          speedKph: speedKph,
          onDoorChanged: onDoorOpenChanged,
        ),
        const SizedBox(height: 14),
        for (final door in VehicleDoor.values)
          _DoorRow(
            door: door,
            state: state?.doors[door] ?? const VehicleDoorState(),
            windowLevel: state?.windows[door] ?? 0,
            pendingWindowLevel: pendingWindowLevels[door],
            enabled: enabled,
            moving: speedKph > 0,
            onDoorChanged: (open) => onDoorOpenChanged(door, open),
            onLockChanged: (locked) => onDoorLockChanged(door, locked),
            onWindowChanged: (level) => onWindowChanged(door, level),
            onWindowChangeEnd: (level) => onWindowChangeEnd(door, level),
          ),
      ],
    ),
  );
}

class _VehicleDoorDiagram extends StatelessWidget {
  const _VehicleDoorDiagram({
    required this.state,
    required this.enabled,
    required this.speedKph,
    required this.onDoorChanged,
  });

  final VehicleControlState? state;
  final bool enabled;
  final double speedKph;
  final void Function(VehicleDoor door, bool open) onDoorChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final carWidth = (width * 0.30).clamp(104.0, 154.0);
      final doorWidth = ((width - carWidth - 28) / 2).clamp(82.0, 118.0);
      return SizedBox(
        height: 226,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: carWidth,
              height: 196,
              decoration: BoxDecoration(
                color: const Color(0xFF162A40),
                borderRadius: BorderRadius.circular(carWidth / 2),
                border: Border.all(color: const Color(0xFF92A7BA), width: 3),
              ),
            ),
            Positioned(
              top: 54,
              child: Container(
                width: carWidth * 0.64,
                height: 43,
                decoration: BoxDecoration(
                  color: const Color(0xFF8EC5E7),
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            Positioned(
              bottom: 54,
              child: Container(
                width: carWidth * 0.64,
                height: 43,
                decoration: BoxDecoration(
                  color: const Color(0xFF8EC5E7),
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            Positioned(
              top: 63,
              left: 4,
              child: _DoorDiagramButton(
                door: VehicleDoor.frontLeft,
                state: state?.doors[VehicleDoor.frontLeft],
                width: doorWidth,
                enabled: enabled,
                canOpen: speedKph <= 0,
                onChanged: onDoorChanged,
              ),
            ),
            Positioned(
              top: 63,
              right: 4,
              child: _DoorDiagramButton(
                door: VehicleDoor.frontRight,
                state: state?.doors[VehicleDoor.frontRight],
                width: doorWidth,
                enabled: enabled,
                canOpen: speedKph <= 0,
                onChanged: onDoorChanged,
              ),
            ),
            Positioned(
              bottom: 51,
              left: 4,
              child: _DoorDiagramButton(
                door: VehicleDoor.rearLeft,
                state: state?.doors[VehicleDoor.rearLeft],
                width: doorWidth,
                enabled: enabled,
                canOpen: speedKph <= 0,
                onChanged: onDoorChanged,
              ),
            ),
            Positioned(
              bottom: 51,
              right: 4,
              child: _DoorDiagramButton(
                door: VehicleDoor.rearRight,
                state: state?.doors[VehicleDoor.rearRight],
                width: doorWidth,
                enabled: enabled,
                canOpen: speedKph <= 0,
                onChanged: onDoorChanged,
              ),
            ),
            if (state == null)
              const Positioned(
                bottom: 4,
                child: Text(
                  'Connect simulator to control doors',
                  style: TextStyle(color: AppTheme.mutedBlue, fontSize: 11),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _DoorDiagramButton extends StatelessWidget {
  const _DoorDiagramButton({
    required this.door,
    required this.state,
    required this.width,
    required this.enabled,
    required this.canOpen,
    required this.onChanged,
  });

  final VehicleDoor door;
  final VehicleDoorState? state;
  final double width;
  final bool enabled;
  final bool canOpen;
  final void Function(VehicleDoor door, bool open) onChanged;

  @override
  Widget build(BuildContext context) {
    final isOpen = state?.open ?? false;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: enabled && (!isOpen ? canOpen : true)
            ? () => onChanged(door, !isOpen)
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
          decoration: BoxDecoration(
            color: isOpen
                ? const Color(0xFFFFEBCF)
                : enabled
                ? const Color(0xFFE4F3ED)
                : const Color(0xFFE8EDF1),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: isOpen ? Colors.orange : const Color(0xFFB8C9D7),
            ),
          ),
          child: Column(
            children: [
              AnimatedRotation(
                turns: isOpen
                    ? (door == VehicleDoor.frontLeft ||
                              door == VehicleDoor.rearLeft
                          ? -0.08
                          : 0.08)
                    : 0,
                duration: const Duration(milliseconds: 220),
                child: Icon(
                  isOpen ? Icons.door_sliding_outlined : Icons.sensor_door,
                  size: 20,
                  color: isOpen ? Colors.deepOrange : AppTheme.blue,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                switch (door) {
                  VehicleDoor.frontLeft => 'Front L',
                  VehicleDoor.frontRight => 'Front R',
                  VehicleDoor.rearLeft => 'Rear L',
                  VehicleDoor.rearRight => 'Rear R',
                },
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                isOpen ? 'OPEN' : 'CLOSED',
                style: TextStyle(
                  fontSize: 9,
                  color: isOpen ? Colors.deepOrange : AppTheme.mutedBlue,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DoorRow extends StatelessWidget {
  const _DoorRow({
    required this.door,
    required this.state,
    required this.windowLevel,
    required this.pendingWindowLevel,
    required this.enabled,
    required this.moving,
    required this.onDoorChanged,
    required this.onLockChanged,
    required this.onWindowChanged,
    required this.onWindowChangeEnd,
  });

  final VehicleDoor door;
  final VehicleDoorState state;
  final int windowLevel;
  final double? pendingWindowLevel;
  final bool enabled;
  final bool moving;
  final ValueChanged<bool> onDoorChanged;
  final ValueChanged<bool> onLockChanged;
  final ValueChanged<double> onWindowChanged;
  final ValueChanged<double> onWindowChangeEnd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                door.label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: enabled && (state.open || !moving)
                  ? () => onDoorChanged(!state.open)
                  : null,
              child: Text(state.open ? 'Close' : 'Open'),
            ),
            IconButton(
              tooltip: state.locked ? 'Unlock' : 'Lock',
              onPressed: enabled ? () => onLockChanged(!state.locked) : null,
              icon: Icon(
                state.locked ? Icons.lock_outline : Icons.lock_open_rounded,
              ),
            ),
            Text(
              '${(pendingWindowLevel ?? windowLevel.toDouble()).round()}%',
              style: const TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
            ),
          ],
        ),
        Slider(
          value: (pendingWindowLevel ?? windowLevel.toDouble())
              .clamp(0, 100)
              .toDouble(),
          max: 100,
          divisions: 10,
          label: '${(pendingWindowLevel ?? windowLevel.toDouble()).round()}%',
          onChanged: enabled ? onWindowChanged : null,
          onChangeEnd: enabled ? onWindowChangeEnd : null,
        ),
      ],
    ),
  );
}

class _ClimatePanel extends StatelessWidget {
  const _ClimatePanel({
    required this.state,
    required this.enabled,
    required this.pendingTemperature,
    required this.onTemperatureChanged,
    required this.onTemperatureChangeEnd,
    required this.onClimateChanged,
    required this.onFanChanged,
    required this.onSeatHeatingChanged,
  });

  final VehicleControlState? state;
  final bool enabled;
  final double? pendingTemperature;
  final ValueChanged<double> onTemperatureChanged;
  final ValueChanged<double> onTemperatureChangeEnd;
  final ValueChanged<bool> onClimateChanged;
  final ValueChanged<int> onFanChanged;
  final ValueChanged<bool> onSeatHeatingChanged;

  @override
  Widget build(BuildContext context) {
    final climateOn = state?.climateOn ?? false;
    // The fallbacks only position disabled widgets; labels show '—' instead.
    final liveTemperature = pendingTemperature ?? state?.targetTemperatureC;
    final temperature = liveTemperature ?? 21;
    final temperatureLabel = liveTemperature == null
        ? '—'
        : '${liveTemperature.round()} °C';
    return _Panel(
      title: 'Climate',
      subtitle: enabled
          ? 'Cabin climate controls'
          : 'Connect the simulator to adjust climate',
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Climate system'),
            value: climateOn,
            onChanged: enabled ? onClimateChanged : null,
          ),
          Row(
            children: [
              const Expanded(child: Text('Target temperature')),
              Text(temperatureLabel),
            ],
          ),
          Slider(
            value: temperature.clamp(16, 30).toDouble(),
            min: 16,
            max: 30,
            divisions: 14,
            label: temperatureLabel,
            onChanged: enabled ? onTemperatureChanged : null,
            onChangeEnd: enabled ? onTemperatureChangeEnd : null,
          ),
          Row(
            children: [
              const Expanded(child: Text('Fan speed')),
              DropdownButton<int>(
                value: state?.fanLevel.clamp(0, 5).toInt(),
                hint: const Text('—'),
                items: [
                  for (var level = 0; level <= 5; level++)
                    DropdownMenuItem(value: level, child: Text('$level')),
                ],
                onChanged: enabled && state != null
                    ? (value) {
                        if (value != null) onFanChanged(value);
                      }
                    : null,
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Seat heating'),
            value: state?.seatHeatingEnabled ?? false,
            onChanged: enabled ? onSeatHeatingChanged : null,
          ),
        ],
      ),
    );
  }
}

class _ChargingPanel extends StatelessWidget {
  const _ChargingPanel({
    required this.state,
    required this.enabled,
    required this.onChargingChanged,
    required this.onTargetChanged,
  });

  final VehicleControlState? state;
  final bool enabled;
  final ValueChanged<bool> onChargingChanged;
  final ValueChanged<int> onTargetChanged;

  @override
  Widget build(BuildContext context) {
    final connected = state?.chargingConnected ?? false;
    // The fallback only positions the disabled slider; the label shows '—'.
    final target = state?.targetChargePercent ?? 80;
    final targetLabel = state == null ? '—' : '$target%';
    return _Panel(
      title: 'Charging',
      subtitle: 'Charging state reported by the connected simulator',
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Charger connected'),
            subtitle: Text(
              state == null
                  ? '—'
                  : connected
                  ? '${state!.chargingPowerKw.toStringAsFixed(1)} kW'
                  : 'Not charging',
            ),
            value: connected,
            onChanged: enabled ? onChargingChanged : null,
          ),
          Row(
            children: [
              const Expanded(child: Text('Charge target')),
              Text(targetLabel),
            ],
          ),
          Slider(
            value: target.toDouble(),
            min: 50,
            max: 100,
            divisions: 10,
            label: targetLabel,
            onChanged: enabled && state != null
                ? (value) => onTargetChanged(value.round())
                : null,
          ),
        ],
      ),
    );
  }
}

class _PassengerProfilesPanel extends StatelessWidget {
  const _PassengerProfilesPanel({
    required this.preferences,
    required this.enabled,
    required this.onAdd,
    required this.onEdit,
    required this.onSelected,
    required this.onDelete,
  });

  final VehicleControlsPreferences preferences;
  final bool enabled;
  final VoidCallback onAdd;
  final ValueChanged<PassengerProfile> onEdit;
  final ValueChanged<PassengerProfile> onSelected;
  final ValueChanged<PassengerProfile> onDelete;

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Passenger profiles',
    subtitle: 'Saved for this vehicle',
    trailing: IconButton(
      tooltip: 'Add passenger profile',
      onPressed: onAdd,
      icon: const Icon(Icons.person_add_alt_1_rounded),
    ),
    child: preferences.passengerProfiles.isEmpty
        ? const Text(
            'Add a profile to save preferred cabin temperature and fan settings.',
            style: TextStyle(color: AppTheme.mutedBlue),
          )
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final profile in preferences.passengerProfiles)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InputChip(
                      label: Text(
                        '${profile.name} · ${profile.role} · ${profile.seatPosition}',
                      ),
                      tooltip: [
                        'Mirrors L(${profile.leftMirrorHorizontal.round()},'
                            '${profile.leftMirrorVertical.round()}) '
                            'R(${profile.rightMirrorHorizontal.round()},'
                            '${profile.rightMirrorVertical.round()})',
                        profile.lastUsedAt == null
                            ? 'Not used yet'
                            : 'Last used ${profile.lastUsedAt!.toLocal()}',
                      ].join(' · '),
                      selected: profile.id == preferences.selectedProfileId,
                      onPressed: enabled ? () => onSelected(profile) : null,
                      onDeleted: () => onDelete(profile),
                      avatar: const Icon(Icons.person_outline, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Edit ${profile.name}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onEdit(profile),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                  ],
                ),
            ],
          ),
  );
}

class _AlertsPanel extends StatelessWidget {
  const _AlertsPanel({required this.preferences, required this.onSettings});

  final VehicleControlsPreferences preferences;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Alerts and history',
    subtitle: 'Safety, battery and charging notifications',
    trailing: TextButton(onPressed: onSettings, child: const Text('Settings')),
    child: preferences.alertHistory.isEmpty
        ? const _EmptyAlerts()
        : Column(
            children: [
              for (final alert in preferences.alertHistory.take(6))
                _AlertTile(alert: alert),
              if (preferences.alertHistory.length > 6)
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${preferences.alertHistory.length - 6} earlier alerts saved',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.mutedBlue,
                    ),
                  ),
                ),
            ],
          ),
  );
}

class _EmptyAlerts extends StatelessWidget {
  const _EmptyAlerts();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 14),
    child: Row(
      children: [
        Icon(Icons.check_circle_outline, color: Color(0xFF168266)),
        SizedBox(width: 10),
        Expanded(child: Text('No vehicle alerts have been recorded.')),
      ],
    ),
  );
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.alert});

  final VehicleAlert alert;

  String _acknowledgement() {
    String time(DateTime value) =>
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}:'
        '${value.second.toString().padLeft(2, '0')}';
    final shown = alert.shownAt;
    final acknowledged = alert.acknowledgedAt;
    if (shown == null) return 'Not shown (alerts off)';
    if (acknowledged == null) return 'Shown ${time(shown)} · not acknowledged';
    return 'Shown ${time(shown)} · Acknowledged ${time(acknowledged)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = switch (alert.severity) {
      VehicleAlertSeverity.critical => const Color(0xFFCC3445),
      VehicleAlertSeverity.warning => const Color(0xFFCC8128),
      VehicleAlertSeverity.info => AppTheme.blue,
    };
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        switch (alert.severity) {
          VehicleAlertSeverity.critical => Icons.error_outline_rounded,
          VehicleAlertSeverity.warning => Icons.warning_amber_rounded,
          VehicleAlertSeverity.info => Icons.info_outline_rounded,
        },
        color: color,
      ),
      title: Text(alert.title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        [
          alert.value == null
              ? alert.message
              : '${alert.message} (${alert.value})',
          if (alert.requiresAcknowledgement) _acknowledgement(),
        ].join('\n'),
      ),
      trailing: Text(
        TimeOfDay.fromDateTime(alert.timestamp).format(context),
        style: const TextStyle(fontSize: 11, color: AppTheme.mutedBlue),
      ),
    );
  }
}

class _NotificationSettingsSheet extends StatefulWidget {
  const _NotificationSettingsSheet({required this.preferences});

  final VehicleControlsPreferences preferences;

  @override
  State<_NotificationSettingsSheet> createState() =>
      _NotificationSettingsSheetState();
}

class _NotificationSettingsSheetState
    extends State<_NotificationSettingsSheet> {
  late VehicleControlsPreferences _value = widget.preferences;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Alert settings', style: Theme.of(context).textTheme.titleLarge),
          SwitchListTile(
            title: const Text('In-app notifications'),
            value: _value.notificationsEnabled,
            onChanged: (enabled) => setState(
              () => _value = _value.copyWith(notificationsEnabled: enabled),
            ),
          ),
          SwitchListTile(
            title: const Text('Safety alerts'),
            value: _value.safetyAlertsEnabled,
            onChanged: (enabled) => setState(
              () => _value = _value.copyWith(safetyAlertsEnabled: enabled),
            ),
          ),
          SwitchListTile(
            title: const Text('Battery alerts'),
            value: _value.batteryAlertsEnabled,
            onChanged: (enabled) => setState(
              () => _value = _value.copyWith(batteryAlertsEnabled: enabled),
            ),
          ),
          SwitchListTile(
            title: const Text('Charging alerts'),
            value: _value.chargingAlertsEnabled,
            onChanged: (enabled) => setState(
              () => _value = _value.copyWith(chargingAlertsEnabled: enabled),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, _value),
              child: const Text('Save settings'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PassengerProfileDialog extends StatefulWidget {
  const _PassengerProfileDialog({this.initialProfile});

  final PassengerProfile? initialProfile;

  @override
  State<_PassengerProfileDialog> createState() =>
      _PassengerProfileDialogState();
}

class _PassengerProfileDialogState extends State<_PassengerProfileDialog> {
  final TextEditingController _name = TextEditingController();
  double _temperature = 21;
  int _fanLevel = 1;
  bool _seatHeating = false;
  String _role = 'passenger';
  String _seatPosition = 'frontLeft';
  double _leftMirrorHorizontal = 0;
  double _leftMirrorVertical = 0;
  double _rightMirrorHorizontal = 0;
  double _rightMirrorVertical = 0;

  @override
  void initState() {
    super.initState();
    final profile = widget.initialProfile;
    if (profile == null) return;
    _name.text = profile.name;
    _temperature = profile.preferredTemperatureC.toDouble();
    _fanLevel = profile.fanLevel;
    _seatHeating = profile.seatHeating;
    _role = profile.role;
    _seatPosition = profile.seatPosition;
    _leftMirrorHorizontal = profile.leftMirrorHorizontal;
    _leftMirrorVertical = profile.leftMirrorVertical;
    _rightMirrorHorizontal = profile.rightMirrorHorizontal;
    _rightMirrorVertical = profile.rightMirrorVertical;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(
      context,
      PassengerProfile(
        id:
            widget.initialProfile?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        role: _role,
        seatPosition: _seatPosition,
        preferredTemperatureC: _temperature.round(),
        fanLevel: _fanLevel,
        seatHeating: _seatHeating,
        leftMirrorHorizontal: _leftMirrorHorizontal,
        leftMirrorVertical: _leftMirrorVertical,
        rightMirrorHorizontal: _rightMirrorHorizontal,
        rightMirrorVertical: _rightMirrorVertical,
        lastUsedAt: widget.initialProfile?.lastUsedAt,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initialProfile == null ? 'Passenger profile' : 'Edit profile',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            autofocus: true,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Role'),
            items: const [
              DropdownMenuItem(value: 'driver', child: Text('Driver')),
              DropdownMenuItem(value: 'passenger', child: Text('Passenger')),
              DropdownMenuItem(value: 'child', child: Text('Child')),
              DropdownMenuItem(value: 'caregiver', child: Text('Caregiver')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _role = value);
            },
          ),
          DropdownButtonFormField<String>(
            initialValue: _seatPosition,
            decoration: const InputDecoration(labelText: 'Seat position'),
            items: const [
              DropdownMenuItem(value: 'frontLeft', child: Text('Front left')),
              DropdownMenuItem(value: 'frontRight', child: Text('Front right')),
              DropdownMenuItem(value: 'rearLeft', child: Text('Rear left')),
              DropdownMenuItem(value: 'rearRight', child: Text('Rear right')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _seatPosition = value);
            },
          ),
          Row(
            children: [
              const Expanded(child: Text('Preferred temperature')),
              Text('${_temperature.round()} °C'),
            ],
          ),
          Slider(
            value: _temperature,
            min: 16,
            max: 30,
            divisions: 14,
            onChanged: (value) => setState(() => _temperature = value),
          ),
          DropdownButtonFormField<int>(
            initialValue: _fanLevel,
            decoration: const InputDecoration(labelText: 'Fan level'),
            items: [
              for (var level = 0; level <= 5; level++)
                DropdownMenuItem(value: level, child: Text('$level')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _fanLevel = value);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Seat heating preference'),
            value: _seatHeating,
            onChanged: (value) => setState(() => _seatHeating = value),
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Mirror preferences (saved with this profile)'),
            ),
          ),
          const Text(
            'Seat and mirror preferences are saved to this vehicle profile. '
            'The current simulator applies cabin climate and seat heating.',
            style: TextStyle(fontSize: 12, color: AppTheme.mutedBlue),
          ),
          _mirrorSlider(
            'Left mirror horizontal',
            _leftMirrorHorizontal,
            (value) => setState(() => _leftMirrorHorizontal = value),
          ),
          _mirrorSlider(
            'Left mirror vertical',
            _leftMirrorVertical,
            (value) => setState(() => _leftMirrorVertical = value),
          ),
          _mirrorSlider(
            'Right mirror horizontal',
            _rightMirrorHorizontal,
            (value) => setState(() => _rightMirrorHorizontal = value),
          ),
          _mirrorSlider(
            'Right mirror vertical',
            _rightMirrorVertical,
            (value) => setState(() => _rightMirrorVertical = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty ? null : _save,
        child: Text(
          widget.initialProfile == null ? 'Save profile' : 'Save changes',
        ),
      ),
    ],
  );

  Widget _mirrorSlider(
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(value.round().toString()),
        ],
      ),
      Slider(
        value: value,
        min: -20,
        max: 20,
        divisions: 40,
        onChanged: onChanged,
      ),
    ],
  );
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppTheme.navy,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: AppTheme.mutedBlue,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _PageError extends StatelessWidget {
  const _PageError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 42, color: Colors.red),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFFECEC),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: TextStyle(color: Colors.red.shade800)),
  );
}
