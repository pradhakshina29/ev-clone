import 'package:flutter_application_2/screens/trip_planner.dart';
import 'package:flutter_application_2/services/api/api_client.dart';
import 'package:flutter_application_2/services/charging_station_service.dart';
import 'package:flutter_application_2/services/road_directions_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('trip planning failures map to readable messages, never raw errors', () {
    expect(
      tripPlanningErrorMessage(
        const FormatException('No matching destination was found.'),
      ),
      contains('could not be found'),
    );
    expect(
      tripPlanningErrorMessage(
        const FormatException('A driving route could not be found.'),
      ),
      contains('No driving route exists'),
    );
    expect(
      tripPlanningErrorMessage(
        const RoadDirectionsException(
          'Place search is temporarily rate limited.',
        ),
      ),
      'Place search is temporarily rate limited.',
    );
    expect(
      tripPlanningErrorMessage(const MapServiceBusyException()),
      endsWith('Tap Plan Trip to retry.'),
    );
    expect(
      tripPlanningErrorMessage(
        const ApiException(429, 'rate_limited', 'Too many map requests.'),
      ),
      'Too many map requests.',
    );
    final generic = tripPlanningErrorMessage(
      StateError('socket closed at 0x1f'),
    );
    expect(generic, isNot(contains('0x1f')));
  });
}
