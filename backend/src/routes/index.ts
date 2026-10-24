import type { Router } from 'express';

import type { AssistantConfig } from '../services/assistant.js';
import type { GeoConfig } from '../services/geo.js';
import type { PayPalConfig } from '../services/paypal.js';
import { assistantRouter } from './assistant.js';
import { chargingCardRouter } from './chargingCard.js';
import { geoRouter } from './geo.js';
import { meRouter } from './me.js';
import { vehiclesRouter } from './vehicles.js';

export type RouterDeps = {
  paypal: PayPalConfig;
  assistant: AssistantConfig;
  assistantPerMinuteLimit?: number;
  geo: GeoConfig;
};

/** Every router is mounted under /v1 behind requireAuth (see app.ts). */
export function createRouters(deps: RouterDeps): Router[] {
  return [
    meRouter(),
    vehiclesRouter(),
    chargingCardRouter(deps.paypal),
    assistantRouter(deps.assistant, deps.assistantPerMinuteLimit),
    geoRouter(deps.geo),
  ];
}
