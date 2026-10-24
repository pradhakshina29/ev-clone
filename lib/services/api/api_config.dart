import 'package:flutter/foundation.dart';

/// Set at build time:
/// `--dart-define=API_BASE_URL=https://your-service.onrender.com`
const String _definedApiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// Base URL of the EV Smart Companion backend. Debug builds fall back to a
/// local backend; release and profile builds never do.
String get apiBaseUrl {
  if (_definedApiBaseUrl.isNotEmpty) return _definedApiBaseUrl;
  if (kDebugMode) return 'http://localhost:8081';
  throw StateError(
    'API_BASE_URL is not set. Build with '
    '--dart-define=API_BASE_URL=https://your-service.onrender.com',
  );
}

/// Stops a release or profile build at startup when API_BASE_URL is missing
/// or not HTTPS, instead of failing later on the first request.
void ensureApiBaseUrlConfigured() {
  if (kDebugMode) return;
  final url = apiBaseUrl;
  if (!url.startsWith('https://')) {
    throw StateError(
      'API_BASE_URL must use https:// in release builds. '
      'Build with --dart-define=API_BASE_URL=https://...',
    );
  }
}
