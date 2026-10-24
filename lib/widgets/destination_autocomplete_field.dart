import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/road_route.dart';

typedef PlaceSearch = Future<List<GeocodedDestination>> Function(String query);

class DestinationAutocompleteField extends StatefulWidget {
  const DestinationAutocompleteField({
    super.key,
    required this.searchPlaces,
    required this.onQueryChanged,
    required this.onPlaceSelected,
    this.debounceDuration = const Duration(milliseconds: 400),
    this.minimumQueryLength = 3,
    this.labelText = 'Destination',
    this.hintText = 'Enter a city, address or place',
    this.prefixIcon = Icons.flag_outlined,
  });

  final PlaceSearch searchPlaces;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<GeocodedDestination?> onPlaceSelected;
  final Duration debounceDuration;
  final int minimumQueryLength;
  final String labelText;
  final String hintText;
  final IconData prefixIcon;

  @override
  State<DestinationAutocompleteField> createState() =>
      _DestinationAutocompleteFieldState();
}

class _DestinationAutocompleteFieldState
    extends State<DestinationAutocompleteField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  List<GeocodedDestination> _suggestions = const [];
  String? _searchMessage;
  bool _loading = false;
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) return;
    _cancelSearch(clearSuggestions: true);
  }

  void _handleChanged(String value) {
    _debounce?.cancel();
    _searchGeneration++;
    _searchMessage = null;
    _suggestions = const [];
    _loading = false;
    widget.onQueryChanged(value);
    widget.onPlaceSelected(null);

    final query = value.trim();
    if (query.isEmpty || query.length < widget.minimumQueryLength) {
      setState(() {});
      return;
    }

    final generation = _searchGeneration;
    _debounce = Timer(widget.debounceDuration, () {
      _fetchSuggestions(query, generation);
    });
    setState(() {});
  }

  Future<void> _fetchSuggestions(String query, int generation) async {
    if (!mounted ||
        !_focusNode.hasFocus ||
        generation != _searchGeneration) {
      return;
    }
    setState(() {
      _loading = true;
      _searchMessage = null;
      _suggestions = const [];
    });
    try {
      final places = await widget.searchPlaces(query);
      if (!mounted ||
          !_focusNode.hasFocus ||
          generation != _searchGeneration) {
        return;
      }
      setState(() {
        _loading = false;
        _suggestions = places;
        _searchMessage = places.isEmpty ? 'No places found' : null;
      });
    } catch (error, stackTrace) {
      debugPrint('Destination place search failed: $error\n$stackTrace');
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _loading = false;
        _suggestions = const [];
        _searchMessage =
            error.toString().contains('rate limited')
                ? 'Place search is temporarily rate limited. Please try again shortly.'
                : 'Could not search places. Check your connection and try again.';
      });
    }
  }

  void _selectPlace(GeocodedDestination place) {
    _debounce?.cancel();
    _searchGeneration++;
    _controller.value = TextEditingValue(
      text: place.displayLabel,
      selection: TextSelection.collapsed(offset: place.displayLabel.length),
    );
    setState(() {
      _loading = false;
      _suggestions = const [];
      _searchMessage = null;
    });
    widget.onQueryChanged(place.displayLabel);
    widget.onPlaceSelected(place);
    _focusNode.unfocus();
  }

  void _cancelSearch({required bool clearSuggestions}) {
    _debounce?.cancel();
    _searchGeneration++;
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (clearSuggestions) {
        _suggestions = const [];
        _searchMessage = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      onTapOutside: (_) {
        if (_focusNode.hasFocus) _focusNode.unfocus();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _handleChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: widget.labelText,
            hintText: widget.hintText,
            prefixIcon: Icon(widget.prefixIcon),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _controller.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Clear ${widget.labelText.toLowerCase()}',
                    onPressed: () {
                      _controller.clear();
                      _handleChanged('');
                    },
                    icon: const Icon(Icons.clear),
                  )
                : null,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_loading || _suggestions.isNotEmpty || _searchMessage != null)
          Card(
            margin: const EdgeInsets.only(top: 6),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Searching places…'),
                    ),
                  ),
                if (_searchMessage != null)
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _searchMessage!,
                        style: TextStyle(
                          color: _searchMessage == 'No places found'
                              ? AppTheme.mutedBlue
                              : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                for (var index = 0; index < _suggestions.length; index++) ...[
                  if (index > 0) const Divider(height: 1),
                  _suggestionTile(_suggestions[index]),
                ],
              ],
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 4, left: 4),
          child: Text(
            'Place search by Photon · © OpenStreetMap contributors',
            style: TextStyle(fontSize: 11, color: AppTheme.mutedBlue),
          ),
        ),
        ],
      ),
    );
  }

  Widget _suggestionTile(GeocodedDestination place) {
    final details = [
      place.addressComponents['city'],
      place.addressComponents['state'],
      place.addressComponents['country'],
    ]
        .whereType<String>()
        .where((part) => part.trim().isNotEmpty)
        .toSet()
        .join(', ');
    final subtitle = details.isNotEmpty
        ? details
        : place.address == place.displayLabel
        ? null
        : place.address;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.location_on_outlined, color: AppTheme.blue),
      title: Text(place.displayLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => _selectPlace(place),
    );
  }
}
