# Spotify music screen

Dashboard → **Music** searches Spotify and controls playback on the user's
own Spotify devices through the official Spotify Web API. It is independent of
BLE: it never touches the vehicle connection or telemetry, and no Spotify
data or token is sent to the vehicle simulator. The simulator has no music
interface, so there is no simulator integration.

## How it works

- **Sign-in:** Authorization Code with PKCE (`lib/services/spotify/spotify_auth_service.dart`).
  No client secret exists in the app. Scopes: `user-read-playback-state`
  (now playing) and `user-modify-playback-state` (play/pause). Search needs no
  scope.
- **Tokens:** stored with `flutter_secure_storage` (Android Keystore, iOS
  Keychain; on the web, encrypted browser storage). Refreshed automatically;
  if Spotify rejects the refresh token, the app asks the user to connect again.
  **Disconnect** deletes them from the device (Spotify has no revocation
  endpoint; users can also remove access at spotify.com/account).
- **API calls** (`lib/services/spotify/spotify_api.dart`, checked against the
  official OpenAPI schema): `GET /v1/search?type=track&limit=10` (10 is the
  documented maximum), `GET /v1/me/player`, `PUT /v1/me/player/play`,
  `PUT /v1/me/player/pause`. HTTP 429 waits for `Retry-After` (or 1 s, 2 s
  backoff), at most twice and never longer than 20 s; otherwise the user sees
  how long to wait. Playback state is fetched on open and after each command,
  never on a timer. Results are kept only in memory while the screen is open.
- **Playback:** the Web API controls playback on a Spotify Connect device
  (the Spotify app on a phone, desktop, car or speaker). It needs **Spotify
  Premium** and an **active device**; the screen explains both errors. Audio is
  never streamed or downloaded by this app. **Open in Spotify** always works.

## Setup (Spotify Developer Dashboard)

1. Sign in at developer.spotify.com/dashboard and create an app. Select
   **Web API** (add Android/iOS if asked).
2. Add the redirect URIs exactly:
   - Android/iOS: `evsmartcompanion://spotify-callback`
   - Web (development): `http://127.0.0.1:5100/spotify_callback.html`.
     Spotify allows http only for loopback IPs, so open the web app at
     `http://127.0.0.1:5100`, not `localhost`. A deployed web build needs its
     HTTPS origin + `/spotify_callback.html`.
3. Copy the **Client ID** (public, not a secret). Never use or store the
   client secret; PKCE does not need it.
4. Under **User Management**, add the Spotify account of every tester (apps in
   development mode only work for listed users; others get 403).
5. Build or run with the client ID:
   `flutter run --dart-define=SPOTIFY_CLIENT_ID=<client id> --dart-define=API_BASE_URL=...`

Without `SPOTIFY_CLIENT_ID` the Music screen says Spotify is not set up.

The app's Android `CallbackActivity` (AndroidManifest.xml) and iOS URL type
(Info.plist) use the `evsmartcompanion` scheme; change both together with the
dashboard entry if the redirect URI ever changes.

## Spotify terms checklist

- Content is attributed to Spotify on the screen; every track links back with
  **Open in Spotify**. Before a public release, add the official Spotify logo
  per Spotify's Design Guidelines (not bundled here).
- Album artwork is shown uncropped (`BoxFit.contain`).
- No Spotify data is cached beyond the open screen, stored on the backend or
  used to train models. Playback restrictions and Premium requirements are not
  bypassed.
