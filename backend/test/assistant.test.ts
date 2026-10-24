// Ported from the original learning-assistant tests.
import request from 'supertest';
import { describe, expect, it, vi } from 'vitest';

import { logger } from '../src/logger.js';
import { apiApp, fakeFetch, jsonResponse } from './fixtures.js';
import { bearer } from './helpers.js';

const ASK = '/v1/assistant/ask';
const geminiAnswer = (text: string) =>
  jsonResponse({ steps: [{ type: 'model_output', content: [{ type: 'text', text }] }] });

describe('learning assistant', () => {
  it('rejects empty and excessively long questions, topics and context', async () => {
    const gemini = fakeFetch(() => geminiAnswer('unused'));
    const app = apiApp({ geminiFetch: gemini.fetch });
    for (const body of [
      { message: '   ' },
      { message: 'x'.repeat(2001) },
      { message: 'ok', topic: 't'.repeat(121) },
      { message: 'ok', context: 'c'.repeat(2001) },
      { message: 'ok', extra: true },
    ]) {
      const response = await request(app).post(ASK).set(bearer('alice')).send(body);
      expect(response.status).toBe(400);
    }
    expect(gemini.requests).toHaveLength(0);
  });

  it('uses the server-side key and the same message/topic/context contract', async () => {
    const gemini = fakeFetch(() => geminiAnswer('Regenerative braking recovers energy.'));
    const response = await request(apiApp({ geminiFetch: gemini.fetch }))
      .post(ASK)
      .set(bearer('alice'))
      .send({ message: 'What is regen?', topic: 'Braking', context: '{"batteryPercent":80}' });
    expect(response.status).toBe(200);
    expect(response.body).toEqual({
      success: true,
      answer: 'Regenerative braking recovers energy.',
    });

    const sent = gemini.requests[0];
    expect(sent?.url).toBe('https://generativelanguage.googleapis.com/v1beta/interactions');
    expect((sent?.init?.headers as Record<string, string>)['x-goog-api-key']).toBe(
      'test-only-gemini-key',
    );
    const body = JSON.parse(String(sent?.init?.body)) as Record<string, unknown>;
    expect(body.model).toBe('gemini-flash-latest');
    expect(body.store).toBe(false);
    expect(body.input).toBe(
      'Learning topic: Braking\n\nLearning context: {"batteryPercent":80}\n\nLearner question: What is regen?',
    );
    expect(String(body.system_instruction)).toContain('Do not diagnose vehicle faults');
    expect(JSON.stringify(response.body)).not.toContain('test-only-gemini-key');
  });

  it('sends a question without context and parses output_text', async () => {
    const gemini = fakeFetch(() => jsonResponse({ output_text: '  Charging basics.  ' }));
    const response = await request(apiApp({ geminiFetch: gemini.fetch }))
      .post(ASK)
      .set(bearer('alice'))
      .send({ message: 'How does charging work?' });
    expect(response.body.answer).toBe('Charging basics.');
    const body = JSON.parse(String(gemini.requests[0]?.init?.body)) as { input: string };
    expect(body.input).toBe(
      'Learning topic: EV learning\n\nLearner question: How does charging work?',
    );
  });

  it('logs provider errors without logging the API key and returns a safe message', async () => {
    const errorSpy = vi.spyOn(logger, 'error');
    const gemini = fakeFetch(() =>
      jsonResponse({ error: { message: 'Bad key test-only-gemini-key rejected' } }, 403),
    );
    const response = await request(apiApp({ geminiFetch: gemini.fetch }))
      .post(ASK)
      .set(bearer('alice'))
      .send({ message: 'Hello?' });
    expect(response.status).toBe(503);
    expect(response.body.error).toEqual({
      code: 'assistant_not_configured',
      message: 'The EV learning assistant is not configured correctly. Please contact support.',
    });
    // A rejected key fails the same way on every model, so no retry is made.
    expect(gemini.requests).toHaveLength(1);
    const logged = JSON.stringify(errorSpy.mock.calls);
    expect(logged).toContain('[REDACTED]');
    expect(logged).not.toContain('test-only-gemini-key');
    errorSpy.mockRestore();
  });

  it('retries an overloaded model once on the fallback model', async () => {
    const gemini = fakeFetch((_url, init) => {
      const { model } = JSON.parse(String(init?.body)) as { model: string };
      return model === 'gemini-flash-latest'
        ? jsonResponse({ error: { message: 'high demand', code: 'service_unavailable' } }, 503)
        : geminiAnswer('Fallback answer.');
    });
    const response = await request(
      apiApp({ geminiFetch: gemini.fetch, geminiFallbackModel: 'gemini-flash-lite-latest' }),
    )
      .post(ASK)
      .set(bearer('alice'))
      .send({ message: 'Hello?' });
    expect(response.status).toBe(200);
    expect(response.body.answer).toBe('Fallback answer.');
    expect(
      gemini.requests.map((r) => (JSON.parse(String(r.init?.body)) as { model: string }).model),
    ).toEqual(['gemini-flash-latest', 'gemini-flash-lite-latest']);
  });

  it('treats a timed-out model as busy and asks the fallback model', async () => {
    const gemini = fakeFetch((_url, init) => {
      const { model } = JSON.parse(String(init?.body)) as { model: string };
      if (model === 'gemini-flash-latest') {
        throw new DOMException('The operation timed out.', 'TimeoutError');
      }
      return geminiAnswer('Answer after timeout.');
    });
    const response = await request(
      apiApp({ geminiFetch: gemini.fetch, geminiFallbackModel: 'gemini-flash-lite-latest' }),
    )
      .post(ASK)
      .set(bearer('alice'))
      .send({ message: 'Hello?' });
    expect(response.body.answer).toBe('Answer after timeout.');
  });

  it('reports busy when every model is overloaded or rate limited', async () => {
    let calls = 0;
    const gemini = fakeFetch(() =>
      jsonResponse({ error: { message: 'slow down' } }, calls++ === 0 ? 503 : 429),
    );
    const response = await request(
      apiApp({ geminiFetch: gemini.fetch, geminiFallbackModel: 'gemini-flash-lite-latest' }),
    )
      .post(ASK)
      .set(bearer('alice'))
      .send({ message: 'Hello?' });
    expect(response.status).toBe(503);
    expect(response.body.error.code).toBe('assistant_busy');
    expect(gemini.requests).toHaveLength(2);
  });

  it('reports network failures and empty output as temporarily unavailable', async () => {
    for (const handler of [
      () => {
        throw new TypeError('fetch failed');
      },
      () => jsonResponse({ steps: [] }),
      () => new Response('not json', { status: 200 }),
    ]) {
      const response = await request(apiApp({ geminiFetch: fakeFetch(handler).fetch }))
        .post(ASK)
        .set(bearer('alice'))
        .send({ message: 'Hello?' });
      expect(response.status).toBe(503);
    }
  });

  it('limits each user to 20 questions per minute', async () => {
    const app = apiApp({ geminiFetch: fakeFetch(() => geminiAnswer('ok')).fetch });
    for (let i = 0; i < 20; i++) {
      expect(
        (await request(app).post(ASK).set(bearer('alice')).send({ message: 'q' })).status,
      ).toBe(200);
    }
    const limited = await request(app).post(ASK).set(bearer('alice')).send({ message: 'q' });
    expect(limited.status).toBe(429);
    // Another user is not affected.
    expect((await request(app).post(ASK).set(bearer('bob')).send({ message: 'q' })).status).toBe(
      200,
    );
  });
});
