import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/charging_station.dart';
import '../models/road_route.dart';
import '../models/trip_plan.dart';
import 'ev_range_service.dart';

class TripFeasibilityService {
  const TripFeasibilityService();

  TripVehicleState createVehicleState({
    required String vehicleId,
    required String vehicleModel,
    required double maximumRangeKm,
    required double batteryPercentage,
    required double safetyReserveFraction,
  }) {
    if (!safetyReserveFraction.isFinite ||
        safetyReserveFraction < 0 ||
        safetyReserveFraction >= 1) {
      throw ArgumentError.value(
        safetyReserveFraction,
        'safetyReserveFraction',
        'Must be between zero (inclusive) and one (exclusive).',
      );
    }
    final availableRange = EvRangeService.calculateCurrentRangeKm(
      maximumRangeKm: maximumRangeKm,
      batteryPercentage: batteryPercentage,
    );
    final safetyFactor = 1 - safetyReserveFraction;
    final usableRange = EvRangeService.calculateUsableRange(
      estimatedRangeKm: availableRange,
      safetyFactor: safetyFactor,
    );
    return TripVehicleState(
      vehicleId: vehicleId,
      vehicleModel: vehicleModel,
      maximumRangeKm: maximumRangeKm,
      batteryPercentage: batteryPercentage,
      availableRangeKm: availableRange,
      usableRangeKm: usableRange,
      minimumReserveKm: availableRange - usableRange,
    );
  }

