import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const H = { 'Content-Type': 'application/json' };

export const options = {
  stages: [
    { duration: '1m', target: 60 },
    { duration: '3m', target: 60 },
    { duration: '30s', target: 0 },
  ],
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
}
