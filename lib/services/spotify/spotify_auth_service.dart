import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

/// Public client ID of the app registered in the Spotify Developer Dashboard.
/// PKCE needs no client secret, so none exists anywhere in the app.
/// Set at build time: `--dart-define=SPOTIFY_CLIENT_ID=your-client-id`.
const String spotifyClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');

/// Must match a redirect URI registered in the Spotify Developer Dashboard,
/// and the scheme in AndroidManifest.xml / Info.plist.
const String spotifyCallbackScheme = 'evsmartcompanion';
const String spotifyMobileRedirectUri =
    '$spotifyCallbackScheme://spotify-callback';

/// The web build receives the callback on web/spotify_callback.html. Spotify
/// accepts http only for loopback IPs, so run it on `http://127.0.0.1:PORT`
/// in development (never `localhost`).
String get spotifyRedirectUri => kIsWeb
    ? '${Uri.base.origin}/spotify_callback.html'
    : spotifyMobileRedirectUri;

/// Only what the music screen uses: reading playback (now playing, devices)
/// and play/pause. Search needs no scope.
const List<String> spotifyScopes = [
  'user-read-playback-state',
  'user-modify-playback-state',
];

enum SpotifyErrorKind {
  notConfigured,
  notConnected,
  cancelled,
  authExpired,
  premiumRequired,
  noActiveDevice,
  forbidden,
  rateLimited,
  network,
  unavailable,
}

class SpotifyException implements Exception {
  const SpotifyException(this.kind, this.message, {this.retryAfter});

  final SpotifyErrorKind kind;
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

class SpotifyTokens {
  const SpotifyTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// Refreshes a minute early so a request never carries a token that
  /// expires in flight.
  bool isExpired(DateTime now) =>
      !now.isBefore(expiresAt.subtract(const Duration(minutes: 1)));

  Map<String, Object> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };

  static SpotifyTokens? fromJson(Object? value) {
    if (value is! Map) return null;
    final access = value['accessToken'];
    final refresh = value['refreshToken'];
    final expiresAt = DateTime.tryParse('${value['expiresAt']}');
    if (access is! String || refresh is! String || expiresAt == null) {
      return null;
    }
    return SpotifyTokens(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
    );
  }
}

abstract interface class SpotifyTokenStore {
  Future<SpotifyTokens?> read();
  Future<void> write(SpotifyTokens tokens);
  Future<void> clear();
}

/// Android Keystore / iOS Keychain backed storage.
class SecureSpotifyTokenStore implements SpotifyTokenStore {
  SecureSpotifyTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'spotify_tokens';
  final FlutterSecureStorage _storage;

