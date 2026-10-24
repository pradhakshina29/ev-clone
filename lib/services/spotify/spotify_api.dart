import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'spotify_auth_service.dart';

/// A track from Spotify's TrackObject, kept only in memory for display.
class SpotifyTrack {
  const SpotifyTrack({
    required this.id,
    required this.name,
    required this.artists,
    required this.albumName,
    required this.uri,
    this.imageUrl,
    this.spotifyUrl,
    this.durationMs,
    this.isPlayable,
  });

  final String id;
  final String name;
  final List<String> artists;
  final String albumName;
  final String uri;
  final String? imageUrl;
  final String? spotifyUrl;
  final int? durationMs;
  final bool? isPlayable;

  String get artistLabel =>
      artists.isEmpty ? 'Unknown artist' : artists.join(', ');

  static SpotifyTrack? fromJson(Object? json) {
    if (json is! Map || json['type'] != 'track') return null;
    final id = json['id'];
    final name = json['name'];
    final uri = json['uri'];
    if (id is! String || name is! String || uri is! String) return null;
    final album = json['album'] is Map ? json['album'] as Map : const {};
    final images = [
      for (final image
          in album['images'] is List ? album['images'] as List : const [])
        if (image is Map && image['url'] is String) image,
    ];
    // Images come largest first; a ~300 px one suits the list and card.
    images.sort(
      (a, b) =>
          ((a['width'] as num?) ?? 0).compareTo((b['width'] as num?) ?? 0),
    );
    final image = images.firstWhere(
      (image) => ((image['width'] as num?) ?? 0) >= 200,
      orElse: () => images.isEmpty ? const {} : images.last,
    );
    final externalUrls = json['external_urls'];
    return SpotifyTrack(
      id: id,
      name: name,
      uri: uri,
      artists: [
        for (final artist
            in json['artists'] is List ? json['artists'] as List : const [])
          if (artist is Map && artist['name'] is String)
            artist['name'] as String,
      ],
      albumName: album['name'] is String ? album['name'] as String : '',
      imageUrl: image['url'] as String?,
      spotifyUrl: externalUrls is Map && externalUrls['spotify'] is String
          ? externalUrls['spotify'] as String
          : null,
      durationMs: (json['duration_ms'] as num?)?.toInt(),
      isPlayable: json['is_playable'] as bool?,
    );
  }
}

/// From CurrentlyPlayingContextObject (GET /me/player).
class SpotifyPlayback {
  const SpotifyPlayback({
    required this.isPlaying,
    this.track,
    this.itemName,
    this.deviceName,
    this.deviceRestricted = false,
  });

  final bool isPlaying;
  final SpotifyTrack? track;

  /// Name of a non-track item (e.g. a podcast episode).
  final String? itemName;
  final String? deviceName;

  /// The device accepts no Web API commands.
  final bool deviceRestricted;

  static SpotifyPlayback fromJson(Map json) {
    final device = json['device'] is Map ? json['device'] as Map : const {};
    final item = json['item'];
    return SpotifyPlayback(
      isPlaying: json['is_playing'] == true,
      track: SpotifyTrack.fromJson(item),
      itemName: item is Map && item['name'] is String
          ? item['name'] as String
          : null,
      deviceName: device['name'] as String?,
      deviceRestricted: device['is_restricted'] == true,
    );
  }
}

typedef Sleep = Future<void> Function(Duration duration);

/// Spotify Web API calls used by the music screen (see the official OpenAPI
/// schema: GET /search, GET /me/player, PUT /me/player/play, PUT
/// /me/player/pause). Nothing is cached beyond the current screen.
class SpotifyApi {
  SpotifyApi({
    SpotifyAuthService? auth,
    http.Client? client,
    Sleep? sleep,
    this.maxRateLimitRetries = 2,
    this.maxRetryWait = const Duration(seconds: 20),
  }) : _auth = auth ?? SpotifyAuthService.shared,
       _http = client ?? http.Client(),
       _sleep = sleep ?? Future.delayed;

  static const _host = 'api.spotify.com';

  /// The search endpoint's documented maximum per item type.
  static const searchLimit = 10;

  final SpotifyAuthService _auth;
  final http.Client _http;
  final Sleep _sleep;
  final int maxRateLimitRetries;
  final Duration maxRetryWait;

