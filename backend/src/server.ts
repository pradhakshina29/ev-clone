import { createApp } from './app.js';
import { loadEnv } from './config/env.js';
import { connectDatabase, disconnectDatabase } from './db/connect.js';
import { logger } from './logger.js';
import { createJwtVerifier } from './middleware/auth.js';
import { authRouter } from './routes/auth.js';
import { createRouters } from './routes/index.js';

const env = loadEnv();
await connectDatabase({
  uri: env.mongodbUri,
  dbName: env.mongodbDbName,
  autoIndex: env.nodeEnv !== 'production',
});

const verifyAccessToken = createJwtVerifier(env.jwtSecret);
const app = createApp({
  nodeEnv: env.nodeEnv,
  corsOrigins: env.corsOrigins,
  verifyIdToken: verifyAccessToken,
  authRouter: authRouter({ jwtSecret: env.jwtSecret, verifyAccessToken }),
  routers: createRouters({
    paypal: {
      clientId: env.paypalClientId,
      clientSecret: env.paypalClientSecret,
      apiBase: env.paypalApiBase,
      demoExchangeRateInrToUsd: env.demoExchangeRateInrToUsd,
      fetch,
    },
    assistant: {
      apiKey: env.geminiApiKey,
      model: env.geminiModel,
      fallbackModel: env.geminiFallbackModel,
      fetch,
    },
    geo: { fetch },
  }),
});

const server = app.listen(env.port, () => {
  logger.info({ port: env.port }, 'EV Smart Companion API listening');
});

let shuttingDown = false;
function shutdown(signal: string) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info({ signal }, 'Shutting down');
  server.close(() => {
    void disconnectDatabase().finally(() => process.exit(0));
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
