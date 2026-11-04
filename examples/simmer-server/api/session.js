// Simmer's partner server: the one endpoint a Mealio partner adds.
// It mints a Mealio SDK session for the signed-in user, using the secret key,
// which never leaves this server.
//
// Simmer has no accounts, so "the user" is the random id the app makes on first
// launch. A real partner passes its own user id here instead.
//
// SIMMER_DEMO_TOKEN keeps strangers from minting sessions on our key. It ships
// inside the demo app, so it is a speed bump, not a secret.

const MEALIO = process.env.MEALIO_BASE_URL || 'https://mealio.co';
const USER_ID = /^[A-Za-z0-9_-]{8,64}$/;

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  const secret = process.env.MEALIO_SECRET_KEY;
  const demo = process.env.SIMMER_DEMO_TOKEN;
  if (!secret || !demo) return res.status(500).json({ error: 'Server not configured' });
  if (req.headers['x-simmer-demo-token'] !== demo) return res.status(401).json({ error: 'Unauthorized' });

  const user = String(req.headers['x-simmer-user'] || '');
  if (!USER_ID.test(user)) return res.status(400).json({ error: 'Send x-simmer-user: the device id.' });

  const r = await fetch(`${MEALIO}/api/v1/sessions`, {
    method: 'POST',
    headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: JSON.stringify({ externalUserId: `simmer-${user}` }),
  });
  const body = await r.json().catch(() => ({ error: 'Mealio did not answer' }));
  return res.status(r.status).json(body);
};
