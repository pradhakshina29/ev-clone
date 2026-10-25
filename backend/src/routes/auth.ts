import { Router, type Request } from 'express';
import { ipKeyGenerator, rateLimit } from 'express-rate-limit';
import { z } from 'zod';

import { currentUser, requireAuth, type TokenVerifier } from '../middleware/auth.js';
import { HttpError } from '../middleware/errors.js';
import { validate, validBody } from '../middleware/validate.js';
import { changePassword, login, logout, refresh, signUp } from '../services/auth.js';
import { vehicleJson } from '../services/serialize.js';
import { requiredText, text, vehicleDetails } from './schemas.js';

// Same rule as the app; at most 64 characters because bcrypt uses 72 bytes.
const password = z
  .string()
  .min(8, 'Use 8+ characters with uppercase, lowercase, and a number.')
  .max(64, 'Use at most 64 characters.')
  .regex(/[a-z]/, 'Use 8+ characters with uppercase, lowercase, and a number.')
  .regex(/[A-Z]/, 'Use 8+ characters with uppercase, lowercase, and a number.')
  .regex(/\d/, 'Use 8+ characters with uppercase, lowercase, and a number.');
const email = z.string().trim().toLowerCase().max(254).pipe(z.email('Enter a valid email.'));

const signUpSchema = z.object({
  name: requiredText(128),
  email,
  password,
  phone: text(32).optional(),
  city: text(80).optional(),
  ...vehicleDetails,
});
const loginSchema = z.object({ email: z.string().trim().max(254), password: z.string().max(200) });
const refreshSchema = z.object({ refreshToken: z.string().min(1).max(200) });
const changePasswordSchema = z.object({
  currentPassword: z.string().min(1).max(200),
  newPassword: password,
});

export type AuthRouterOptions = {
  jwtSecret: string;
  verifyAccessToken: TokenVerifier;
  loginPerIpLimit?: number;
  loginPerEmailLimit?: number;
};

/**
 * Per-IP rate-limit key. ipKeyGenerator is called directly (not through a
 * wrapper) so express-rate-limit's ERR_ERL_KEY_GEN_IPV6 check can see it;
 * IPv6 clients share one key per /56 subnet, IPv4 clients one per address.
 */
export const ipRateLimitKey = (prefix: string) => (req: Request) =>
  `${prefix}:${ipKeyGenerator(req.ip ?? '')}`;

const tooManyAttempts = () =>
  new HttpError(429, 'rate_limited', 'Too many attempts. Please wait a few minutes and try again.');

/** Public auth endpoints, mounted at /v1/auth before requireAuth. */
export function authRouter(options: AuthRouterOptions) {
  const router = Router();

  const loginPerIp = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: options.loginPerIpLimit ?? 30,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    keyGenerator: ipRateLimitKey('login-ip'),
    handler: (_req, _res, next) => next(tooManyAttempts()),
  });
  const loginPerEmail = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: options.loginPerEmailLimit ?? 10,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    keyGenerator: (req) => {
      const body = req.body as { email?: unknown } | undefined;
      return `login-email:${String(body?.email ?? '')
        .trim()
        .toLowerCase()}`;
    },
    handler: (_req, _res, next) => next(tooManyAttempts()),
  });
  const signUpPerIp = rateLimit({
    windowMs: 60 * 60 * 1000,
    limit: 10,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    keyGenerator: ipRateLimitKey('signup-ip'),
    handler: (_req, _res, next) => next(tooManyAttempts()),
  });

  router.post('/signup', signUpPerIp, validate({ body: signUpSchema }), async (req, res) => {
    const vehicle = await signUp(validBody(req, signUpSchema));
    res.status(201).json({
      message: 'Account created. Log in with your email and password.',
      vehicle: vehicleJson(vehicle),
    });
  });

  router.post(
    '/login',
    loginPerIp,
    loginPerEmail,
    validate({ body: loginSchema }),
    async (req, res) => {
      const body = validBody(req, loginSchema);
      res.json(await login(options.jwtSecret, body.email, body.password));
    },
  );

  router.post('/refresh', validate({ body: refreshSchema }), async (req, res) => {
    const { refreshToken } = validBody(req, refreshSchema);
    res.json(await refresh(options.jwtSecret, refreshToken));
  });

  router.post('/logout', validate({ body: refreshSchema }), async (req, res) => {
    await logout(validBody(req, refreshSchema).refreshToken);
    res.status(204).end();
  });

  router.post(
    '/change-password',
    requireAuth(options.verifyAccessToken),
    validate({ body: changePasswordSchema }),
    async (req, res) => {
      const body = validBody(req, changePasswordSchema);
      res.json(
        await changePassword(
          options.jwtSecret,
          currentUser(req).uid,
          body.currentPassword,
          body.newPassword,
        ),
      );
    },
  );

  return router;
}
