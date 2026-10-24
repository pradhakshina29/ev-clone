import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/charging_station.dart';
import 'api/api_client.dart';

/// Every public OpenStreetMap (Overpass) server was busy or unreachable.
class MapServiceBusyException implements Exception {
  const MapServiceBusyException();

  String get message => 'Map service is busy, please try again in a minute.';

  @override
  String toString() => message;
}

class ChargingStationService {
  ChargingStationService({http.Client? client, ApiClient? api})
    : _client = client ?? http.Client(),
      _api = api ?? ApiClient();

  // Public Overpass servers that allow browser (CORS) requests. They are
  // often overloaded, so a slow server does not block the others: the next
  // one starts after [_staggerDelay] (or at once when one fails) and the first
  // good answer wins.
  static final List<Uri> _endpoints = [
    Uri.https('overpass-api.de', '/api/interpreter'),
    Uri.https('maps.mail.ru', '/osm/tools/overpass/api/interpreter'),
    Uri.https('overpass.private.coffee', '/api/interpreter'),
    Uri.https('overpass.kumi.systems', '/api/interpreter'),
  ];
  static const _staggerDelay = Duration(seconds: 8);
  // The server that answered last is tried first next time.
  static int _preferredEndpoint = 0;
  static const double defaultRouteCorridorWidthKm = 5;

  final http.Client _client;
  final ApiClient _api;
  final Map<String, (DateTime, List<ChargingStation>)> _cache = {};

  Future<List<ChargingStation>> findNearbyStations({
    required LatLng center,
    required double radiusKm,
  }) async {
    if (!radiusKm.isFinite || radiusKm <= 0) {
      throw ArgumentError.value(radiusKm, 'radiusKm', 'Must be positive.');
    }

    // A bounding box is much cheaper for Overpass than a large `around`
    // circle; stations outside the circle are filtered out below.
    final query =
        '''
[out:json][timeout:25];
nwr["amenity"="charging_station"](${_bbox(center, radiusKm)});
out center tags;
''';

    final cacheKey =
        'near:${center.latitude.toStringAsFixed(5)},'
        '${center.longitude.toStringAsFixed(5)}:${radiusKm.toStringAsFixed(3)}';
    final cached = _cached(cacheKey);
    if (cached != null) {
      final refreshedDistances =
          cached
              .map(
                (station) => station.withDistanceFromOrigin(
                  ChargingStation.distanceBetweenKm(center, station.location),
                ),
              )
              .where((station) => station.distanceKm <= radiusKm)
              .toList()
            ..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
      return List.unmodifiable(refreshedDistances);
    }
    final decoded = await _overpassJson(
      query,
      total: const Duration(seconds: 45),
    );
    if (decoded is! Map<String, dynamic> || decoded['elements'] is! List) {
      throw const FormatException(
        'OpenStreetMap returned invalid station data.',
      );
    }

    final stations = _parseStations(
      decoded['elements'] as List,
      origin: center,
    ).where((station) => station.distanceKm <= radiusKm).toList();
    stations.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    final result = _deduplicate(stations);
    _cache[cacheKey] = (DateTime.now(), result);
    return result;
  }

