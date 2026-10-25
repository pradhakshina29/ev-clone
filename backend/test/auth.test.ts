import bcrypt from 'bcryptjs';
import { SignJWT } from 'jose';
import request from 'supertest';
import type { Request } from 'express';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { createApp } from '../src/app.js';
import { createJwtVerifier } from '../src/middleware/auth.js';
import { RefreshToken } from '../src/models/refreshToken.js';
import { User } from '../src/models/user.js';
import { Vehicle } from '../src/models/vehicle.js';
import { authRouter, ipRateLimitKey } from '../src/routes/auth.js';
import { meRouter } from '../src/routes/me.js';
import { EV001, EV002, seedVehicles } from './fixtures.js';

const SECRET = 'test-only-jwt-secret-that-is-long-enough-123';
const PASSWORD = 'Secret123';

function authApp(limits: { loginPerEmailLimit?: number } = {}) {
  const verifyAccessToken = createJwtVerifier(SECRET);
  return createApp({
    nodeEnv: 'test',
    corsOrigins: [],
    verifyIdToken: verifyAccessToken,
    authRouter: authRouter({ jwtSecret: SECRET, verifyAccessToken, ...limits }),
    routers: [meRouter()],
  });
}

const signUpBody = (overrides: Record<string, unknown> = {}) => ({
  name: 'Alice',
  email: 'Alice@Example.com',
  password: PASSWORD,
  phone: '9876543210',
  city: 'Chennai',
  ...EV001,
  ...overrides,
});

beforeAll(async () => {
  await User.createIndexes();
  await Vehicle.createIndexes();
  await RefreshToken.createIndexes();
});
beforeEach(seedVehicles);

describe('sign-up', () => {
  it('creates the account with a hashed password and links the vehicle in one step', async () => {
    const response = await request(authApp())
      .post('/v1/auth/signup')
      .send(signUpBody({ registrationNumber: 'tn01 ab1234' }));
    expect(response.status).toBe(201);
    expect(response.body.vehicle).toMatchObject({ id: 'EV001' });
    // Sign-up does not log in: the user logs in afterwards.
    expect(response.body).not.toHaveProperty('accessToken');

    const user = await User.findOne({ email: 'alice@example.com' }).select('+passwordHash').lean();
    expect(user).toMatchObject({ name: 'Alice', city: 'Chennai', vehicleId: 'EV001' });
    expect(user?.passwordHash).not.toContain(PASSWORD);
    expect(await bcrypt.compare(PASSWORD, user!.passwordHash)).toBe(true);
    expect((await Vehicle.findById('EV001').lean())?.ownerUid).toBe(user?._id);
  });

  it('rejects a vehicle that is already linked and saves nothing', async () => {
    const app = authApp();
    await request(app).post('/v1/auth/signup').send(signUpBody());
    const response = await request(app)
      .post('/v1/auth/signup')
      .send(signUpBody({ name: 'Mallory', email: 'mallory@example.com' }));
    expect(response.status).toBe(409);
    expect(response.body.error).toEqual({
      code: 'vehicle_already_claimed',
      message: 'This vehicle is already linked to another account.',
    });
    expect(await User.exists({ email: 'mallory@example.com' })).toBeNull();
  });

  it('rejects details that do not match the vehicle record and saves nothing', async () => {
    const response = await request(authApp())
      .post('/v1/auth/signup')
      .send(signUpBody({ vin: 'WRONGVIN' }));
    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('vehicle_not_verified');
    expect(await User.countDocuments()).toBe(0);
    expect((await Vehicle.findById('EV001').lean())?.ownerUid).toBeNull();
  });

  it('rejects an email that already has an account and keeps the second vehicle free', async () => {
    const app = authApp();
    await request(app).post('/v1/auth/signup').send(signUpBody());
    const response = await request(app)
      .post('/v1/auth/signup')
      .send(signUpBody({ email: 'alice@example.com', ...EV002 }));
    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('email_taken');
    expect((await Vehicle.findById('EV002').lean())?.ownerUid).toBeNull();
  });

  it('rejects weak passwords, bad emails and unknown fields', async () => {
    const app = authApp();
    for (const overrides of [
      { password: 'short1A' },
      { password: 'alllowercase1' },
      { email: 'not-an-email' },
      { isAdmin: true },
      { passwordHash: 'x' },
    ]) {
      const response = await request(app).post('/v1/auth/signup').send(signUpBody(overrides));
      expect(response.status).toBe(400);
    }
    expect(await User.countDocuments()).toBe(0);
  });
});

