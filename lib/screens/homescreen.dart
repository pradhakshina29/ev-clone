import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import '../services/auth_service.dart';
import '../app_theme.dart';
import '../models/vehicle.dart';
import '../models/vehicle_health.dart';
import '../models/vehicle_telemetry.dart';
import '../services/distance_unit_service.dart';
import '../services/data_service.dart';
import '../services/weather_service.dart';
import '../widgets/vehicle_ble_state_view.dart';
import '../widgets/ev_logo.dart';
import '../widgets/weather_card.dart';
import 'charging_station_page.dart';
import 'maintenance.dart';
import 'music_page.dart';
import 'learn_screen.dart';
import 'profile_page.dart';
import '../services/learning_assistant_service.dart';
import 'trip_planner.dart';
import 'vehicle_health_page.dart';
import 'vehicle_details_page.dart';
import 'vehicle_controls_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.vehicle});

  final Vehicle vehicle;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _DashboardIdentity {
  const _DashboardIdentity({required this.name, required this.vehicle});

  final String name;
  final Vehicle vehicle;
}

class _HomeScreenState extends State<HomeScreen> {
  final DataService dataService = DataService();
  final WeatherService weatherService = WeatherService();
  late Future<_DashboardIdentity> dashboardIdentity;
  StreamSubscription<Vehicle?>? _vehicleSubscription;
  Vehicle? _latestVehicle;
  String? _vehicleStreamError;
  String _distanceUnit = 'km';
  int navIndex = 0;

  @override
  void initState() {
    super.initState();
    dashboardIdentity = _loadDashboardIdentity();
    _loadDistanceUnitPreference();
  }

  Future<void> _loadDistanceUnitPreference() async {
    final uid = AuthService().currentUser?.uid;
    if (uid == null) return;
    try {
      final profile = await dataService.getUserProfile(uid);
      if (!mounted) return;
      setState(() {
        _distanceUnit = DistanceUnitService.normalize(profile?.distanceUnit);
      });
    } catch (_) {
      // Keep the kilometre default if the preference cannot be loaded.
    }
  }

  @override
  void dispose() {
    _vehicleSubscription?.cancel();
    weatherService.dispose();
    super.dispose();
  }

  Future<_DashboardIdentity> _loadDashboardIdentity() async {
    final uid = AuthService().currentUser?.uid;
    if (uid == null) throw StateError('Please log in to load your dashboard.');

    final profile = await dataService.getUserProfile(uid);
    final vehicleId = profile?.vehicleId;
    if (profile == null || vehicleId == null || vehicleId.isEmpty) {
      throw StateError('Your user profile has no registered vehicle.');
    }
    if (vehicleId != widget.vehicle.id) {
      throw StateError('The selected vehicle does not match your profile.');
    }

    // Re-read authoritative identity from the backend each time the dashboard opens.
    final vehicle = await dataService.getVehicleById(vehicleId);
    if (vehicle == null) {
      throw StateError('Your registered vehicle is missing or inactive.');
    }
    await _vehicleSubscription?.cancel();
    _latestVehicle = vehicle;
    _vehicleStreamError = null;
    _vehicleSubscription = dataService
        .watchVehicleById(vehicleId)
        .listen(
          (updatedVehicle) {
            if (!mounted) return;
            if (updatedVehicle == null) {
              setState(
                () => _vehicleStreamError =
                    'The registered vehicle is no longer available.',
              );
              return;
            }
            setState(() {
              _latestVehicle = updatedVehicle;
              _vehicleStreamError = null;
            });
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(
              () => _vehicleStreamError =
                  'Could not refresh vehicle data: $error',
            );
          },
        );

    return _DashboardIdentity(name: profile.name, vehicle: vehicle);
  }

  void retryLoadingIdentity() {
    setState(() => dashboardIdentity = _loadDashboardIdentity());
  }

