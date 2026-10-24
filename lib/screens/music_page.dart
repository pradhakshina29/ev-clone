import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../services/spotify/spotify_api.dart';
import '../services/spotify/spotify_auth_service.dart';

/// Spotify search and playback control. Independent of BLE: nothing here
/// touches the vehicle connection or telemetry, and no Spotify data or
/// token is ever sent to the vehicle simulator.
class MusicPage extends StatefulWidget {
  const MusicPage({super.key, this.auth, this.api, this.openUrl});

  final SpotifyAuthService? auth;
  final SpotifyApi? api;
  final Future<bool> Function(Uri url)? openUrl;

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  late final SpotifyAuthService _auth =
      widget.auth ?? SpotifyAuthService.shared;
  late final SpotifyApi _api = widget.api ?? SpotifyApi(auth: _auth);
  final _searchController = TextEditingController();

  bool? _connected;
  bool _busy = false;
  bool _searching = false;
  String? _message;
  bool _messageIsError = false;
  List<SpotifyTrack>? _results;
  SpotifyTrack? _selected;
  SpotifyPlayback? _playback;
  bool _playbackLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadConnection();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadConnection() async {
    final connected = await _auth.isConnected();
    if (!mounted) return;
    setState(() => _connected = connected);
    if (connected) await _refreshPlayback();
  }

