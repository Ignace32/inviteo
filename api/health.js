'use strict';
// GET /api/health — diagnostic de configuration. Ne renvoie JAMAIS de valeur : uniquement présent/absent,
// forme (« ressemble à une clé JWT ») et état de joignabilité de Supabase.
const { json } = require('./_lib/http');
const jwtLike = (v) => /^eyJ[\w-]+\.[\w-]+\.[\w-]+$/.test(v || '');

module.exports = async function handler(req, res) {
  if (req.method !== 'GET') { res.writeHead(405, { Allow: 'GET' }); return res.end(); }
  const e = process.env, url = e.SUPABASE_URL || '', anon = e.SUPABASE_ANON_KEY || '', svc = e.SUPABASE_SERVICE_ROLE_KEY || '', site = e.PUBLIC_SITE_URL || '';
  const r = {
    SUPABASE_URL: !url ? 'ABSENTE' : /^https:\/\/[a-z0-9]{15,30}\.supabase\.co$/.test(url) ? 'ok' : 'FORME SUSPECTE (attendu : https://xxxx.supabase.co, sans / final ni chemin)',
    SUPABASE_ANON_KEY: !anon ? 'ABSENTE' : jwtLike(anon) ? 'ok' : 'FORME SUSPECTE (doit commencer par eyJ : onglet Legacy API Keys)',
    SUPABASE_SERVICE_ROLE_KEY: !svc ? 'ABSENTE' : jwtLike(svc) ? 'ok' : 'FORME SUSPECTE (doit commencer par eyJ : onglet Legacy API Keys)',
    PUBLIC_SITE_URL: !site ? 'ABSENTE' : /^https:\/\/[^/\s]+$/.test(site) ? 'ok' : 'FORME SUSPECTE (sans / final)',
  };
  if (anon && svc && anon === svc) r.SUPABASE_SERVICE_ROLE_KEY = 'IDENTIQUE à la clé anon : une des deux est mal copiée';
  r.supabase_joignable = 'non testé';
  if (r.SUPABASE_URL === 'ok' && anon) {
    try {
      const x = await fetch(`${url}/auth/v1/health`, { headers: { apikey: anon }, signal: AbortSignal.timeout(6000) });
      r.supabase_joignable = x.ok ? 'ok' : `réponse ${x.status} (clé anon refusée ou projet en pause)`;
    } catch (_) { r.supabase_joignable = 'INJOIGNABLE (adresse du projet incorrecte ?)'; }
  }
  r.tout_est_bon = Object.values(r).every((v) => v === 'ok');
  json(res, 200, r);
};
