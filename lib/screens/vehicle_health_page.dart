import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:model_viewer_pro/model_viewer_pro.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import '../app_theme.dart';
import '../models/vehicle.dart';
import '../models/vehicle_health.dart';
import '../models/vehicle_telemetry.dart';
import '../services/data_service.dart';
import '../services/vehicle_health_history.dart';
import '../widgets/vehicle_ble_state_view.dart';
import '../services/vehicle_model_load_bridge_stub.dart'
    if (dart.library.js_interop) '../services/vehicle_model_load_bridge_web.dart'
    as model_bridge;
import 'maintenance.dart';

const _ink = Color(0xFF071326);
const _muted = Color(0xFF6383AA);
const _line = Color(0xFFE5EBF0);
const _blue = Color(0xFF2789D7);
const _green = Color(0xFF1EA76A);
const _amber = Color(0xFFE4A22F);
const _red = Color(0xFFD93C4E);
const _modelAsset = 'assets/models/ev_health_car.glb';

class VehicleHealthPage extends StatefulWidget {
  const VehicleHealthPage({
    super.key,
    required this.vehicle,
    this.dataService,
    this.healthHistory,
  });

  final Vehicle vehicle;
  final DataService? dataService;

  /// Session-only battery readings; defaults to the app-wide recorder.
  final VehicleHealthHistory? healthHistory;

  @override
  State<VehicleHealthPage> createState() => _VehicleHealthPageState();
}

