import 'package:flutter/material.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import 'vehicle_simulator_peripheral.dart';

void main() => runApp(const VehicleSimulatorApp());

class VehicleSimulatorApp extends StatelessWidget {
  const VehicleSimulatorApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'EV Vehicle Simulator',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2388D9)),
      useMaterial3: true,
    ),
    home: const VehicleSimulatorPage(),
  );
}

class VehicleSimulatorPage extends StatefulWidget {
  const VehicleSimulatorPage({super.key});

  @override
  State<VehicleSimulatorPage> createState() => _VehicleSimulatorPageState();
}

class _VehicleSimulatorPageState extends State<VehicleSimulatorPage> {
  final VehicleSimulatorPeripheral _peripheral = VehicleSimulatorPeripheral();
  final TextEditingController _vehicleIdController = TextEditingController();

  @override
  void dispose() {
    _vehicleIdController.dispose();
    _peripheral.dispose();
    super.dispose();
  }

  Future<void> _toggleAdvertising() async {
    if (_peripheral.advertising) {
      await _peripheral.stopAdvertising();
      return;
    }
    try {
      await _peripheral.startAdvertising(_vehicleIdController.text);
    } on ArgumentError catch (error) {
      _message(error.message.toString());
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _send(String action, {VehicleDoor? door, bool? enabled, int? level}) {
    try {
      final command = VehicleControlCommand(
        requestId: DateTime.now().microsecondsSinceEpoch.toString(),
        action: action,
        door: door,
        enabled: enabled,
        level: level,
      );
      _peripheral.updateState(applyVehicleCommand(_peripheral.state, command));
    } on VehicleSafetyException catch (error) {
      _message(error.message);
    }
  }

  Future<void> _applyScenario(String scenario) async {
    final current = _peripheral.state;
    switch (scenario) {
      case 'Parked':
        _peripheral.updateState(
          current.copyWith(
            speedKph: 0,
            vehicleOn: false,
            chargingConnected: false,
            chargingPowerKw: 0,
            chargingInterrupted: false,
            doors: {
              for (final door in VehicleDoor.values)
                door: const VehicleDoorState(),
            },
          ),
          event: 'Scenario: parked vehicle',
        );
      case 'Driving':
        _peripheral.updateState(
          current.copyWith(
            speedKph: 30,
            vehicleOn: true,
            chargingConnected: false,
            chargingPowerKw: 0,
            chargingInterrupted: false,
            doors: {
              for (final door in VehicleDoor.values)
                door: const VehicleDoorState(open: false, locked: true),
            },
          ),
          event: 'Scenario: vehicle driving at 30 km/h',
        );
      case 'Door open while moving':
        _peripheral.updateState(
          current.copyWith(
            speedKph: 30,
            vehicleOn: true,
            chargingConnected: false,
            chargingPowerKw: 0,
            chargingInterrupted: false,
            doors: {
              for (final door in VehicleDoor.values)
                door: door == VehicleDoor.frontLeft
                    ? const VehicleDoorState(open: true, locked: false)
                    : const VehicleDoorState(),
            },
          ),
          event: 'Scenario: front left door open while moving',
        );
      case 'Door unlocked while moving':
        _peripheral.updateState(
          current.copyWith(
            speedKph: 30,
            vehicleOn: true,
            chargingConnected: false,
            chargingPowerKw: 0,
            chargingInterrupted: false,
            doors: {
              for (final door in VehicleDoor.values)
                door: door == VehicleDoor.rearRight
                    ? const VehicleDoorState(open: false, locked: false)
                    : const VehicleDoorState(),
            },
          ),
          event: 'Scenario: rear right door unlocked while moving',
        );
      case 'Low battery (8%)':
      case 'Critical battery (5%)':
        final battery = scenario == 'Low battery (8%)' ? 8.0 : 5.0;
        _peripheral.updateState(
          current.copyWith(
            speedKph: 0,
            vehicleOn: false,
            batteryPercent: battery,
            rangeKm: battery * 3.5,
            chargingConnected: false,
            chargingPowerKw: 0,
            chargingInterrupted: false,
          ),
          event: 'Scenario: battery at ${battery.round()}%',
        );
      case 'Charging started':
        final battery = current.batteryPercent
            .clamp(0, current.targetChargePercent - 1)
            .toDouble();
        _peripheral.updateState(
          current.copyWith(
            speedKph: 0,
            vehicleOn: false,
            batteryPercent: battery,
            rangeKm: battery * 3.5,
            chargingConnected: true,
            chargingInterrupted: false,
            chargingPowerKw: 7.2,
          ),
          event: 'Scenario: charging started at ${battery.round()}%',
        );
      case 'Charging completed':
        final startingBattery = (current.targetChargePercent - 1).toDouble();
        _peripheral.updateState(
          current.copyWith(
            speedKph: 0,
            vehicleOn: false,
            batteryPercent: startingBattery,
            rangeKm: startingBattery * 3.5,
            chargingConnected: true,
            chargingInterrupted: false,
            chargingPowerKw: 7.2,
          ),
          event: 'Scenario: charging started at ${startingBattery.round()}%',
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final battery = current.targetChargePercent.toDouble();
        _peripheral.updateState(
          current.copyWith(
            speedKph: 0,
            vehicleOn: false,
            batteryPercent: battery,
            rangeKm: battery * 3.5,
            chargingConnected: false,
            chargingInterrupted: false,
            chargingPowerKw: 0,
          ),
          event: 'Scenario: charging completed at ${battery.round()}%',
        );
      case 'Charging interrupted':
        final startingBattery = current.batteryPercent
            .clamp(0, current.targetChargePercent - 1)
            .toDouble();
        _peripheral.updateState(
          current.copyWith(
            speedKph: 0,
            vehicleOn: false,
            batteryPercent: startingBattery,
            rangeKm: startingBattery * 3.5,
            chargingConnected: true,
            chargingInterrupted: false,
            chargingPowerKw: 7.2,
          ),
          event: 'Scenario: charging started before interruption',
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        _peripheral.updateState(
          current.copyWith(
            speedKph: 0,
            vehicleOn: false,
            chargingConnected: false,
            chargingInterrupted: true,
            chargingPowerKw: 0,
          ),
          event: 'Scenario: charging interrupted unexpectedly',
        );
      case 'Vehicle disconnected':
        await _peripheral.simulateVehicleDisconnected();
      case 'Vehicle reconnected':
        await _peripheral.startAdvertising(_vehicleIdController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EV VEHICLE SIMULATOR')),
      body: AnimatedBuilder(
        animation: Listenable.merge([_peripheral, _vehicleIdController]),
        builder: (context, _) {
          final state = _peripheral.state;
          final advertisedName = _peripheral.advertising
              ? _peripheral.advertisedName
              : vehicleSimulatorNameFor(_vehicleIdController.text);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                advertisedName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              Card(
                color: _peripheral.error == null
                    ? const Color(0xFFE8F4FC)
                    : const Color(0xFFFFECEC),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'BLE Status',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 12,
                            color: _peripheral.advertising
                                ? const Color(0xFF168266)
                                : Colors.grey,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _peripheral.advertising
                                ? 'Advertising'
                                : 'Not Advertising',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: _peripheral.advertising
                                  ? const Color(0xFF168266)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(advertisedName),
                      if (_peripheral.status != 'Ready to advertise') ...[
                        const SizedBox(height: 6),
                        Text(
                          _peripheral.status,
                          style: TextStyle(
                            color: _peripheral.error == null
                                ? Colors.black54
                                : Colors.red,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              DropdownMenu<String>(
                controller: _vehicleIdController,
                enabled: !_peripheral.advertising,
                requestFocusOnTap: true,
                expandedInsets: EdgeInsets.zero,
                label: const Text('Vehicle ID'),
                helperText:
                    'Pick or type the vehicle document ID of the signed-in '
                    'EV app user. It advertises as $advertisedName.',
                dropdownMenuEntries: [
                  for (final id in demoVehicleIds)
                    DropdownMenuEntry(
                      value: id,
                      label: id,
                      trailingIcon: Text(vehicleSimulatorNameFor(id)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _toggleAdvertising,
                icon: Icon(
                  _peripheral.advertising
                      ? Icons.stop_circle_outlined
                      : Icons.bluetooth_searching_rounded,
                ),
                label: Text(
                  _peripheral.advertising
                      ? 'STOP VEHICLE SIMULATOR'
                      : 'START VEHICLE SIMULATOR',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    _peripheral.updateState(const VehicleControlState()),
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Restore Normal State'),
              ),
              const SizedBox(height: 20),
              const _SectionTitle('Demo scenarios'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final scenario in [
                    'Parked',
                    'Driving',
                    'Door open while moving',
                    'Door unlocked while moving',
                    'Low battery (8%)',
                    'Critical battery (5%)',
                    'Charging started',
                    'Charging completed',
                    'Charging interrupted',
                    'Vehicle disconnected',
                    'Vehicle reconnected',
                  ])
                    ActionChip(
                      label: Text(scenario),
                      onPressed: () => _applyScenario(scenario),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              _Panel(
                title: 'Vehicle telemetry',
                child: Column(
                  children: [
                    _SliderControl(
                      label: 'Speed',
                      value: state.speedKph,
                      maximum: 240,
                      divisions: 48,
                      display: '${state.speedKph.round()} km/h',
                      onChanged: (value) {
                        if (state.chargingConnected && value > 0) {
                          _message('Stop charging before the vehicle moves.');
                          return;
                        }
                        _peripheral.updateState(
                          state.copyWith(speedKph: value),
                        );
                      },
                    ),
                    _SliderControl(
                      label: 'Battery',
                      value: state.batteryPercent,
                      maximum: 100,
                      divisions: 20,
                      display: '${state.batteryPercent.round()}%',
                      onChanged: (value) => _peripheral.updateState(
                        state.copyWith(
                          batteryPercent: value,
                          rangeKm: value * 3.5,
                        ),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Vehicle on'),
                      value: state.vehicleOn,
                      onChanged: (value) {
                        try {
                          _peripheral.updateState(
                            applyVehicleCommand(
                              state,
                              VehicleControlCommand(
                                requestId: DateTime.now().microsecondsSinceEpoch
                                    .toString(),
                                action: 'vehicleOn',
                                enabled: value,
                              ),
                            ),
                          );
                        } on VehicleSafetyException catch (error) {
                          _message(error.message);
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Panel(
                title: 'Four doors and windows',
                child: Column(
                  children: [
                    for (final door in VehicleDoor.values)
                      _DoorControl(
                        door: door,
                        state: state.doors[door]!,
                        windowLevel: state.windows[door]!,
                        onDoorChanged: (open) =>
                            _send('doorOpen', door: door, enabled: open),
                        onLockChanged: (locked) =>
                            _send('doorLock', door: door, enabled: locked),
                        onWindowChanged: (level) =>
                            _send('windowLevel', door: door, level: level),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Panel(
                title: 'Charging and climate',
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Charger connected'),
                      subtitle: Text(
                        state.chargingConnected
                            ? '${state.chargingPowerKw.toStringAsFixed(1)} kW'
                            : 'Not connected',
                      ),
                      value: state.chargingConnected,
                      onChanged: (value) {
                        try {
                          _peripheral.updateState(
                            applyVehicleCommand(
                              state,
                              VehicleControlCommand(
                                requestId: DateTime.now().microsecondsSinceEpoch
                                    .toString(),
                                action: 'chargingConnected',
                                enabled: value,
                              ),
                            ),
                          );
                        } on VehicleSafetyException catch (error) {
                          _message(error.message);
                        }
                      },
                    ),
                    _SliderControl(
                      label: 'Charge limit',
                      value: state.targetChargePercent.toDouble(),
                      minimum: 50,
                      maximum: 100,
                      divisions: 10,
                      display: '${state.targetChargePercent}%',
                      onChanged: (value) =>
                          _send('targetCharge', level: value.round()),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Cabin climate'),
                      value: state.climateOn,
                      onChanged: (value) => _send('climate', enabled: value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Seat heating'),
                      value: state.seatHeatingEnabled,
                      onChanged: (value) =>
                          _send('seatHeating', enabled: value),
                    ),
                    _SliderControl(
                      label: 'Cabin target',
                      value: state.targetTemperatureC,
                      minimum: 16,
                      maximum: 30,
                      divisions: 14,
                      display: '${state.targetTemperatureC.round()} °C',
                      onChanged: (value) => _peripheral.updateState(
                        state.copyWith(targetTemperatureC: value),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Headlights'),
                      value: state.lightsOn,
                      onChanged: (value) => _send('headlights', enabled: value),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Panel(
                title: 'Simulator event log',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Recent local demo events'),
                    const SizedBox(height: 8),
                    if (_peripheral.eventLog.isEmpty)
                      const Text('No simulator events yet.')
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final event in _peripheral.eventLog.take(8))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(event),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Demo data is sent only over Bluetooth and is not written to any server.',
                style: TextStyle(color: Colors.black54),
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DoorControl extends StatelessWidget {
  const _DoorControl({
    required this.door,
    required this.state,
    required this.windowLevel,
    required this.onDoorChanged,
    required this.onLockChanged,
    required this.onWindowChanged,
  });

  final VehicleDoor door;
  final VehicleDoorState state;
  final int windowLevel;
  final ValueChanged<bool> onDoorChanged;
  final ValueChanged<bool> onLockChanged;
  final ValueChanged<int> onWindowChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(door.label),
        subtitle: Text(
          state.open
              ? 'Open'
              : state.locked
              ? 'Closed · locked'
              : 'Closed · unlocked',
        ),
        leading: Icon(
          state.open
              ? Icons.door_sliding_outlined
              : Icons.door_front_door_outlined,
          color: state.open ? Colors.orange : const Color(0xFF2388D9),
        ),
        trailing: Wrap(
          spacing: 4,
          children: [
            IconButton(
              tooltip: state.open ? 'Close door' : 'Open door',
              onPressed: () => onDoorChanged(!state.open),
              icon: Icon(
                state.open
                    ? Icons.meeting_room_outlined
                    : Icons.sensor_door_outlined,
              ),
            ),
            IconButton(
              tooltip: state.locked ? 'Unlock door' : 'Lock door',
              onPressed: () => onLockChanged(!state.locked),
              icon: Icon(
                state.locked ? Icons.lock_outline : Icons.lock_open_outlined,
              ),
            ),
          ],
        ),
      ),
      Slider(
        value: windowLevel.toDouble(),
        max: 100,
        divisions: 10,
        label: 'Window $windowLevel%',
        onChanged: (value) => onWindowChanged(value.round()),
      ),
    ],
  );
}

class _SliderControl extends StatelessWidget {
  const _SliderControl({
    required this.label,
    required this.value,
    required this.maximum,
    required this.divisions,
    required this.display,
    required this.onChanged,
    this.minimum = 0,
  });

  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(display, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
      Slider(
        value: value.clamp(minimum, maximum),
        min: minimum,
        max: maximum,
        divisions: divisions,
        onChanged: onChanged,
      ),
    ],
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) =>
      Text(title, style: Theme.of(context).textTheme.titleMedium);
}