  Future<List<SpotifyTrack>> searchTracks(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final json = await _send(
      'GET',
      '/v1/search',
      query: {'q': trimmed, 'type': 'track', 'limit': '$searchLimit'},
    );
    final tracks = json is Map && json['tracks'] is Map
        ? json['tracks'] as Map
        : const {};
    return [
      for (final item
          in tracks['items'] is List ? tracks['items'] as List : const [])
        ?SpotifyTrack.fromJson(item),
    ];
  }

  /// Null when nothing is playing on any device (204).
  Future<SpotifyPlayback?> playbackState() async {
    final json = await _send('GET', '/v1/me/player');
    return json is Map ? SpotifyPlayback.fromJson(json) : null;
  }

  Future<void> playTrack(String trackUri) => _send(
    'PUT',
    '/v1/me/player/play',
    body: {
      'uris': [trackUri],
    },
  );

  /// Resumes whatever the active device was playing.
  Future<void> resume() => _send('PUT', '/v1/me/player/play');

  Future<void> pause() => _send('PUT', '/v1/me/player/pause');

  Future<Object?> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri.https(_host, path, query);
    var refreshed = false;
    var rateLimitRetries = 0;
    while (true) {
      final token = await _auth.accessToken();
      final http.Response response;
      try {
        final request = http.Request(method, uri)
          ..headers['Authorization'] = 'Bearer $token';
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.body = jsonEncode(body);
        }
        response = await http.Response.fromStream(
          await _http.send(request).timeout(const Duration(seconds: 20)),
        );
      } on TimeoutException {
        throw const SpotifyException(
          SpotifyErrorKind.network,
          'Spotify did not answer in time. Check your connection and try again.',
        );
      } catch (_) {
        throw const SpotifyException(
          SpotifyErrorKind.network,
          'Could not reach Spotify. Check your connection and try again.',
        );
      }

      final status = response.statusCode;
      if (status == 200) {
        return response.body.isEmpty ? null : jsonDecode(response.body);
      }
      if (status == 202 || status == 204) return null;
      if (status == 401 && !refreshed) {
        // The access token was revoked or expired early: refresh once.
        refreshed = true;
        await _auth.accessToken(forceRefresh: true);
        continue;
      }
      if (status == 429) {
        // Retry-After when given, else exponential backoff; never a tight loop.
        final wait =
            retryAfterFrom(response) ??
            Duration(seconds: 1 << rateLimitRetries);
        if (rateLimitRetries < maxRateLimitRetries && wait <= maxRetryWait) {
          rateLimitRetries++;
          debugPrint('[Spotify] Rate limited; retrying in ${wait.inSeconds}s');
          await _sleep(wait);
          continue;
        }
        throw SpotifyException(
          SpotifyErrorKind.rateLimited,
          'Spotify is limiting requests right now. Try again in '
          '${wait.inSeconds < 1 ? 1 : wait.inSeconds} seconds.',
          retryAfter: wait,
        );
      }
      throw _errorFor(response);
    }
  }

  static SpotifyException _errorFor(http.Response response) {
    String? reason;
    String? message;
    try {
      final json = jsonDecode(response.body);
      final error = json is Map ? json['error'] : null;
      if (error is Map) {
        reason = error['reason'] as String?;
        message = error['message'] as String?;
      }
    } catch (_) {
      // Non-JSON error bodies are never shown.
    }
    final status = response.statusCode;
    debugPrint('[Spotify] Request failed: HTTP $status ${reason ?? ''}');
    if (reason == 'PREMIUM_REQUIRED') {
      return const SpotifyException(
        SpotifyErrorKind.premiumRequired,
        'Playback control needs a Spotify Premium account. Use Open in Spotify instead.',
      );
    }
    if (reason == 'NO_ACTIVE_DEVICE' ||
        (status == 404 && message?.contains('device') == true)) {
      return const SpotifyException(
        SpotifyErrorKind.noActiveDevice,
        'No active Spotify device. Open Spotify on your phone, car or speaker, '
        'start any song, then try again.',
      );
    }
    if (status == 401) {
      return const SpotifyException(
        SpotifyErrorKind.authExpired,
        'Your Spotify sign-in has expired. Connect Spotify again.',
      );
    }
    if (status == 403) {
      return const SpotifyException(
        SpotifyErrorKind.forbidden,
        'Spotify refused this request. If the app is in development mode, '
        'your Spotify account must be added as a user in the Spotify Developer Dashboard.',
      );
    }
    return const SpotifyException(
      SpotifyErrorKind.unavailable,
      'Spotify is temporarily unavailable. Please try again.',
    );
  }
}