  TripPlanningResult assess({
    required TripPlanningRequest request,
    required GeocodedDestination destination,
    required RoadRoute route,
    required List<ChargingStation> stations,
    bool stationSearchFailed = false,
  }) {
    final points = route.points;
    final measuredGeometryLength = _geometryDistanceKm(points);
    final scale = measuredGeometryLength > 0
        ? route.distanceKm / measuredGeometryLength
        : 1.0;
    final orderedStations =
        stations
            .map(
              (station) => (
                station: station,
                progress:
                    _distanceAlongRouteKm(station.location, points) * scale,
              ),
            )
            .where(
              (entry) =>
                  entry.progress >= 0 && entry.progress <= route.distanceKm,
            )
            .toList()
          ..sort((a, b) => a.progress.compareTo(b.progress));

    final initialRangeKm = request.vehicle.availableRangeKm;
    final initialSafeRangeKm = request.vehicle.usableRangeKm;
    final fullRangeKm = request.vehicle.maximumRangeKm;
    final fullSafeRangeKm = EvRangeService.calculateUsableRange(
      estimatedRangeKm: fullRangeKm,
      safetyFactor: 1 - request.safetyReserveFraction,
    );
    final predecessorIndexes = List<int?>.filled(orderedStations.length, null);
    final stopCounts = List<int?>.filled(orderedStations.length, null);
    final stationLegs = <String, TripLegAssessment>{};

    for (var index = 0; index < orderedStations.length; index++) {
      final entry = orderedStations[index];
      var bestStopCount =
          entry.progress + (entry.station.distanceFromRouteKm ?? 0) <=
                  initialSafeRangeKm
              ? 1
              : null;
      int? bestPredecessor;
      for (var previousIndex = 0;
          previousIndex < index;
          previousIndex++) {
        final previousStopCount = stopCounts[previousIndex];
        if (previousStopCount == null) continue;
        final previous = orderedStations[previousIndex];
        final distance =
            entry.progress -
            previous.progress +
            (previous.station.distanceFromRouteKm ?? 0) +
            (entry.station.distanceFromRouteKm ?? 0);
        if (distance > fullSafeRangeKm) continue;
        final candidateStopCount = previousStopCount + 1;
        if (bestStopCount == null ||
            candidateStopCount < bestStopCount ||
            (candidateStopCount == bestStopCount &&
                (bestPredecessor == null ||
                    previousIndex > bestPredecessor))) {
          bestStopCount = candidateStopCount;
          bestPredecessor = previousIndex;
        }
      }
      stopCounts[index] = bestStopCount;
      predecessorIndexes[index] = bestPredecessor;

      final fromIndex = bestPredecessor;
      final incomingDistance = fromIndex == null
          ? entry.progress + (entry.station.distanceFromRouteKm ?? 0)
          : entry.progress -
                orderedStations[fromIndex].progress +
                (orderedStations[fromIndex].station.distanceFromRouteKm ?? 0) +
                (entry.station.distanceFromRouteKm ?? 0);
      stationLegs[entry.station.id] = _leg(
        from: fromIndex == null
            ? 'Start'
            : orderedStations[fromIndex].station.name ??
                  orderedStations[fromIndex].station.id,
        to: entry.station.name ?? entry.station.id,
        distanceKm: incomingDistance,
        availableRangeKm: fromIndex == null ? initialRangeKm : fullRangeKm,
        safetyReserveFraction: request.safetyReserveFraction,
      );
    }

    var selectedTerminalIndex = -1;
    var feasible = route.distanceKm <= initialSafeRangeKm;
    var bestTerminalStopCount = feasible ? 0 : null;
    for (var index = 0; index < orderedStations.length; index++) {
      final stopCount = stopCounts[index];
      if (stopCount == null) continue;
      final entry = orderedStations[index];
      final distance =
          route.distanceKm -
          entry.progress +
          (entry.station.distanceFromRouteKm ?? 0);
      if (distance > fullSafeRangeKm) continue;
      if (bestTerminalStopCount == null ||
          stopCount < bestTerminalStopCount) {
        bestTerminalStopCount = stopCount;
        selectedTerminalIndex = index;
        feasible = true;
      }
    }

    var partialTerminalIndex = selectedTerminalIndex;
    if (!feasible) {
      for (var index = 0; index < orderedStations.length; index++) {
        if (stopCounts[index] != null &&
            (partialTerminalIndex < 0 ||
                orderedStations[index].progress >
                    orderedStations[partialTerminalIndex].progress)) {
          partialTerminalIndex = index;
        }
      }
    }
    final pathIndexes = <int>[];
    for (
      var index = partialTerminalIndex;
      index >= 0;
      index = predecessorIndexes[index] ?? -1
    ) {
      pathIndexes.add(index);
      if (predecessorIndexes[index] == null) break;
    }
    final path = pathIndexes.reversed.toList(growable: false);
    final selectedStops = path
        .map((index) => orderedStations[index].station)
        .toList(growable: false);
    final selectedIds = selectedStops.map((station) => station.id).toSet();
    final legs = <TripLegAssessment>[];
    var cursorProgressKm = 0.0;
    var cursorDiversionKm = 0.0;
    var cursorLabel = 'Start';
    var rangeAtCursorKm = initialRangeKm;
    for (final index in path) {
      final entry = orderedStations[index];
      final distance =
          entry.progress -
          cursorProgressKm +
          cursorDiversionKm +
          (entry.station.distanceFromRouteKm ?? 0);
      final leg = _leg(
        from: cursorLabel,
        to: entry.station.name ?? entry.station.id,
        distanceKm: distance,
        availableRangeKm: rangeAtCursorKm,
        safetyReserveFraction: request.safetyReserveFraction,
      );
      legs.add(leg);
      stationLegs[entry.station.id] = leg;
      cursorProgressKm = entry.progress;
      cursorDiversionKm = entry.station.distanceFromRouteKm ?? 0;
      cursorLabel = entry.station.name ?? entry.station.id;
      rangeAtCursorKm = fullRangeKm;
    }
    if (feasible) {
      legs.add(
        _leg(
          from: cursorLabel,
          to: destination.name,
          distanceKm:
              route.distanceKm - cursorProgressKm + cursorDiversionKm,
          availableRangeKm: rangeAtCursorKm,
          safetyReserveFraction: request.safetyReserveFraction,
        ),
      );
    } else {
      final nextStation = orderedStations
          .where(
            (entry) =>
                !selectedIds.contains(entry.station.id) &&
                entry.progress > cursorProgressKm + 0.01,
          )
          .firstOrNull;
      legs.add(
        _leg(
          from: cursorLabel,
          to: nextStation?.station.name ?? destination.name,
          distanceKm: nextStation == null
              ? route.distanceKm - cursorProgressKm + cursorDiversionKm
              : nextStation.progress -
                    cursorProgressKm +
                    cursorDiversionKm +
                    (nextStation.station.distanceFromRouteKm ?? 0),
          availableRangeKm: rangeAtCursorKm,
          safetyReserveFraction: request.safetyReserveFraction,
        ),
      );
    }

    final stationAssessments = orderedStations
        .map(
          (entry) => TripStationAssessment(
            station: entry.station,
            routeProgressKm: entry.progress,
            incomingLeg: stationLegs[entry.station.id],
            selectedForPlan: selectedIds.contains(entry.station.id),
          ),
        )
        .toList(growable: false);
    final warnings = <String>[];
    if (stationSearchFailed) {
      warnings.add(
        'Charging stations could not be loaded because the map service is '
        'busy. The route is shown; tap Plan Trip again to retry the station '
        'search.',
      );
    } else if (stations.isEmpty) {
      warnings.add('No live charging stations were found along this route.');
    }
    if (!feasible) {
      warnings.add(
        'No feasible charging-stop sequence reaches the destination while '
        'maintaining the configured reserve.',
      );
    }
    if (selectedStops.isNotEmpty) {
      warnings.add(
        'Leg distances use OSRM route progress plus station diversion '
        'distances; roads to and from stations are not separately routed. '
        'Charging is assumed to restore rated range. Charger compatibility, '
        'availability, and charge time are not verified.',
      );
    }
    return TripPlanningResult(
      request: request,
      start: request.start,
      destination: destination,
      route: route,
      liveStations: List.unmodifiable(stations),
      stationAssessments: List.unmodifiable(stationAssessments),
      selectedStops: List.unmodifiable(selectedStops),
      legs: List.unmodifiable(legs),
      isFeasible: feasible,
      warnings: List.unmodifiable(warnings),
    );
  }

