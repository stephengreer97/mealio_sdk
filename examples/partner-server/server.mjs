// The one endpoint a partner adds: mint a Mealio session for the signed-in user.
//   MEALIO_SECRET_KEY=sk_test_... node server.mjs
import http from 'node:http';

const SECRET = process.env.MEALIO_SECRET_KEY;
const MEALIO = process.env.MEALIO_BASE_URL || 'https://mealio.co';
if (!SECRET) { console.error('Set MEALIO_SECRET_KEY'); process.exit(1); }

http.createServer(async (req, res) => {
  if (req.method !== 'POST' || req.url !== '/mealio/session') { res.writeHead(404).end(); return; }
  // Replace with your own auth. The external id is YOUR user id.
  const userId = req.headers['x-demo-user'] || 'demo-user-1';
  const r = await fetch(`${MEALIO}/api/v1/sessions`, {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify({ externalUserId: String(userId) }),
  });
  const body = await r.text();
  res.writeHead(r.status, { 'content-type': 'application/json' }).end(body);
}).listen(8787, () => console.log('partner server on http://localhost:8787'));