describe('login, refresh and logout', () => {
  beforeEach(async () => {
    await request(authApp()).post('/v1/auth/signup').send(signUpBody());
  });

  const loginAs = (
    app: ReturnType<typeof authApp>,
    password = PASSWORD,
    email = 'alice@example.com',
  ) => request(app).post('/v1/auth/login').send({ email, password });

  it('logs in with the same email and password, and the token opens /v1/me', async () => {
    const app = authApp();
    const response = await loginAs(app, PASSWORD, '  ALICE@example.com ');
    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({ accessTokenExpiresIn: 900 });
    expect(response.body.user).toMatchObject({ email: 'alice@example.com', vehicleId: 'EV001' });
    expect(JSON.stringify(response.body)).not.toContain('passwordHash');

    const me = await request(app)
      .get('/v1/me')
      .set('Authorization', `Bearer ${response.body.accessToken}`);
    expect(me.status).toBe(200);
    expect(me.body.name).toBe('Alice');
  });

  it('gives the same error for a wrong password and an unknown email', async () => {
    const app = authApp();
    const wrongPassword = await loginAs(app, 'Wrong1234');
    const unknownEmail = await loginAs(app, PASSWORD, 'nobody@example.com');
    for (const response of [wrongPassword, unknownEmail]) {
      expect(response.status).toBe(401);
      expect(response.body.error).toEqual({
        code: 'invalid_credentials',
        message: 'Email or password is incorrect.',
      });
    }
  });

  it('limits repeated login attempts for one email', async () => {
    const app = authApp({ loginPerEmailLimit: 3 });
    for (let i = 0; i < 3; i++) expect((await loginAs(app, 'Wrong1234')).status).toBe(401);
    const blocked = await loginAs(app, PASSWORD);
    expect(blocked.status).toBe(429);
    expect(blocked.body.error.code).toBe('rate_limited');
  });

  it("rotates refresh tokens and revokes all of the user's tokens when an old one is reused", async () => {
    const app = authApp();
    const first = (await loginAs(app)).body.refreshToken as string;
    const otherDevice = (await loginAs(app)).body.refreshToken as string;

    const rotated = await request(app).post('/v1/auth/refresh').send({ refreshToken: first });
    expect(rotated.status).toBe(200);
    expect(rotated.body.refreshToken).not.toBe(first);
    const second = rotated.body.refreshToken as string;

    // Reusing the first (stolen) token fails and ends every session of the user.
    const reuse = await request(app).post('/v1/auth/refresh').send({ refreshToken: first });
    expect(reuse.status).toBe(401);
    const afterReuse = await request(app).post('/v1/auth/refresh').send({ refreshToken: second });
    expect(afterReuse.status).toBe(401);
    const other = await request(app).post('/v1/auth/refresh').send({ refreshToken: otherDevice });
    expect(other.status).toBe(401);
  });

  it('logout revokes the refresh token', async () => {
    const app = authApp();
    const { refreshToken } = (await loginAs(app)).body as { refreshToken: string };
    expect((await request(app).post('/v1/auth/logout').send({ refreshToken })).status).toBe(204);
    expect((await request(app).post('/v1/auth/refresh').send({ refreshToken })).status).toBe(401);
    // Logging out twice is harmless.
    expect((await request(app).post('/v1/auth/logout').send({ refreshToken })).status).toBe(204);
  });

  it('rejects tampered, foreign-signed and malformed tokens', async () => {
    const app = authApp();
    const { accessToken, refreshToken } = (await loginAs(app)).body as {
      accessToken: string;
      refreshToken: string;
    };
    const tampered = `${accessToken.slice(0, -4)}AAAA`;
    const foreign = await new SignJWT({ typ: 'access' })
      .setProtectedHeader({ alg: 'HS256' })
      .setSubject('someone')
      .setIssuer('ev-smart-companion-api')
      .setAudience('ev-smart-companion-app')
      .setExpirationTime('5m')
      .sign(new TextEncoder().encode('a-different-secret-of-sufficient-length!!'));
    for (const token of [tampered, foreign, refreshToken, 'garbage']) {
      const response = await request(app).get('/v1/me').set('Authorization', `Bearer ${token}`);
      expect(response.status).toBe(401);
    }
    expect((await request(app).post('/v1/auth/refresh').send({ refreshToken: 'x.y' })).status).toBe(
      401,
    );
  });

  it('changes the password, ends other sessions and keeps the user signed in', async () => {
    const app = authApp();
    const session = (await loginAs(app)).body as { accessToken: string; refreshToken: string };
    const auth = { Authorization: `Bearer ${session.accessToken}` };

    const wrong = await request(app)
      .post('/v1/auth/change-password')
      .set(auth)
      .send({ currentPassword: 'Wrong1234', newPassword: 'NewSecret456' });
    expect(wrong.status).toBe(400);

    const changed = await request(app)
      .post('/v1/auth/change-password')
      .set(auth)
      .send({ currentPassword: PASSWORD, newPassword: 'NewSecret456' });
    expect(changed.status).toBe(200);
    expect(changed.body).toHaveProperty('accessToken');

    expect((await loginAs(app)).status).toBe(401);
    expect((await loginAs(app, 'NewSecret456')).status).toBe(200);
    const oldSession = await request(app)
      .post('/v1/auth/refresh')
      .send({ refreshToken: session.refreshToken });
    expect(oldSession.status).toBe(401);

    expect(
      (
        await request(app).post('/v1/auth/change-password').send({
          currentPassword: 'NewSecret456',
          newPassword: 'Another789',
        })
      ).status,
    ).toBe(401);
  });
});

describe('rate-limit keys', () => {
  const key = (ip: string) => ipRateLimitKey('login-ip')({ ip } as Request);

  it('groups IPv6 clients per /56 subnet and keeps IPv4 clients apart', () => {
    expect(key('2001:db8:1:1::1')).toBe(key('2001:db8:1:2::9'));
    expect(key('2001:db8:1:1::1')).not.toBe(key('2001:db8:2::1'));
    expect(key('203.0.113.7')).toBe('login-ip:203.0.113.7');
    expect(key('203.0.113.7')).not.toBe(key('203.0.113.8'));
  });

  it('passes express-rate-limit validation without ERR_ERL_KEY_GEN_IPV6', async () => {
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {});
    try {
      const app = authApp();
      await request(app).post('/v1/auth/signup').send(signUpBody());
      await request(app)
        .post('/v1/auth/login')
        .send({ email: 'alice@example.com', password: PASSWORD });
      const codes = logged.mock.calls.flat().map((arg) => (arg as { code?: unknown })?.code);
      expect(
        codes.filter((code) => typeof code === 'string' && code.startsWith('ERR_ERL')),
      ).toEqual([]);
    } finally {
      logged.mockRestore();
    }
  });
});