  static TripLegAssessment _leg({
    required String from,
    required String to,
    required double distanceKm,
    required double availableRangeKm,
    required double safetyReserveFraction,
  }) {
    final reserveKm = availableRangeKm * safetyReserveFraction;
    final remainingRangeKm = availableRangeKm - distanceKm;
    final reachable = distanceKm <= availableRangeKm - reserveKm + 1e-9;
    return TripLegAssessment(
      from: from,
      to: to,
      distanceKm: distanceKm,
      availableRangeKm: availableRangeKm,
      minimumReserveKm: reserveKm,
      remainingRangeKm: math.max(0, remainingRangeKm),
      isReachable: reachable,
    );
  }

  static double _geometryDistanceKm(List<LatLng> points) {
    var distance = 0.0;
    for (var index = 1; index < points.length; index++) {
      distance += ChargingStation.distanceBetweenKm(
        points[index - 1],
        points[index],
      );
    }
    return distance;
  }

  static double _distanceAlongRouteKm(LatLng location, List<LatLng> route) {
    if (route.length < 2) return 0;
    var traversed = 0.0;
    var closestDistance = double.infinity;
    var closestProgress = 0.0;
    for (var index = 1; index < route.length; index++) {
      final start = route[index - 1];
      final end = route[index];
      final segmentLength = ChargingStation.distanceBetweenKm(start, end);
      final meanLatitude = location.latitude * math.pi / 180;
      final scaleX = 111.320 * math.cos(meanLatitude);
      const scaleY = 110.574;
      final dx = (end.longitude - start.longitude) * scaleX;
      final dy = (end.latitude - start.latitude) * scaleY;
      final px = (location.longitude - start.longitude) * scaleX;
      final py = (location.latitude - start.latitude) * scaleY;
      final denominator = dx * dx + dy * dy;
      final fraction = denominator == 0
          ? 0.0
          : ((px * dx + py * dy) / denominator).clamp(0.0, 1.0);
      final crossTrack = math.sqrt(
        math.pow(px - dx * fraction, 2) + math.pow(py - dy * fraction, 2),
      );
      if (crossTrack < closestDistance) {
        closestDistance = crossTrack;
        closestProgress = traversed + segmentLength * fraction;
      }
      traversed += segmentLength;
    }
    return closestProgress;
  }
}