class _VehicleHealthPageState extends State<VehicleHealthPage> {
  late final DataService _data =
      widget.dataService ?? DataService();
  late final Stream<List<VehicleMaintenanceRecord>> _maintenanceStream =
      _data.watchVehicleMaintenanceRecords(widget.vehicle.id);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Vehicle health'),
        backgroundColor: AppTheme.background,
      ),
      body: VehicleBleStateView(
        builder: (context, client, snapshot) {
          final matchingSnapshot = snapshot?.vehicleId == widget.vehicle.id
              ? snapshot
              : null;
          final telemetry = VehicleData.fromSnapshot(matchingSnapshot);
          final health = telemetry == null
              ? null
              : VehicleHealthData.fromTelemetry(telemetry);
          final lastUpdated = matchingSnapshot == null
              ? 'No live simulator packet'
              : 'Simulator packet ${matchingSnapshot.sequence}';
          return StreamBuilder<List<VehicleMaintenanceRecord>>(
            stream: _maintenanceStream,
            builder: (context, maintenanceSnapshot) {
              final records = maintenanceSnapshot.data ?? const [];
              return LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 850;
                  final padding = wide ? 28.0 : 16.0;
                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(padding, 18, padding, 38),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Heading(
                              eyebrow: 'VEHICLE HEALTH',
                              title: widget.vehicle.model.isEmpty
                                  ? 'Your EV, at a glance'
                                  : widget.vehicle.model,
                              subtitle:
                                  'A clear view of vehicle condition, driving '
                                  'efficiency and service history.',
                            ),
                            const SizedBox(height: 17),
                            _HealthLiveSnapshot(
                              snapshot: matchingSnapshot,
                              health: health,
                            ),
                            const SizedBox(height: 14),
                            _HealthScorePanel(health: health),
                            const SizedBox(height: 16),
                            _VehicleModelCard(
                              vehicleName: widget.vehicle.model,
                            ),
                            const SizedBox(height: 25),
                            _SectionHeading(
                              eyebrow: 'QUICK STATUS',
                              title: 'Component health',
                              subtitle:
                                  'Tap any component for its detailed status.',
                            ),
                            const SizedBox(height: 11),
                            _ComponentGrid(
                              health: health,
                              telemetry: telemetry,
                              liveState: matchingSnapshot?.state,
                              wide: wide,
                            ),
                            const SizedBox(height: 25),
                            _BatterySection(
                              health: health,
                              telemetry: telemetry,
                              liveState: matchingSnapshot?.state,
                              capacityKwh: telemetry?.batteryCapacityKwh,
                              history:
                                  widget.healthHistory ??
                                  VehicleHealthHistory.shared,
                              vehicleId: widget.vehicle.id,
                            ),
                            const SizedBox(height: 25),
                            _MotorSection(health: health, telemetry: telemetry),
                            const SizedBox(height: 25),
                            _TireSection(
                              health: health,
                              telemetry: telemetry,
                              liveState: matchingSnapshot?.state,
                            ),
                            const SizedBox(height: 25),
                            _BrakeSection(health: health, telemetry: telemetry),
                            const SizedBox(height: 25),
                            _SoftwareSection(
                              health: health,
                              telemetry: telemetry,
                            ),
                            const SizedBox(height: 25),
                            _DrivingEfficiencySection(
                              health: health,
                              telemetry: telemetry,
                              wide: wide,
                            ),
                            const SizedBox(height: 25),
                            _RangeImpactSection(telemetry: telemetry),
                            const SizedBox(height: 25),
                            const _TripEfficiencySection(),
                            const SizedBox(height: 25),
                            _RegenerationSection(telemetry: telemetry),
                            const SizedBox(height: 25),
                            _DrivingTipsSection(health: health),
                            const SizedBox(height: 25),
                            _MaintenanceStatusSection(
                              health: health,
                              telemetry: telemetry,
                              onComponentSelected: (component) =>
                                  _showComponentDetails(
                                    context,
                                    component,
                                    telemetry,
                                    health,
                                    telemetry?.batteryCapacityKwh,
                                    matchingSnapshot?.state,
                                  ),
                            ),
                            const SizedBox(height: 25),
                            _ServiceHistorySection(
                              records: records,
                              isLoading:
                                  maintenanceSnapshot.connectionState ==
                                  ConnectionState.waiting,
                              hasError: maintenanceSnapshot.hasError,
                              onRetry: () => setState(() {}),
                              onManage: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      MaintenancePage(vehicle: widget.vehicle),
                                ),
                              ),
                            ),
                            const SizedBox(height: 25),
                            _NextServiceSection(
                              records: records,
                              isLoading:
                                  maintenanceSnapshot.connectionState ==
                                  ConnectionState.waiting,
                              hasError: maintenanceSnapshot.hasError,
                              onManage: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      MaintenancePage(vehicle: widget.vehicle),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            _DataDisclosure(
                              lastUpdated: lastUpdated,
                              hasTelemetry: telemetry != null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

void _showComponentDetails(
  BuildContext context,
  VehicleHealthComponent component,
  VehicleData? telemetry,
  VehicleHealthData? health,
  double? capacityKwh, [
  VehicleControlState? liveState,
]) {
  final score = health?.component(component).score;
  final status =
      health?.component(component).status ?? VehicleHealthStatus.unavailable;
  final details = switch (component) {
    VehicleHealthComponent.battery => <(String, String)>[
      ('Health', _percent(score)),
      ('Current charge', _percent(liveState?.batteryPercent)),
      ('Temperature', _temperature(telemetry?.batteryTemperatureC)),
      ('Voltage', _quantity(telemetry?.batteryVoltageV, unit: 'V', decimals: 1)),
      ('Capacity', _quantity(capacityKwh, unit: 'kWh', decimals: 1)),
      ('Estimated range', _quantity(liveState?.rangeKm, unit: 'km')),
      ('Battery age', _age(telemetry?.batteryAgeMonths)),
      ('Charging cycles', _quantity(telemetry?.chargingCycles)),
      ('Charging efficiency', 'Not reported'),
      ('Last charging session', 'Not reported'),
      ('DC fast-charge share', _percent(telemetry?.dcFastChargePercentage)),
    ],
    VehicleHealthComponent.motor => <(String, String)>[
      ('Health', _percent(score)),
      ('Status', telemetry?.motorStatus ?? 'Not reported'),
      ('Temperature', _temperature(telemetry?.motorTemperatureC)),
      ('Efficiency', _percent(telemetry?.motorEfficiencyPercent)),
      ('Current load', _percent(telemetry?.motorLoadPercent)),
      ('RPM', _quantity(telemetry?.motorRpm, unit: 'rpm')),
      ('Operating hours', _quantity(telemetry?.motorOperatingHours, unit: 'h')),
    ],
    VehicleHealthComponent.tires => <(String, String)>[
      ('Health', _percent(score)),
      (
        'Front left',
        _tire(
          telemetry?.tirePressureFlPsi,
          telemetry?.tireTemperatureFlC,
          telemetry?.tireTreadFlPercent,
        ),
      ),
      (
        'Front right',
        _tire(
          telemetry?.tirePressureFrPsi,
          telemetry?.tireTemperatureFrC,
          telemetry?.tireTreadFrPercent,
        ),
      ),
      (
        'Rear left',
        _tire(
          telemetry?.tirePressureRlPsi,
          telemetry?.tireTemperatureRlC,
          telemetry?.tireTreadRlPercent,
        ),
      ),
      (
        'Rear right',
        _tire(
          telemetry?.tirePressureRrPsi,
          telemetry?.tireTemperatureRrC,
          telemetry?.tireTreadRrPercent,
        ),
      ),
      ('Pressure reference', '35 PSI baseline; confirm vehicle placard'),
    ],
    VehicleHealthComponent.brakes => <(String, String)>[
      ('Health', _percent(score)),
      (
        'Brake-pad life',
        telemetry?.frontBrakePadLifePercent == null &&
                telemetry?.rearBrakePadLifePercent == null
            ? 'Not reported'
            : 'Front ${_percent(telemetry?.frontBrakePadLifePercent)} · '
                  'Rear ${_percent(telemetry?.rearBrakePadLifePercent)}',
      ),
      ('Brake fluid', telemetry?.brakeFluidStatus ?? 'Not reported'),
      ('Brake temperature', _temperature(telemetry?.brakeTemperatureC)),
      ('Hard-braking events', _quantity(telemetry?.hardBrakingEvents)),
      (
        'Energy recovered',
        _quantity(telemetry?.regenerativeEnergyKwh, unit: 'kWh', decimals: 1),
      ),
    ],
    VehicleHealthComponent.software => <(String, String)>[
      (
        'Vehicle software',
        telemetry?.vehicleSoftwareVersion ?? 'Version not reported',
      ),
      ('Update', _softwareUpdate(telemetry?.softwareUpdateAvailable)),
      (
        'Infotainment',
        telemetry?.infotainmentVersion ?? 'Version not reported',
      ),
      ('Firmware', telemetry?.firmwareVersion ?? 'Version not reported'),
      ('Security status', telemetry?.securityStatus ?? 'Not reported'),
    ],
  };

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                component.name.toUpperCase(),
                style: const TextStyle(
                  color: _blue,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                component.name[0].toUpperCase() + component.name.substring(1),
                style: const TextStyle(
                  color: _ink,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              _StatusPill(
                label: _statusLabel(status),
                color: _statusColor(status),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final row in details)
                        _DetailRow(label: row.$1, value: row.$2),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _DetailRow(
                label: 'Recommended action',
                value: switch (status) {
                  VehicleHealthStatus.healthy =>
                    'Continue routine care and monitoring.',
                  VehicleHealthStatus.attention =>
                    'Review the current reading and arrange an inspection if it persists.',
                  VehicleHealthStatus.critical =>
                    'Arrange a professional service inspection.',
                  VehicleHealthStatus.unavailable =>
                    'Connect vehicle telemetry to receive a current status.',
                },
              ),
              const SizedBox(height: 4),
              const Text(
                'Only values supplied by connected vehicle telemetry are '
                'shown. Missing sensor readings are not estimated.',
                style: TextStyle(color: _muted, fontSize: 11, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _percent(num? value) =>
    value == null || !value.isFinite ? 'Not reported' : '${value.round()}%';

String _quantity(num? value, {String unit = '', int decimals = 0}) {
  if (value == null || !value.isFinite) return 'Not reported';
  final formatted = decimals == 0
      ? value.round().toString()
      : value.toStringAsFixed(decimals);
  return unit.isEmpty ? formatted : '$formatted $unit';
}

String _temperature(num? value) =>
    value == null || !value.isFinite ? 'Not reported' : '${value.round()}°C';

String _age(int? months) {
  if (months == null || months < 0) return 'Not reported';
  final years = months ~/ 12;
  final remainingMonths = months % 12;
  return years == 0
      ? '$remainingMonths months'
      : '$years years $remainingMonths months';
}

String _tire(num? pressure, num? temperature, [num? treadPercent]) {
  if (pressure == null) return 'Pressure not reported';
  final temp = temperature == null ? '' : ' · ${temperature.round()}°C';
  final tread = treadPercent == null ? '' : ' · tread ${treadPercent.round()}%';
  return '${pressure.toStringAsFixed(1)} PSI$temp$tread';
}

String _softwareUpdate(bool? updateAvailable) => switch (updateAvailable) {
  null => 'Not reported',
  true => 'Update available',
  false => 'Up to date',
};

Color _statusColor(VehicleHealthStatus status) => switch (status) {
  VehicleHealthStatus.healthy => _green,
  VehicleHealthStatus.attention => _amber,
  VehicleHealthStatus.critical => _red,
  VehicleHealthStatus.unavailable => _muted,
};

String _statusLabel(VehicleHealthStatus status) => switch (status) {
  VehicleHealthStatus.healthy => 'GOOD',
  VehicleHealthStatus.attention => 'WARNING',
  VehicleHealthStatus.critical => 'CRITICAL',
  VehicleHealthStatus.unavailable => 'NO DATA',
};

class _HealthLiveSnapshot extends StatelessWidget {
  const _HealthLiveSnapshot({required this.snapshot, required this.health});

  final VehicleStateSnapshot? snapshot;
  final VehicleHealthData? health;

  @override
  Widget build(BuildContext context) {
    final state = snapshot?.state;
    final telemetry = health?.telemetry;
    final tires = health?.component(VehicleHealthComponent.tires);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 22,
          runSpacing: 12,
          children: [
            _LiveValue(
              label: 'Battery',
              value: state == null ? 'N/A' : '${state.batteryPercent.round()}%',
            ),
            _LiveValue(
              label: 'Range',
              value: state == null ? 'N/A' : '${state.rangeKm.round()} km',
            ),
            _LiveValue(
              label: 'Speed',
              value: state == null ? 'N/A' : '${state.speedKph.round()} km/h',
            ),
            _LiveValue(
              label: 'Battery health',
              value: telemetry == null
                  ? 'N/A'
                  : '${telemetry.batteryHealth.round()}%',
            ),
            _LiveValue(
              label: 'Motor temperature',
              value: telemetry?.motorTemperatureC == null
                  ? 'N/A'
                  : '${telemetry!.motorTemperatureC!.round()}°C',
            ),
            _LiveValue(
              label: 'Tire condition',
              value: tires == null ||
                      tires.status == VehicleHealthStatus.unavailable
                  ? 'N/A'
                  : _statusLabel(tires.status),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveValue extends StatelessWidget {
  const _LiveValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 140,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            color: _ink,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ],
    ),
  );
}

class _HealthScorePanel extends StatelessWidget {
  const _HealthScorePanel({required this.health});

  final VehicleHealthData? health;

  @override
  Widget build(BuildContext context) {
    final score = health?.score;
    final status = health?.overallHealthStatus ??
        VehicleHealthStatus.unavailable;
    final color = _statusColor(status);
    return _Panel(
      child: Row(
        children: [
          SizedBox(
            width: 116,
            height: 116,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(
                begin: 0,
                end: (score ?? 0).clamp(0, 100) / 100,
              ),
              duration: const Duration(milliseconds: 950),
              curve: Curves.easeOutCubic,
              builder: (context, progress, _) => Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 10,
                      strokeCap: StrokeCap.round,
                      backgroundColor: const Color(0xFFEAF0F4),
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        score == null ? '—' : score.round().toString(),
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 34,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Text(
                        'OUT OF 100',
                        style: TextStyle(
                          color: _muted,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'VEHICLE HEALTH SCORE',
                  style: TextStyle(
                    color: _blue,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  health?.overallStatus ?? 'STATUS UNAVAILABLE',
                  style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  score == null
                      ? 'Health indicators appear when the vehicle reports them over Bluetooth.'
                      : 'Calculated from reported battery, motor, tire, brake '
                            'and software health values.',
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ComponentGrid extends StatelessWidget {
  const _ComponentGrid({
    required this.health,
    required this.telemetry,
    required this.liveState,
    required this.wide,
  });

  final VehicleHealthData? health;
  final VehicleData? telemetry;
  final VehicleControlState? liveState;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final components = VehicleHealthComponent.values;
    return GridView.builder(
      itemCount: components.length,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: wide ? 5 : 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        mainAxisExtent: 108,
      ),
      itemBuilder: (context, index) {
        final component = components[index];
        final componentHealth = health?.component(component);
        return _ComponentCard(
          component: component,
          value: componentHealth?.displayValue ?? '—',
          status:
              componentHealth?.status ?? VehicleHealthStatus.unavailable,
          onTap: () => _showComponentDetails(
            context,
            component,
            telemetry,
            health,
            telemetry?.batteryCapacityKwh,
            liveState,
          ),
        );
      },
    );
  }
}

class _ComponentCard extends StatelessWidget {
  const _ComponentCard({
    required this.component,
    required this.value,
    required this.status,
    required this.onTap,
  });

  final VehicleHealthComponent component;
  final String value;
  final VehicleHealthStatus status;
  final VoidCallback onTap;

  IconData get _icon => switch (component) {
    VehicleHealthComponent.battery => Icons.battery_full_rounded,
    VehicleHealthComponent.motor => Icons.settings_input_component_rounded,
    VehicleHealthComponent.tires => Icons.tire_repair_rounded,
    VehicleHealthComponent.brakes => Icons.disc_full_rounded,
    VehicleHealthComponent.software => Icons.system_update_alt_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: _line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_icon, size: 18, color: color),
                  const Spacer(),
                  Icon(Icons.arrow_outward_rounded, size: 14, color: _muted),
                ],
              ),
              const Spacer(),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                status == VehicleHealthStatus.unavailable
                    ? component.name[0].toUpperCase() +
                          component.name.substring(1)
                    : '${component.name[0].toUpperCase()}'
                          '${component.name.substring(1)} · '
                          '${_statusLabel(status)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: status == VehicleHealthStatus.unavailable
                      ? _muted
                      : _statusColor(status),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatterySection extends StatelessWidget {
  const _BatterySection({
    required this.health,
    required this.telemetry,
    required this.liveState,
    required this.capacityKwh,
    required this.history,
    required this.vehicleId,
  });

  final VehicleHealthData? health;
  final VehicleData? telemetry;
  final VehicleControlState? liveState;
  final double? capacityKwh;
  final VehicleHealthHistory history;
  final String vehicleId;

  @override
  Widget build(BuildContext context) {
    final score = health?.component(VehicleHealthComponent.battery).score;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'BATTERY HEALTH',
          title: 'The heart of your EV',
        ),
        const SizedBox(height: 11),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 9,
                runSpacing: 9,
                children: [
                  _MetricChip(label: 'Health', value: _percent(score)),
                  _MetricChip(
                    label: 'Current charge',
                    value: _percent(liveState?.batteryPercent),
                  ),
                  _MetricChip(
                    label: 'Estimated range',
                    value: _quantity(liveState?.rangeKm, unit: 'km'),
                  ),
                  _MetricChip(
                    label: 'Temperature',
                    value: _temperature(telemetry?.batteryTemperatureC),
                  ),
                  _MetricChip(
                    label: 'Voltage',
                    value: _quantity(
                      telemetry?.batteryVoltageV,
                      unit: 'V',
                      decimals: 1,
                    ),
                  ),
                  _MetricChip(
                    label: 'Capacity',
                    value: _quantity(capacityKwh, unit: 'kWh', decimals: 1),
                  ),
                  _MetricChip(
                    label: 'Cycles',
                    value: _quantity(telemetry?.chargingCycles),
                  ),
                  _MetricChip(
                    label: 'Battery age',
                    value: _age(telemetry?.batteryAgeMonths),
                  ),
                ],
              ),
              const SizedBox(height: 19),
              const Text(
                'BATTERY HEALTH TIMELINE',
                style: TextStyle(
                  color: _ink,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 10),
              ListenableBuilder(
                listenable: history,
                builder: (context, _) {
                  final samples = history.samplesFor(vehicleId);
                  if (samples.isEmpty) {
                    return const _NoDataMessage(
                      icon: Icons.show_chart_rounded,
                      message:
                          'Battery health history is not available yet. '
                          'Readings received over Bluetooth during this '
                          'session will appear here.',
                    );
                  }
                  return _BatteryTimeline(samples: samples);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Battery readings received during this session, oldest on the left.
class _BatteryTimeline extends StatelessWidget {
  const _BatteryTimeline({required this.samples});

  final List<HealthSample> samples;

  @override
  Widget build(BuildContext context) {
    final first = samples.first;
    final last = samples.last;
    String time(DateTime value) =>
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 120,
          width: double.infinity,
          child: CustomPaint(painter: _TimelinePainter(samples)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            const _LegendDot(color: _green, label: 'Battery health %'),
            const _LegendDot(color: _blue, label: 'Charge %'),
            const _LegendDot(color: _amber, label: 'Temperature °C'),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${samples.length} readings this session · '
          '${time(first.time)}–${time(last.time)} · now '
          '${last.stateOfHealthPercent.round()}% health, '
          '${last.batteryTemperatureC.round()}°C',
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
    ],
  );
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.samples);

  final List<HealthSample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _line
      ..strokeWidth = 1;
    for (final fraction in [0.0, 0.5, 1.0]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    // All three series share a 0–100 scale (°C fits it for normal readings).
    _line100(canvas, size, (s) => s.stateOfHealthPercent, _green);
    _line100(canvas, size, (s) => s.batteryPercent, _blue);
    _line100(canvas, size, (s) => s.batteryTemperatureC, _amber);
  }

  void _line100(
    Canvas canvas,
    Size size,
    double Function(HealthSample sample) value,
    Color color,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Offset point(int index) {
      final x = samples.length == 1
          ? size.width / 2
          : size.width * index / (samples.length - 1);
      final y = size.height * (1 - value(samples[index]).clamp(0, 100) / 100);
      return Offset(x, y);
    }

    if (samples.length == 1) {
      canvas.drawCircle(point(0), 3, paint..style = PaintingStyle.fill);
      return;
    }
    final path = Path()..moveTo(point(0).dx, point(0).dy);
    for (var index = 1; index < samples.length; index++) {
      final next = point(index);
      path.lineTo(next.dx, next.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TimelinePainter oldDelegate) =>
      oldDelegate.samples.length != samples.length ||
      (samples.isNotEmpty &&
          oldDelegate.samples.isNotEmpty &&
          oldDelegate.samples.last != samples.last);
}


class _MotorSection extends StatelessWidget {
  const _MotorSection({required this.health, required this.telemetry});

  final VehicleHealthData? health;
  final VehicleData? telemetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _SectionHeading(
        eyebrow: 'MOTOR HEALTH',
        title: 'Power, in balance',
      ),
      const SizedBox(height: 11),
      _Panel(
        child: Wrap(
          spacing: 9,
          runSpacing: 9,
          children: [
            _MetricChip(
              label: 'Motor health',
              value: _percent(
                health?.component(VehicleHealthComponent.motor).score,
              ),
            ),
            _MetricChip(
              label: 'Temperature',
              value: _temperature(telemetry?.motorTemperatureC),
            ),
            _MetricChip(
              label: 'Efficiency',
              value: _percent(telemetry?.motorEfficiencyPercent),
            ),
            _MetricChip(
              label: 'RPM',
              value: _quantity(telemetry?.motorRpm, unit: 'rpm'),
            ),
            _MetricChip(
              label: 'Status',
              value: telemetry?.motorStatus ?? 'Not reported',
            ),
            _MetricChip(
              label: 'Operating hours',
              value: _quantity(telemetry?.motorOperatingHours, unit: 'h'),
            ),
          ],
        ),
      ),
    ],
  );
}

class _TireSection extends StatelessWidget {
  const _TireSection({
    required this.health,
    required this.telemetry,
    required this.liveState,
  });

  final VehicleHealthData? health;
  final VehicleData? telemetry;
  final VehicleControlState? liveState;

  @override
  Widget build(BuildContext context) {
    final tires = <(String, double?, double?, double?)>[
      (
        'Front left',
        telemetry?.tirePressureFlPsi,
        telemetry?.tireTemperatureFlC,
        telemetry?.tireTreadFlPercent,
      ),
      (
        'Front right',
        telemetry?.tirePressureFrPsi,
        telemetry?.tireTemperatureFrC,
        telemetry?.tireTreadFrPercent,
      ),
      (
        'Rear left',
        telemetry?.tirePressureRlPsi,
        telemetry?.tireTemperatureRlC,
        telemetry?.tireTreadRlPercent,
      ),
      (
        'Rear right',
        telemetry?.tirePressureRrPsi,
        telemetry?.tireTemperatureRrC,
        telemetry?.tireTreadRrPercent,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'TIRE HEALTH',
          title: 'Four points of contact',
        ),
        const SizedBox(height: 11),
        _Panel(
          child: Column(
            children: [
              const Text(
                'FRONT',
                style: TextStyle(
                  color: _muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 9),
              for (final row in [
                [0, 1],
                [2, 3],
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Row(
                    children: [
                      for (final index in row)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: index.isEven ? 7 : 0,
                              left: index.isOdd ? 7 : 0,
                            ),
                            child: _TireTile(
                              label: tires[index].$1,
                              pressure: tires[index].$2,
                              temperature: tires[index].$3,
                              treadPercent: tires[index].$4,
                              onTap: () => _showComponentDetails(
                                context,
                                VehicleHealthComponent.tires,
                                telemetry,
                                health,
                                telemetry?.batteryCapacityKwh,
                                liveState,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const Text(
                'REAR',
                style: TextStyle(
                  color: _muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '35 PSI is a generic reference only (warning below 30, '
                'critical below 25). Check the vehicle placard for the '
                'correct pressure for your EV.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 10, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TireTile extends StatelessWidget {
  const _TireTile({
    required this.label,
    required this.pressure,
    required this.temperature,
    required this.treadPercent,
    required this.onTap,
  });

  final String label;
  final double? pressure;
  final double? temperature;
  final double? treadPercent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = pressure == null
        ? VehicleHealthStatus.unavailable
        : HealthThresholds.worst([
            HealthThresholds.tirePressure(pressure),
            HealthThresholds.tireTread(treadPercent),
          ]);
    final color = _statusColor(status);
    return Material(
      color: const Color(0xFFF7F9FB),
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: [
              Icon(Icons.tire_repair_rounded, color: color, size: 21),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      pressure == null
                          ? '— PSI'
                          : '${pressure!.toStringAsFixed(1)} PSI'
                                '${temperature == null ? '' : ' · ${temperature!.round()}°C'}'
                                '${treadPercent == null ? '' : ' · ${treadPercent!.round()}%'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrakeSection extends StatelessWidget {
  const _BrakeSection({required this.health, required this.telemetry});

  final VehicleHealthData? health;
  final VehicleData? telemetry;

  @override
  Widget build(BuildContext context) {
    final score = health?.component(VehicleHealthComponent.brakes).score;
    final status =
        health?.component(VehicleHealthComponent.brakes).status ??
        VehicleHealthStatus.unavailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'BRAKE HEALTH',
          title: 'Confident stopping',
        ),
        const SizedBox(height: 11),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Brake system · ${_percent(score)}',
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  _StatusPill(
                    label: _statusLabel(status),
                    color: _statusColor(status),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: (score ?? 0).clamp(0, 100) / 100,
                  minHeight: 9,
                  backgroundColor: const Color(0xFFEAF0F4),
                  valueColor: AlwaysStoppedAnimation(_statusColor(status)),
                ),
              ),
              const SizedBox(height: 13),
              Wrap(
                spacing: 9,
                runSpacing: 9,
                children: [
                  _MetricChip(
                    label: 'Front pad life',
                    value: _percent(telemetry?.frontBrakePadLifePercent),
                  ),
                  _MetricChip(
                    label: 'Rear pad life',
                    value: _percent(telemetry?.rearBrakePadLifePercent),
                  ),
                  _MetricChip(
                    label: 'Brake fluid',
                    value: telemetry?.brakeFluidStatus ?? 'Not reported',
                  ),
                ],
              ),
              const SizedBox(height: 9),
              const Text(
                'Wear details appear when supplied by the vehicle. Follow the '
                'service schedule for routine inspection.',
                style: TextStyle(color: _muted, fontSize: 11, height: 1.45),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SoftwareSection extends StatelessWidget {
  const _SoftwareSection({required this.health, required this.telemetry});

  final VehicleHealthData? health;
  final VehicleData? telemetry;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'SOFTWARE HEALTH',
          title: 'Vehicle software status',
        ),
        const SizedBox(height: 11),
        _Panel(
          child: Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              _MetricChip(
                label: 'Update',
                value: _softwareUpdate(telemetry?.softwareUpdateAvailable),
              ),
              _MetricChip(
                label: 'Vehicle software',
                value: telemetry?.vehicleSoftwareVersion ?? 'Not reported',
              ),
              _MetricChip(
                label: 'Infotainment',
                value: telemetry?.infotainmentVersion ?? 'Not reported',
              ),
              _MetricChip(
                label: 'Firmware',
                value: telemetry?.firmwareVersion ?? 'Not reported',
              ),
              _MetricChip(
                label: 'Security',
                value: telemetry?.securityStatus ?? 'Not reported',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DrivingEfficiencySection extends StatelessWidget {
  const _DrivingEfficiencySection({
    required this.health,
    required this.telemetry,
    required this.wide,
  });

  final VehicleHealthData? health;
  final VehicleData? telemetry;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final efficiency = telemetry?.efficiencyKmPerKwh;
    final consumption = efficiency != null && efficiency > 0
        ? 100 / efficiency
        : null;
    final values = <(String, String)>[
      ('Efficiency score', _quantity(telemetry?.ecoScore, unit: '/100')),
      (
        'Average efficiency',
        _quantity(consumption, unit: 'kWh/100 km', decimals: 1),
      ),
      ('Best efficiency', 'Not reported'),
      ('Average speed', 'Not reported'),
      (
        'Energy recovered',
        _quantity(telemetry?.regenerativeEnergyKwh, unit: 'kWh', decimals: 1),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'DRIVING EFFICIENCY',
          title: 'Make every kWh count',
          subtitle: 'Driving data is shown when reported by your vehicle.',
        ),
        const SizedBox(height: 11),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GridView.builder(
                itemCount: values.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: wide ? 3 : 2,
                  crossAxisSpacing: 9,
                  mainAxisSpacing: 9,
                  mainAxisExtent: 75,
                ),
                itemBuilder: (context, index) => _MetricTile(
                  label: values[index].$1,
                  value: values[index].$2,
                ),
              ),
              if (telemetry?.tripsAnalyzed == null ||
                  telemetry!.tripsAnalyzed == 0) ...[
                const SizedBox(height: 11),
                const _NoDataMessage(
                  icon: Icons.route_rounded,
                  message:
                      'Trip efficiency will appear once the vehicle reports '
                      'driving history.',
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RangeImpactSection extends StatelessWidget {
  const _RangeImpactSection({required this.telemetry});

  final VehicleData? telemetry;

  static const _labels = {
    'driving': 'Driving',
    'climate': 'Climate control',
    'speed': 'High speed',
    'elevation': 'Elevation',
    'accessories': 'Accessories',
  };

  @override
  Widget build(BuildContext context) {
    final impact = telemetry?.rangeImpact;
    final total =
        impact?.values.fold<double>(0, (sum, value) => sum + value) ?? 0;
    final entries = impact == null || total <= 0
        ? const <MapEntry<String, double>>[]
        : (impact.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'RANGE IMPACT',
          title: 'What is affecting your range?',
          subtitle: 'Energy-use breakdown from recent vehicle data.',
        ),
        const SizedBox(height: 11),
        _Panel(
          child: entries.isEmpty
              ? const _NoDataMessage(
                  icon: Icons.donut_large_rounded,
                  message:
                      'Range-impact breakdown is not available because the '
                      'vehicle does not report energy use by cause yet.',
                )
              : Column(
                  children: [
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _labels[entry.key] ?? entry.key,
                                    style: const TextStyle(
                                      color: _ink,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${(entry.value / total * 100).round()}%',
                                  style: const TextStyle(
                                    color: _ink,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(99),
                              child: LinearProgressIndicator(
                                value: entry.value / total,
                                minHeight: 8,
                                backgroundColor: const Color(0xFFEAF0F4),
                                valueColor: const AlwaysStoppedAnimation(_blue),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _TripEfficiencySection extends StatelessWidget {
  const _TripEfficiencySection();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SectionHeading(
        eyebrow: 'TRIP EFFICIENCY',
        title: 'Route replay',
        subtitle: 'Review energy use along trips you have driven.',
      ),
      SizedBox(height: 11),
      _Panel(
        child: _NoDataMessage(
          icon: Icons.map_outlined,
          message:
              'No trip efficiency data available yet. Trip planning routes '
              'are not saved as driven GPS history, so they are not shown as '
              'replay or efficiency results.',
        ),
      ),
    ],
  );
}

class _RegenerationSection extends StatelessWidget {
  const _RegenerationSection({required this.telemetry});

  final VehicleData? telemetry;

  @override
  Widget build(BuildContext context) {
    final recovered = telemetry?.regenerativeEnergyKwh;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'REGENERATIVE BRAKING',
          title: 'Energy returned to your battery',
        ),
        const SizedBox(height: 11),
        _Panel(
          child: Row(
            children: [
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  color: _green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(
                  Icons.energy_savings_leaf_rounded,
                  color: _green,
                  size: 38,
                ),
              ),
              const SizedBox(width: 17),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recovered == null
                          ? 'Not reported'
                          : '${recovered.toStringAsFixed(1)} kWh',
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Text(
                      'ENERGY RECOVERED',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.7,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Regen efficiency and event counts appear when '
                      'provided by vehicle telemetry.',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DrivingTipsSection extends StatelessWidget {
  const _DrivingTipsSection({required this.health});

  final VehicleHealthData? health;

  @override
  Widget build(BuildContext context) {
    final tips = health?.drivingTips ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'SMART DRIVING TIPS',
          title: 'Small changes, smoother drives',
        ),
        const SizedBox(height: 11),
        if (tips.isEmpty)
          const _Panel(
            child: _NoDataMessage(
              icon: Icons.lightbulb_outline_rounded,
              message:
                  'Personalized tips will appear when eco score, trip '
                  'efficiency or braking data is available.',
            ),
          )
        else
          ...tips.map(
            (tip) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Panel(
                child: Row(
                  children: [
                    const Icon(Icons.lightbulb_outline_rounded, color: _blue),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tip,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MaintenanceStatusSection extends StatelessWidget {
  const _MaintenanceStatusSection({
    required this.health,
    required this.telemetry,
    required this.onComponentSelected,
  });

  final VehicleHealthData? health;
  final VehicleData? telemetry;
  final ValueChanged<VehicleHealthComponent> onComponentSelected;

  @override
  Widget build(BuildContext context) {
    final batteryTemperature = telemetry?.batteryTemperatureC;
    final batteryCooling = HealthThresholds.batteryTemperature(
      batteryTemperature,
    );
    final brake =
        health?.component(VehicleHealthComponent.brakes).status ??
        VehicleHealthStatus.unavailable;
    final tire =
        health?.component(VehicleHealthComponent.tires).status ??
        VehicleHealthStatus.unavailable;
    final software =
        health?.component(VehicleHealthComponent.software).status ??
        VehicleHealthStatus.unavailable;
    final items = <(String, VehicleHealthStatus, VehicleHealthComponent?)>[
      ('Battery cooling', batteryCooling, VehicleHealthComponent.battery),
      ('Brake system', brake, VehicleHealthComponent.brakes),
      ('Tire pressure', tire, VehicleHealthComponent.tires),
      (
        'Brake fluid',
        HealthThresholds.brakeFluid(telemetry?.brakeFluidStatus),
        VehicleHealthComponent.brakes,
      ),
      ('Software', software, VehicleHealthComponent.software),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'MAINTENANCE',
          title: 'Current condition',
          subtitle: 'Live component condition and scheduled service.',
        ),
        const SizedBox(height: 11),
        _Panel(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              for (final item in items)
                InkWell(
                  onTap: item.$3 == null
                      ? null
                      : () => onComponentSelected(item.$3!),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.$1,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _StatusPill(
                          label: _statusLabel(item.$2),
                          color: _statusColor(item.$2),
                        ),
                        const SizedBox(width: 5),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: _muted,
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ServiceHistorySection extends StatelessWidget {
  const _ServiceHistorySection({
    required this.records,
    required this.isLoading,
    required this.hasError,
    required this.onRetry,
    required this.onManage,
  });

  final List<VehicleMaintenanceRecord> records;
  final bool isLoading;
  final bool hasError;
  final VoidCallback onRetry;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(
            child: _SectionHeading(
              eyebrow: 'SERVICE HISTORY',
              title: 'Care, well recorded',
            ),
          ),
          TextButton(onPressed: onManage, child: const Text('VIEW ALL')),
        ],
      ),
      const SizedBox(height: 11),
      _Panel(
        child: hasError
            ? _NoDataMessage(
                icon: Icons.cloud_off_rounded,
                message: 'Service history could not be loaded.',
                action: TextButton(
                  onPressed: onRetry,
                  child: const Text('RETRY'),
                ),
              )
            : isLoading
            ? const Center(child: CircularProgressIndicator())
            : records.isEmpty
            ? _NoDataMessage(
                icon: Icons.handyman_outlined,
                message: 'No service records yet.',
                action: TextButton(
                  onPressed: onManage,
                  child: const Text('OPEN MAINTENANCE'),
                ),
              )
            : Column(
                children: [
                  for (var index = 0; index < records.take(4).length; index++)
                    _ServiceRecordTile(
                      record: records[index],
                      isLast: index == records.take(4).length - 1,
                    ),
                ],
              ),
      ),
    ],
  );
}

class _NextServiceSection extends StatelessWidget {
  const _NextServiceSection({
    required this.records,
    required this.isLoading,
    required this.hasError,
    required this.onManage,
  });

  final List<VehicleMaintenanceRecord> records;
  final bool isLoading;
  final bool hasError;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final upcoming =
        records
            .where(
              (record) =>
                  record.nextServiceDate != null &&
                  !record.nextServiceDate!.isBefore(
                    DateTime(now.year, now.month, now.day),
                  ),
            )
            .toList()
          ..sort((a, b) => a.nextServiceDate!.compareTo(b.nextServiceDate!));
    final next = upcoming.isEmpty ? null : upcoming.first;
    final date = next?.nextServiceDate;
    final dateLabel = date == null
        ? 'Not scheduled'
        : MaterialLocalizations.of(context).formatMediumDate(date.toLocal());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          eyebrow: 'NEXT SERVICE',
          title: 'Stay on schedule',
        ),
        const SizedBox(height: 11),
        _Panel(
          child: hasError
              ? const _NoDataMessage(
                  icon: Icons.cloud_off_rounded,
                  message: 'The service schedule could not be loaded.',
                )
              : isLoading
              ? const Center(child: CircularProgressIndicator())
              : Row(
                  children: [
                    const _IconBadge(
                      icon: Icons.event_available_rounded,
                      color: _blue,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            next?.serviceType ?? 'Routine vehicle inspection',
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            dateLabel,
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: onManage,
                      child: const Text('DETAILS'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ServiceRecordTile extends StatelessWidget {
  const _ServiceRecordTile({required this.record, required this.isLast});

  final VehicleMaintenanceRecord record;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final date = record.serviceDate == null
        ? 'Date not recorded'
        : MaterialLocalizations.of(
            context,
          ).formatMediumDate(record.serviceDate!.toLocal());
    final statusColor = record.status.toLowerCase().contains('upcoming')
        ? _blue
        : _green;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: isLast ? null : const Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          _IconBadge(icon: Icons.build_rounded, color: statusColor),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.serviceType,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(date, style: const TextStyle(color: _muted, fontSize: 11)),
              ],
            ),
          ),
          _StatusPill(label: record.status.toUpperCase(), color: statusColor),
        ],
      ),
    );
  }
}

class _DataDisclosure extends StatelessWidget {
  const _DataDisclosure({
    required this.lastUpdated,
    required this.hasTelemetry,
  });

  final String lastUpdated;
  final bool hasTelemetry;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFFEAF4FF),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Text(
      '${hasTelemetry ? 'Vehicle telemetry · $lastUpdated. ' : 'No vehicle telemetry is currently available. '}'
      'Unavailable values are labelled rather than estimated. The battery '
      'timeline shows only readings received during this session; trip '
      'history and energy breakdowns require historical data from the '
      'vehicle.',
      style: const TextStyle(color: _ink, fontSize: 10, height: 1.45),
    ),
  );
}

class _VehicleModelCard extends StatefulWidget {
  const _VehicleModelCard({required this.vehicleName});

  final String vehicleName;

  @override
  State<_VehicleModelCard> createState() => _VehicleModelCardState();
}

class _VehicleModelCardState extends State<_VehicleModelCard> {
  final ModelViewerProController _controller = ModelViewerProController();
  StreamSubscription<model_bridge.VehicleModelLoadEvent>? _webLoadSubscription;
  Timer? _loadTimeout;
  bool _modelLoaded = false;
  bool _modelFailed = false;
  String? _error;
  int _retryKey = 0;

  bool get _usesHtmlViewer => kIsWeb;
  bool get _supported =>
      kIsWeb ||
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS ||
      Theme.of(context).platform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      model_bridge.initializeVehicleModelLoadBridge();
      _webLoadSubscription = model_bridge.vehicleModelLoadEvents.listen((
        event,
      ) {
        if (!mounted) return;
        _loadTimeout?.cancel();
        setState(() {
          _modelLoaded = event.loaded;
          _modelFailed = !event.loaded;
          _error = event.error;
        });
        if (!event.loaded) {
          debugPrint('EV GLB web rendering failed: ${event.error}');
        }
      });
    }
    _startLoadTimeout();
  }

  @override
  void dispose() {
    _webLoadSubscription?.cancel();
    _loadTimeout?.cancel();
    _controller.dispose();
    super.dispose();
  }

  String get _modelSource => kIsWeb
      ? Uri.base.resolve('assets/assets/models/ev_health_car.glb').toString()
      : _modelAsset;

  String get _webModelEventsScript =>
      '''
    (() => {
      const viewer = document.querySelector('model-viewer');
      if (!viewer || viewer.dataset.evHealthEvents === '$_retryKey') return;
      viewer.dataset.evHealthEvents = '$_retryKey';
      const send = (status, error) => window.postMessage({
        source: 'ev-smart-companion-model',
        status,
        error: error || null
      }, '*');
      viewer.addEventListener('load', () => send('loaded'), { once: true });
      viewer.addEventListener('error', event =>
        send('error', event.detail?.type || 'Unable to parse or render this GLB'),
        { once: true }
      );
      if (viewer.loaded) send('loaded');
    })();
  ''';

  void _onNativeModelLoad(List<String> meshNames) {
    if (!mounted) return;
    _loadTimeout?.cancel();
    final success = meshNames.isNotEmpty;
    setState(() {
      _modelLoaded = success;
      _modelFailed = !success;
      _error = success
          ? null
          : 'The viewer could not discover meshes in the bundled GLB.';
    });
    if (success) {
      _controller.setShadowIntensity(0.75);
      _controller.setShadowSoftness(0.85);
      _controller.setExposure(1.15);
      debugPrint('EV GLB loaded. Available meshes: $meshNames');
    } else {
      debugPrint('EV GLB load failed. Source: $_modelSource');
    }
  }

  void _retry() {
    _loadTimeout?.cancel();
    setState(() {
      _retryKey++;
      _modelLoaded = false;
      _modelFailed = false;
      _error = null;
    });
    _startLoadTimeout();
  }

  void _startLoadTimeout() {
    _loadTimeout = Timer(const Duration(seconds: 40), () {
      if (!mounted || _modelLoaded || _modelFailed || !_supported) return;
      debugPrint('EV GLB load timed out. Source: $_modelSource');
      setState(() {
        _modelFailed = true;
        _error = 'Timed out while loading the bundled vehicle model.';
      });
    });
  }

  void _resetView() {
    if (_usesHtmlViewer) {
      _retry();
      return;
    }
    _controller.resetCamera();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).width < 600 ? 330.0 : 430.0;
    const orbit = '45deg 68deg auto';
    return _Panel(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _SectionHeading(
                  eyebrow: 'INTERACTIVE 3D VEHICLE',
                  title: widget.vehicleName.isEmpty
                      ? 'Explore your EV'
                      : widget.vehicleName,
                ),
              ),
              if (_modelLoaded)
                TextButton.icon(
                  onPressed: _resetView,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('RESET VIEW'),
                ),
            ],
          ),
          const SizedBox(height: 11),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_supported)
                    _usesHtmlViewer
                        ? ModelViewer(
                            key: ValueKey(_retryKey),
                            src: _modelSource,
                            alt: 'Interactive 3D EV model',
                            backgroundColor: const Color(0xFFF1F4F7),
                            cameraControls: true,
                            autoRotate: false,
                            disableZoom: false,
                            cameraOrbit: orbit,
                            cameraTarget: 'auto auto auto',
                            fieldOfView: '30deg',
                            minCameraOrbit: 'auto 20deg auto',
                            maxCameraOrbit: 'auto 88deg auto',
                            shadowIntensity: 0.75,
                            shadowSoftness: 0.85,
                            exposure: 1.15,
                            loading: Loading.eager,
                            reveal: Reveal.auto,
                            relatedJs: _webModelEventsScript,
                          )
                        : ModelViewerProViewer(
                            key: ValueKey(_retryKey),
                            src: _modelSource,
                            controller: _controller,
                            alt: 'Interactive 3D EV model',
                            backgroundColor: const Color(0xFFF1F4F7),
                            cameraControls: true,
                            autoRotate: false,
                            disableZoom: false,
                            cameraOrbit: orbit,
                            cameraTarget: 'auto auto auto',
                            fieldOfView: '30deg',
                            minCameraOrbit: 'auto 20deg auto',
                            maxCameraOrbit: 'auto 88deg auto',
                            shadowIntensity: 0.75,
                            shadowSoftness: 0.85,
                            exposure: 1.15,
                            onLoad: _onNativeModelLoad,
                          ),
                  if (!_modelLoaded)
                    ColoredBox(
                      color: const Color(0xFFF1F4F7).withValues(alpha: 0.94),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                !_supported
                                    ? Icons.desktop_access_disabled_rounded
                                    : _modelFailed
                                    ? Icons.view_in_ar_outlined
                                    : Icons.threed_rotation_rounded,
                                color: _modelFailed ? _red : _blue,
                                size: 37,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                !_supported
                                    ? '3D viewer is not supported on this platform'
                                    : _modelFailed
                                    ? 'Unable to load vehicle model.'
                                    : 'Loading your vehicle...',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: _ink,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 6),
                                Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                              if (_modelFailed) ...[
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: _retry,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('RETRY'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.open_with_rounded, color: _blue, size: 17),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'Drag to rotate • Scroll or pinch to zoom',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ),
              if (_modelLoaded)
                TextButton(
                  onPressed: _resetView,
                  child: const Text('RESET VIEW'),
                ),
            ],
          ),
          const SizedBox(height: 3),
          const Text(
            'This bundled CC0 sample is a generic toy-car model, not a scan of '
            'your specific EV. Its meshes do not expose separate vehicle '
            'components for 3D highlighting.',
            style: TextStyle(color: _muted, fontSize: 10, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.eyebrow,
    required this.title,
    this.subtitle,
  });

  final String eyebrow;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        eyebrow,
        style: const TextStyle(
          color: _blue,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.05,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        title,
        style: const TextStyle(
          color: _ink,
          fontSize: 19,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.25,
        ),
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        Text(
          subtitle!,
          style: const TextStyle(color: _muted, fontSize: 12, height: 1.4),
        ),
      ],
    ],
  );
}

class _Heading extends StatelessWidget {
  const _Heading({required this.eyebrow, required this.title, this.subtitle});

  final String eyebrow;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        eyebrow,
        style: const TextStyle(
          color: _blue,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.15,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        title,
        style: const TextStyle(
          color: _ink,
          fontSize: 25,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.35,
        ),
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        Text(
          subtitle!,
          style: const TextStyle(color: _muted, fontSize: 12, height: 1.45),
        ),
      ],
    ],
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _line),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0A112840),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: child,
  );
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 104, maxWidth: 220),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFF7F9FB),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _muted, fontSize: 10)),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(
      color: const Color(0xFFF7F9FB),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _muted, fontSize: 10),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _ink,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _NoDataMessage extends StatelessWidget {
  const _NoDataMessage({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _muted, size: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 11,
                  height: 1.45,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 4), action!],
            ],
          ),
        ),
      ],
    ),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: _ink,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 9,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.3,
      ),
    ),
  );
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 38,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(icon, color: color, size: 18),
  );
}
