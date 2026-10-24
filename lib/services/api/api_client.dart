import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../auth_service.dart';
import 'api_config.dart';

/// Returns the signed-in user's access token, or null when signed out.
typedef IdTokenProvider = Future<String?> Function({bool forceRefresh});

Future<String?> _sessionAccessToken({bool forceRefresh = false}) =>
    AuthService().accessToken(forceRefresh: forceRefresh);

class ApiException implements Exception {
  const ApiException(this.statusCode, this.code, this.message);

  /// 0 when no HTTP response was received (offline, timeout).
  final int statusCode;
  final String code;
  final String message;

  bool get isNotFound => statusCode == 404;

  @override
  String toString() => message;
}

/// Talks to the backend with the access token attached. Never logs tokens
/// or request/response bodies.
class ApiClient {
  ApiClient({
    http.Client? httpClient,
    IdTokenProvider? tokenProvider,
    String? baseUrl,
    // Long enough for a free Render instance to wake from sleep.
    this.timeout = const Duration(seconds: 60),
  }) : _http = httpClient ?? http.Client(),
       _tokenProvider = tokenProvider ?? _sessionAccessToken,
       _baseUrl = (baseUrl ?? apiBaseUrl).replaceFirst(RegExp(r'/+$'), '');

  final http.Client _http;
  final IdTokenProvider _tokenProvider;
  final String _baseUrl;
  final Duration timeout;

  static const _idempotentMethods = {'GET', 'PUT', 'DELETE'};

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _json('GET', path, query: query);

  Future<dynamic> post(String path, [Object? body]) =>
      _json('POST', path, body: body);

  Future<dynamic> put(String path, [Object? body]) =>
      _json('PUT', path, body: body);

  Future<dynamic> patch(String path, [Object? body]) =>
      _json('PATCH', path, body: body);

  Future<dynamic> delete(String path) => _json('DELETE', path);

  /// Raw bytes (e.g. the profile photo). Returns null on 404.
  Future<Uint8List?> getBytes(String path) async {
    try {
      final response = await _send('GET', path);
      return response.bodyBytes;
    } on ApiException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
  }

  Future<dynamic> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final response = await _send(method, path, query: query, body: body);
    if (response.body.isEmpty) return null;
    return jsonDecode(response.body);
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    final encodedBody = body == null ? null : jsonEncode(body);
    // Render's free plan wakes slowly: retry once, but only where repeating is safe.
    final attempts = _idempotentMethods.contains(method) ? 2 : 1;

    http.Response? response;
    for (var attempt = 1; ; attempt++) {
      try {
        final (first, sentToken) = await _attempt(
          method,
          uri,
          encodedBody,
          refresh: false,
        );
        response = first;
        if (response.statusCode == 401 && sentToken) {
          // The token may have just expired: refresh it once and retry.
          (response, _) = await _attempt(
            method,
            uri,
            encodedBody,
            refresh: true,
          );
        }
        break;
      } on TimeoutException {
        if (attempt >= attempts) {
          throw const ApiException(
            0,
            'timeout',
            'Server is waking up, please try again.',
          );
        }
      } on http.ClientException {
        if (attempt >= attempts) {
          throw const ApiException(
            0,
            'network',
            'No internet connection. Check your connection and try again.',
          );
        }
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    throw _errorFrom(response);
  }

  /// Sends one request; also reports whether a token was attached.
  Future<(http.Response, bool)> _attempt(
    String method,
    Uri uri,
    String? body, {
    required bool refresh,
  }) async {
    final token = await _tokenProvider(forceRefresh: refresh);
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json';
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body;
    }
    final streamed = await _http.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed).timeout(timeout);
    return (response, token != null && token.isNotEmpty);
  }

  ApiException _errorFrom(http.Response response) {
    var code = 'http_${response.statusCode}';
    String? message;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = decoded['error'] as Map;
        if (error['code'] is String) code = error['code'] as String;
        if (error['message'] is String) message = error['message'] as String;
      }
    } catch (_) {
      // Non-JSON error bodies (e.g. a proxy page) are never shown to users.
    }
    final status = response.statusCode;
    if (code == 'vehicle_not_found') {
      message = "You don't have access to this vehicle.";
    } else if (status == 401 &&
        (code == 'unauthenticated' || message == null)) {
      message = 'Your sign-in has expired. Please sign in again.';
    } else if (status == 429) {
      message ??= 'Too many requests. Please wait a moment and try again.';
    } else if (status == 502 || status == 503 || status == 504) {
      message ??= 'Server is waking up, please try again.';
    }
    return ApiException(
      status,
      code,
      message ?? 'Something went wrong. Please try again.',
    );
  }
}