  Future<List<ChargingStation>> findAlongRoute({
    required LatLng origin,
    required List<LatLng> routePoints,
    required double searchRadiusKm,
    double corridorWidthKm = defaultRouteCorridorWidthKm,
  }) async {
    if (routePoints.length < 2) {
      throw ArgumentError.value(
        routePoints,
        'routePoints',
        'At least two route points are required.',
      );
    }
    if (!corridorWidthKm.isFinite || corridorWidthKm <= 0) {
      throw ArgumentError.value(
        corridorWidthKm,
        'corridorWidthKm',
        'Must be a positive finite value.',
      );
    }
    if (!searchRadiusKm.isFinite || searchRadiusKm <= 0) {
      throw ArgumentError.value(
        searchRadiusKm,
        'searchRadiusKm',
        'Must be a positive finite radius.',
      );
    }

    final cacheKey =
        'route:${corridorWidthKm.toStringAsFixed(1)}:'
        '${searchRadiusKm.toStringAsFixed(3)}:'
        '${origin.latitude.toStringAsFixed(5)},'
        '${origin.longitude.toStringAsFixed(5)}:'
        '${Object.hashAll(routePoints.map((point) => Object.hash(point.latitude.toStringAsFixed(5), point.longitude.toStringAsFixed(5))))}';
    final cached = _cached(cacheKey);
    if (cached != null) {
      return cached
          .map(
            (station) => station.withDistanceFromOrigin(
              ChargingStation.distanceBetweenKm(origin, station.location),
            ),
          )
          .where((station) => station.distanceKm <= searchRadiusKm)
          .toList(growable: false);
    }

    final query =
        '''
[out:json][timeout:25];
nwr["amenity"="charging_station"](${_bbox(origin, searchRadiusKm)});
out center tags;
''';
    final decoded = await _overpassJson(
      query,
      total: const Duration(seconds: 45),
    );
    if (decoded is! Map<String, dynamic> || decoded['elements'] is! List) {
      throw const FormatException(
        'OpenStreetMap returned invalid route-corridor data.',
      );
    }
    final candidates = _parseStations(
      decoded['elements'] as List,
      origin: origin,
    );
    final stations = candidates
        .map((station) {
          final routeDistance = _distanceToRouteKm(
            station.location,
            routePoints,
          );
          return routeDistance <= corridorWidthKm &&
                  station.distanceKm <= searchRadiusKm
              ? station.withDistanceFromRoute(routeDistance)
              : null;
        })
        .whereType<ChargingStation>()
        .toList();
    stations.sort(
      (a, b) =>
          (a.distanceFromRouteKm ?? 0).compareTo(b.distanceFromRouteKm ?? 0),
    );
    final result = _deduplicate(stations);
    _cache[cacheKey] = (DateTime.now(), result);
    return result;
  }

  Future<List<ChargingStation>> findAlongEntireRoute({
    required LatLng origin,
    required List<LatLng> routePoints,
    double corridorWidthKm = defaultRouteCorridorWidthKm,
  }) async {
    if (routePoints.length < 2) {
      throw ArgumentError.value(
        routePoints,
        'routePoints',
        'At least two route points are required.',
      );
    }
    if (!corridorWidthKm.isFinite || corridorWidthKm <= 0) {
      throw ArgumentError.value(
        corridorWidthKm,
        'corridorWidthKm',
        'Must be a positive finite value.',
      );
    }

    final geometryHash = Object.hashAll(
      routePoints.map(
        (point) => Object.hash(
          point.latitude.toStringAsFixed(5),
          point.longitude.toStringAsFixed(5),
        ),
      ),
    );
    final cacheKey =
        'entire-route:${corridorWidthKm.toStringAsFixed(2)}:'
        '${origin.latitude.toStringAsFixed(5)},'
        '${origin.longitude.toStringAsFixed(5)}:$geometryHash';
    final cached = _cached(cacheKey);
    if (cached != null) return List.unmodifiable(cached);

    // One bounding box per ~50 km of road (widened by the corridor) keeps
    // the query small; stations outside the corridor are filtered out below.
    final selectors = StringBuffer();
    for (final box in _routeBoxes(routePoints, corridorWidthKm)) {
      selectors.writeln('nwr["amenity"="charging_station"]($box);');
    }
    final query =
        '''
[out:json][timeout:50];
(
$selectors);
out center tags;
''';
    final decoded = await _overpassJson(
      query,
      total: const Duration(seconds: 60),
    );
    if (decoded is! Map<String, dynamic> || decoded['elements'] is! List) {
      throw const FormatException(
        'OpenStreetMap returned invalid full-route station data.',
      );
    }
    final stations = _parseStations(decoded['elements'] as List, origin: origin)
        .map((station) {
          final diversionKm = distanceToRouteKm(station.location, routePoints);
          return diversionKm <= corridorWidthKm
              ? station.withDistanceFromRoute(diversionKm)
              : null;
        })
        .whereType<ChargingStation>()
        .toList();
    stations.sort(
      (a, b) =>
          (a.distanceFromRouteKm ?? 0).compareTo(b.distanceFromRouteKm ?? 0),
    );
    final result = _deduplicate(stations);
    _cache[cacheKey] = (DateTime.now(), result);
    return result;
  }

