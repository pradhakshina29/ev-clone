import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_2/models/charging_station.dart';
import 'package:flutter_application_2/services/charging_station_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'support/fake_api.dart';

void main() {
  group('ChargingStation', () {
    test('parses OSM tags and calculates geographic distance', () {
      final station = ChargingStation.fromOverpassElement({
        'type': 'node',
        'id': 42,
        'lat': 13.0827,
        'lon': 80.2707,
        'tags': {
          'amenity': 'charging_station',
          'name': 'City charging point',
          'operator': 'Local operator',
          'addr:street': 'Main Road',
          'addr:city': 'Chennai',
          'socket:type2': '2',
          'socket:type2:output': '22 kW',
          'capacity': '2',
          'opening_hours': '24/7',
        },
      }, origin: const LatLng(13.0827, 80.2707));

      expect(station.id, 'node/42');
      expect(station.name, 'City charging point');
      expect(station.operator, 'Local operator');
      expect(station.address, 'Main Road, Chennai');
      expect(station.connectors, ['type2']);
      expect(station.power, '22 kW');
      expect(station.chargingPoints, 2);
      expect(station.openingHours, '24/7');
      expect(station.distanceKm, 0);
      expect(station.phone, isNull);
    });

    test(
      'parses way center coordinates and leaves absent tags unavailable',
      () {
        final station = ChargingStation.fromOverpassElement({
          'type': 'way',
          'id': 17,
          'center': {'lat': 10.0, 'lon': 20.0},
          'tags': {'amenity': 'charging_station'},
        }, origin: const LatLng(10, 20));

        expect(station.location, const LatLng(10, 20));
        expect(station.name, isNull);
        expect(station.operator, isNull);
        expect(station.chargingPoints, isNull);
      },
    );

    test(
      'generates a stable identity when the source omits its element ID',
      () {
        final element = {
          'type': 'node',
          'lat': 13.0827,
          'lon': 80.2707,
          'tags': {
            'amenity': 'charging_station',
            'name': 'City charging point',
            'operator': 'Local operator',
          },
        };

        final first = ChargingStation.fromOverpassElement(
          element,
          origin: const LatLng(13, 80),
        );
        final second = ChargingStation.fromOverpassElement(
          element,
          origin: const LatLng(13, 80),
        );

        expect(first.id, isNotEmpty);
        expect(second.id, first.id);
      },
    );

    test(
      'fast-charge classification requires source power of at least 50 kW',
      () {
        ChargingStation stationWithPower(String power) => ChargingStation(
          id: power,
          location: const LatLng(0, 0),
          distanceKm: 0,
          power: power,
        );

        expect(stationWithPower('22 kW').isFastCharging, isFalse);
        expect(stationWithPower('50 kW').isFastCharging, isTrue);
        expect(stationWithPower('150kW / 22 kW').isFastCharging, isTrue);
        expect(
          const ChargingStation(
            id: 'unknown-power',
            location: LatLng(0, 0),
            distanceKm: 0,
          ).isFastCharging,
          isFalse,
        );
      },
    );
  });

  test(
    'queries Overpass with a box covering the range radius and sorts by distance',
    () async {
      late String query;
      final client = MockClient((request) async {
        query = request.bodyFields['data']!;
        return http.Response(
          jsonEncode({
            'elements': [
              {
                'type': 'node',
                'id': 2,
                'lat': 13.1,
                'lon': 80.27,
                'tags': {'amenity': 'charging_station', 'operator': 'B'},
              },
              {
                'type': 'node',
                'id': 1,
                'lat': 13.09,
                'lon': 80.27,
                'tags': {'amenity': 'charging_station', 'operator': 'A'},
              },
            ],
          }),
          200,
        );
      });
      final service = ChargingStationService(
        client: client,
        api: FakeApi().client(),
      );
      addTearDown(service.close);

      final stations = await service.findNearbyStations(
        center: const LatLng(13.0827, 80.2707),
        radiusKm: 30,
      );

      expect(
        query,
        contains('nwr["amenity"="charging_station"](12.81139,79.99'),
      );
      expect(query, isNot(contains('around:')));
      expect(stations.map((station) => station.operator), ['A', 'B']);
      expect(stations.first.distanceKm, lessThan(stations.last.distanceKm));
    },
  );

  test(
    'preserves distinct nearby stations while removing a co-located duplicate',
    () async {
      expect(
        ChargingStation.distanceBetweenKm(
          const LatLng(13.1, 80.27),
          const LatLng(13.10018, 80.27),
        ),
        closeTo(0.02, 0.005),
      );
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'elements': [
              {
                'type': 'node',
                'id': 1,
                'lat': 13.1,
                'lon': 80.27,
                'tags': {
                  'amenity': 'charging_station',
                  'name': 'Central Charging',
                  'operator': 'Network A',
                },
              },
              {
                'type': 'way',
                'id': 2,
                'center': {'lat': 13.10002, 'lon': 80.27},
                'tags': {
                  'amenity': 'charging_station',
                  'name': 'Central Charging',
                  'operator': 'Network A',
                },
              },
              {
                'type': 'node',
                'id': 3,
                'lat': 13.10018,
                'lon': 80.27,
                'tags': {
                  'amenity': 'charging_station',
                  'name': 'Central Charging',
                  'operator': 'Network A',
                },
              },
              {
                'type': 'node',
                'id': 4,
                'lat': 13.10036,
                'lon': 80.27,
                'tags': {
                  'amenity': 'charging_station',
                  'name': 'Central Charging',
                  'operator': 'Network B',
                },
              },
              {
                'type': 'node',
                'id': 5,
                'lat': 13.10054,
                'lon': 80.27,
                'tags': {'amenity': 'charging_station'},
              },
            ],
          }),
          200,
        );
      });
      final service = ChargingStationService(
        client: client,
        api: FakeApi().client(),
      );
      addTearDown(service.close);

      final stations = await service.findNearbyStations(
        center: const LatLng(13.0827, 80.2707),
        radiusKm: 10,
      );

      expect(stations.map((station) => station.id), [
        'node/1',
        'node/3',
        'node/4',
        'node/5',
      ]);
      expect(stations.map((station) => station.operator).toSet(), {
        'Network A',
        'Network B',
        null,
      });
    },
  );

  test('filters corridor candidates and records distance from route', () async {
    late String query;
    final client = MockClient((request) async {
      query = request.bodyFields['data']!;
      return http.Response(
        jsonEncode({
          'elements': [
            {
              'type': 'node',
              'id': 1,
              'lat': 0.01,
              'lon': 0.5,
              'tags': {
                'amenity': 'charging_station',
                'name': 'On route',
                'operator': 'Network A',
              },
            },
            {
              'type': 'node',
              'id': 2,
              'lat': 0.1,
              'lon': 0.5,
              'tags': {
                'amenity': 'charging_station',
                'name': 'Too far from route',
                'operator': 'Network B',
              },
            },
            {
              'type': 'node',
              'id': 3,
              'lat': 0,
              'lon': 1.5,
              'tags': {
                'amenity': 'charging_station',
                'name': 'Outside search radius',
                'operator': 'Network C',
              },
            },
          ],
        }),
        200,
      );
    });
    final service = ChargingStationService(
      client: client,
      api: FakeApi().client(),
    );
    addTearDown(service.close);

    final stations = await service.findAlongRoute(
      origin: const LatLng(0, 0),
      routePoints: const [LatLng(0, 0), LatLng(0, 2)],
      searchRadiusKm: 100,
      corridorWidthKm: 5,
    );

    expect(query, contains('(-0.90437,-0.89842,0.90437,0.89842)'));
    expect(stations.map((station) => station.name), ['On route']);
    expect(stations.single.distanceFromRouteKm, closeTo(1.1, 0.2));
    expect(stations.single.distanceKm, greaterThan(40));
  });

  test(
    'searches the entire long route, including beyond origin radius',
    () async {
      late String query;
      final client = MockClient((request) async {
        query = request.bodyFields['data']!;
        return http.Response(
          jsonEncode({
            'elements': [
              {
                'type': 'node',
                'id': 81,
                'lat': 0,
                'lon': 1.9,
                'tags': {
                  'amenity': 'charging_station',
                  'name': 'Far route station',
                },
              },
              {
                'type': 'node',
                'id': 82,
                'lat': 0.2,
                'lon': 1,
                'tags': {
                  'amenity': 'charging_station',
                  'name': 'Outside corridor',
                },
              },
            ],
          }),
          200,
        );
      });
      final service = ChargingStationService(
        client: client,
        api: FakeApi().client(),
      );
      addTearDown(service.close);

      final stations = await service.findAlongEntireRoute(
        origin: const LatLng(0, 0),
        routePoints: const [LatLng(0, 0), LatLng(0, 2)],
        corridorWidthKm: 5,
      );

      expect(query, contains('(-0.04522,-0.04492,0.04522,2.04492)'));
      expect(query, isNot(contains('around:')));
      expect(stations.map((station) => station.name), ['Far route station']);
      expect(stations.single.distanceKm, greaterThan(200));
      expect(stations.single.distanceFromRouteKm, closeTo(0, 0.01));
    },
  );

  test('calculates station diversion from a route', () {
    expect(
      ChargingStationService.distanceToRouteKm(const LatLng(0.01, 1), const [
        LatLng(0, 0),
        LatLng(0, 2),
      ]),
      closeTo(1.1, 0.1),
    );
  });

  group('Overpass server fallback', () {
    const center = LatLng(13.0827, 80.2707);
    final okBody = jsonEncode({
      'elements': [
        {
          'type': 'node',
          'id': 1,
          'lat': 13.09,
          'lon': 80.27,
          'tags': {'amenity': 'charging_station'},
        },
      ],
    });

    test('a busy server falls through to the next one', () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        return request.url.host == 'overpass-api.de'
            ? http.Response('# 502 Gateway Timeout', 502)
            : http.Response(okBody, 200);
      });

      final stations = await ChargingStationService(
        client: client,
        api: FakeApi().client(),
      ).findNearbyStations(center: center, radiusKm: 5);

      expect(stations, hasLength(1));
      expect(hosts, contains('overpass-api.de'));
      expect(hosts.last, isNot('overpass-api.de'));
    });

    test('searches through the backend before any public server', () async {
      final api = FakeApi()
        ..on('POST /v1/geo/overpass', (_) => jsonDecode(okBody));
      final client = MockClient((request) async {
        fail('Unexpected direct request to ${request.url.host}');
      });

      final stations = await ChargingStationService(
        client: client,
        api: api.client(),
      ).findNearbyStations(center: center, radiusKm: 5);

      expect(stations, hasLength(1));
      final sent = jsonDecode(api.requests.single.body) as Map;
      expect(sent['data'], contains('nwr["amenity"="charging_station"]'));
      expect(api.requests.single.headers['Authorization'], 'Bearer test-token');
    });

    test('a query the backend rejects is not retried directly', () async {
      final api = FakeApi()
        ..on('POST /v1/geo/overpass', (_) => const FakeReply(400));
      var directCalls = 0;
      final client = MockClient((_) async {
        directCalls++;
        return http.Response(okBody, 200);
      });

      await expectLater(
        ChargingStationService(
          client: client,
          api: api.client(),
        ).findNearbyStations(center: const LatLng(12.7, 80.0), radiusKm: 5),
        throwsA(isA<StateError>()),
      );
      expect(directCalls, 0);
    });

    test('a TLS failure on one server falls through to the next', () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        if (hosts.length == 1) {
          throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
        }
        return http.Response(okBody, 200);
      });

      final stations = await ChargingStationService(
        client: client,
        api: FakeApi().client(),
      ).findNearbyStations(center: center, radiusKm: 5);

      expect(stations, hasLength(1));
      expect(hosts, hasLength(2));
    });

    test('an Overpass runtime-error reply is treated as busy', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return calls == 1
            ? http.Response(
                jsonEncode({
                  'elements': <Object>[],
                  'remark': 'runtime error: Query timed out',
                }),
                200,
              )
            : http.Response(okBody, 200);
      });

      final stations = await ChargingStationService(
        client: client,
        api: FakeApi().client(),
      ).findNearbyStations(center: const LatLng(13.1, 80.3), radiusKm: 5);

      expect(calls, 2);
      expect(stations, hasLength(1));
    });

    test('all servers busy gives a friendly, retryable error', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('busy', 503);
      });

      await expectLater(
        ChargingStationService(
          client: client,
          api: FakeApi().client(),
        ).findNearbyStations(center: const LatLng(12.9, 80.2), radiusKm: 5),
        throwsA(
          isA<MapServiceBusyException>().having(
            (error) => error.message,
            'message',
            'Map service is busy, please try again in a minute.',
          ),
        ),
      );
      expect(calls, 4);
    });

    test('a refusing server (406) falls through to the next one', () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        return hosts.length == 1
            ? http.Response('<h1>406 Not Acceptable</h1>', 406)
            : http.Response(okBody, 200);
      });

      final stations = await ChargingStationService(
        client: client,
        api: FakeApi().client(),
      ).findNearbyStations(center: center, radiusKm: 5);

      expect(stations, hasLength(1));
      expect(hosts, hasLength(2));
    });

    testWidgets('a hanging server does not block the next one', (tester) async {
      final hanging = Completer<http.Response>();
      final hosts = <String>[];
      final client = MockClient((request) {
        hosts.add(request.url.host);
        return hosts.length == 1
            ? hanging.future
            : Future.value(http.Response(okBody, 200));
      });
      List<ChargingStation>? stations;
      ChargingStationService(client: client, api: FakeApi().client())
          .findNearbyStations(center: center, radiusKm: 5)
          .then((value) => stations = value);

      await tester.pump(const Duration(seconds: 7));
      expect(stations, isNull);
      expect(hosts, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(hosts, hasLength(2));
      expect(stations, hasLength(1));
      hanging.complete(http.Response('late', 504));
      await tester.pump();
    });

    testWidgets('gives up with the busy message at the overall time limit', (
      tester,
    ) async {
      final client = MockClient((_) => Completer<http.Response>().future);
      Object? error;
      ChargingStationService(client: client, api: FakeApi().client())
          .findNearbyStations(center: const LatLng(12.5, 79.8), radiusKm: 5)
          .catchError((Object e) {
            error = e;
            return const <ChargingStation>[];
          });

      await tester.pump(const Duration(seconds: 44));
      expect(error, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(error, isA<MapServiceBusyException>());
      // Let the abandoned requests' own time limits run out.
      await tester.pump(const Duration(seconds: 30));
    });

    test('a rejected query is not retried on other servers', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('bad query', 400);
      });

      await expectLater(
        ChargingStationService(
          client: client,
          api: FakeApi().client(),
        ).findNearbyStations(center: const LatLng(12.8, 80.1), radiusKm: 5),
        throwsA(isA<StateError>()),
      );
      expect(calls, 1);
    });
  });
}
