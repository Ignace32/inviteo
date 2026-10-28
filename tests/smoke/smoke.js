'use strict';
// Contrôle rapide d'un déploiement (sans aucune écriture en base) :
//   node tests/smoke/smoke.js https://inviteo-dun.vercel.app
//   LOCAL=1 node tests/smoke/smoke.js http://127.0.0.1:3100      (serveur local : en-têtes Vercel non vérifiés)
// Optionnel : SMOKE_AGENT_EMAIL / SMOKE_AGENT_PASSWORD (compte agent de test) pour vérifier la connexion réelle.
const base = (process.argv[2] || '').replace(/\/+$/, '');
if (!/^https?:\/\//.test(base)) { console.error('Usage : node smoke.js <URL du site>'); process.exit(2); }
const LOCAL = !!process.env.LOCAL;
let pass = 0, fail = 0;
const ok = (c, m, d) => { if (c) { pass++; console.log('PASS ', m); } else { fail++; console.log('FAIL ', m + (d ? '  → ' + d : '')); } };
const get = (p, o) => fetch(base + p, Object.assign({ redirect: 'manual' }, o));
const post = (p, b, h) => fetch(base + p, { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, h), body: JSON.stringify(b) });

(async () => {
  // Pages statiques
  for (const [p, re] of [['/', /Invit/], ['/mentions-legales', /./], ['/confidentialite', /./], ['/modele-anniversaire', /./], ['/scanner', /Connexion agent/], ['/organisateur', /Connexion/]]) {
    const r = await get(p); const t = r.status === 200 ? await r.text() : '';
    ok(r.status === 200 && re.test(t), `page ${p} : 200`, 'HTTP ' + r.status);
  }
  const home = await (await get('/')).text();
  ok(/243990228413/.test(home), 'site vitrine : numéro WhatsApp présent');
  ok(/0[.,]60/.test(home) && /0[.,]70/.test(home) && /1[.,]00/.test(home), 'site vitrine : prix 0,60 / 0,70 / 1,00 $ présents');

  // Fichiers qui ne doivent jamais être publics
  for (const p of ['/supabase/migrations/20261101000001_schema.sql', '/.env', '/.env.example', '/tests/web/run.sh', '/README.md', '/DEPLOY.md', '/api/_lib/supabase.js']) {
    const r = await get(p); ok(r.status === 404 || r.status === 403 || r.status === 308 && !/\.sql|\.env/.test(p), `non publié : ${p}`, 'HTTP ' + r.status);
  }
  // Aucun secret dans les fichiers statiques
  for (const p of ['/assets/scanner.js', '/assets/organisateur.js', '/assets/invitation.js', '/script.js']) {
    const t = await (await get(p)).text(); ok(!/service_role|SERVICE_ROLE|eyJ[\w-]{20,}\.[\w-]{20,}\./.test(t), `aucun secret dans ${p}`);
  }

  // Jetons
  const r1 = await get('/i/' + 'x'.repeat(43)); ok(r1.status === 404, 'lien /i/ inconnu : 404 (la base répond)', 'HTTP ' + r1.status);
  ok(r1.status !== 503, "fonctions serveur configurées (SUPABASE_URL, clé service_role) — sinon 503");
  ok(/noindex/i.test(r1.headers.get('x-robots-tag') || '') && /no-store/.test(r1.headers.get('cache-control') || ''), '/i/ : noindex et no-store');
  const s1 = await get('/s/' + 'y'.repeat(43)); const st = await s1.text();
  ok(s1.status === 200 && /billet d'entrée/.test(st) && !st.includes('y'.repeat(43)), '/s/<jeton> : page explicative, jeton non répété');

  // API : protections
  ok((await post('/api/scan', { event_id: 'x' })).status === 401, '/api/scan sans connexion : 401');
  ok((await post('/api/ticket', { guest_id: 'x' })).status === 401, '/api/ticket sans connexion : 401');
  ok((await post('/api/organizer', { fn: 'organizer_events', args: {} })).status === 401, '/api/organizer sans connexion : 401');
  ok((await get('/api/rsvp')).status === 405, '/api/rsvp en GET : 405');
  ok((await post('/api/rsvp', { token: 'x', attending: true }, { Origin: 'https://evil.example' })).status === 403, '/api/rsvp depuis une autre origine : 403');
  const a = await post('/api/auth', { email: 'inconnu@exemple.invalid', password: 'mauvais-mot-de-passe' });
  ok(a.status === 401, 'connexion avec un faux compte : 401 (Supabase Auth joignable, clé anon valide)', 'HTTP ' + a.status + (a.status === 503 ? ' = SUPABASE_URL / SUPABASE_ANON_KEY manquantes ou fausses' : ''));
  if (process.env.SMOKE_AGENT_EMAIL) {
    const g = await post('/api/auth', { email: process.env.SMOKE_AGENT_EMAIL, password: process.env.SMOKE_AGENT_PASSWORD || '' });
    ok(g.status === 200, 'connexion du compte agent de test : 200', 'HTTP ' + g.status);
    if (g.status === 200) {
      const j = await g.json(); const ev = await get('/api/my-events', { headers: { Authorization: 'Bearer ' + j.access_token } });
      ok(ev.status === 200 && Array.isArray((await ev.json()).events), 'événements affectés à l\'agent lus (RPC my_assigned_events)');
    }
  }

  // En-têtes de sécurité (Vercel seulement)
  if (!LOCAL) {
    const sc = await get('/scanner'), h = (r, k) => r.headers.get(k) || '';
    ok(/camera=\(self\)/.test(h(sc, 'permissions-policy')), '/scanner : caméra autorisée', h(sc, 'permissions-policy'));
    ok(/script-src 'self'/.test(h(sc, 'content-security-policy')), '/scanner : CSP sans script en ligne');
    const hm = await get('/'); ok(/camera=\(\)/.test(h(hm, 'permissions-policy')), "accueil : caméra interdite", h(hm, 'permissions-policy'));
    ok(/nosniff/.test(h(hm, 'x-content-type-options')) && /DENY/.test(h(hm, 'x-frame-options')), 'accueil : nosniff et X-Frame-Options DENY');
    const inv = await get('/i/' + 'x'.repeat(43)); ok(/script-src 'self'/.test(h(inv, 'content-security-policy')), '/i/ : CSP sans script en ligne');
    ok(/no-referrer/.test(h(inv, 'referrer-policy')), '/i/ : Referrer-Policy no-referrer');
  }
  console.log(`\nRésultat : ${pass} réussis, ${fail} échoués`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
