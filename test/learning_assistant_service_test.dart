import 'package:flutter_application_2/services/learning_assistant_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_api.dart';

const _noContext = LearningVehicleContext(vehicle: null, telemetry: null);

void main() {
  test('returns the Gemini answer from the backend', () async {
    final api = FakeApi()
      ..on(
        'POST /v1/assistant/ask',
        (_) => {'success': true, 'answer': 'Regen recovers energy.'},
      );
    final answer = await ApiLearningAssistantService(
      api: api.client(),
    ).ask('What is regen?', context: _noContext);
    expect(answer, 'Regen recovers energy.');
  });

  test('shows the backend reason when Gemini is busy or misconfigured', () async {
    for (final (code, message) in [
      (
        'assistant_busy',
        'The EV learning assistant is busy right now. Please try again in a minute.',
      ),
      (
        'assistant_not_configured',
        'The EV learning assistant is not configured correctly. Please contact support.',
      ),
    ]) {
      final api = FakeApi()
        ..on(
          'POST /v1/assistant/ask',
          (_) => FakeReply(503, {
            'error': {'code': code, 'message': message},
          }),
        );
      await expectLater(
        ApiLearningAssistantService(
          api: api.client(),
        ).ask('Hi', context: _noContext),
        throwsA(
          isA<LearningAssistantException>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );
    }
  });

  test('rejects an empty question without calling the backend', () async {
    final api = FakeApi();
    await expectLater(
      ApiLearningAssistantService(
        api: api.client(),
      ).ask('   ', context: _noContext),
      throwsA(isA<LearningAssistantException>()),
    );
    expect(api.requests, isEmpty);
  });
}
