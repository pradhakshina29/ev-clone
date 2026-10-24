import { logger } from '../logger.js';
import { HttpError } from '../middleware/errors.js';

/**
 * Server-side fetches of public OpenStreetMap services (OSRM routing and
 * Overpass station search). Some phones lack the root certificate these
 * hosts now chain to, so the app reaches them through this API instead.
 */
export type GeoConfig = { fetch: typeof fetch };

const OSRM_BASE = 'https://router.project-osrm.org/route/v1/driving';
export const OVERPASS_ENDPOINTS = [
  'https://overpass-api.de/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];
// overpass-api.de refuses requests without an identifying User-Agent.
const USER_AGENT = 'EVSmartCompanion/1.0 (backend map proxy)';
const ROUTE_TIMEOUT_MS = 20_000;
const OVERPASS_ATTEMPT_TIMEOUT_MS = 40_000;
const OVERPASS_TOTAL_MS = 55_000;

function mapBusy() {
  return new HttpError(503, 'map_busy', 'Map service is busy, please try again in a minute.');
}

export type RouteRequest = { fromLat: number; fromLon: number; toLat: number; toLon: number };

/** Returns OSRM's JSON unchanged (its `code` says whether a route exists). */
export async function fetchRoute(config: GeoConfig, route: RouteRequest): Promise<unknown> {
  const coordinates = `${route.fromLon},${route.fromLat};${route.toLon},${route.toLat}`;
  const url = `${OSRM_BASE}/${coordinates}?overview=full&geometries=geojson&steps=false`;
  let response: Response;
  let body: string;
  try {
    response = await config.fetch(url, {
      headers: { Accept: 'application/json', 'User-Agent': USER_AGENT },
      signal: AbortSignal.timeout(ROUTE_TIMEOUT_MS),
    });
    body = await response.text();
  } catch (error) {
    logger.error(
      { errorName: error instanceof Error ? error.name : 'Error' },
      'Routing provider request failed',
    );
    throw mapBusy();
  }
  // OSRM answers 400 with a JSON `code` (e.g. NoRoute) for unroutable trips.
  if (response.status === 200 || response.status === 400) {
    try {
      const payload = JSON.parse(body) as { code?: unknown };
      if (typeof payload.code === 'string') return payload;
    } catch {
      // Falls through to the error below.
    }
  }
  logger.error({ httpStatus: response.status }, 'Routing provider returned an unusable response');
  throw mapBusy();
}

/** Tries each Overpass server in turn; returns the first good JSON body as text. */
export async function fetchOverpass(config: GeoConfig, query: string): Promise<string> {
  const deadline = Date.now() + OVERPASS_TOTAL_MS;
  for (const endpoint of OVERPASS_ENDPOINTS) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const host = new URL(endpoint).host;
    try {
      const response = await config.fetch(endpoint, {
        method: 'POST',
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': USER_AGENT,
        },
        body: new URLSearchParams({ data: query }).toString(),
        signal: AbortSignal.timeout(Math.min(remaining, OVERPASS_ATTEMPT_TIMEOUT_MS)),
      });
      const body = await response.text();
      if (response.status === 400) {
        throw new HttpError(400, 'invalid_query', 'OpenStreetMap rejected the station search.');
      }
      // A 200 can still carry an Overpass timeout/out-of-memory remark.
      const overloaded = body.includes('"remark"') && body.includes('runtime error');
      if (response.status === 200 && !overloaded && isElementsJson(body)) return body;
      logger.warn(
        { host, httpStatus: response.status, overloaded },
        'Overpass server busy or refusing',
      );
    } catch (error) {
      if (error instanceof HttpError) throw error;
      logger.warn(
        { host, errorName: error instanceof Error ? error.name : 'Error' },
        'Overpass server unreachable',
      );
    }
  }
  throw mapBusy();
}

function isElementsJson(body: string) {
  try {
    const payload = JSON.parse(body) as { elements?: unknown };
    return Array.isArray(payload.elements);
  } catch {
    return false;
  }
}
