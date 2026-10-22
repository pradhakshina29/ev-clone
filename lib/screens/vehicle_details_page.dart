import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/user_model.dart';
import '../models/vehicle.dart';
import '../services/api/api_client.dart';
import '../services/auth_service.dart';
import '../services/distance_unit_service.dart';
import '../services/data_service.dart';
import '../widgets/common_widgets.dart';
import '../widgets/vehicle_ble_state_view.dart';
import 'auth_gate.dart';

class VehicleDetailsPage extends StatefulWidget {
  const VehicleDetailsPage({super.key, this.pendingSignup, this.vehicle});

  final PendingSignup? pendingSignup;
  final Vehicle? vehicle;

  @override
  State<VehicleDetailsPage> createState() => _VehicleDetailsPageState();
}

class _VehicleDetailsPageState extends State<VehicleDetailsPage> {
  final formKey = GlobalKey<FormState>();
  final registration = TextEditingController();
  final model = TextEditingController();
  final ownerName = TextEditingController();
  final vin = TextEditingController();
  final authService = AuthService();
  final dataService = DataService();
  String? _distanceUnit;
  String? _distanceUnitError;
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    // During sign-up nobody is logged in yet, so there is no profile to read.
    if (widget.pendingSignup == null) _loadDistanceUnit();
  }

  Future<void> _loadDistanceUnit() async {
    try {
      final uid = authService.currentUser?.uid;
      if (uid == null) throw StateError('Sign in to load vehicle preferences.');
      final profile = await dataService.getUserProfile(uid);
      if (profile == null) {
        throw StateError('Your user profile is unavailable.');
      }
      if (!mounted) return;
      setState(() {
        _distanceUnit = DistanceUnitService.normalize(profile.distanceUnit);
        _distanceUnitError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _distanceUnitError = 'Could not load your distance preference: $error';
      });
    }
  }

  @override
  void dispose() {
    registration.dispose();
    model.dispose();
    ownerName.dispose();
    vin.dispose();
    super.dispose();
  }

  Future<void> saveVehicleAndContinue() async {
    if (isLoading) return;
    if (!formKey.currentState!.validate()) return;

    setState(() => isLoading = true);
    final signup = widget.pendingSignup;
    try {
      if (signup != null) {
        // One request creates the account and links the vehicle; on any
        // error nothing is saved.
        await authService.signUp(
          name: signup.name,
          email: signup.email,
          password: signup.password,
          phone: signup.mobile,
          city: signup.city,
          registrationNumber: registration.text,
          model: model.text,
          ownerName: ownerName.text,
          vin: vin.text,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Account created. Log in with your email and password.',
            ),
          ),
        );
      } else {
        final user = authService.currentUser;
        if (user == null) {
          throw StateError('Your sign-in session ended. Please log in again.');
        }
        final vehicle = await dataService.verifyConnectedVehicleDetails(
          uid: user.uid,
          registrationNumber: registration.text,
          model: model.text,
          ownerName: ownerName.text,
          vin: vin.text,
        );
        if (vehicle == null) {
          throw StateError(
            'These details do not match the vehicle connected to this account.',
          );
        }
      }

      if (!mounted) return;
      // After sign-up nobody is logged in, so AuthGate shows Login.
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthGate()),
        (route) => false,
      );
    } catch (error) {
      debugPrint(
        error is ApiException
            ? 'Vehicle registration failed: HTTP ${error.statusCode} ${error.code}'
            : 'Vehicle registration failed: ${error.runtimeType}',
      );
      if (mounted) {
        await showErrorDialog(
          context,
          authService.messageFor(error),
          title: signup != null
              ? 'Unable to create your account'
              : 'Unable to verify vehicle',
        );
      }
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  Future<void> _configureVehicle(Vehicle vehicle) async {
    final formKey = GlobalKey<FormState>();
    final rangeController = TextEditingController(
      text: vehicle.maximumRangeKm != null && vehicle.maximumRangeKm! > 0
          ? vehicle.maximumRangeKm.toString()
          : '',
    );
    final capacityController = TextEditingController(
      text:
          vehicle.batteryCapacityKwh != null && vehicle.batteryCapacityKwh! > 0
          ? vehicle.batteryCapacityKwh.toString()
          : '',
    );
    final connectorController = TextEditingController(
      text: vehicle.connectorType,
    );
    var saving = false;

    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Vehicle configuration'),
            content: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: rangeController,
                      inputFormatters: [LengthLimitingTextInputFormatter(8)],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Maximum rated range (km)',
                        helperText:
                            'Required to calculate current range and charging search radius.',
                      ),
                      validator: (value) {
                        final parsed = double.tryParse(value?.trim() ?? '');
                        if (parsed == null || !parsed.isFinite || parsed <= 0) {
                          return 'Enter a maximum range greater than zero.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: capacityController,
                      inputFormatters: [LengthLimitingTextInputFormatter(8)],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Battery capacity (kWh)',
                        helperText: 'Optional; enter only a known value.',
                      ),
                      validator: (value) {
                        final text = value?.trim() ?? '';
                        if (text.isEmpty) return null;
                        final parsed = double.tryParse(text);
                        if (parsed == null || !parsed.isFinite || parsed <= 0) {
                          return 'Enter a value greater than zero or leave blank.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: connectorController,
                      inputFormatters: [LengthLimitingTextInputFormatter(40)],
                      decoration: const InputDecoration(
                        labelText: 'Connector type',
                        helperText: 'Optional; enter a known connector type.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (!formKey.currentState!.validate()) return;
                        setDialogState(() => saving = true);
                        try {
                          final capacity =
                              capacityController.text.trim().isEmpty
                              ? null
                              : double.parse(capacityController.text.trim());
                          await dataService.updateVehicleConfiguration(
                            vehicleId: vehicle.id,
                            maximumRangeKm: double.parse(
                              rangeController.text.trim(),
                            ),
                            batteryCapacityKwh: capacity,
                            connectorType: connectorController.text.trim(),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (error) {
                          setDialogState(() => saving = false);
                          if (dialogContext.mounted) {
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Could not save vehicle configuration: $error',
                                ),
                              ),
                            );
                          }
                        }
                      },
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      );

      if (saved == true && mounted) {
        final refreshed = await dataService.getVehicleRecordById(vehicle.id);
        if (!mounted) return;
        if (refreshed == null) {
          throw StateError(
            'Configuration was saved, but the vehicle could not be reloaded.',
          );
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vehicle configuration saved.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reload vehicle data: $error')),
        );
      }
    } finally {
      rangeController.dispose();
      capacityController.dispose();
      connectorController.dispose();
    }
  }

  Widget _registeredVehicleView(Vehicle vehicle) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My vehicle'),
        actions: [
          IconButton(
            tooltip: 'Configure vehicle',
            onPressed: isLoading ? null : () => _configureVehicle(vehicle),
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.electric_car_rounded),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            vehicle.model.isEmpty
                                ? 'Vehicle model unavailable'
                                : vehicle.model,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _InfoTile(
                      label: 'Registration',
                      value: _displayValue(vehicle.registrationNumber),
                    ),
                    _InfoTile(
                      label: 'Vehicle ID',
                      value: _displayValue(vehicle.id),
                    ),
                    _InfoTile(
                      label: 'Owner',
                      value: _displayValue(vehicle.ownerName),
                    ),
                    _InfoTile(
                      label: 'Status',
                      value: vehicle.isActive ? 'Active' : 'Inactive',
                    ),
                    _InfoTile(
                      label: 'Maximum rated range',
                      value:
                          vehicle.maximumRangeKm != null &&
                              vehicle.maximumRangeKm! > 0
                          ? _formatRange(vehicle.maximumRangeKm!)
                          : 'Not available',
                    ),
                    _InfoTile(
                      label: 'Battery capacity',
                      value:
                          vehicle.batteryCapacityKwh != null &&
                              vehicle.batteryCapacityKwh! > 0
                          ? '${vehicle.batteryCapacityKwh} kWh'
                          : 'Not available',
                    ),
                    _InfoTile(
                      label: 'Connector type',
                      value: _displayValue(vehicle.connectorType),
                    ),
                    _InfoTile(
                      label: 'Bluetooth',
                      value: _displayValue(vehicle.bluetoothDeviceId),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              VehicleBleStateView(
                builder: (context, client, snapshot) {
                  final state = snapshot?.vehicleId == vehicle.id
                      ? snapshot?.state
                      : null;
                  return Column(
                    children: [
                      _InfoTile(
                        label: 'Current battery',
                        value: state == null
                            ? 'N/A — connect to the simulator'
                            : '${state.batteryPercent.toStringAsFixed(0)}%',
                      ),
                      _InfoTile(
                        label: 'Current estimated range',
                        value: state == null
                            ? 'N/A — connect to the simulator'
                            : _formatRange(state.rangeKm),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              if (vehicle.maximumRangeKm == null ||
                  vehicle.maximumRangeKm! <= 0 ||
                  vehicle.batteryCapacityKwh == null ||
                  vehicle.batteryCapacityKwh! <= 0 ||
                  vehicle.connectorType.trim().isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7E8),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Some vehicle configuration is missing.',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Configure known values and save them. Missing values are not estimated.',
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => _configureVehicle(vehicle),
                          icon: const Icon(Icons.tune_rounded),
                          label: const Text('Configure'),
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

  String _displayValue(String value) =>
      value.trim().isEmpty ? 'Not available' : value;

  String _formatRange(double rangeKm) {
    final unit = _distanceUnit;
    if (unit == null) {
      return _distanceUnitError ?? 'Loading distance preference…';
    }
    return DistanceUnitService.format(rangeKm, unit);
  }

  @override
  Widget build(BuildContext context) {
    final vehicle = widget.vehicle;

    if (vehicle != null) {
      return StreamBuilder<Vehicle?>(
        stream: dataService.watchVehicleById(vehicle.id),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              appBar: AppBar(title: const Text('My vehicle')),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Could not load vehicle data: ${snapshot.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final latestVehicle = snapshot.data;
          if (latestVehicle == null) {
            return Scaffold(
              appBar: AppBar(title: const Text('My vehicle')),
              body: const Center(
                child: Text('This vehicle is no longer available.'),
              ),
            );
          }
          return _registeredVehicleView(latestVehicle);
        },
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
            child: Column(
              children: [
                ScreenHeader(
                  title: widget.pendingSignup == null
                      ? 'Register Your Vehicle'
                      : 'Verify Your Vehicle',
                  subtitle: 'Enter the details of your pre-registered vehicle.',
                ),
                const SizedBox(height: 34),
                TextInputField(
                  controller: registration,
                  label: 'Registration Number',
                  hint: 'Enter registration number',
                  icon: Icons.confirmation_number_outlined,
                  textCapitalization: TextCapitalization.characters,
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter the registered vehicle number'
                      : null,
                ),
                const SizedBox(height: 18),
                TextInputField(
                  controller: model,
                  label: 'Vehicle Model',
                  hint: 'Enter vehicle model',
                  icon: Icons.electric_car_outlined,
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter the vehicle model'
                      : null,
                ),
                const SizedBox(height: 18),
                TextInputField(
                  controller: ownerName,
                  label: 'Owner Name',
                  hint: 'Enter registered owner name',
                  icon: Icons.person_outline,
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter the registered owner name'
                      : null,
                ),
                const SizedBox(height: 18),
                TextInputField(
                  controller: vin,
                  label: 'VIN',
                  hint: 'Enter vehicle VIN',
                  icon: Icons.fingerprint,
                  textCapitalization: TextCapitalization.characters,
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter the vehicle VIN'
                      : null,
                ),
                const SizedBox(height: 30),
                PrimaryButton(
                  label: 'Verify and Pair Vehicle',
                  onPressed: saveVehicleAndContinue,
                  isLoading: isLoading,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
