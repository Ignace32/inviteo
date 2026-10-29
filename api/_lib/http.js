'use strict';
const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); res.end(JSON.stringify(obj)); };
const sameOrigin = (req) => { const o = req.headers.origin; if (!o) return true; try { return new URL(o).host === req.headers.host; } catch (_) { return false; } };
async function readJson(req, max = 4000) {
  if (req.body && typeof req.body === 'object') return req.body;
  let raw = '';
  for await (const c of req) { raw += c; if (raw.length > max) throw new Error('too_big'); }
  return JSON.parse(raw || '{}');
}
const bearer = (req) => (/^Bearer ([\w-]+\.[\w-]+\.[\w-]+)$/.exec(req.headers.authorization || '') || [])[1];
// Traduit une erreur Supabase en réponse : jamais de « succès » inventé.
const upstreamError = (res, e) => {
  if (e.code === 'not_configured') return json(res, 503, { error: 'unavailable' });
  const s = e.status;
  if (s === 401) return json(res, 401, { error: 'authentication_required' });
  if (s === 403) return json(res, 403, { error: 'forbidden' });
  if (s >= 400 && s < 500) return json(res, 400, { error: 'refused' });
  return json(res, 503, { error: 'unavailable' });
};
module.exports = { json, sameOrigin, readJson, bearer, upstreamError };
