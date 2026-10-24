import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_application_2/screens/music_page.dart';
import 'package:flutter_application_2/services/spotify/spotify_api.dart';
import 'package:flutter_application_2/services/spotify/spotify_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryStore implements SpotifyTokenStore {
  SpotifyTokens? tokens;

  @override
  Future<void> clear() async => tokens = null;

  @override
  Future<SpotifyTokens?> read() async => tokens;

  @override
  Future<void> write(SpotifyTokens value) async => tokens = value;
}

final _now = DateTime.utc(2026, 10, 24, 12);
const _redirect = 'evsmartcompanion://spotify-callback';

SpotifyTokens _tokens({bool expired = false}) => SpotifyTokens(
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  expiresAt: expired ? _now : _now.add(const Duration(hours: 1)),
);

http.Response _json(
  Object body, [
  int status = 200,
  Map<String, String>? headers,
]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...?headers},
);

SpotifyAuthService _auth(
  _MemoryStore store, {
  http.Client? client,
  SpotifyAuthenticator? authenticate,
  String clientId = 'test-client-id',
}) => SpotifyAuthService(
  client: client ?? MockClient((_) async => http.Response('', 500)),
  store: store,
  authenticate: authenticate ?? (_, _) async => throw StateError('unused'),
  clientId: clientId,
  redirectUri: _redirect,
  now: () => _now,
);

Map<String, Object?> _track(String id, String name) => {
  'type': 'track',
  'id': id,
  'name': name,
  'uri': 'spotify:track:$id',
  'duration_ms': 215000,
  'artists': [
    {'name': 'Artist A'},
    {'name': 'Artist B'},
  ],
  'album': {
    'name': 'Album X',
    'images': [
      {'url': 'https://i.scdn.co/640', 'width': 640, 'height': 640},
      {'url': 'https://i.scdn.co/300', 'width': 300, 'height': 300},
      {'url': 'https://i.scdn.co/64', 'width': 64, 'height': 64},
    ],
  },
  'external_urls': {'spotify': 'https://open.spotify.com/track/$id'},
};

