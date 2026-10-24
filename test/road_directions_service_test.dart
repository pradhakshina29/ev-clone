import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_application_2/models/road_route.dart';
import 'package:flutter_application_2/services/road_directions_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'support/fake_api.dart';

void main() {
  test('geocodes a destination and returns an OSRM road route', () async {
    final client = MockClient((request) async {
      if (request.url.host == 'nominatim.openstreetmap.org') {
        expect(request.url.queryParameters['q'], 'Chennai Airport');
        return http.Response(
          jsonEncode([
            {
              'name': 'Chennai International Airport',
              'display_name': 'Chennai Airport, Chennai, India',
              'lat': '12.9941',
              'lon': '80.1709',
            },
          ]),
          200,
        );
      }
      expect(request.url.host, 'router.project-osrm.org');
      expect(request.url.path, '/route/v1/driving/80.27,13.08;80.1709,12.9941');
      return http.Response(
        jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'distance': 12500,
              'duration': 1800,
              'geometry': {
                'coordinates': [
                  [80.27, 13.08],
                  [80.22, 13.03],
                  [80.1709, 12.9941],
                ],
              },
            },
          ],
        }),
        200,
      );
    });
    final service = RoadDirectionsService(
      client: client,
      api: FakeApi().client(),
    );
    addTearDown(client.close);

    final destination = await service.geocode('Chennai Airport');
    final route = await service.route(
      origin: const LatLng(13.08, 80.27),
      destination: destination,
    );

    expect(destination.location, const LatLng(12.9941, 80.1709));
    expect(route.points, hasLength(3));
    expect(route.distanceKm, 12.5);
    expect(route.duration, const Duration(minutes: 30));
    expect(route.destination.name, 'Chennai International Airport');
  });

  test('fetches the road route through the backend when available', () async {
    final api = FakeApi()
      ..on(
        'GET /v1/geo/route',
        (_) => {
          'code': 'Ok',
          'routes': [
            {
              'distance': 8000,
              'duration': 900,
              'geometry': {
                'coordinates': [
                  [80.27, 13.08],
                  [80.2, 13.0],
                ],
              },
            },
          ],
        },
      );
    final client = MockClient((request) async {
      fail('Unexpected direct request to ${request.url.host}');
    });
    final service = RoadDirectionsService(client: client, api: api.client());

    final route = await service.route(
      origin: const LatLng(13.08, 80.27),
      destination: const GeocodedDestination(
        name: 'Guindy',
        address: 'Guindy, Chennai',
        displayName: 'Guindy',
        location: LatLng(13.0, 80.2),
      ),
    );

    expect(route.distanceKm, 8);
    expect(route.points, hasLength(2));
    expect(api.requests.single.url.queryParameters, {
      'fromLat': '13.08',
      'fromLon': '80.27',
      'toLat': '13.0',
      'toLon': '80.2',
    });
  });

  test('rejects empty destination query', () {
    final service = RoadDirectionsService(
      client: MockClient((_) async => http.Response('[]', 200)),
      api: FakeApi().client(),
    );
    addTearDown(service.close);

    expect(service.geocode('  '), throwsArgumentError);
  });

  test(
    'searches Photon place autocomplete and preserves place metadata',
    () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'photon.komoot.io');
        expect(request.url.path, '/api');
        expect(request.url.queryParameters['q'], 'Chennai Central');
        expect(request.url.queryParameters['limit'], '6');
        expect(request.url.queryParameters['lat'], '13.08');
        expect(request.url.queryParameters['lon'], '80.27');
        return http.Response(
          jsonEncode({
            'features': [
              {
                'geometry': {
                  'type': 'Point',
                  'coordinates': [80.275, 13.082],
                },
                'properties': {
                  'name': 'Chennai Central Railway Station',
                  'city': 'Chennai',
                  'state': 'Tamil Nadu',
                  'country': 'India',
                  'osm_type': 'N',
                  'osm_id': 12345,
                },
              },
              {
                'geometry': {
                  'type': 'Point',
                  'coordinates': [80.2, 13.1],
                },
                'properties': {'country': 'India'},
              },
            ],
          }),
          200,
        );
      });
      final service = RoadDirectionsService(
        client: client,
        api: FakeApi().client(),
      );
      addTearDown(client.close);

      final places = await service.searchPlaces(
        ' Chennai Central ',
        proximity: const LatLng(13.08, 80.27),
      );

      expect(places, hasLength(1));
      expect(places.single.name, 'Chennai Central Railway Station');
      expect(places.single.displayLabel, 'Chennai Central Railway Station');
      expect(
        places.single.address,
        'Chennai Central Railway Station, Chennai, Tamil Nadu, India',
      );
      expect(places.single.location, const LatLng(13.082, 80.275));
      expect(places.single.placeId, 'N/12345');
      expect(places.single.addressComponents['state'], 'Tamil Nadu');
    },
  );

  test('skips provider calls for too-short place searches', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{"features":[]}', 200);
    });
    final service = RoadDirectionsService(
      client: client,
      api: FakeApi().client(),
    );
    addTearDown(client.close);

    expect(await service.searchPlaces('Ch'), isEmpty);
    expect(requests, 0);
  });

  test('reports rate limiting and malformed place responses', () async {
    final rateLimitedService = RoadDirectionsService(
      client: MockClient((_) async => http.Response('rate limited', 429)),
      api: FakeApi().client(),
    );
    addTearDown(rateLimitedService.close);
    await expectLater(
      rateLimitedService.searchPlaces('Chennai'),
      throwsA(
        isA<RoadDirectionsException>().having(
          (error) => error.message,
          'message',
          contains('rate limited'),
        ),
      ),
    );

    final invalidService = RoadDirectionsService(
      client: MockClient((_) async => http.Response('{"features":{}}', 200)),
      api: FakeApi().client(),
    );
    addTearDown(invalidService.close);
    await expectLater(
      invalidService.searchPlaces('Chennai'),
      throwsFormatException,
    );
  });
}