  List<ChargingStation> _parseStations(
    List elements, {
    required LatLng origin,
  }) {
    final stations = <ChargingStation>[];
    final seenIds = <String>{};
    for (final element in elements) {
      if (element is! Map<String, dynamic>) continue;
      try {
        final station = ChargingStation.fromOverpassElement(
          element,
          origin: origin,
        );
        if (seenIds.add(station.id)) stations.add(station);
      } on FormatException catch (error) {
        debugPrint('Skipping malformed OpenStreetMap charging station: $error');
      }
    }
    return stations;
  }

  List<ChargingStation> _deduplicate(List<ChargingStation> stations) {
    final unique = <ChargingStation>[];
    for (final station in stations) {
      final duplicate = unique.any((existing) {
        final stationName = _normalizedIdentity(station.name);
        final existingName = _normalizedIdentity(existing.name);
        final stationOperator = _normalizedIdentity(station.operator);
        final existingOperator = _normalizedIdentity(existing.operator);
        if (stationName.isEmpty ||
            existingName.isEmpty ||
            stationOperator.isEmpty ||
            existingOperator.isEmpty ||
            stationName != existingName ||
            stationOperator != existingOperator) {
          return false;
        }
        final distance = ChargingStation.distanceBetweenKm(
          station.location,
          existing.location,
        );
        return distance <= 0.01;
      });
      if (!duplicate) unique.add(station);
    }
    return List.unmodifiable(unique);
  }

  static String _normalizedIdentity(Object? value) =>
      value?.toString().trim().toLowerCase() ?? '';

