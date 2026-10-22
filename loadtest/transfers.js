import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const H = { 'Content-Type': 'application/json' };

// PROFILE=rollout|fault picks a steady profile; the default is the milestone 5 autoscaling ramp.
const PROFILES = {
  rollout: [{ duration: '20s', target: 40 }, { duration: '3m30s', target: 40 }, { duration: '10s', target: 0 }],
  // Gentle, long load for fault drills: enough traffic for burn-rate math, little enough to leave the laptop alone.
  fault: [{ duration: '10s', target: 10 }, { duration: __ENV.FAULT_DURATION || '12m', target: 10 }, { duration: '10s', target: 0 }],
};
const stages = PROFILES[__ENV.PROFILE] ||
  [{ duration: '1m', target: 60 }, { duration: '3m', target: 60 }, { duration: '30s', target: 0 }];

export const options = {
  stages: stages,
  thresholds: { http_req_failed: ['rate<0.01'], http_req_duration: ['p(95)<1000'] },
};

// Many accounts so transfers do not all queue on the same two rows.
export function setup() {
  const ids = [];
  for (let i = 0; i < 40; i++) {
    const r = http.post(`${BASE}/accounts`, JSON.stringify({ owner: `load-${i}`, currency: 'USD' }), { headers: H });
    const id = r.json('id');
    http.post(`${BASE}/accounts/${id}/deposits`, JSON.stringify({ amount: 1000000000 }),
      { headers: { ...H, 'Idempotency-Key': `seed-${Date.now()}-${i}` } });
    ids.push(id);
  }
  return ids;
}

export default function (ids) {
  const a = ids[Math.floor(Math.random() * ids.length)];
  let b = ids[Math.floor(Math.random() * ids.length)];
  if (a === b) b = ids[(ids.indexOf(a) + 1) % ids.length];
  const r = http.post(`${BASE}/transfers`, JSON.stringify({ fromAccountId: a, toAccountId: b, amount: 1 }),
    { headers: { ...H, 'Idempotency-Key': `${__VU}-${__ITER}-${Date.now()}` } });
  check(r, { 'transfer ok': (x) => x.status === 200 || x.status === 201 });
  if (__ENV.PROFILE === 'fault') sleep(0.5);
}
