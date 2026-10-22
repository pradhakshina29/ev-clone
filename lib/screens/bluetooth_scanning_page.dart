import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/vehicle.dart';
import '../services/vehicle_ble_client.dart';
import 'homescreen.dart';
import 'vehicle_controls_page.dart';

class BluetoothScanningPage extends StatefulWidget {
  const BluetoothScanningPage({
    super.key,
    required this.vehicle,
    this.bleClient,
  });

  final Vehicle vehicle;
  final VehicleBleClient? bleClient;

  @override
  State<BluetoothScanningPage> createState() => _BluetoothScanningPageState();
}

class _BluetoothScanningPageState extends State<BluetoothScanningPage> {
  late final VehicleBleClient _ble =
      widget.bleClient ?? VehicleBleClient.shared;

  @override
  void initState() {
    super.initState();
    _ble.addListener(_onBleChanged);
    if (kIsWeb || _ble.webAdapter != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ble.inspectWebCapabilities());
      });
    }
  }

  @override
  void dispose() {
    _ble.removeListener(_onBleChanged);
    super.dispose();
  }

  void _onBleChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    try {
      await _ble.start(
        widget.vehicle.id,
        deviceName: widget.vehicle.bluetoothDeviceName,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final matchesVehicle = _ble.vehicleId == widget.vehicle.id;
    final phase = matchesVehicle ? _ble.phase : VehicleBlePhase.stopped;
    final connected = matchesVehicle && _ble.isConnected;
    final unsupported = !_ble.isSupported;
    final activeAttempt = switch (phase) {
      VehicleBlePhase.authorizing ||
      VehicleBlePhase.scanning ||
      VehicleBlePhase.selectingDevice ||
      VehicleBlePhase.connecting ||
      VehicleBlePhase.gattConnected ||
      VehicleBlePhase.discoveringServices ||
      VehicleBlePhase.discoveringCharacteristics ||
      VehicleBlePhase.subscribingNotifications ||
      VehicleBlePhase.awaitingTelemetry => true,
      _ => false,
    };
    final supported = !unsupported;
    final status = phase == VehicleBlePhase.stopped && unsupported
        ? (kIsWeb || _ble.webAdapter != null
              ? 'Web Bluetooth is unavailable in this browser or page context.'
              : 'Bluetooth vehicle connection requires a physical Android device.')
        : switch (phase) {
            VehicleBlePhase.authorizing => 'Requesting Bluetooth permission…',
            VehicleBlePhase.scanning => 'Searching for the vehicle simulator…',
            VehicleBlePhase.selectingDevice =>
              'Select the simulator in the browser Bluetooth chooser…',
            VehicleBlePhase.connecting =>
              'Connecting to the vehicle simulator…',
            VehicleBlePhase.gattConnected =>
              'Connected to GATT; preparing discovery…',
            VehicleBlePhase.discoveringServices =>
              'Discovering the vehicle service…',
            VehicleBlePhase.discoveringCharacteristics =>
              'Vehicle service found; discovering characteristics…',
            VehicleBlePhase.subscribingNotifications =>
              'Characteristics found; enabling telemetry…',
            VehicleBlePhase.awaitingTelemetry =>
              'Connected — waiting for vehicle data',
            VehicleBlePhase.identityMismatch =>
              _ble.error ??
                  'The simulator vehicle ID does not match this vehicle.',
            VehicleBlePhase.connected =>
              'Connected · receiving live vehicle state',
            VehicleBlePhase.reconnecting =>
              'Connection interrupted · reconnecting…',
            VehicleBlePhase.unsupported =>
              _ble.error ?? 'Bluetooth is not supported in this environment.',
            VehicleBlePhase.error =>
              _ble.error ?? 'Bluetooth connection failed.',
            VehicleBlePhase.stopped =>
              'Ready to connect to ${widget.vehicle.bluetoothDeviceName.isEmpty ? 'the vehicle simulator' : widget.vehicle.bluetoothDeviceName}.',
          };

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 30, 28, 24),
          child: Column(
            children: [
              const Text(
                'Vehicle connection',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.navy,
                ),
              ),
              const SizedBox(height: 35),
              Container(
                width: 110,
                height: 110,
                decoration: const BoxDecoration(
                  color: Color(0xFFE8F3FC),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  connected ? Icons.bluetooth_connected : Icons.bluetooth,
                  size: 55,
                  color: connected ? const Color(0xFF13845A) : AppTheme.blue,
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Vehicle profile ready',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.navy,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.vehicle.model,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (widget.vehicle.bluetoothDeviceName.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  widget.vehicle.bluetoothDeviceName,
                  style: const TextStyle(color: AppTheme.mutedBlue),
                ),
              ],
              const SizedBox(height: 22),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        status,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color:
                              phase == VehicleBlePhase.error ||
                                  phase == VehicleBlePhase.identityMismatch ||
                                  phase == VehicleBlePhase.unsupported
                              ? Colors.red.shade700
                              : AppTheme.navy,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (matchesVehicle &&
                          _ble.selectedDeviceName != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Selected device: ${_ble.selectedDeviceName}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppTheme.mutedBlue,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      if (connected &&
                          _ble.snapshot.value?.vehicleId == widget.vehicle.id)
                        Text(
                          'Last live update: ${_ble.lastDataUpdate?.toLocal()}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppTheme.mutedBlue,
                            fontSize: 12,
                          ),
                        ),
                      const SizedBox(height: 14),
                      if (connected)
                        OutlinedButton.icon(
                          onPressed: () => unawaited(_ble.disconnect()),
                          icon: const Icon(Icons.bluetooth_disabled),
                          label: const Text('Disconnect'),
                        )
                      else
                        FilledButton.icon(
                          onPressed:
                              !supported ||
                                  activeAttempt ||
                                  phase == VehicleBlePhase.reconnecting
                              ? null
                              : () => unawaited(_connect()),
                          icon: activeAttempt
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.bluetooth_searching),
                          label: Text(
                            activeAttempt
                                ? 'Connecting…'
                                : phase == VehicleBlePhase.error ||
                                      phase == VehicleBlePhase.identityMismatch
                                ? 'Retry connection'
                                : phase == VehicleBlePhase.reconnecting
                                ? 'Reconnect'
                                : 'Connect Vehicle',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          VehicleControlsPage(vehicle: widget.vehicle),
                    ),
                  ),
                  child: const Text('Open vehicle controls'),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HomeScreen(vehicle: widget.vehicle),
                  ),
                  (route) => false,
                ),
                child: Text(
                  connected
                      ? 'Go to dashboard'
                      : 'Continue to dashboard without connecting',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
