// Ported from the original learning assistant: same prompt, endpoint, limits
// and response parsing. The API key is never logged or returned.
import { logger } from '../logger.js';
import { HttpError } from '../middleware/errors.js';

export const MAX_QUESTION_LENGTH = 2000;
export const MAX_TOPIC_LENGTH = 120;
export const MAX_CONTEXT_LENGTH = 2000;
const ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/interactions';
// Leaves room for one fallback attempt inside the app's 60 s request timeout.
const TIMEOUT_MS = 20_000;

export type AssistantConfig = {
  apiKey: string;
  model: string;
  /** Another Gemini model tried once when [model] is overloaded or rate limited. */
  fallbackModel?: string;
  fetch: typeof fetch;
};

const SYSTEM_INSTRUCTION = [
  'You are EV Smart Companion Assistant, an educational tutor for electric-vehicle owners.',
  'Explain EV concepts clearly, progressively, and in simple language when appropriate.',
  'Help learners understand EV batteries and health, charging, motors, regenerative braking, range, energy consumption, driving efficiency, tire pressure, brakes, and EV maintenance concepts.',
  'Use practical examples when helpful.',
  'Do not diagnose vehicle faults, control a vehicle, change settings, initiate charging, or perform maintenance actions.',
  'Do not provide unsafe instructions or high-voltage repair guidance. For warning lights or possible faults, direct the learner to the vehicle manual and qualified support.',
  'Do not claim access to private information or live vehicle data beyond context explicitly supplied in this request.',
].join(' ');

const temporarilyUnavailable = () =>
  new HttpError(
    503,
    'assistant_unavailable',
    'The EV learning assistant is temporarily unavailable.',
  );

function redact(text: string, apiKey: string): string {
  return apiKey ? text.split(apiKey).join('[REDACTED]') : text;
}

function providerErrorMessage(body: string): string {
  try {
    const payload = JSON.parse(body) as { error?: { message?: string }; message?: string };
    return payload.error?.message ?? payload.message ?? body;
  } catch {
    return body;
  }
}

export async function askLearningAssistant(
  config: AssistantConfig,
  input: { message: string; topic?: string; context?: string },
): Promise<string> {
  const question = input.message.trim();
  const topic = input.topic?.trim() || 'EV learning';
  const context = input.context?.trim() ?? '';
  if (!config.apiKey) {
    logger.error('GEMINI_API_KEY is not configured');
    throw new HttpError(
      503,
      'assistant_not_configured',
      'The EV learning assistant is not configured yet.',
    );
  }

  const userPrompt = [
    `Learning topic: ${topic}`,
    context ? `Learning context: ${context}` : '',
    `Learner question: ${question}`,
  ]
    .filter(Boolean)
    .join('\n\n');

  const models = [config.model, config.fallbackModel].filter(
    (model, index, all): model is string => !!model && all.indexOf(model) === index,
  );
  let failure: ModelFailure = 'unavailable';
  for (const model of models) {
    const result = await askModel(config, model, userPrompt);
    if (typeof result === 'string') return result;
    failure = result.failure;
    // Only an overloaded or rate-limited model is worth retrying on another
    // Gemini model; a rejected key or bad request would fail the same way.
    if (failure !== 'busy') break;
  }
  if (failure === 'busy') {
    throw new HttpError(
      503,
      'assistant_busy',
      'The EV learning assistant is busy right now. Please try again in a minute.',
    );
  }
  if (failure === 'rejected') {
    throw new HttpError(
      503,
      'assistant_not_configured',
      'The EV learning assistant is not configured correctly. Please contact support.',
    );
  }
  throw temporarilyUnavailable();
}

type ModelFailure = 'busy' | 'rejected' | 'unavailable';

async function askModel(
  config: AssistantConfig,
  model: string,
  userPrompt: string,
): Promise<string | { failure: ModelFailure }> {
  let response: Response;
  try {
    response = await config.fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': config.apiKey },
      body: JSON.stringify({
        model,
        input: userPrompt,
        system_instruction: SYSTEM_INSTRUCTION,
        generation_config: { temperature: 0.3, max_output_tokens: 700 },
        store: false,
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (error) {
    logger.error(
      { model, errorName: error instanceof Error ? error.name : 'Error' },
      'Learning assistant provider request failed',
    );
    // An overloaded model often hangs instead of answering 503.
    return {
      failure: error instanceof Error && error.name === 'TimeoutError' ? 'busy' : 'unavailable',
    };
  }

  let body: string;
  try {
    body = await response.text();
  } catch {
    logger.error(
      { model, httpStatus: response.status },
      'Could not read the learning assistant response',
    );
    return { failure: 'unavailable' };
  }

  if (!response.ok) {
    logger.error(
      {
        model,
        httpStatus: response.status,
        providerMessage: redact(providerErrorMessage(body), config.apiKey).slice(0, 500),
      },
      'Learning assistant provider rejected the request',
    );
    if (response.status === 429 || response.status === 503) return { failure: 'busy' };
    // 400 (invalid key), 401/403 (key or project disabled), 404 (retired model).
    if ([400, 401, 403, 404].includes(response.status)) return { failure: 'rejected' };
    return { failure: 'unavailable' };
  }

  let payload: { output_text?: unknown; steps?: unknown };
  try {
    payload = JSON.parse(body) as typeof payload;
  } catch {
    logger.error(
      { model, httpStatus: response.status },
      'Learning assistant returned invalid JSON',
    );
    return { failure: 'unavailable' };
  }

  type Step = { type?: unknown; content?: unknown };
  type Part = { type?: unknown; text?: unknown };
  const outputParts = (Array.isArray(payload.steps) ? (payload.steps as Step[]) : [])
    .filter((step) => step?.type === 'model_output')
    .flatMap((step) => (Array.isArray(step.content) ? (step.content as Part[]) : []))
    .filter(
      (part): part is { type: 'text'; text: string } =>
        part?.type === 'text' && typeof part.text === 'string',
    )
    .map((part) => part.text.trim())
    .filter(Boolean);
  const answer = (
    typeof payload.output_text === 'string' ? payload.output_text : outputParts.join('\n')
  ).trim();
  if (!answer) {
    logger.error(
      { model, httpStatus: response.status },
      'Learning assistant returned an empty response',
    );
    return { failure: 'unavailable' };
  }
  return answer;
}