  /// Decoded Overpass JSON, fetched through our backend first: some phones
  /// lack the root certificate the public Overpass servers chain to. The
  /// public servers are still tried directly when the backend is unavailable.
  Future<Object?> _overpassJson(String query, {required Duration total}) async {
    final deadline = DateTime.now().add(total);
    try {
      return await _api
          .post('/v1/geo/overpass', {'data': query})
          .timeout(total);
    } on ApiException catch (error) {
      if (error.statusCode == 400) {
        throw StateError('OpenStreetMap rejected the station search (400).');
      }
      debugPrint('Backend station search failed: ${error.code}');
    } on Exception catch (error) {
      debugPrint('Backend station search failed: $error');
    }
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) throw const MapServiceBusyException();
    final response = await _postOverpass(query, total: remaining);
    return jsonDecode(response.body);
  }

  /// Posts an Overpass query to the servers in turn, starting the next one
  /// every [_staggerDelay] or as soon as one fails, and returns the first good
  /// answer. Throws [MapServiceBusyException] when every server failed or
  /// [total] has passed, so the screen never waits longer than that.
  Future<http.Response> _postOverpass(
    String query, {
    required Duration total,
  }) async {
    final result = Completer<http.Response>();
    final order = [
      for (var i = 0; i < _endpoints.length; i++)
        (_preferredEndpoint + i) % _endpoints.length,
    ];
    var started = 0;
    var running = 0;

    void startNext() {
      if (result.isCompleted || started >= order.length) return;
      final index = order[started++];
      running++;
      _tryEndpoint(index, query, total).then(
        (response) {
          running--;
          if (result.isCompleted) return;
          if (response != null) {
            _preferredEndpoint = index;
            result.complete(response);
            return;
          }
          startNext();
          if (running == 0) {
            result.completeError(const MapServiceBusyException());
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          running--;
          if (!result.isCompleted) result.completeError(error, stackTrace);
        },
      );
    }

    startNext();
    final stagger = Timer.periodic(_staggerDelay, (_) => startNext());
    try {
      return await result.future.timeout(
        total,
        onTimeout: () => throw const MapServiceBusyException(),
      );
    } finally {
      stagger.cancel();
    }
  }

  /// One server attempt: the response, or null when the server is busy,
  /// refusing or unreachable. A rejected (malformed) query is thrown.
  Future<http.Response?> _tryEndpoint(
    int index,
    String query,
    Duration timeout,
  ) async {
    final endpoint = _endpoints[index];
    try {
      final response = await _client
          .post(
            endpoint,
            headers: const {
              'Accept': 'application/json',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {'data': query},
          )
          .timeout(timeout);
      // A 200 can still carry an Overpass timeout/out-of-memory remark.
      final overloaded =
          response.statusCode == 200 &&
          response.body.contains('"remark"') &&
          response.body.contains('runtime error');
      if (response.statusCode == 200 && !overloaded) return response;
      debugPrint(
        'OpenStreetMap server ${endpoint.host} returned '
        '${overloaded ? 'a runtime error' : 'HTTP ${response.statusCode}'}.',
      );
      if (response.statusCode == 400) {
        throw StateError(
          'OpenStreetMap rejected the station search (${response.statusCode}).',
        );
      }
    } on TimeoutException {
      debugPrint('OpenStreetMap server ${endpoint.host} timed out.');
    } on Exception catch (error) {
      // Includes TLS failures (HandshakeException), so one bad server never
      // ends the search for the others.
      debugPrint('OpenStreetMap server ${endpoint.host} failed: $error');
    }
    return null;
  }

  List<ChargingStation>? _cached(String key) {
    final value = _cache[key];
    if (value == null) return null;
    if (DateTime.now().difference(value.$1) > const Duration(minutes: 3)) {
      _cache.remove(key);
      return null;
    }
    return value.$2;
  }

  static double _distanceToRouteKm(LatLng point, List<LatLng> route) {
    if (route.length == 1) {
      return ChargingStation.distanceBetweenKm(point, route.single);
    }
    var minimum = double.infinity;
    for (var i = 0; i < route.length - 1; i++) {
      final start = route[i];
      final end = route[i + 1];
      final meanLatitude = point.latitude * math.pi / 180;
      final scaleX = 111.320 * math.cos(meanLatitude);
      final scaleY = 110.574;
      final dx = (end.longitude - start.longitude) * scaleX;
      final dy = (end.latitude - start.latitude) * scaleY;
      final px = (point.longitude - start.longitude) * scaleX;
      final py = (point.latitude - start.latitude) * scaleY;
      final lengthSquared = dx * dx + dy * dy;
      final fraction = lengthSquared == 0
          ? 0.0
          : ((px * dx + py * dy) / lengthSquared).clamp(0.0, 1.0);
      final closestX = dx * fraction;
      final closestY = dy * fraction;
      minimum = math.min(
        minimum,
        math.sqrt(math.pow(px - closestX, 2) + math.pow(py - closestY, 2)),
      );
    }
    return minimum;
  }

  static double distanceToRouteKm(LatLng point, List<LatLng> route) =>
      _distanceToRouteKm(point, route);

  /// `south,west,north,east` of a square around [center] covering [radiusKm].
  static String _bbox(LatLng center, double radiusKm) =>
      _boxAround([center], radiusKm);

  static String _boxAround(List<LatLng> points, double marginKm) {
    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    final latMargin = marginKm / 110.574;
    final widestLatitude = math.max(south.abs(), north.abs()) + latMargin;
    final cosLat = math.cos(math.min(widestLatitude, 89.0) * math.pi / 180);
    final lonMargin = marginKm / (111.320 * cosLat);
    String fixed(double value) => value.toStringAsFixed(5);
    return '${fixed(math.max(-90, south - latMargin))},'
        '${fixed(math.max(-180, west - lonMargin))},'
        '${fixed(math.min(90, north + latMargin))},'
        '${fixed(math.min(180, east + lonMargin))}';
  }

  /// Splits the route into ~50 km pieces and returns one box per piece,
  /// widened by the corridor.
  static List<String> _routeBoxes(List<LatLng> route, double corridorWidthKm) {
    const pieceKm = 50.0;
    final boxes = <String>[];
    var piece = <LatLng>[route.first];
    var pieceLength = 0.0;
    for (var index = 1; index < route.length; index++) {
      pieceLength += ChargingStation.distanceBetweenKm(
        route[index - 1],
        route[index],
      );
      piece.add(route[index]);
      if (pieceLength >= pieceKm) {
        boxes.add(_boxAround(piece, corridorWidthKm));
        piece = [route[index]];
        pieceLength = 0;
      }
    }
    if (piece.length > 1 || boxes.isEmpty) {
      boxes.add(_boxAround(piece, corridorWidthKm));
    }
    return boxes;
  }

  void close() {
    _client.close();
  }
}
