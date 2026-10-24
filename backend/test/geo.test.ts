import request from 'supertest';
import { describe, expect, it } from 'vitest';

import { OVERPASS_ENDPOINTS } from '../src/services/geo.js';
import { apiApp, fakeFetch, jsonResponse } from './fixtures.js';
import { bearer } from './helpers.js';

const ROUTE = '/v1/geo/route';
const OVERPASS = '/v1/geo/overpass';
const trip = { fromLat: '13.08', fromLon: '80.27', toLat: '12.97', toLon: '77.59' };
const stationQuery =
  '[out:json][timeout:25];\nnwr["amenity"="charging_station"](12.9,80.1,13.1,80.3);\nout center tags;\n';
const osrmRoute = {
  code: 'Ok',
  routes: [
    {
      distance: 346000,
      duration: 21000,
      geometry: {
        type: 'LineString',
        coordinates: [
          [80.27, 13.08],
          [77.59, 12.97],
        ],
      },
    },
  ],
};

describe('geo route proxy', () => {
  it('requires sign-in and valid coordinates', async () => {
    const osrm = fakeFetch(() => jsonResponse(osrmRoute));
    const app = apiApp({ geoFetch: osrm.fetch });
    expect((await request(app).get(ROUTE).query(trip)).status).toBe(401);
    for (const query of [
      { ...trip, fromLat: '91' },
      { ...trip, toLon: 'abc' },
      { fromLat: '13', fromLon: '80' },
      { ...trip, extra: '1' },
    ]) {
      const response = await request(app).get(ROUTE).query(query).set(bearer('alice'));
      expect(response.status).toBe(400);
    }
    expect(osrm.requests).toHaveLength(0);
  });

  it('fetches OSRM server-side in lon,lat order and returns its JSON', async () => {
    const osrm = fakeFetch(() => jsonResponse(osrmRoute));
    const response = await request(apiApp({ geoFetch: osrm.fetch }))
      .get(ROUTE)
      .query(trip)
      .set(bearer('alice'));
    expect(response.status).toBe(200);
    expect(response.body).toEqual(osrmRoute);
    expect(osrm.requests[0]?.url).toBe(
      'https://router.project-osrm.org/route/v1/driving/80.27,13.08;77.59,12.97' +
        '?overview=full&geometries=geojson&steps=false',
    );
    expect((osrm.requests[0]?.init?.headers as Record<string, string>)['User-Agent']).toContain(
      'EVSmartCompanion',
    );
  });

  it('passes an OSRM NoRoute answer through and hides provider failures', async () => {
    const noRoute = fakeFetch(() => jsonResponse({ code: 'NoRoute', message: 'Impossible' }, 400));
    const unroutable = await request(apiApp({ geoFetch: noRoute.fetch }))
      .get(ROUTE)
      .query(trip)
      .set(bearer('alice'));
    expect(unroutable.status).toBe(200);
    expect(unroutable.body.code).toBe('NoRoute');

    for (const fetch of [
      fakeFetch(() => new Response('<html>Bad gateway</html>', { status: 502 })).fetch,
      fakeFetch(() => {
        throw new TypeError('fetch failed');
      }).fetch,
    ]) {
      const response = await request(apiApp({ geoFetch: fetch }))
        .get(ROUTE)
        .query(trip)
        .set(bearer('alice'));
      expect(response.status).toBe(503);
      expect(response.body.error.code).toBe('map_busy');
    }
  });
});

describe('geo overpass proxy', () => {
  it('only forwards charging-station searches', async () => {
    const overpass = fakeFetch(() => jsonResponse({ elements: [] }));
    const app = apiApp({ geoFetch: overpass.fetch });
    for (const body of [
      {},
      { data: '[out:json];nwr["amenity"="cafe"](1,2,3,4);out;' },
      { data: 'nwr["amenity"="charging_station"](1,2,3,4);out;' },
      { data: stationQuery + ' '.repeat(20_001) },
      { data: stationQuery, extra: true },
    ]) {
      const response = await request(app).post(OVERPASS).set(bearer('alice')).send(body);
      expect(response.status).toBe(400);
    }
    expect(overpass.requests).toHaveLength(0);
  });

  it('posts the query form-encoded and returns the station JSON', async () => {
    const elements = [{ type: 'node', id: 1, lat: 13, lon: 80, tags: { name: 'Hub' } }];
    const overpass = fakeFetch(() => jsonResponse({ elements }));
    const response = await request(apiApp({ geoFetch: overpass.fetch }))
      .post(OVERPASS)
      .set(bearer('alice'))
      .send({ data: stationQuery });
    expect(response.status).toBe(200);
    expect(response.body).toEqual({ elements });
    expect(overpass.requests).toHaveLength(1);
    expect(overpass.requests[0]?.url).toBe(OVERPASS_ENDPOINTS[0]);
    expect(new URLSearchParams(String(overpass.requests[0]?.init?.body)).get('data')).toBe(
      stationQuery,
    );
  });

  it('falls through busy, overloaded and unreachable servers', async () => {
    let calls = 0;
    const overpass = fakeFetch(() => {
      calls++;
      if (calls === 1) throw new TypeError('fetch failed');
      if (calls === 2) {
        return jsonResponse({ elements: [], remark: 'runtime error: Query timed out' });
      }
      return jsonResponse({ elements: [] });
    });
    const response = await request(apiApp({ geoFetch: overpass.fetch }))
      .post(OVERPASS)
      .set(bearer('alice'))
      .send({ data: stationQuery });
    expect(response.status).toBe(200);
    expect(overpass.requests.map((sent) => sent.url)).toEqual(OVERPASS_ENDPOINTS);
  });

  it('reports map_busy when every server fails and does not retry a rejected query', async () => {
    const busy = fakeFetch(() => new Response('busy', { status: 504 }));
    const allBusy = await request(apiApp({ geoFetch: busy.fetch }))
      .post(OVERPASS)
      .set(bearer('alice'))
      .send({ data: stationQuery });
    expect(allBusy.status).toBe(503);
    expect(allBusy.body.error.code).toBe('map_busy');
    expect(busy.requests).toHaveLength(OVERPASS_ENDPOINTS.length);

    const rejected = fakeFetch(() => new Response('syntax error', { status: 400 }));
    const response = await request(apiApp({ geoFetch: rejected.fetch }))
      .post(OVERPASS)
      .set(bearer('alice'))
      .send({ data: stationQuery });
    expect(response.status).toBe(400);
    expect(rejected.requests).toHaveLength(1);
  });
});
