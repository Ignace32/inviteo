'use strict';
// GET /api/my-events (agent connecté) → événements publiés auxquels il est affecté (colonnes limitées).
const { rpcAs } = require('./_lib/supabase');
const { json, bearer, upstreamError } = require('./_lib/http');
module.exports = async function handler(req, res) {
  if (req.method !== 'GET') { res.writeHead(405, { Allow: 'GET' }); return res.end(); }
  const jwt = bearer(req); if (!jwt) return json(res, 401, { error: 'authentication_required' });
  try { return json(res, 200, { events: await rpcAs(jwt, 'my_assigned_events', {}) }); } catch (e) { return upstreamError(res, e); }
};
