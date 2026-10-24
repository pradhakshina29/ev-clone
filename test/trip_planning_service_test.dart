import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_2/models/charging_station.dart';
import 'package:flutter_application_2/models/road_route.dart';
import 'package:flutter_application_2/models/trip_plan.dart';
import 'package:flutter_application_2/services/charging_station_service.dart';
import 'package:flutter_application_2/services/road_directions_service.dart';
import 'package:flutter_application_2/services/trip_feasibility_service.dart';
import 'package:flutter_application_2/services/trip_planning_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'support/fake_api.dart';

void main() {
  const feasibility = TripFeasibilityService();

  TripPlanningRequest requestFor({
    required String vehicleId,
    required double maximumRangeKm,
    required double batteryPercentage,
    String destination = 'Destination',
  }) {
    final state = feasibility.createVehicleState(
      vehicleId: vehicleId,
      vehicleModel: 'EV Test',
      maximumRangeKm: maximumRangeKm,
      batteryPercentage: batteryPercentage,
      safetyReserveFraction: 0.2,
    );
    return TripPlanningRequest(
      start: const LatLng(0, 0),
      destinationQuery: destination,
      vehicle: state,
      safetyReserveFraction: 0.2,
    );
  }

  RoadRoute route(double distanceKm, GeocodedDestination destination) =>
      RoadRoute(
        points: const [LatLng(0, 0), LatLng(0, 3)],
        distanceKm: distanceKm,
        duration: const Duration(hours: 3),
        destination: destination,
      );

  ChargingStation station(String id, double longitude) => ChargingStation(
    id: id,
    name: id,
    location: LatLng(0, longitude),
    distanceKm: 0,
    distanceFromRouteKm: 0,
  );

  test(
    'uses the explicit configurable reserve with existing EV range logic',
    () {
      final vehicle = feasibility.createVehicleState(
        vehicleId: 'EV001',
        vehicleModel: 'EV Test',
        maximumRangeKm: 300,
        batteryPercentage: 80,
        safetyReserveFraction: 0.2,
      );

      expect(vehicle.availableRangeKm, 240);
      expect(vehicle.usableRangeKm, closeTo(192, 1e-9));
      expect(vehicle.minimumReserveKm, closeTo(48, 1e-9));
    },
  );

  test('selects sequential charging stops while maintaining the reserve', () {
    const destination = GeocodedDestination(
      name: 'Destination',
      address: 'Destination',
      location: LatLng(0, 3),
    );
    final result = feasibility.assess(
      request: requestFor(
        vehicleId: 'EV001',
        maximumRangeKm: 200,
        batteryPercentage: 100,
      ),
      destination: destination,
      route: route(300, destination),
      stations: [station('first', 1), station('second', 2)],
    );

    expect(result.isFeasible, isTrue);
    expect(result.selectedStops.map((item) => item.id), ['first', 'second']);
    expect(result.legs, hasLength(3));
    expect(result.legs.every((leg) => leg.isReachable), isTrue);
    expect(result.legs.first.minimumReserveKm, 40);
  });

  test('finds a feasible station sequence despite a distracting detour', () {
    const destination = GeocodedDestination(
      name: 'Destination',
      address: 'Destination',
      location: LatLng(0, 3.45),
    );
    final routeWithDetour = RoadRoute(
      points: const [LatLng(0, 0), LatLng(0, 3.45)],
      distanceKm: 345,
      duration: const Duration(hours: 4),
      destination: destination,
    );
    final detourStation = ChargingStation(
      id: 'detour',
      name: 'Detour station',
      location: const LatLng(0.045, 0.89),
      distanceKm: 0,
      distanceFromRouteKm: 5,
    );
    final result = feasibility.assess(
      request: requestFor(
        vehicleId: 'EV001',
        maximumRangeKm: 200,
        batteryPercentage: 100,
      ),
      destination: destination,
      route: routeWithDetour,
      stations: [station('early', 0.85), detourStation, station('later', 2.45)],
    );

    expect(result.isFeasible, isTrue);
    expect(result.selectedStops.map((item) => item.id), ['early', 'later']);
    expect(result.legs.every((leg) => leg.isReachable), isTrue);
  });

  test('rejects a first station beyond current safe range', () {
    const destination = GeocodedDestination(
      name: 'Far destination',
      address: 'Far destination',
      location: LatLng(0, 5),
    );
    final result = feasibility.assess(
      request: requestFor(
        vehicleId: 'EV001',
        maximumRangeKm: 100,
        batteryPercentage: 100,
      ),
      destination: destination,
      route: route(500, destination),
      stations: [station('unreachable', 1.5)],
    );

    expect(result.isFeasible, isFalse);
    expect(result.selectedStops, isEmpty);
    expect(result.legs.single.isReachable, isFalse);
  });

  test('reports a no-station result instead of inventing a stop', () {
    const destination = GeocodedDestination(
      name: 'Destination',
      address: 'Destination',
      location: LatLng(0, 3),
    );
    final result = feasibility.assess(
      request: requestFor(
        vehicleId: 'EV001',
        maximumRangeKm: 100,
        batteryPercentage: 100,
      ),
      destination: destination,
      route: route(300, destination),
      stations: const [],
    );

    expect(result.isFeasible, isFalse);
    expect(result.selectedStops, isEmpty);
    expect(
      result.warnings,
      contains('No live charging stations were found along this route.'),
    );
  });

  test(
    're-evaluates range and feasibility when the selected vehicle changes',
    () {
      const destination = GeocodedDestination(
        name: 'Destination',
        address: 'Destination',
        location: LatLng(0, 3),
      );
      final routeResult = route(300, destination);
      final liveStations = [station('first', 1), station('second', 2)];
      final longRangeResult = feasibility.assess(
        request: requestFor(
          vehicleId: 'EV-LONG',
          maximumRangeKm: 200,
          batteryPercentage: 100,
        ),
        destination: destination,
        route: routeResult,
        stations: liveStations,
      );
      final shortRangeResult = feasibility.assess(
        request: requestFor(
          vehicleId: 'EV-SHORT',
          maximumRangeKm: 100,
          batteryPercentage: 100,
        ),
        destination: destination,
        route: routeResult,
        stations: liveStations,
      );

      expect(longRangeResult.request.vehicle.vehicleId, 'EV-LONG');
      expect(longRangeResult.isFeasible, isTrue);
      expect(shortRangeResult.request.vehicle.vehicleId, 'EV-SHORT');
      expect(shortRangeResult.isFeasible, isFalse);
    },
  );

  test('destination changes produce a newly geocoded route result', () async {
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        return http.Response(jsonEncode({'elements': []}), 200);
      }
      if (request.url.host == 'nominatim.openstreetmap.org') {
        final query = request.url.queryParameters['q'];
        final longitude = query == 'Alpha' ? '1' : '2';
        return http.Response(
          jsonEncode([
            {
              'lat': '0',
              'lon': longitude,
              'name': query,
              'display_name': '$query, Test',
            },
          ]),
          200,
        );
      }
      if (request.url.host == 'router.project-osrm.org') {
        final endLongitude = request.url.path.contains(';1.0,0.0') ? 1 : 2;
        return http.Response(
          jsonEncode({
            'code': 'Ok',
            'routes': [
              {
                'distance': endLongitude * 100000,
                'duration': endLongitude * 3600,
                'geometry': {
                  'type': 'LineString',
                  'coordinates': [
                    [0, 0],
                    [endLongitude, 0],
                  ],
                },
              },
            ],
          }),
          200,
        );
      }
      return http.Response('Unexpected request: ${request.url}', 500);
    });
    addTearDown(client.close);
    final directions = RoadDirectionsService(
      client: client,
      api: FakeApi().client(),
    );
    final stations = ChargingStationService(
      client: client,
      api: FakeApi().client(),
    );
    final planner = TripPlanningService(
      directions: directions,
      stations: stations,
    );
    final first = await planner.plan(
      requestFor(
        vehicleId: 'EV001',
        maximumRangeKm: 300,
        batteryPercentage: 100,
        destination: 'Alpha',
      ),
    );
    final second = await planner.plan(
      requestFor(
        vehicleId: 'EV001',
        maximumRangeKm: 300,
        batteryPercentage: 100,
        destination: 'Beta',
      ),
    );

    expect(first.destination.name, 'Alpha');
    expect(second.destination.name, 'Beta');
    expect(first.route.distanceKm, 100);
    expect(second.route.distanceKm, 200);
    expect(second.destination, isNot(same(first.destination)));
  });

  test(
    'routes to selected place coordinates without Nominatim geocoding',
    () async {
      const selected = GeocodedDestination(
        name: 'Chennai Central Railway Station',
        displayName:
            'Chennai Central Railway Station, Chennai, Tamil Nadu, India',
        address: 'Chennai Central Railway Station, Chennai, Tamil Nadu, India',
        placeId: 'N/12345',
        addressComponents: {
          'city': 'Chennai',
          'state': 'Tamil Nadu',
          'country': 'India',
        },
        location: LatLng(13.082, 80.275),
      );
      final client = MockClient((request) async {
        if (request.url.host == 'router.project-osrm.org') {
          expect(request.url.path, '/route/v1/driving/80.0,13.0;80.275,13.082');
          return http.Response(
            jsonEncode({
              'code': 'Ok',
              'routes': [
                {
                  'distance': 14000,
                  'duration': 1800,
                  'geometry': {
                    'coordinates': [
                      [80, 13],
                      [80.275, 13.082],
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        if (request.method == 'POST' && request.url.host == 'overpass-api.de') {
          return http.Response(jsonEncode({'elements': []}), 200);
        }
        fail('Unexpected provider request: ${request.url}');
      });
      addTearDown(client.close);
      final directions = RoadDirectionsService(
        client: client,
        api: FakeApi().client(),
      );
      final stations = ChargingStationService(
        client: client,
        api: FakeApi().client(),
      );
      final planner = TripPlanningService(
        directions: directions,
        stations: stations,
      );
      final request = requestFor(
        vehicleId: 'EV001',
        maximumRangeKm: 300,
        batteryPercentage: 100,
        destination: selected.displayLabel,
      );
      final result = await planner.plan(
        TripPlanningRequest(
          start: const LatLng(13, 80),
          destinationQuery: request.destinationQuery,
          selectedDestination: selected,
          vehicle: request.vehicle,
        ),
      );

      expect(result.destination, same(selected));
      expect(result.route.destination.location, selected.location);
      expect(result.route.distanceKm, 14);
    },
  );
}