  String greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  void openChargingMap() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChargingStationPage()),
    );
  }

  Future<void> openProfile() async {
    setState(() => navIndex = 3);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProfilePage()),
    );
    if (mounted) {
      setState(() => navIndex = 0);
      _loadDistanceUnitPreference();
    }
  }

  Future<void> openLearn() async {
    final uid = AuthService().currentUser?.uid;
    if (uid == null) return;
    setState(() => navIndex = 2);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LearnScreen(
          vehicleStream: dataService.watchConnectedVehicle(uid),
          assistant: ApiLearningAssistantService(),
          distanceUnit: _distanceUnit,
        ),
      ),
    );
    if (mounted) setState(() => navIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FA),
      body: SafeArea(
        child: FutureBuilder<_DashboardIdentity>(
          future: dashboardIdentity,
          builder: (context, identitySnapshot) {
            if (identitySnapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (identitySnapshot.hasError || !identitySnapshot.hasData) {
              return _LoadError(
                message:
                    identitySnapshot.error?.toString() ??
                    'Could not load your vehicle profile.',
                onRetry: retryLoadingIdentity,
              );
            }

            final identity = identitySnapshot.data!;
            if (_vehicleStreamError != null) {
              return _LoadError(
                message: _vehicleStreamError!,
                onRetry: retryLoadingIdentity,
              );
            }
            final vehicle = _latestVehicle ?? identity.vehicle;
            return VehicleBleStateView(
              builder: (context, ble, snapshot) => LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 900;
                  final matchingSnapshot = snapshot?.vehicleId == vehicle.id
                      ? snapshot
                      : null;
                  final data = matchingSnapshot?.state;
                  final contentWidth = wide ? 1160.0 : 760.0;
                  final batterySection = _BatteryPanel(
                    data: data,
                    distanceUnit: _distanceUnit,
                  );
                  final weatherSection = WeatherCard(
                    service: weatherService,
                    distanceUnit: _distanceUnit,
                  );
                  final summary = _VehicleHealthSummary(
                    snapshot: matchingSnapshot,
                  );
                  final actions = _QuickActions(
                    onControls: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VehicleControlsPage(vehicle: vehicle),
                      ),
                    ),
                    onTripPlanner: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TripPlannerPage(
                          vehicleId: vehicle.id,
                          onConfigureVehicle: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  VehicleDetailsPage(vehicle: vehicle),
                            ),
                          ),
                          distanceUnit: _distanceUnit,
                        ),
                      ),
                    ),
                    onHealth: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VehicleHealthPage(vehicle: vehicle),
                      ),
                    ),
                    onMaintenance: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MaintenancePage(vehicle: vehicle),
                      ),
                    ),
                    onMusic: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const MusicPage()),
                    ),
                  );

                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: contentWidth),
                      child: CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              wide ? 32 : 20,
                              16,
                              wide ? 32 : 20,
                              28,
                            ),
                            sliver: SliverList(
                              delegate: SliverChildListDelegate([
                                _DashboardHeader(
                                  greeting: greeting(),
                                  name: identity.name,
                                  onProfile: openProfile,
                                ),
                                const SizedBox(height: 22),
                                _VehicleHero(
                                  vehicle: vehicle,
                                  data: data,
                                  connected:
                                      ble.isConnected &&
                                      ble.vehicleId == vehicle.id,
                                ),
                                const SizedBox(height: 18),
                                if (wide)
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: batterySection),
                                      const SizedBox(width: 16),
                                      Expanded(child: weatherSection),
                                    ],
                                  )
                                else ...[
                                  batterySection,
                                  const SizedBox(height: 14),
                                  weatherSection,
                                ],
                                const SizedBox(height: 16),
                                summary,
                                const SizedBox(height: 24),
                                _SectionHeading(
                                  eyebrow: 'AT A GLANCE',
                                  title: 'Your next move',
                                ),
                                const SizedBox(height: 12),
                                actions,
                              ]),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: navIndex,
        onTap: (index) {
          if (index == 3) {
            openProfile();
          } else {
            setState(() => navIndex = index);
            if (index == 1) openChargingMap();
            if (index == 2) openLearn();
          }
        },
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        selectedItemColor: AppTheme.blue,
        unselectedItemColor: AppTheme.mutedBlue,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.grid_view_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.ev_station_rounded),
            label: 'Charging',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.school_outlined),
            label: 'Learn',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.greeting,
    required this.name,
    required this.onProfile,
  });

  final String greeting;
  final String name;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const EVLogoMark(size: 42),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'EV SMART COMPANION',
              style: TextStyle(
                color: AppTheme.mutedBlue,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.25,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '$greeting, ${name.split(' ').first}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.navy,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
      IconButton(
        tooltip: 'Open profile',
        onPressed: onProfile,
        icon: const CircleAvatar(
          radius: 21,
          backgroundColor: Colors.white,
          child: Icon(Icons.person_outline_rounded, color: AppTheme.navy),
        ),
      ),
    ],
  );
}

class _VehicleHero extends StatelessWidget {
  const _VehicleHero({
    required this.vehicle,
    required this.data,
    required this.connected,
  });

