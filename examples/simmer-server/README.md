# Simmer demo server

The partner endpoint for the Simmer demo app. One function, `POST /api/session`,
that turns the app's device id into a Mealio SDK session using the secret key.

Deployed as the Vercel project `simmer-demo-server` (team mealios-projects).
Environment: `MEALIO_SECRET_KEY` (sk_test of the "Simmer demo" sandbox app) and
`SIMMER_DEMO_TOKEN`. Local copies live in `.env.local`, which is gitignored.
