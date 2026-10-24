import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import '../app_theme.dart';
import '../models/vehicle.dart';
import '../models/vehicle_health.dart';
import '../models/vehicle_telemetry.dart';
import '../services/api/api_client.dart';
import '../services/data_service.dart';
import '../services/maintenance_schedule_service.dart';
import '../widgets/vehicle_ble_state_view.dart';

class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key, required this.vehicle, this.dataService});

  final Vehicle vehicle;
  final DataService? dataService;

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends State<MaintenancePage> {
  static const _categories = [
    'All',
    'Battery',
    'Brakes',
    'Tires',
    'Software',
    'Other',
  ];
  late final DataService _data = widget.dataService ?? DataService();
  late final Stream<List<VehicleMaintenanceRecord>> _recordsStream = _data
      .watchVehicleMaintenanceRecords(widget.vehicle.id);
  late final Stream<Vehicle?> _vehicleStream = _data.watchVehicleById(
    widget.vehicle.id,
  );
  String _selectedCategory = 'All';

  Future<void> _addRecord() async {
    final formKey = GlobalKey<FormState>();
    final typeController = TextEditingController();
    final centerController = TextEditingController();
    final costController = TextEditingController();
    final odometerController = TextEditingController();
    final notesController = TextEditingController();
    var category = 'Other';
    DateTime? serviceDate;
    DateTime? nextServiceDate;

    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Add service record'),
            content: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: category,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: _categories
                          .where((value) => value != 'All')
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => category = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: typeController,
                      inputFormatters: [LengthLimitingTextInputFormatter(80)],
                      decoration: const InputDecoration(
                        labelText: 'Service performed',
                        hintText: 'e.g. Tire rotation',
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? 'Enter the service performed.'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    _DatePickerField(
                      label: 'Completion date',
                      value: serviceDate,
                      onTap: () async {
                        final picked = await _pickDate(
                          dialogContext,
                          initialDate: DateTime.now(),
                        );
                        if (picked != null) {
                          setDialogState(() => serviceDate = picked);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    _DatePickerField(
                      label: 'Next due date (optional)',
                      value: nextServiceDate,
                      onTap: () async {
                        final picked = await _pickDate(
                          dialogContext,
                          initialDate:
                              serviceDate?.add(const Duration(days: 365)) ??
                              DateTime.now().add(const Duration(days: 365)),
                        );
                        if (picked != null) {
                          setDialogState(() => nextServiceDate = picked);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: odometerController,
                      inputFormatters: [LengthLimitingTextInputFormatter(9)],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Odometer (km, optional)',
                      ),
                      validator: (value) => _validateOptionalNumber(
                        value,
                        'Enter a valid odometer.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: costController,
                      inputFormatters: [LengthLimitingTextInputFormatter(10)],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Cost (optional)',
                      ),
                      validator: (value) =>
                          _validateOptionalNumber(value, 'Enter a valid cost.'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: centerController,
                      inputFormatters: [LengthLimitingTextInputFormatter(120)],
                      decoration: const InputDecoration(
                        labelText: 'Service center (optional)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: notesController,
                      inputFormatters: [LengthLimitingTextInputFormatter(1000)],
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Notes (optional)',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (formKey.currentState!.validate() && serviceDate != null) {
                    Navigator.pop(dialogContext, true);
                  } else if (serviceDate == null) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(
                        content: Text('Choose the completion date.'),
                      ),
                    );
                  }
                },
                child: const Text('Save record'),
              ),
            ],
          ),
        ),
      );

      if (confirmed != true || serviceDate == null) return;
      await _data.addVehicleMaintenanceRecord(
        vehicleId: widget.vehicle.id,
        serviceType: typeController.text,
        category: category,
        serviceDate: serviceDate!,
        nextServiceDate: nextServiceDate,
        odometerKm: double.tryParse(odometerController.text.trim()),
        cost: double.tryParse(costController.text.trim()),
        serviceCenter: centerController.text,
        notes: notesController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Service record saved.')));
    } on ApiException catch (error) {
      debugPrint('Maintenance record save failed (${error.code}).');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.code == 'vehicle_not_found'
                ? 'You do not have access to save service records for this vehicle.'
                : 'Could not save the record. ${error.message}',
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Maintenance record save failed: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the service record.')),
      );
    } finally {
      typeController.dispose();
      centerController.dispose();
      costController.dispose();
      odometerController.dispose();
      notesController.dispose();
    }
  }

  Future<DateTime?> _pickDate(
    BuildContext context, {
    required DateTime initialDate,
  }) {
    final today = DateTime.now();
    final normalizedInitial = initialDate.isBefore(DateTime(2000))
        ? today
        : initialDate;
    return showDatePicker(
      context: context,
      initialDate: normalizedInitial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
  }

  String? _validateOptionalNumber(String? value, String message) {
    if (value == null || value.trim().isEmpty) return null;
    final number = double.tryParse(value.trim());
    return number == null || !number.isFinite || number < 0 ? message : null;
  }

  void _showRecordDetails(VehicleMaintenanceRecord record) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                record.serviceType,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              if (record.category != null)
                _DetailRow(label: 'Category', value: record.category!),
              if (record.serviceDate != null)
                _DetailRow(
                  label: 'Service date',
                  value: _dateLabel(record.serviceDate!),
                ),
              if (record.nextServiceDate != null)
                _DetailRow(
                  label: 'Next due',
                  value: _dateLabel(record.nextServiceDate!),
                ),
              if (record.odometerKm != null)
                _DetailRow(
                  label: 'Odometer',
                  value: '${_whole(record.odometerKm!)} km',
                ),
              if (record.cost != null)
                _DetailRow(label: 'Cost', value: _money(record.cost!)),
              if ((record.serviceCenter ?? '').isNotEmpty)
                _DetailRow(
                  label: 'Service center',
                  value: record.serviceCenter!,
                ),
              if ((record.notes ?? '').isNotEmpty)
                _DetailRow(label: 'Notes', value: record.notes!),
              _DetailRow(label: 'Status', value: record.status),
              const _SourceLabel(label: 'USER ENTERED'),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Maintenance & alerts'),
        backgroundColor: AppTheme.background,
      ),
      backgroundColor: AppTheme.background,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRecord,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add service'),
      ),
      body: StreamBuilder<List<VehicleMaintenanceRecord>>(
        stream: _recordsStream,
        builder: (context, recordSnapshot) {
          if (recordSnapshot.hasError) {
            final error = recordSnapshot.error;
            final message = kDebugMode
                ? 'Maintenance read failed: ${_maintenanceReadError(error)}'
                : 'Maintenance records could not be loaded.';
            return _LoadError(message: message, onRetry: () => setState(() {}));
          }
          if (recordSnapshot.connectionState == ConnectionState.waiting &&
              !recordSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final records = recordSnapshot.data ?? const [];
          return StreamBuilder<Vehicle?>(
            stream: _vehicleStream,
            builder: (context, vehicleSnapshot) => VehicleBleStateView(
              builder: (context, client, snapshot) {
                final vehicle = vehicleSnapshot.data ?? widget.vehicle;
                final matchingSnapshot = snapshot?.vehicleId == vehicle.id
                    ? snapshot
                    : null;
                final telemetry = VehicleData.fromSnapshot(matchingSnapshot);
                return RefreshIndicator(
                  onRefresh: _data.refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
                    children: [
                      _VehicleHeader(
                        vehicle: vehicle,
                        odometerKm: telemetry?.odometerKm,
                      ),
                      const SizedBox(height: 14),
                      _LiveTelemetrySummary(snapshot: matchingSnapshot),
                      const SizedBox(height: 14),
                      _MaintenanceOverview(records: records),
                      const SizedBox(height: 22),
                      _SectionHeading(
                        title: 'Attention needed',
                        subtitle: telemetry == null
                            ? 'Only simulator measurements are used. Unsupported diagnostics remain unavailable.'
                            : 'Rule-based checks from simulator measurements.',
                      ),
                      const SizedBox(height: 10),
                      _SignalAlerts(telemetry: telemetry),
                      const SizedBox(height: 22),
                      _CostSummary(
                        records: records,
                        odometerKm: telemetry?.odometerKm,
                      ),
                      const SizedBox(height: 22),
                      _SectionHeading(
                        title: 'Service history',
                        subtitle: records.isEmpty
                            ? 'No service records yet.'
                            : '${records.length} user-entered ${records.length == 1 ? 'record' : 'records'}',
                        action: TextButton.icon(
                          onPressed: _addRecord,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _CategoryFilter(
                        categories: _categories,
                        selected: _selectedCategory,
                        onSelected: (category) {
                          setState(() => _selectedCategory = category);
                        },
                      ),
                      const SizedBox(height: 10),
                      _ServiceHistory(
                        records: records,
                        category: _selectedCategory,
                        onRecordTap: _showRecordDetails,
                        onAdd: _addRecord,
                      ),
                      const SizedBox(height: 22),
                      const _CoverageNotice(),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

String _maintenanceReadError(Object? error) {
  if (error is ApiException) return error.message;
  return error == null ? 'Unknown error' : error.runtimeType.toString();
}

class _LiveTelemetrySummary extends StatelessWidget {
  const _LiveTelemetrySummary({required this.snapshot});

  final VehicleStateSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final state = snapshot?.state;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'LIVE SIMULATOR DATA',
              style: TextStyle(
                color: AppTheme.mutedBlue,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 18,
              runSpacing: 10,
              children: [
                Text(
                  'Battery: ${state == null ? 'N/A' : '${state.batteryPercent.round()}%'}',
                ),
                Text(
                  'Range: ${state == null ? 'N/A' : '${state.rangeKm.round()} km'}',
                ),
                Text(
                  'Speed: ${state == null ? 'N/A' : '${state.speedKph.round()} km/h'}',
                ),
                const Text('Battery health: N/A'),
                const Text('Odometer: N/A'),
                const Text('Tire condition: N/A'),
              ],
            ),
            if (state == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Connect to the simulator for live measurements. Unsupported diagnostics are not inferred.',
                  style: TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MaintenanceOverview extends StatelessWidget {
  const _MaintenanceOverview({required this.records});

  final List<VehicleMaintenanceRecord> records;

  @override
  Widget build(BuildContext context) {
    final latestByService = <String, VehicleMaintenanceRecord>{};
    for (final record in records) {
      final key = record.serviceType.trim().toLowerCase();
      latestByService.putIfAbsent(key, () => record);
    }
    final dueItems =
        latestByService.values
            .where((record) => record.nextServiceDate != null)
            .map(
              (record) => (
                record,
                MaintenanceScheduleService.assessDate(record.nextServiceDate),
              ),
            )
            .toList()
          ..sort((a, b) {
            final dateCompare = a.$1.nextServiceDate!.compareTo(
              b.$1.nextServiceDate!,
            );
            return dateCompare;
          });
    final overdue = dueItems
        .where((item) => item.$2.status == MaintenanceDueStatus.overdue)
        .length;
    final dueSoon = dueItems
        .where(
          (item) =>
              item.$2.status == MaintenanceDueStatus.dueSoon ||
              item.$2.status == MaintenanceDueStatus.dueToday,
        )
        .length;
    final next = dueItems.isEmpty ? null : dueItems.first;
    final color = overdue > 0
        ? const Color(0xFFD93C4E)
        : dueSoon > 0
        ? const Color(0xFFE4A22F)
        : const Color(0xFF1EA76A);
    final label = overdue > 0
        ? '$overdue item${overdue == 1 ? '' : 's'} overdue'
        : dueSoon > 0
        ? '$dueSoon item${dueSoon == 1 ? '' : 's'} due soon'
        : dueItems.isEmpty
        ? 'No due dates recorded'
        : 'On schedule';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF102E52), Color(0xFF1E5C91)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'VEHICLE MAINTENANCE',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                overdue > 0 ? Icons.error_outline : Icons.check_circle_outline,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              const _SourceLabel(label: 'CALCULATED'),
            ],
          ),
          const SizedBox(height: 14),
          if (next != null) ...[
            const Text(
              'NEXT SERVICE',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              next.$1.serviceType,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '${next.$2.description} · ${_dateLabel(next.$1.nextServiceDate!)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ] else
            const Text(
              'Add a service record with a next due date to track upcoming maintenance.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              _SummaryMetric(value: '$overdue', label: 'OVERDUE'),
              const SizedBox(width: 24),
              _SummaryMetric(value: '$dueSoon', label: 'DUE SOON'),
              const Spacer(),
              if (records.isNotEmpty)
                Text(
                  'Last service ${records.first.serviceDate == null ? 'not dated' : _dateLabel(records.first.serviceDate!)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SignalAlerts extends StatelessWidget {
  const _SignalAlerts({required this.telemetry});

  final VehicleData? telemetry;

  @override
  Widget build(BuildContext context) {
    if (telemetry == null) {
      return const _NoticeCard(
        icon: Icons.sensors_off_outlined,
        text:
            'Vehicle condition alerts appear when supported telemetry is reported.',
        source: 'NO SIGNAL DATA',
      );
    }
    final signals = <(String, double)>[
      if (telemetry!.tirePressureFlPsi != null)
        ('Front left tire', telemetry!.tirePressureFlPsi!),
      if (telemetry!.tirePressureFrPsi != null)
        ('Front right tire', telemetry!.tirePressureFrPsi!),
      if (telemetry!.tirePressureRlPsi != null)
        ('Rear left tire', telemetry!.tirePressureRlPsi!),
      if (telemetry!.tirePressureRrPsi != null)
        ('Rear right tire', telemetry!.tirePressureRrPsi!),
    ];
    bool needsAttention(VehicleHealthStatus status) =>
        status == VehicleHealthStatus.attention ||
        status == VehicleHealthStatus.critical;
    final lowPressure = signals
        .where(
          (signal) =>
              needsAttention(HealthThresholds.tirePressure(signal.$2)),
        )
        .toList();
    final batteryStatus = HealthThresholds.batteryTemperature(
      telemetry!.batteryTemperatureC,
    );
    final hotBattery = needsAttention(batteryStatus);
    final motorStatus = HealthThresholds.motorTemperature(
      telemetry!.motorTemperatureC,
    );
    final hotMotor = needsAttention(motorStatus);
    final pads = <(String, double)>[
      if (telemetry!.frontBrakePadLifePercent != null)
        ('Front', telemetry!.frontBrakePadLifePercent!),
      if (telemetry!.rearBrakePadLifePercent != null)
        ('Rear', telemetry!.rearBrakePadLifePercent!),
    ].where((pad) => needsAttention(HealthThresholds.brakePad(pad.$2))).toList();
    if (lowPressure.isEmpty && !hotBattery && !hotMotor && pads.isEmpty) {
      return const _NoticeCard(
        icon: Icons.check_circle_outline,
        text:
            'No conditions requiring attention were found in the available signals.',
        source: 'REPORTED DATA',
      );
    }
    return Column(
      children: [
        for (final signal in lowPressure)
          _AlertCard(
            title: 'Tire pressure needs attention',
            message:
                '${signal.$1}: ${signal.$2.toStringAsFixed(0)} PSI. Check the vehicle placard for the correct pressure.',
            icon: Icons.tire_repair_rounded,
            critical:
                HealthThresholds.tirePressure(signal.$2) ==
                VehicleHealthStatus.critical,
          ),
        if (hotBattery)
          _AlertCard(
            title: 'Battery temperature is elevated',
            message:
                'Reported battery temperature is ${telemetry!.batteryTemperatureC!.toStringAsFixed(0)}°C. Follow the vehicle guidance and contact qualified service if it persists.',
            icon: Icons.thermostat_rounded,
            critical: batteryStatus == VehicleHealthStatus.critical,
          ),
        if (hotMotor)
          _AlertCard(
            title: 'Motor temperature is elevated',
            message:
                'Reported motor temperature is ${telemetry!.motorTemperatureC!.toStringAsFixed(0)}°C. Drive gently and stop safely if it keeps rising.',
            icon: Icons.settings_input_component_rounded,
            critical: motorStatus == VehicleHealthStatus.critical,
          ),
        for (final pad in pads)
          _AlertCard(
            title: 'Brake pads are worn',
            message:
                '${pad.$1} pad life is ${pad.$2.toStringAsFixed(0)}%. Arrange a brake service.',
            icon: Icons.disc_full_rounded,
            critical:
                HealthThresholds.brakePad(pad.$2) ==
                VehicleHealthStatus.critical,
          ),
        const SizedBox(height: 5),
        const Align(
          alignment: Alignment.centerLeft,
          child: _SourceLabel(label: 'RULE-BASED · REPORTED TELEMETRY'),
        ),
      ],
    );
  }
}

class _CostSummary extends StatelessWidget {
  const _CostSummary({required this.records, required this.odometerKm});

  final List<VehicleMaintenanceRecord> records;
  final double? odometerKm;

  @override
  Widget build(BuildContext context) {
    final costs = records.where((record) => record.cost != null).toList();
    if (costs.isEmpty) {
      return const _Panel(
        child: _NoticeCard(
          icon: Icons.account_balance_wallet_outlined,
          text: 'No maintenance costs recorded yet.',
          source: 'USER ENTERED',
        ),
      );
    }
    final now = DateTime.now();
    final total = costs.fold<double>(
      0,
      (currentTotal, record) => currentTotal + record.cost!,
    );
    final thisYear = costs
        .where(
          (record) =>
              record.serviceDate != null &&
              record.serviceDate!.year == now.year,
        )
        .fold<double>(0, (currentTotal, record) => currentTotal + record.cost!);
    final average = total / costs.length;
    final spendByCategory = <String, double>{};
    for (final record in costs) {
      final category = _categoryFor(record);
      spendByCategory.update(
        category,
        (value) => value + record.cost!,
        ifAbsent: () => record.cost!,
      );
    }
    final topCategory = spendByCategory.entries.reduce(
      (a, b) => a.value >= b.value ? a : b,
    );

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeading(
            title: 'Maintenance costs',
            subtitle: 'Calculated from recorded service costs.',
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              _CostMetric(label: 'TOTAL SPENT', value: _money(total)),
              _CostMetric(label: 'THIS YEAR', value: _money(thisYear)),
              _CostMetric(label: 'AVERAGE SERVICE', value: _money(average)),
              if (odometerKm != null && odometerKm! > 0)
                _CostMetric(
                  label: 'RECORDED COST / KM',
                  value: _money(total / odometerKm!),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Highest spend: ${topCategory.key} · ${_money(topCategory.value)}',
            style: const TextStyle(
              color: AppTheme.mutedBlue,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const _SourceLabel(label: 'CALCULATED · USER-ENTERED COSTS'),
        ],
      ),
    );
  }
}

class _ServiceHistory extends StatelessWidget {
  const _ServiceHistory({
    required this.records,
    required this.category,
    required this.onRecordTap,
    required this.onAdd,
  });

  final List<VehicleMaintenanceRecord> records;
  final String category;
  final ValueChanged<VehicleMaintenanceRecord> onRecordTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final filtered = records
        .where(
          (record) => category == 'All' || _categoryFor(record) == category,
        )
        .toList();
    if (filtered.isEmpty) {
      return _Panel(
        child: _EmptyState(
          icon: Icons.handyman_outlined,
          title: records.isEmpty
              ? 'No service history yet'
              : 'No matching records',
          message: records.isEmpty
              ? 'Add a service that has actually been completed. It will be saved to this vehicle.'
              : 'No records are categorized as $category.',
          actionLabel: records.isEmpty ? 'Add service record' : null,
          onAction: records.isEmpty ? onAdd : null,
        ),
      );
    }
    return _Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var index = 0; index < filtered.length; index++)
            InkWell(
              onTap: () => onRecordTap(filtered[index]),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 21,
                      backgroundColor: const Color(0xFFEDF5FC),
                      child: Icon(
                        _categoryIcon(_categoryFor(filtered[index])),
                        color: AppTheme.blue,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            filtered[index].serviceType,
                            style: const TextStyle(
                              color: AppTheme.navy,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              if (filtered[index].serviceDate != null)
                                _dateLabel(filtered[index].serviceDate!),
                              if (filtered[index].odometerKm != null)
                                '${_whole(filtered[index].odometerKm!)} km',
                              if (filtered[index].serviceCenter?.isNotEmpty ==
                                  true)
                                filtered[index].serviceCenter!,
                            ].join(' · '),
                            style: const TextStyle(
                              color: AppTheme.mutedBlue,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (filtered[index].cost != null)
                      Text(
                        _money(filtered[index].cost!),
                        style: const TextStyle(
                          color: AppTheme.navy,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    const Icon(Icons.chevron_right, color: AppTheme.mutedBlue),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VehicleHeader extends StatelessWidget {
  const _VehicleHeader({required this.vehicle, required this.odometerKm});

  final Vehicle vehicle;
  final double? odometerKm;

  @override
  Widget build(BuildContext context) => _Panel(
    child: Row(
      children: [
        const CircleAvatar(
          backgroundColor: Color(0xFFEDF5FC),
          child: Icon(Icons.electric_car_rounded, color: AppTheme.blue),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                vehicle.model.isEmpty ? 'Vehicle' : vehicle.model,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                vehicle.registrationNumber.isEmpty
                    ? 'Registration unavailable'
                    : vehicle.registrationNumber,
                style: const TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text(
              'ODOMETER',
              style: TextStyle(
                color: AppTheme.mutedBlue,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              odometerKm == null ? 'Not reported' : '${_whole(odometerKm!)} km',
              style: const TextStyle(
                color: AppTheme.navy,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _CoverageNotice extends StatelessWidget {
  const _CoverageNotice();

  @override
  Widget build(BuildContext context) => const _Panel(
    child: _NoticeCard(
      icon: Icons.verified_user_outlined,
      text:
          'Insurance and warranty dates are not available in this vehicle’s data yet. No expiry reminders are inferred.',
      source: 'NOT RECORDED',
    ),
  );
}

class _CategoryFilter extends StatelessWidget {
  const _CategoryFilter({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final category in categories)
          Padding(
            padding: const EdgeInsets.only(right: 7),
            child: ChoiceChip(
              label: Text(category),
              selected: selected == category,
              onSelected: (_) => onSelected(category),
            ),
          ),
      ],
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final trailingAction = action;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
              ),
            ],
          ),
        ),
        ?trailingAction,
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(15)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE5EBF0)),
    ),
    child: child,
  );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.text,
    required this.source,
  });

  final IconData icon;
  final String text;
  final String source;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: AppTheme.blue, size: 21),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: const TextStyle(color: AppTheme.navy, height: 1.4),
            ),
            const SizedBox(height: 7),
            _SourceLabel(label: source),
          ],
        ),
      ),
    ],
  );
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.title,
    required this.message,
    required this.icon,
    required this.critical,
  });

  final String title;
  final String message;
  final IconData icon;
  final bool critical;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: critical ? const Color(0xFFFFF1F2) : const Color(0xFFFFF8EB),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(
        color: critical ? const Color(0xFFF1C1C7) : const Color(0xFFF1D8A9),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          color: critical ? const Color(0xFFD93C4E) : const Color(0xFFB87312),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                message,
                style: const TextStyle(color: AppTheme.mutedBlue, height: 1.35),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SourceLabel extends StatelessWidget {
  const _SourceLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      color: AppTheme.mutedBlue,
      fontSize: 9,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.7,
    ),
  );
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      Text(
        label,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
        ),
      ),
    ],
  );
}

class _CostMetric extends StatelessWidget {
  const _CostMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: AppTheme.mutedBlue,
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(
          color: AppTheme.navy,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );
}

class _DatePickerField extends StatelessWidget {
  const _DatePickerField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: Text(value == null ? 'Select date' : _dateLabel(value!)),
    ),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.navy,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      children: [
        Icon(icon, color: AppTheme.mutedBlue, size: 34),
        const SizedBox(height: 8),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppTheme.navy,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.mutedBlue, height: 1.4),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add),
            label: Text(actionLabel!),
          ),
        ],
      ],
    ),
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 42, color: AppTheme.blue),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