  final Vehicle vehicle;
  final VehicleControlState? data;
  final bool connected;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    padding: const EdgeInsets.fromLTRB(22, 20, 22, 21),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF101F34), Color(0xFF183A51), Color(0xFF12665F)],
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x24101F34),
          blurRadius: 22,
          offset: Offset(0, 11),
        ),
      ],
    ),
    child: Stack(
      children: [
        Positioned(
          right: -22,
          top: -54,
          child: Container(
            width: 190,
            height: 190,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.07),
                width: 24,
              ),
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4CD7A7).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.circle,
                          size: 7,
                          color: Color(0xFF55E0AF),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          data == null
                              ? (connected
                                    ? 'WAITING FOR TELEMETRY'
                                    : 'NOT CONNECTED')
                              : data?.batteryPercent != null &&
                                    data!.batteryPercent <= 20
                              ? 'LOW BATTERY'
                              : data?.chargingConnected == true
                              ? 'CHARGING'
                              : 'VEHICLE LINKED',
                          style: const TextStyle(
                            color: Color(0xFFB3F2D9),
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    vehicle.model,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 25,
                      height: 1.12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    vehicle.registrationNumber,
                    style: const TextStyle(
                      color: Color(0xFFBDD0DD),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.1,
                    ),
                  ),
                  if (vehicle.bluetoothDeviceName.isNotEmpty) ...[
                    const SizedBox(height: 13),
                    Row(
                      children: [
                        const Icon(
                          Icons.bluetooth_rounded,
                          size: 16,
                          color: Color(0xFF73D9D0),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            vehicle.bluetoothDeviceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFD0E2E8),
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        const Text(
                          'Preview',
                          style: TextStyle(
                            color: Color(0xFFB5C4CC),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.electric_car_rounded,
              size: 86,
              color: Color(0xFF7BDCC8),
            ),
          ],
        ),
      ],
    ),
  );
}

class _BatteryPanel extends StatelessWidget {
  const _BatteryPanel({required this.data, required this.distanceUnit});

  final VehicleControlState? data;
  final String distanceUnit;

  @override
  Widget build(BuildContext context) {
    final batteryPercent = data?.batteryPercent;
    final battery = batteryPercent == null
        ? null
        : (batteryPercent / 100).clamp(0.0, 1.0);
    final displayRange = data == null
        ? 'N/A'
        : DistanceUnitService.format(data!.rangeKm, distanceUnit, decimals: 0);
    return Container(
      padding: const EdgeInsets.all(21),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0C172A3B),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeading(eyebrow: 'ENERGY', title: 'Driving range'),
          const SizedBox(height: 18),
          Row(
            children: [
              SizedBox(
                width: 104,
                height: 104,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: battery ?? 0),
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) => SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: battery == null ? 0 : value,
                          strokeWidth: 9,
                          strokeCap: StrokeCap.round,
                          backgroundColor: const Color(0xFFE9EEF2),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            batteryPercent != null && batteryPercent <= 20
                                ? const Color(0xFFE7A647)
                                : const Color(0xFF28A985),
                          ),
                        ),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          batteryPercent == null
                              ? 'N/A'
                              : '${batteryPercent.round()}%',
                          style: const TextStyle(
                            color: AppTheme.navy,
                            fontSize: 25,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Text(
                          'BATTERY',
                          style: TextStyle(
                            color: AppTheme.mutedBlue,
                            fontSize: 8,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayRange,
                      style: const TextStyle(
                        color: AppTheme.navy,
                        fontSize: 39,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      batteryPercent == null
                          ? 'Connect to the simulator for live range'
                          : 'estimated range',
                      style: const TextStyle(
                        color: AppTheme.mutedBlue,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _ChargeBadge(
                      isCharging: data?.chargingConnected ?? false,
                      unavailable: data == null,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 17),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: battery ?? 0,
              minHeight: 6,
              backgroundColor: const Color(0xFFE9EEF2),
              valueColor: AlwaysStoppedAnimation<Color>(
                batteryPercent != null && batteryPercent <= 20
                    ? const Color(0xFFE7A647)
                    : const Color(0xFF28A985),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChargeBadge extends StatelessWidget {
  const _ChargeBadge({required this.isCharging, this.unavailable = false});

  final bool isCharging;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final color = unavailable
        ? const Color(0xFF526477)
        : isCharging
        ? const Color(0xFF197B69)
        : const Color(0xFF526477);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: !unavailable && isCharging
            ? const Color(0xFFE6F6EF)
            : const Color(0xFFF0F3F6),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            unavailable
                ? Icons.bluetooth_disabled
                : isCharging
                ? Icons.bolt_rounded
                : Icons.power_outlined,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            unavailable
                ? 'Telemetry unavailable'
                : isCharging
                ? 'Charging now'
                : 'Not charging',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _VehicleHealthSummary extends StatelessWidget {
  const _VehicleHealthSummary({required this.snapshot});

  final VehicleStateSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final telemetry = VehicleData.fromSnapshot(snapshot);
    final health = telemetry == null
        ? null
        : VehicleHealthData.fromTelemetry(telemetry);
    final needsAttention = health?.components
        .where(
          (component) =>
              component.status == VehicleHealthStatus.attention ||
              component.status == VehicleHealthStatus.critical,
        )
        .map((component) => component.label)
        .toList();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF5F0),
        borderRadius: BorderRadius.circular(20),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 470;
          final content = [
            Expanded(
              flex: 2,
              child: Text(
                'Vehicle health: ${health == null ? 'N/A' : _sentenceCase(health.overallStatus)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.navy,
                ),
              ),
            ),
            _SummaryMetric(
              label: 'BATTERY HEALTH',
              value: telemetry == null
                  ? 'N/A'
                  : '${telemetry.batteryHealth.round()}%',
              icon: Icons.favorite_outline,
            ),
            _SummaryMetric(
              label: 'NEEDS ATTENTION',
              value: needsAttention == null
                  ? 'Not reported'
                  : needsAttention.isEmpty
                  ? 'Nothing'
                  : needsAttention.join(', '),
              icon: Icons.info_outline,
            ),
          ];
          if (compact) {
            return Column(
              children: [
                Row(children: [content[0]]),
                const Divider(height: 24),
                Row(
                  children: [content[1], const SizedBox(width: 12), content[2]],
                ),
              ],
            );
          }
          return Row(
            children: [
              content[0],
              const _SummaryDivider(),
              content[1],
              const _SummaryDivider(),
              content[2],
            ],
          );
        },
      ),
    );
  }
}

String _sentenceCase(String value) =>
    value.isEmpty ? value : value[0] + value.substring(1).toLowerCase();

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF318B72)),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.mutedBlue,
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .6,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 13,
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