  void _show(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsError = error;
    });
  }

  /// Shows [error]; a lost sign-in returns the screen to "Connect".
  void _handleError(Object error) {
    if (error is SpotifyException) {
      if (error.kind == SpotifyErrorKind.notConnected ||
          error.kind == SpotifyErrorKind.authExpired) {
        setState(() {
          _connected = false;
          _results = null;
          _selected = null;
          _playback = null;
        });
      }
      _show(error.message, error: error.kind != SpotifyErrorKind.cancelled);
    } else {
      debugPrint('[Spotify] Unexpected error: $error');
      _show(
        'Something went wrong with Spotify. Please try again.',
        error: true,
      );
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) _handleError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
    await _auth.connect();
    if (!mounted) return;
    setState(() => _connected = true);
    _show('Spotify connected.');
    await _refreshPlayback();
  });

  Future<void> _disconnect() => _run(() async {
    await _auth.disconnect();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _results = null;
      _selected = null;
      _playback = null;
      _playbackLoaded = false;
    });
    _searchController.clear();
    _show('Spotify disconnected from this device.');
  });

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      _show('Enter a song, artist or album to search.', error: true);
      return;
    }
    if (_searching) return;
    setState(() {
      _searching = true;
      _message = null;
      _selected = null;
    });
    try {
      final results = await _api.searchTracks(query);
      if (!mounted) return;
      setState(() => _results = results);
    } catch (error) {
      if (mounted) _handleError(error);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Fetched on open and after each command, never on a timer.
  Future<void> _refreshPlayback() async {
    try {
      final playback = await _api.playbackState();
      if (!mounted) return;
      setState(() {
        _playback = playback;
        _playbackLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _playbackLoaded = true);
      _handleError(error);
    }
  }

  Future<void> _command(Future<void> Function() command, String done) =>
      _run(() async {
        await command();
        _show(done);
        // Spotify applies commands asynchronously; give it a moment.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await _refreshPlayback();
      });

  Future<void> _openInSpotify(SpotifyTrack track) async {
    final url = track.spotifyUrl;
    if (url == null) {
      _show('This track has no Spotify link.', error: true);
      return;
    }
    final open =
        widget.openUrl ??
        (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!await open(Uri.parse(url))) {
      _show('Could not open Spotify.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connected;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Music'),
        actions: [
          if (connected == true)
            TextButton.icon(
              onPressed: _busy ? null : _disconnect,
              icon: const Icon(Icons.link_off_rounded),
              label: const Text('Disconnect'),
            ),
        ],
      ),
      body: connected == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
              children: [
                if (!_auth.isConfigured)
                  const _InfoCard(
                    icon: Icons.settings_suggest_outlined,
                    title: 'Spotify is not set up',
                    body:
                        'This build has no Spotify client ID. A developer must '
                        'register the app in the Spotify Developer Dashboard and build '
                        'with --dart-define=SPOTIFY_CLIENT_ID=…',
                  )
                else if (!connected)
                  _connectCard()
                else ...[
                  _nowPlayingCard(),
                  const SizedBox(height: 14),
                  _searchField(),
                  if (_selected case final track?) ...[
                    const SizedBox(height: 14),
                    _selectedCard(track),
                  ],
                  const SizedBox(height: 10),
                  _resultsList(),
                ],
                if (_message != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _message!,
                    style: TextStyle(
                      color: _messageIsError
                          ? Theme.of(context).colorScheme.error
                          : AppTheme.mutedBlue,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                const Text(
                  'Music content and playback are provided by Spotify. Playback '
                  'controls need Spotify Premium and an active Spotify device; '
                  'audio always plays in Spotify, not in this app.',
                  style: TextStyle(fontSize: 11, color: AppTheme.mutedBlue),
                ),
              ],
            ),
    );
  }

  Widget _connectCard() => _InfoCard(
    icon: Icons.music_note_rounded,
    title: 'Connect Spotify',
    body:
        'Search songs and control playback on your Spotify devices. You sign '
        'in on Spotify\'s own page; this app never sees your password.',
    action: FilledButton.icon(
      onPressed: _busy ? null : _connect,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.login_rounded),
      label: const Text('Connect Spotify'),
    ),
  );

  Widget _nowPlayingCard() {
    final playback = _playback;
    final track = playback?.track;
    final canControl = playback != null && !playback.deviceRestricted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'NOW PLAYING',
                    style: TextStyle(
                      color: AppTheme.mutedBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _busy ? null : _refreshPlayback,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (!_playbackLoaded)
              const LinearProgressIndicator()
            else if (playback == null)
              const Text(
                'Nothing is playing. Open Spotify on a phone, car or speaker to '
                'make it an active device.',
                style: TextStyle(color: AppTheme.mutedBlue),
              )
            else ...[
              Row(
                children: [
                  _Artwork(url: track?.imageUrl, size: 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track?.name ?? playback.itemName ?? 'Unknown item',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.navy,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (track != null)
                          Text(
                            track.artistLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Text(
                          'On ${playback.deviceName ?? 'a Spotify device'}',
                          style: const TextStyle(
                            color: AppTheme.mutedBlue,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filled(
                    tooltip: playback.isPlaying ? 'Pause' : 'Resume',
                    onPressed: _busy || !canControl
                        ? null
                        : () => playback.isPlaying
                              ? _command(_api.pause, 'Paused.')
                              : _command(_api.resume, 'Resumed.'),
                    icon: Icon(
                      playback.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                ],
              ),
              if (playback.deviceRestricted)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'This device does not accept remote control.',
                    style: TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _searchField() => TextField(
    controller: _searchController,
    textInputAction: TextInputAction.search,
    maxLength: 100,
    onSubmitted: (_) => _search(),
    decoration: InputDecoration(
      labelText: 'Search Spotify',
      hintText: 'Song, artist or album',
      counterText: '',
      prefixIcon: const Icon(Icons.search_rounded),
      suffixIcon: _searching
          ? const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : IconButton(
              tooltip: 'Search',
              onPressed: _search,
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
      border: const OutlineInputBorder(),
    ),
  );

  Widget _resultsList() {
    final results = _results;
    if (results == null) return const SizedBox.shrink();
    if (results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No songs found. Try different words.',
          style: TextStyle(color: AppTheme.mutedBlue),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < results.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            ListTile(
              selected: _selected?.id == results[i].id,
              leading: _Artwork(url: results[i].imageUrl, size: 44),
              title: Text(
                results[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  results[i].artistLabel,
                  if (results[i].albumName.isNotEmpty) results[i].albumName,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: results[i].durationMs == null
                  ? null
                  : Text(_duration(results[i].durationMs!)),
              onTap: () => setState(() {
                _selected = results[i];
                _message = null;
              }),
            ),
          ],
        ],
      ),
    );
  }

  Widget _selectedCard(SpotifyTrack track) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Artwork(url: track.imageUrl, size: 72),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.name,
                      style: const TextStyle(
                        color: AppTheme.navy,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(track.artistLabel),
                    if (track.albumName.isNotEmpty)
                      Text(
                        track.albumName,
                        style: const TextStyle(color: AppTheme.mutedBlue),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || track.isPlayable == false
                ? null
                : () => _command(
                    () => _api.playTrack(track.uri),
                    'Playing "${track.name}" on your active Spotify device.',
                  ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play on Spotify device'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _openInSpotify(track),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Open in Spotify'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Play needs Spotify Premium and Spotify open on a device. Without '
            'them, use Open in Spotify.',
            style: TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  static String _duration(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(icon, color: AppTheme.blue, size: 36),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.navy,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.mutedBlue),
          ),
          if (action != null) ...[const SizedBox(height: 14), action!],
        ],
      ),
    ),
  );
}

/// Album artwork as Spotify provides it (never cropped), or a placeholder.
class _Artwork extends StatelessWidget {
  const _Artwork({required this.url, required this.size});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: const Color(0xFFEAF2F7),
      child: const Icon(Icons.music_note_rounded, color: AppTheme.mutedBlue),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: url == null
          ? placeholder
          : Image.network(
              url!,
              width: size,
              height: size,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}