void main() {
  group('PKCE sign-in', () {
    test('S256 challenge matches the RFC 7636 example', () {
      expect(
        SpotifyAuthService.codeChallengeFor(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        ),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('authorizes with PKCE and stores the exchanged tokens', () async {
      final store = _MemoryStore();
      Uri? authorizeUrl;
      Map<String, String>? tokenForm;
      final auth = _auth(
        store,
        authenticate: (url, scheme) async {
          authorizeUrl = url;
          expect(scheme, 'evsmartcompanion');
          return '$_redirect?code=auth-code&state=${url.queryParameters['state']}';
        },
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://accounts.spotify.com/api/token',
          );
          expect(
            request.headers['content-type'],
            startsWith('application/x-www-form-urlencoded'),
          );
          tokenForm = request.bodyFields;
          return _json({
            'access_token': 'access-1',
            'token_type': 'Bearer',
            'expires_in': 3600,
            'refresh_token': 'refresh-1',
            'scope': 'user-read-playback-state user-modify-playback-state',
          });
        }),
      );

      await auth.connect();

      final query = authorizeUrl!.queryParameters;
      expect(authorizeUrl!.host, 'accounts.spotify.com');
      expect(authorizeUrl!.path, '/authorize');
      expect(query['response_type'], 'code');
      expect(query['client_id'], 'test-client-id');
      expect(query['redirect_uri'], _redirect);
      expect(query['code_challenge_method'], 'S256');
      expect(
        query['scope'],
        'user-read-playback-state user-modify-playback-state',
      );
      expect(query['state'], hasLength(24));
      expect(tokenForm!['grant_type'], 'authorization_code');
      expect(tokenForm!['code'], 'auth-code');
      expect(tokenForm!['redirect_uri'], _redirect);
      expect(tokenForm!.containsKey('client_secret'), isFalse);
      // The verifier sent to the token endpoint is the one behind the challenge.
      expect(
        SpotifyAuthService.codeChallengeFor(tokenForm!['code_verifier']!),
        query['code_challenge'],
      );
      expect(store.tokens?.accessToken, 'access-1');
      expect(store.tokens?.expiresAt, _now.add(const Duration(seconds: 3600)));
    });

    test(
      'rejects a callback with the wrong state and stores nothing',
      () async {
        final store = _MemoryStore();
        final auth = _auth(
          store,
          authenticate: (_, _) async => '$_redirect?code=x&state=forged',
        );
        await expectLater(auth.connect(), throwsA(isA<SpotifyException>()));
        expect(store.tokens, isNull);
      },
    );

    test('a denied consent is reported as cancelled', () async {
      final auth = _auth(
        _MemoryStore(),
        authenticate: (url, _) async =>
            '$_redirect?error=access_denied&state=${url.queryParameters['state']}',
      );
      await expectLater(
        auth.connect(),
        throwsA(
          isA<SpotifyException>().having(
            (e) => e.kind,
            'kind',
            SpotifyErrorKind.cancelled,
          ),
        ),
      );
    });

    test('a build without a client ID cannot start sign-in', () async {
      final auth = _auth(_MemoryStore(), clientId: '');
      expect(auth.isConfigured, isFalse);
      await expectLater(
        auth.connect(),
        throwsA(
          isA<SpotifyException>().having(
            (e) => e.kind,
            'kind',
            SpotifyErrorKind.notConfigured,
          ),
        ),
      );
    });

    test(
      'refreshes an expired token and keeps the refresh token Spotify omitted',
      () async {
        final store = _MemoryStore()..tokens = _tokens(expired: true);
        Map<String, String>? form;
        final auth = _auth(
          store,
          client: MockClient((request) async {
            form = request.bodyFields;
            return _json({'access_token': 'access-2', 'expires_in': 3600});
          }),
        );
        expect(await auth.accessToken(), 'access-2');
        expect(form, {
          'grant_type': 'refresh_token',
          'refresh_token': 'refresh-1',
          'client_id': 'test-client-id',
        });
        expect(store.tokens?.refreshToken, 'refresh-1');
      },
    );

    test('a revoked refresh token clears the sign-in', () async {
      final store = _MemoryStore()..tokens = _tokens(expired: true);
      final auth = _auth(
        store,
        client: MockClient((_) async => _json({'error': 'invalid_grant'}, 400)),
      );
      await expectLater(
        auth.accessToken(),
        throwsA(
          isA<SpotifyException>().having(
            (e) => e.kind,
            'kind',
            SpotifyErrorKind.authExpired,
          ),
        ),
      );
      expect(store.tokens, isNull);
    });
  });

  group('Web API', () {
    test(
      'searches tracks with the documented parameters and parses them',
      () async {
        Uri? called;
        final api = SpotifyApi(
          auth: _auth(_MemoryStore()..tokens = _tokens()),
          client: MockClient((request) async {
            called = request.url;
            expect(request.headers['Authorization'], 'Bearer access-1');
            return _json({
              'tracks': {
                'items': [
                  _track('t1', 'First'),
                  {'type': 'track'},
                ],
              },
            });
          }),
        );
        final tracks = await api.searchTracks('  daft punk ');
        expect(called!.host, 'api.spotify.com');
        expect(called!.path, '/v1/search');
        expect(called!.queryParameters, {
          'q': 'daft punk',
          'type': 'track',
          'limit': '10',
        });
        expect(tracks, hasLength(1));
        expect(tracks.single.artistLabel, 'Artist A, Artist B');
        expect(tracks.single.albumName, 'Album X');
        expect(tracks.single.imageUrl, 'https://i.scdn.co/300');
        expect(tracks.single.spotifyUrl, 'https://open.spotify.com/track/t1');
      },
    );

    test('refreshes once on 401 and retries', () async {
      final store = _MemoryStore()..tokens = _tokens();
      final seen = <String?>[];
      final api = SpotifyApi(
        auth: _auth(
          store,
          // The token endpoint answers the forced refresh.
          client: MockClient(
            (_) async =>
                _json({'access_token': 'access-2', 'expires_in': 3600}),
          ),
        ),
        client: MockClient((request) async {
          seen.add(request.headers['Authorization']);
          return seen.length == 1
              ? _json({
                  'error': {'status': 401, 'message': 'expired'},
                }, 401)
              : _json({
                  'tracks': {'items': []},
                });
        }),
      );
      expect(await api.searchTracks('x'), isEmpty);
      expect(seen, ['Bearer access-1', 'Bearer access-2']);
    });

    test('waits for Retry-After on 429, then succeeds', () async {
      final waits = <Duration>[];
      var calls = 0;
      final api = SpotifyApi(
        auth: _auth(_MemoryStore()..tokens = _tokens()),
        sleep: (d) async => waits.add(d),
        client: MockClient(
          (_) async => ++calls == 1
              ? _json(
                  {
                    'error': {'status': 429},
                  },
                  429,
                  {'retry-after': '3'},
                )
              : _json({
                  'tracks': {'items': []},
                }),
        ),
      );
      await api.searchTracks('x');
      expect(waits, [const Duration(seconds: 3)]);
      expect(calls, 2);
    });

    test('gives up instead of waiting a long Retry-After', () async {
      final waits = <Duration>[];
      final api = SpotifyApi(
        auth: _auth(_MemoryStore()..tokens = _tokens()),
        sleep: (d) async => waits.add(d),
        client: MockClient(
          (_) async => _json(
            {
              'error': {'status': 429},
            },
            429,
            {'retry-after': '120'},
          ),
        ),
      );
      await expectLater(
        api.searchTracks('x'),
        throwsA(
          isA<SpotifyException>()
              .having((e) => e.kind, 'kind', SpotifyErrorKind.rateLimited)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 120),
              ),
        ),
      );
      expect(waits, isEmpty);
    });

    test(
      'backs off exponentially without Retry-After and stops after the limit',
      () async {
        final waits = <Duration>[];
        var calls = 0;
        final api = SpotifyApi(
          auth: _auth(_MemoryStore()..tokens = _tokens()),
          sleep: (d) async => waits.add(d),
          client: MockClient((_) async {
            calls++;
            return _json({
              'error': {'status': 429},
            }, 429);
          }),
        );
        await expectLater(
          api.searchTracks('x'),
          throwsA(isA<SpotifyException>()),
        );
        expect(waits, [const Duration(seconds: 1), const Duration(seconds: 2)]);
        expect(calls, 3);
      },
    );

    test('maps Premium-required and no-active-device player errors', () async {
      for (final (status, reason, kind) in [
        (403, 'PREMIUM_REQUIRED', SpotifyErrorKind.premiumRequired),
        (404, 'NO_ACTIVE_DEVICE', SpotifyErrorKind.noActiveDevice),
      ]) {
        final api = SpotifyApi(
          auth: _auth(_MemoryStore()..tokens = _tokens()),
          client: MockClient((request) async {
            expect(request.method, 'PUT');
            expect(jsonDecode(request.body), {
              'uris': ['spotify:track:t1'],
            });
            return _json({
              'error': {
                'status': status,
                'message': 'Player command failed',
                'reason': reason,
              },
            }, status);
          }),
        );
        await expectLater(
          api.playTrack('spotify:track:t1'),
          throwsA(isA<SpotifyException>().having((e) => e.kind, 'kind', kind)),
        );
      }
    });

    test(
      '204 playback means nothing is playing; network failures are reported',
      () async {
        final api = SpotifyApi(
          auth: _auth(_MemoryStore()..tokens = _tokens()),
          client: MockClient((_) async => http.Response('', 204)),
        );
        expect(await api.playbackState(), isNull);

        final offline = SpotifyApi(
          auth: _auth(_MemoryStore()..tokens = _tokens()),
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );
        await expectLater(
          offline.searchTracks('x'),
          throwsA(
            isA<SpotifyException>().having(
              (e) => e.kind,
              'kind',
              SpotifyErrorKind.network,
            ),
          ),
        );
      },
    );
  });

  group('Music screen', () {
    testWidgets('searches, selects a track and offers Open in Spotify', (
      tester,
    ) async {
      final store = _MemoryStore()..tokens = _tokens();
      final auth = _auth(store);
      final opened = <Uri>[];
      final api = SpotifyApi(
        auth: auth,
        client: MockClient(
          (request) async => request.url.path == '/v1/me/player'
              ? http.Response('', 204)
              : _json({
                  'tracks': {
                    'items': [_track('t1', 'First song')],
                  },
                }),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MusicPage(
            auth: auth,
            api: api,
            openUrl: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing is playing'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'first');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.text('First song'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open in Spotify'));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://open.spotify.com/track/t1')]);
      expect(find.text('Play on Spotify device'), findsOneWidget);
    });

    testWidgets('disconnect clears the stored sign-in', (tester) async {
      final store = _MemoryStore()..tokens = _tokens();
      final auth = _auth(store);
      final api = SpotifyApi(
        auth: auth,
        client: MockClient((_) async => http.Response('', 204)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MusicPage(auth: auth, api: api),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(store.tokens, isNull);
      expect(find.text('Connect Spotify'), findsWidgets);
    });

    testWidgets('explains when the build has no Spotify client ID', (
      tester,
    ) async {
      final auth = _auth(_MemoryStore(), clientId: '');
      await tester.pumpWidget(MaterialApp(home: MusicPage(auth: auth)));
      await tester.pumpAndSettle();
      expect(find.text('Spotify is not set up'), findsOneWidget);
    });
  });
}
