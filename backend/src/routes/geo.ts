import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { z } from 'zod';

import { currentUser } from '../middleware/auth.js';
import { HttpError } from '../middleware/errors.js';
import { validate, validBody, validQuery } from '../middleware/validate.js';
import { fetchOverpass, fetchRoute, type GeoConfig } from '../services/geo.js';

const latitude = z.coerce.number().min(-90).max(90);
const longitude = z.coerce.number().min(-180).max(180);

const routeQuery = z.object({
  fromLat: latitude,
  fromLon: longitude,
  toLat: latitude,
  toLon: longitude,
});

export const MAX_OVERPASS_QUERY_LENGTH = 20_000;

// Only the app's own charging-station searches are forwarded, so this is not
// an open Overpass proxy.
const overpassBody = z.object({
  data: z
    .string()
    .max(MAX_OVERPASS_QUERY_LENGTH, 'Station search is too large.')
    .refine(
      (query) =>
        query.trimStart().startsWith('[out:json]') &&
        query.includes('nwr["amenity"="charging_station"]'),
      'Only charging-station searches are supported.',
    ),
});

export function geoRouter(config: GeoConfig, perMinuteLimit = 30) {
  const router = Router();
  router.use(
    '/geo',
    rateLimit({
      windowMs: 60 * 1000,
      limit: perMinuteLimit,
      standardHeaders: 'draft-8',
      legacyHeaders: false,
      // Runs after requireAuth, so the limit is per signed-in user, not per IP.
      keyGenerator: (req) => currentUser(req).uid,
      handler: (_req, _res, next) =>
        next(new HttpError(429, 'rate_limited', 'Too many map requests. Please wait a minute.')),
    }),
  );
  router.get('/geo/route', validate({ query: routeQuery }), async (req, res) => {
    res.json(await fetchRoute(config, validQuery(req, routeQuery)));
  });
  router.post('/geo/overpass', validate({ body: overpassBody }), async (req, res) => {
    const body = await fetchOverpass(config, validBody(req, overpassBody).data);
    res.type('application/json').send(body);
  });
  return router;
}
