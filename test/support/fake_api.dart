import 'dart:convert';

import 'package:flutter_application_2/services/api/api_client.dart';
import 'package:flutter_application_2/services/data_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A non-200 reply for [FakeApi] routes.
class FakeReply {
  const FakeReply(this.status, [this.body]);

  final int status;
  final Object? body;
}

/// An in-memory stand-in for the backend. Routes are keyed by
/// `'METHOD /path'`; a handler returns JSON (200) or a [FakeReply].
class FakeApi {
  final routes = <String, Object? Function(http.Request request)>{};
  final requests = <http.Request>[];
  final tokensRequested = <bool>[];
  String token = 'test-token';

  void on(String route, Object? Function(http.Request request) handler) =>
      routes[route] = handler;

  List<http.Request> requestsTo(String route) => requests
      .where((request) => '${request.method} ${request.url.path}' == route)
      .toList();

  ApiClient client() => ApiClient(
    baseUrl: 'http://api.test',
    tokenProvider: ({bool forceRefresh = false}) async {
      tokensRequested.add(forceRefresh);
      return token;
    },
    httpClient: MockClient((request) async {
      requests.add(request);
      final key = '${request.method} ${request.url.path}';
      final handler = routes[key];
      if (handler == null) {
        return http.Response(
          jsonEncode({
            'error': {'code': 'not_found', 'message': 'No fake route $key'},
          }),
          404,
        );
      }
      final result = handler(request);
      // Non-JSON bodies such as PDF bytes.
      if (result is http.Response) return result;
      if (result is FakeReply) {
        return http.Response(
          result.body == null ? '' : jsonEncode(result.body),
          result.status,
        );
      }
      return http.Response(
        jsonEncode(result),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  DataService dataService() => DataService(api: client());
}
