import { z } from 'zod';

const required = z.string().trim().min(1);

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(8081),
  MONGODB_URI: required.refine(
    (value) => value.startsWith('mongodb://') || value.startsWith('mongodb+srv://'),
    'must start with mongodb:// or mongodb+srv://',
  ),
  MONGODB_DB_NAME: required,
  JWT_SECRET: z.string().min(32, 'must be at least 32 characters'),
  CORS_ORIGINS: required,
  GEMINI_API_KEY: required,
  GEMINI_MODEL: required,
  GEMINI_FALLBACK_MODEL: z.string().trim().default('gemini-flash-lite-latest'),
  PAYPAL_CLIENT_ID: required,
  PAYPAL_CLIENT_SECRET: required,
  PAYPAL_API_BASE: z.url().refine((value) => value.startsWith('https://'), 'must use https://'),
  DEMO_EXCHANGE_RATE_INR_TO_USD: z.coerce.number().positive(),
});

export const envVariableNames = Object.keys(envSchema.shape) as (keyof typeof envSchema.shape)[];

/** Variables with a built-in default; check-env does not require them. */
export const optionalEnvVariableNames: readonly string[] = ['GEMINI_FALLBACK_MODEL'];

export type Env = {
  nodeEnv: 'development' | 'test' | 'production';
  port: number;
  mongodbUri: string;
  mongodbDbName: string;
  jwtSecret: string;
  corsOrigins: string[];
  geminiApiKey: string;
  geminiModel: string;
  geminiFallbackModel: string;
  paypalClientId: string;
  paypalClientSecret: string;
  paypalApiBase: string;
  demoExchangeRateInrToUsd: number;
};

export type EnvResult = { ok: true; env: Env } | { ok: false; problems: string[] };

/** Validates the environment. Problems name the variable, never its value. */
export function parseEnv(source: NodeJS.ProcessEnv): EnvResult {
  const result = envSchema.safeParse(source);
  if (!result.success) {
    const problems = result.error.issues.map((issue) => {
      const name = String(issue.path[0] ?? 'environment');
      return source[name] === undefined || source[name] === ''
        ? `${name} is missing`
        : `${name} is invalid (${issue.message})`;
    });
    return { ok: false, problems };
  }
  const value = result.data;
  return {
    ok: true,
    env: {
      nodeEnv: value.NODE_ENV,
      port: value.PORT,
      mongodbUri: value.MONGODB_URI,
      mongodbDbName: value.MONGODB_DB_NAME,
      jwtSecret: value.JWT_SECRET,
      corsOrigins: value.CORS_ORIGINS.split(',')
        .map((origin) => origin.trim())
        .filter(Boolean),
      geminiApiKey: value.GEMINI_API_KEY,
      geminiModel: value.GEMINI_MODEL,
      geminiFallbackModel: value.GEMINI_FALLBACK_MODEL,
      paypalClientId: value.PAYPAL_CLIENT_ID,
      paypalClientSecret: value.PAYPAL_CLIENT_SECRET,
      paypalApiBase: value.PAYPAL_API_BASE.replace(/\/+$/, ''),
      demoExchangeRateInrToUsd: value.DEMO_EXCHANGE_RATE_INR_TO_USD,
    },
  };
}

export function loadEnv(source: NodeJS.ProcessEnv = process.env): Env {
  const result = parseEnv(source);
  if (!result.ok) {
    console.error('Invalid backend configuration. Fix these in backend/.env:');
    for (const problem of result.problems) console.error(`  - ${problem}`);
    process.exit(1);
  }
  return result.env;
}

/** For scripts (seed, reset) that only need the database settings. */
export function loadDatabaseEnv(source: NodeJS.ProcessEnv = process.env): {
  mongodbUri: string;
  mongodbDbName: string;
} {
  const result = z
    .object({ MONGODB_URI: envSchema.shape.MONGODB_URI, MONGODB_DB_NAME: required })
    .safeParse(source);
  if (!result.success) {
    console.error('Set MONGODB_URI and MONGODB_DB_NAME in backend/.env.');
    process.exit(1);
  }
  return { mongodbUri: result.data.MONGODB_URI, mongodbDbName: result.data.MONGODB_DB_NAME };
}