String _categoryFor(VehicleMaintenanceRecord record) {
  final category = record.category?.trim();
  if (category != null && category.isNotEmpty) {
    final match = _MaintenancePageState._categories
        .skip(1)
        .where((value) => value.toLowerCase() == category.toLowerCase());
    if (match.isNotEmpty) return match.first;
  }
  final text = record.serviceType.toLowerCase();
  if (text.contains('battery') || text.contains('charging')) return 'Battery';
  if (text.contains('brake')) return 'Brakes';
  if (text.contains('tire') ||
      text.contains('tyre') ||
      text.contains('wheel')) {
    return 'Tires';
  }
  if (text.contains('software') || text.contains('update')) return 'Software';
  return 'Other';
}

IconData _categoryIcon(String category) => switch (category) {
  'Battery' => Icons.battery_charging_full_rounded,
  'Brakes' => Icons.car_repair_rounded,
  'Tires' => Icons.tire_repair_rounded,
  'Software' => Icons.system_update_alt_rounded,
  _ => Icons.build_rounded,
};

String _dateLabel(DateTime date) =>
    '${date.day} ${_monthName(date.month)} ${date.year}';

String _monthName(int month) => const [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month - 1];

String _money(double amount) => '₹${amount.toStringAsFixed(2)}';

String _whole(double value) => value.toStringAsFixed(0);
