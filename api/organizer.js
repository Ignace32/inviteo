'use strict';
// POST /api/organizer { fn, args }  (organisateur connecté)
// Liste blanche de fonctions appelées avec le jeton de l'utilisateur : les droits et la sécurité par ligne
// de la base s'appliquent. Aucune autre fonction n'est joignable par cette route.
const { rpcAs } = require('./_lib/supabase');
const { json, sameOrigin, readJson, bearer, upstreamError } = require('./_lib/http');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const FN = {
  organizer_events: { args: {} },
  event_guests:     { args: { p_event_id: 'uuid' } },
  event_stats:      { args: { p_event_id: 'uuid' } },
  revoke_invitation:{ args: { p_invitation_id: 'uuid', p_reason: 'text?' } },
  import_guests:    { args: { p_event_id: 'uuid', p_rows: 'rows' } },
};
const OK = {
  uuid: (v) => typeof v === 'string' && UUID.test(v),
  'text?': (v) => v == null || (typeof v === 'string' && v.length <= 200),
  rows: (v) => Array.isArray(v) && v.length >= 1 && v.length <= 2000 && v.every((r) => r && typeof r === 'object' && !Array.isArray(r) && Object.values(r).every((x) => x == null || typeof x === 'string' || typeof x === 'number')),
};

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
  if (!sameOrigin(req)) return json(res, 403, { error: 'forbidden' });
  const jwt = bearer(req); if (!jwt) return json(res, 401, { error: 'authentication_required' });
  let b; try { b = await readJson(req, 900000); } catch (_) { return json(res, 400, { error: 'invalid_request' }); }
  const spec = typeof b.fn === 'string' && Object.prototype.hasOwnProperty.call(FN, b.fn) ? FN[b.fn] : null;
  const a = b.args && typeof b.args === 'object' && !Array.isArray(b.args) ? b.args : {};
  if (!spec) return json(res, 400, { error: 'invalid_request' });
  const extra = Object.keys(a).filter((k) => !(k in spec.args));
  if (extra.length || Object.entries(spec.args).some(([k, t]) => !OK[t](a[k]))) return json(res, 400, { error: 'invalid_request' });
  try { return json(res, 200, { data: await rpcAs(jwt, b.fn, a) }); } catch (e) { return upstreamError(res, e); }
};
