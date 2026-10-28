'use strict';
// POST /api/scan { event_id, token, request_id } (agent connecté)
// Transmet tel quel à scan_invitation() avec le jeton de l'agent : toute la décision (atomicité,
// rejeu, droits) est prise dans la base. En cas d'erreur réseau/serveur, on renvoie une ERREUR,
// jamais un résultat : le scanner ne doit rien afficher de « valide » sans réponse de la base.
const { rpcAs } = require('./_lib/supabase');
const { json, sameOrigin, readJson, bearer, upstreamError } = require('./_lib/http');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
  if (!sameOrigin(req)) return json(res, 403, { error: 'forbidden' });
  const jwt = bearer(req); if (!jwt) return json(res, 401, { error: 'authentication_required' });
  let b; try { b = await readJson(req); } catch (_) { return json(res, 400, { error: 'invalid_request' }); }
  if (!UUID.test(b.event_id || '') || !UUID.test(b.request_id || '') || typeof b.token !== 'string' || !/^[\w-]{1,200}$/.test(b.token)) return json(res, 400, { error: 'invalid_request' });
  try {
    const r = await rpcAs(jwt, 'scan_invitation', { p_event_id: b.event_id, p_token: b.token, p_request_id: b.request_id });
    if (!r || typeof r.result !== 'string') return json(res, 503, { error: 'unavailable' });
    return json(res, 200, r);
  } catch (e) { return upstreamError(res, e); }
};
