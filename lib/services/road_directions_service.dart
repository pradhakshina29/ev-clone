import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/road_route.dart';
import 'api/api_client.dart';

class RoadDirectionsService {
  RoadDirectionsService({http.Client? client, ApiClient? api})
    : _client = client ?? http.Client(),
      _api = api ?? ApiClient(),
      _ownsClient = client == null;

  final http.Client _client;
  final ApiClient _api;
  final bool _ownsClient;
  final Map<String, GeocodedDestination> _destinationCache = {};
  final Map<String, RoadRoute> _routeCache = {};

  Future<List<GeocodedDestination>> searchPlaces(
    String query, {
    LatLng? proximity,
    int limit = 6,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.length < 3) return const [];
    if (limit < 1 || limit > 10) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 10.');
    }
    final parameters = <String, String>{
      'q': normalizedQuery,
      'limit': '$limit',
      'lang': 'en',
    };
    if (proximity != null) {
      parameters['lat'] = '${proximity.latitude}';
      parameters['lon'] = '${proximity.longitude}';
    }
    final uri = Uri.https('photon.komoot.io', '/api', parameters);
    final response = await _request(
      uri,
      headers: const {'Accept': 'application/json'},
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['features'] is! List) {
      throw const FormatException('Place search returned an invalid response.');
    }
    final places = <GeocodedDestination>[];
    for (final feature in decoded['features'] as List) {
      if (feature is! Map) continue;
      final geometry = feature['geometry'];
      final coordinates = geometry is Map ? geometry['coordinates'] : null;
      final properties = feature['properties'];
      if (coordinates is! List ||
          coordinates.length < 2 ||
          properties is! Map) {
        continue;
      }
      final longitude = _asDouble(coordinates[0]);
      final latitude = _asDouble(coordinates[1]);
      if (latitude == null ||
          longitude == null ||
          !latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        continue;
      }
      final values = Map<String, dynamic>.from(properties);
      final components = <String, String>{};
      for (final key in const [
        'name',
        'housenumber',
        'street',
        'postcode',
        'district',
        'city',
        'county',
        'state',
        'country',
      ]) {
        final value = values[key]?.toString().trim();
        if (value != null && value.isNotEmpty) components[key] = value;
      }
      final name =
          components['name'] ??
          components['street'] ??
          components['city'] ??
          components['district'] ??
          components['county'] ??
          components['state'];
      if (name == null) continue;
      final displayName = _joinPlaceParts([
        components['name'],
        if (components['housenumber'] != null || components['street'] != null)
          [
            components['housenumber'],
            components['street'],
          ].whereType<String>().join(' '),
        components['postcode'],
        components['city'],
        components['district'],
        components['county'],
        components['state'],
        components['country'],
      ]);
      final osmType = values['osm_type']?.toString().trim();
      final osmId = values['osm_id']?.toString().trim();
      places.add(
        GeocodedDestination(
          name: name,
          address: displayName,
          displayName: name,
          location: LatLng(latitude, longitude),
          placeId: osmType != null && osmType.isNotEmpty && osmId != null
              ? '$osmType/$osmId'
              : null,
          addressComponents: Map.unmodifiable(components),
        ),
      );
    }
    return List.unmodifiable(places);
  }

  Future<GeocodedDestination> geocode(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      throw ArgumentError.value(query, 'query', 'Destination cannot be empty.');
    }
    final cached = _destinationCache[normalizedQuery.toLowerCase()];
    if (cached != null) return cached;

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': normalizedQuery,
      'format': 'jsonv2',
      'limit': '1',
      'addressdetails': '1',
    });
    final response = await _request(
      uri,
      headers: const {'Accept': 'application/json'},
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! List || decoded.isEmpty || decoded.first is! Map) {
      throw const FormatException('No matching destination was found.');
    }

    final result = Map<String, dynamic>.from(decoded.first as Map);
    final latitude = double.tryParse(result['lat']?.toString() ?? '');
    final longitude = double.tryParse(result['lon']?.toString() ?? '');
    final displayName = result['display_name']?.toString().trim();
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        displayName == null ||
        displayName.isEmpty) {
      throw const FormatException(
        'Destination result had invalid coordinates.',
      );
    }
    final destination = GeocodedDestination(
      name: result['name']?.toString().trim().isNotEmpty == true
          ? result['name'].toString().trim()
          : normalizedQuery,
      address: displayName,
      displayName: displayName,
      location: LatLng(latitude, longitude),
      placeId: result['place_id']?.toString(),
      addressComponents: result['address'] is Map
          ? Map.unmodifiable(
              Map<String, dynamic>.from(
                result['address'] as Map,
              ).map((key, value) => MapEntry(key, value.toString())),
            )
          : const {},
    );
    _destinationCache[normalizedQuery.toLowerCase()] = destination;
    return destination;
  }

  Future<RoadRoute> route({
    required LatLng origin,
    required GeocodedDestination destination,
  }) async {
    final cacheKey = [
      origin.latitude.toStringAsFixed(4),
      origin.longitude.toStringAsFixed(4),
      destination.location.latitude.toStringAsFixed(5),
      destination.location.longitude.toStringAsFixed(5),
    ].join(',');
    final cached = _routeCache[cacheKey];
    if (cached != null) return cached;

    final decoded = await _routeJson(origin, destination.location);
    if (decoded is! Map<String, dynamic> ||
        decoded['code'] != 'Ok' ||
        decoded['routes'] is! List ||
        (decoded['routes'] as List).isEmpty) {
      throw const FormatException('A driving route could not be found.');
    }
    final route = Map<String, dynamic>.from(
      (decoded['routes'] as List).first as Map,
    );
    final geometry = route['geometry'];
    final rawCoordinates = geometry is Map ? geometry['coordinates'] : null;
    if (rawCoordinates is! List || rawCoordinates.length < 2) {
      throw const FormatException(
        'Routing service returned no route geometry.',
      );
    }
    final points = <LatLng>[];
    for (final coordinate in rawCoordinates) {
      if (coordinate is! List || coordinate.length < 2) continue;
      final longitude = _asDouble(coordinate[0]);
      final latitude = _asDouble(coordinate[1]);
      if (latitude == null || longitude == null) continue;
      points.add(LatLng(latitude, longitude));
    }
    final distanceMeters = _asDouble(route['distance']);
    final durationSeconds = _asDouble(route['duration']);
    if (points.length < 2 ||
        distanceMeters == null ||
        durationSeconds == null ||
        distanceMeters < 0 ||
        durationSeconds < 0) {
      throw const FormatException(
        'Routing service returned invalid route data.',
      );
    }

    final result = RoadRoute(
      points: List.unmodifiable(points),
      distanceKm: distanceMeters / 1000,
      duration: Duration(seconds: durationSeconds.round()),
      destination: destination,
    );
    _routeCache[cacheKey] = result;
    return result;
  }

  /// OSRM's route JSON, fetched through our backend first: some phones lack
  /// the root certificate router.project-osrm.org chains to. OSRM is still
  /// called directly when the backend is unavailable.
  Future<Object?> _routeJson(LatLng origin, LatLng destination) async {
    try {
      return await _api
          .get(
            '/v1/geo/route',
            query: {
              'fromLat': '${origin.latitude}',
              'fromLon': '${origin.longitude}',
              'toLat': '${destination.latitude}',
              'toLon': '${destination.longitude}',
            },
          )
          .timeout(const Duration(seconds: 60));
    } on Exception catch (error) {
      debugPrint('Backend route request failed, trying OSRM directly: $error');
    }
    final coordinates =
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}';
    final uri = Uri.https(
      'router.project-osrm.org',
      '/route/v1/driving/$coordinates',
      {'overview': 'full', 'geometries': 'geojson', 'steps': 'false'},
    );
    final response = await _request(uri);
    return jsonDecode(response.body);
  }

  Future<http.Response> _request(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    late final http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: {
              'User-Agent': 'EVSmartCompanion/1.0 (charging route search)',
              ...headers,
            },
          )
          .timeout(const Duration(seconds: 20));
    } catch (error, stackTrace) {
      debugPrint('OpenStreetMap route request failed: $error\n$stackTrace');
      throw const RoadDirectionsException(
        'Destination or route service is temporarily unavailable. Check your connection and retry.',
      );
    }
    if (response.statusCode != 200) {
      debugPrint(
        'OpenStreetMap/geographic endpoint returned HTTP ${response.statusCode}.',
      );
      if (response.statusCode == 429) {
        throw const RoadDirectionsException(
          'Place search is temporarily rate limited. Wait a moment and try again.',
        );
      }
      throw const RoadDirectionsException(
        'Destination or route service is temporarily unavailable. Retry shortly.',
      );
    }
    return response;
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static String _joinPlaceParts(Iterable<String?> parts) {
    final seen = <String>{};
    final result = <String>[];
    for (final part in parts) {
      final value = part?.trim();
      if (value == null || value.isEmpty || !seen.add(value.toLowerCase())) {
        continue;
      }
      result.add(value);
    }
    return result.join(', ');
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class RoadDirectionsException implements Exception {
  const RoadDirectionsException(this.message);

  final String message;

  @override
  String toString() => message;
}
