'use strict';
// Connexion des agents : le mot de passe transite une fois vers Supabase Auth (GoTrue), jamais stocké ici.
// POST { email, password }  ou  { refresh_token }  →  { access_token, refresh_token, expires_in }
const { json, sameOrigin, readJson } = require('./_lib/http');

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
  if (!sameOrigin(req)) return json(res, 403, { error: 'forbidden' });
  const url = (process.env.SUPABASE_URL || '').replace(/\/+$/, ''), anon = process.env.SUPABASE_ANON_KEY || '';
  if (!/^https?:\/\//.test(url) || !anon) return json(res, 503, { error: 'unavailable' });
  let b; try { b = await readJson(req); } catch (_) { return json(res, 400, { error: 'invalid_request' }); }
  let grant, body;
  if (typeof b.refresh_token === 'string' && /^[\w.-]{6,500}$/.test(b.refresh_token)) { grant = 'refresh_token'; body = { refresh_token: b.refresh_token }; }
  else if (typeof b.email === 'string' && typeof b.password === 'string' && b.email.length <= 254 && b.password.length >= 1 && b.password.length <= 200) { grant = 'password'; body = { email: b.email.trim(), password: b.password }; }
  else return json(res, 400, { error: 'invalid_request' });
  try {
    const r = await fetch(`${url}/auth/v1/token?grant_type=${grant}`, { method: 'POST', headers: { apikey: anon, 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(8000) });
    if (r.status >= 400 && r.status < 500) return json(res, 401, { error: 'invalid_credentials' });
    if (!r.ok) return json(res, 503, { error: 'unavailable' });
    const j = await r.json();
    if (!j.access_token || !j.refresh_token) return json(res, 503, { error: 'unavailable' });
    return json(res, 200, { access_token: j.access_token, refresh_token: j.refresh_token, expires_in: j.expires_in });
  } catch (_) { return json(res, 503, { error: 'unavailable' }); }
};