class _SummaryDivider extends StatelessWidget {
  const _SummaryDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 32,
    margin: const EdgeInsets.symmetric(horizontal: 14),
    color: const Color(0xFFD1E5DC),
  );
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.onControls,
    required this.onTripPlanner,
    required this.onHealth,
    required this.onMaintenance,
    required this.onMusic,
  });

  final VoidCallback onControls;
  final VoidCallback onTripPlanner;
  final VoidCallback onHealth;
  final VoidCallback onMaintenance;
  final VoidCallback onMusic;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 900 ? 4 : 2;
      final actions = [
        _ActionItem(
          'Controls',
          'Manage your EV',
          Icons.tune_rounded,
          const Color(0xFFE4F3ED),
          const Color(0xFF168266),
          onControls,
        ),
        _ActionItem(
          'Trip planner',
          'Plan your route',
          Icons.alt_route_rounded,
          const Color(0xFFE9EFFB),
          const Color(0xFF416FC0),
          onTripPlanner,
        ),
        _ActionItem(
          'Vehicle health',
          'Check diagnostics',
          Icons.monitor_heart_outlined,
          const Color(0xFFF2ECFB),
          const Color(0xFF8055B5),
          onHealth,
        ),
        _ActionItem(
          'Maintenance',
          'Service schedule',
          Icons.build_circle_outlined,
          const Color(0xFFFFF1E2),
          const Color(0xFFCC8128),
          onMaintenance,
        ),
        _ActionItem(
          'Music',
          'Spotify search & play',
          Icons.library_music_outlined,
          const Color(0xFFE6F6EC),
          const Color(0xFF1E8E4E),
          onMusic,
        ),
      ];
      final spacing = 10.0;
      final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final action in actions)
            SizedBox(
              width: width,
              child: _ActionTile(action: action),
            ),
        ],
      );
    },
  );
}

class _ActionItem {
  const _ActionItem(
    this.title,
    this.subtitle,
    this.icon,
    this.tint,
    this.color,
    this.onTap,
  );

  final String title;
  final String subtitle;
  final IconData icon;
  final Color tint;
  final Color color;
  final VoidCallback onTap;
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action});

  final _ActionItem action;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: action.onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: action.tint,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(action.icon, color: action.color, size: 21),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    action.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.navy,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    action.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.mutedBlue,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              size: 12,
              color: AppTheme.mutedBlue,
            ),
          ],
        ),
      ),
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.eyebrow, required this.title});

  final String eyebrow;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        eyebrow,
        style: const TextStyle(
          color: AppTheme.mutedBlue,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        title,
        style: const TextStyle(
          color: AppTheme.navy,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 36,
            color: AppTheme.mutedBlue,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}