  @override
  Future<SpotifyTokens?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      return raw == null ? null : SpotifyTokens.fromJson(jsonDecode(raw));
    } catch (error) {
      debugPrint('[Spotify] Stored sign-in could not be read: $error');
      return null;
    }
  }

  @override
  Future<void> write(SpotifyTokens tokens) =>
      _storage.write(key: _key, value: jsonEncode(tokens.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Opens the Spotify consent page and returns the full callback URL.
typedef SpotifyAuthenticator =
    Future<String> Function(Uri authorizeUrl, String callbackScheme);

Future<String> _webAuthenticate(Uri url, String callbackScheme) =>
    FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: callbackScheme,
    );

/// Spotify Authorization Code flow with PKCE. Never logs tokens or codes.
class SpotifyAuthService {
  SpotifyAuthService({
    http.Client? client,
    SpotifyTokenStore? store,
    SpotifyAuthenticator? authenticate,
    String? clientId,
    String? redirectUri,
    DateTime Function()? now,
    Random? random,
  }) : _http = client ?? http.Client(),
       _store = store ?? SecureSpotifyTokenStore(),
       _authenticate = authenticate ?? _webAuthenticate,
       _clientId = clientId ?? spotifyClientId,
       _redirectUri = redirectUri ?? spotifyRedirectUri,
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  static final SpotifyAuthService shared = SpotifyAuthService();

  static final Uri authorizeEndpoint = Uri.https(
    'accounts.spotify.com',
    '/authorize',
  );
  static final Uri tokenEndpoint = Uri.https(
    'accounts.spotify.com',
    '/api/token',
  );

  final http.Client _http;
  final SpotifyTokenStore _store;
  final SpotifyAuthenticator _authenticate;
  final String _clientId;
  final String _redirectUri;
  final DateTime Function() _now;
  final Random _random;
  Future<SpotifyTokens>? _refreshing;

  bool get isConfigured => _clientId.isNotEmpty;

  Future<bool> isConnected() async => await _store.read() != null;

  Future<void> connect() async {
    if (!isConfigured) {
      throw const SpotifyException(
        SpotifyErrorKind.notConfigured,
        'Spotify is not set up in this build of the app.',
      );
    }
    final verifier = _randomString(64);
    final state = _randomString(24);
    final url = authorizeEndpoint.replace(
      queryParameters: {
        'client_id': _clientId,
        'response_type': 'code',
        'redirect_uri': _redirectUri,
        'code_challenge_method': 'S256',
        'code_challenge': codeChallengeFor(verifier),
        'scope': spotifyScopes.join(' '),
        'state': state,
      },
    );
    final String callback;
    try {
      callback = await _authenticate(url, spotifyCallbackScheme);
    } on PlatformException catch (error) {
      // flutter_web_auth_2 reports a closed browser as code CANCELED.
      if (error.code == 'CANCELED') {
        throw const SpotifyException(
          SpotifyErrorKind.cancelled,
          'Spotify sign-in was cancelled.',
        );
      }
      debugPrint('[Spotify] Sign-in window failed: ${error.code}');
      throw const SpotifyException(
        SpotifyErrorKind.unavailable,
        'Could not open Spotify sign-in. Please try again.',
      );
    } catch (error) {
      debugPrint('[Spotify] Sign-in window failed: ${error.runtimeType}');
      throw const SpotifyException(
        SpotifyErrorKind.unavailable,
        'Could not open Spotify sign-in. Please try again.',
      );
    }
    final params = Uri.parse(callback).queryParameters;
    if (params['state'] != state) {
      throw const SpotifyException(
        SpotifyErrorKind.unavailable,
        'Spotify sign-in could not be verified. Please try again.',
      );
    }
    if (params['error'] != null) {
      throw SpotifyException(
        params['error'] == 'access_denied'
            ? SpotifyErrorKind.cancelled
            : SpotifyErrorKind.unavailable,
        params['error'] == 'access_denied'
            ? 'Spotify access was not granted.'
            : 'Spotify sign-in failed. Please try again.',
      );
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const SpotifyException(
        SpotifyErrorKind.unavailable,
        'Spotify did not return a sign-in code. Please try again.',
      );
    }
    final tokens = await _requestTokens({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': _redirectUri,
      'client_id': _clientId,
      'code_verifier': verifier,
    }, previousRefreshToken: null);
    await _store.write(tokens);
  }

  /// A usable access token, refreshing it when it has expired (or when
  /// [forceRefresh] after a 401).
  Future<String> accessToken({bool forceRefresh = false}) async {
    final tokens = await _store.read();
    if (tokens == null) {
      throw const SpotifyException(
        SpotifyErrorKind.notConnected,
        'Connect Spotify to continue.',
      );
    }
    if (!forceRefresh && !tokens.isExpired(_now())) return tokens.accessToken;
    // Concurrent callers share one refresh; a refresh token may be single-use.
    final refreshing = _refreshing ??= _refresh(
      tokens,
    ).whenComplete(() => _refreshing = null);
    return (await refreshing).accessToken;
  }

  Future<SpotifyTokens> _refresh(SpotifyTokens tokens) async {
    final refreshed = await _requestTokens({
      'grant_type': 'refresh_token',
      'refresh_token': tokens.refreshToken,
      'client_id': _clientId,
    }, previousRefreshToken: tokens.refreshToken);
    await _store.write(refreshed);
    return refreshed;
  }

  /// Forgets the Spotify sign-in on this device. (Spotify has no token
  /// revocation endpoint; access can also be removed at spotify.com/account.)
  Future<void> disconnect() => _store.clear();

  Future<SpotifyTokens> _requestTokens(
    Map<String, String> body, {
    required String? previousRefreshToken,
  }) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            tokenEndpoint,
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: body,
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const SpotifyException(
        SpotifyErrorKind.network,
        'Could not reach Spotify. Check your connection and try again.',
      );
    }
    if (response.statusCode == 400 || response.statusCode == 401) {
      // invalid_grant: the refresh token was revoked or has expired.
      await _store.clear();
      throw const SpotifyException(
        SpotifyErrorKind.authExpired,
        'Your Spotify sign-in has expired. Connect Spotify again.',
      );
    }
    if (response.statusCode == 429) {
      throw SpotifyException(
        SpotifyErrorKind.rateLimited,
        'Spotify is busy. Please wait a moment and try again.',
        retryAfter: retryAfterFrom(response),
      );
    }
    if (response.statusCode != 200) {
      throw const SpotifyException(
        SpotifyErrorKind.unavailable,
        'Spotify sign-in is temporarily unavailable. Please try again.',
      );
    }
    final json = jsonDecode(response.body);
    final access = json is Map ? json['access_token'] : null;
    final expiresIn = json is Map ? json['expires_in'] : null;
    // A refresh may omit refresh_token; the previous one then stays valid.
    final refresh =
        (json is Map ? json['refresh_token'] : null) ?? previousRefreshToken;
    if (access is! String || refresh is! String || expiresIn is! num) {
      throw const SpotifyException(
        SpotifyErrorKind.unavailable,
        'Spotify returned an unexpected sign-in response.',
      );
    }
    return SpotifyTokens(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: _now().add(Duration(seconds: expiresIn.toInt())),
    );
  }

  String _randomString(int length) {
    // RFC 7636 unreserved characters.
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(
      length,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
  }

  /// BASE64URL(SHA256(verifier)) without padding (RFC 7636 S256).
  static String codeChallengeFor(String verifier) => base64UrlEncode(
    sha256.convert(ascii.encode(verifier)).bytes,
  ).replaceAll('=', '');
}

/// Seconds from a 429's Retry-After header (Spotify sends whole seconds).
Duration? retryAfterFrom(http.BaseResponse response) {
  final seconds = int.tryParse(response.headers['retry-after'] ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}
