'use strict';
// Scanner d'entrée : vrai navigateur (caméra factice), vraie base (via le relais), vrais résultats SQL.
// Le détecteur de QR du téléphone (BarcodeDetector) est remplacé par une file de codes : on teste tout
// le reste de la chaîne (boucle de lecture, API, base, écrans). La lecture optique réelle n'est PAS testée ici.
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs'), path = require('path');
const [, , FIX, OUTDIR] = process.argv;
const fx = JSON.parse(fs.readFileSync(FIX));
const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3100), SITE = process.env.PUBLIC_SITE_URL;
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('PASS ', m); } else { fail++; console.log('FAIL ', m); } };
const psql = (sql, input) => execFileSync('psql', ['-X', '-q', '-At', '-d', 'inviteo_web'].concat(input ? [] : ['-c', sql]), input ? { input: sql } : {}).toString().trim();
const jwt = (u) => `eyJ.${u}.sig`;
const used = (id) => psql(`select entries_used from invitations where id='${id}'`);
const logs = (id) => psql(`select count(*) from scan_logs where invitation_id='${id}'`);
function newInv(name, size) {
  const out = psql(`begin; select set_config('request.jwt.claim.sub','${fx.org}',true); set local role authenticated;
    with g as (insert into public.guests (event_id,full_name,party_size) values ('${fx.event}','${name}',${size}) returning id)
    select qr_token || '|' || invitation_id from g, lateral public.issue_invitation(g.id); commit;`, true);
  const [qr, id] = out.split('\n').filter((l) => l.includes('|')).pop().split('|'); return { qr, id };
}
const url = (qr) => `${SITE}/s/${qr}`;

(async () => {
  const browser = await chromium.launch({ args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const ctx = await browser.newContext({ viewport: { width: 375, height: 800 }, deviceScaleFactor: 2, permissions: ['camera'] });
  await ctx.addInitScript(() => {
    window.__q = [];
    window.BarcodeDetector = class { constructor() {} detect() { return Promise.resolve(window.__q.length ? [{ rawValue: window.__q.shift() }] : []); } };
  });
  const problems = [];
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error' && !/favicon|Failed to load resource/.test(m.text())) problems.push(m.text()); });
  page.on('pageerror', (e) => problems.push('pageerror ' + e.message));
  let scanCalls = 0, authCalls = 0;
  page.on('request', (r) => { if (r.url().endsWith('/api/scan')) scanCalls++; if (r.url().endsWith('/api/auth')) authCalls++; });
  const kind = () => page.getAttribute('#result', 'data-kind');
  const waitResult = async () => { await page.waitForFunction(() => { const r = document.getElementById('result'); return !r.hidden && document.getElementById('r-title').textContent !== 'VÉRIFICATION…'; }, null, { timeout: 8000 }); };
  const scanQueue = async (text) => { await page.evaluate((t) => window.__q.push(t), text); await waitResult(); };
  const next = async () => { await page.click('#r-next'); await page.waitForTimeout(750); };
  const title = () => page.textContent('#r-title');

  // Configuration des en-têtes (Vercel) : caméra autorisée uniquement sur /scanner
  const vj = JSON.parse(fs.readFileSync(path.join(__dirname, '../../vercel.json')));
  const rule = vj.headers.find((h) => h.source === '/scanner'), glob = vj.headers.find((h) => /^\/\(\(\?!scanner/.test(h.source));
  ok(rule && /camera=\(self\)/.test(rule.headers.find((x) => x.key === 'Permissions-Policy').value), 'vercel.json : /scanner autorise la caméra (self)');
  ok(glob && /camera=\(\)/.test(glob.headers.find((x) => x.key === 'Permissions-Policy').value), 'vercel.json : caméra interdite ailleurs, /scanner exclu de la règle générale');
  ok(/script-src 'self'/.test(rule.headers.find((x) => x.key === 'Content-Security-Policy').value), 'vercel.json : CSP du scanner sans script en ligne');

  // API sans session
  const raw = (b, hd) => fetch(`${BASE}/api/scan`, { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, hd), body: JSON.stringify(b) });
  const good = { event_id: fx.event, token: fx.a.qr, request_id: '11111111-1111-4111-8111-111111111111' };
  ok((await raw(good)).status === 401, 'API : scan sans connexion refusé (401)');
  ok((await raw({ event_id: 'x', token: 'y' }, { Authorization: 'Bearer ' + jwt(fx.agent.id) })).status === 400, 'API : corps invalide refusé (400)');
  ok((await raw(good, { Authorization: 'Bearer ' + jwt(fx.agent.id), Origin: 'https://evil.example' })).status === 403, 'API : autre origine refusée (403)');
  let r = await (await raw(good, { Authorization: 'Bearer ' + jwt(fx.agent2.id) })).json();
  ok(r.result === 'forbidden' && r.reason === 'not_assigned', 'API : agent non affecté → forbidden / not_assigned');
  r = await (await raw(Object.assign({}, good, { request_id: '22222222-2222-4222-8222-222222222222' }), { Authorization: 'Bearer ' + jwt(fx.org) })).json();
  ok(r.result === 'forbidden', "API : un organisateur ne peut pas valider d'entrée (forbidden)");
  ok(used(fx.a.id) === '0', "aucun refus n'a consommé d'entrée");

  // Connexion
  await page.goto(`${BASE}/scanner`);
  ok(await page.isVisible('#login-form'), 'écran de connexion affiché');
  await page.fill('input[name=email]', fx.agent.email); await page.fill('input[name=password]', 'mauvais'); await page.click('#login-form button');
  await page.waitForFunction(() => /incorrect/.test(document.getElementById('login-msg').textContent));
  ok(!(await page.isVisible('#v-scan')), 'mauvais mot de passe : refus, pas d\'accès au scanner');
  await page.fill('input[name=password]', 'test-pass'); await page.click('#login-form button');
  await page.waitForSelector('#v-scan:not([hidden])');
  ok((await page.textContent('#evt-name')) === 'Mariage Awa & Jean', 'connexion agent : son unique événement choisi automatiquement');
  await page.waitForFunction(() => { const v = document.getElementById('video'); return v.videoWidth > 0; }, null, { timeout: 8000 }).then(() => ok(true, 'caméra (factice) démarrée : flux vidéo actif'), () => ok(false, 'caméra : flux vidéo actif'));
  ok(/Cadrez/.test(await page.textContent('#cam-msg')), 'consigne de cadrage affichée');

  // Scans
  await scanQueue(url(fx.a.qr));
  ok(await kind() === 'ok' && (await title()) === 'ENTRÉE VALIDÉE', 'QR valide → écran VERT « ENTRÉE VALIDÉE »');
  ok((await page.textContent('#r-name')) === "Marie <b>Kabila</b> O'Neil", "nom de l'invité affiché en texte (pas de HTML interprété)");
  ok(/Entrée 1 sur 2/.test(await page.textContent('#r-detail')), 'compteur « Entrée 1 sur 2 »');
  ok(used(fx.a.id) === '1' && logs(fx.a.id) === '1', 'base : 1 entrée, 1 ligne de journal');
  await page.screenshot({ path: path.join(OUTDIR, '5-scan-vert.png') });
  await next();
  await scanQueue(url(fx.a.qr)); ok(/Entrée 2 sur 2/.test(await page.textContent('#r-detail')) && await kind() === 'ok', 'deuxième personne du billet : « Entrée 2 sur 2 » (vert)'); await next();
  await scanQueue(url(fx.a.qr));
  ok(await kind() === 'stop' && (await title()) === 'DÉJÀ UTILISÉ', 'billet épuisé → écran ROUGE « DÉJÀ UTILISÉ »');
  ok(/Premier passage à \d\d:\d\d \(Agent Un\)/.test(await page.textContent('#r-detail')), 'premier passage (heure + agent) affiché');
  ok(used(fx.a.id) === '2', "base : pas d'entrée en trop (2 sur 2)");
  await page.screenshot({ path: path.join(OUTDIR, '6-scan-rouge.png') });
  await next();
  const sc = await page.evaluate(() => document.documentElement.scrollWidth); ok(sc <= 375, `pas de défilement horizontal (${sc})`);

  await scanQueue(fx.b.view ? url(fx.b.view) : ''); ok((await title()) === 'CODE INVALIDE' && await kind() === 'warn', 'jeton du LIEN de la page scanné → CODE INVALIDE (orange)'); await next();
  await scanQueue(url(fx.revoked.qr)); ok((await title()) === 'INVITATION RÉVOQUÉE' && await kind() === 'stop', 'invitation révoquée → rouge'); await next();
  await scanQueue(url(fx.other.qr)); ok((await title()) === 'AUTRE ÉVÉNEMENT' && await kind() === 'stop', "QR d'un autre événement → rouge");
  ok(!(await page.content()).includes('Autre Invité'), "aucune donnée de l'invité de l'autre événement affichée"); await next();
  const before = scanCalls;
  await scanQueue('https://exemple.org/pas-un-billet'); ok((await title()) === 'CODE NON RECONNU', 'QR étranger → « CODE NON RECONNU »'); await next();
  await page.fill('#manual', 'courtjeton'); await page.click('#manual-form button'); await waitResult(); await next();
  ok(scanCalls === before, 'codes non reconnus : aucune requête envoyée au serveur');
  await page.fill('#manual', fx.b.qr); await page.click('#manual-form button'); await waitResult();
  ok(await kind() === 'ok' && used(fx.b.id) === '1', 'saisie manuelle du jeton nu → entrée validée'); await next();

  // Réseau coupé avant l'envoi : jamais de vert
  const n1 = newInv('Réseau Coupé', 1);
  await ctx.setOffline(true);
  await scanQueue(url(n1.qr));
  ok(await kind() === 'unknown' && (await title()) === 'CONTRÔLE NON CONFIRMÉ', 'réseau coupé → « CONTRÔLE NON CONFIRMÉ » (jamais vert)');
  ok(await page.isVisible('#r-retry') && used(n1.id) === '0', 'bouton Réessayer proposé, aucune entrée comptée');
  await ctx.setOffline(false);
  await page.click('#r-retry'); await waitResult();
  ok(await kind() === 'ok' && used(n1.id) === '1' && logs(n1.id) === '1', 'réseau revenu : Réessayer → validé, compté une seule fois'); await next();

  // Réponse perdue APRÈS traitement par le serveur : le rejeu ne compte pas deux fois
  const n2 = newInv('Réponse Perdue', 1);
  let dropped = false;
  await page.route('**/api/scan', async (route) => { if (!dropped) { dropped = true; await route.fetch(); await route.abort('connectionreset'); } else await route.continue(); });
  await scanQueue(url(n2.qr));
  ok(await kind() === 'unknown' && used(n2.id) === '1', 'réponse perdue : écran « non confirmé » alors que le serveur a bien compté 1 entrée');
  await page.click('#r-retry'); await waitResult();
  ok(await kind() === 'ok' && /déjà enregistrée/.test(await page.textContent('#r-detail')), 'Réessayer : même requête rejouée → réponse enregistrée (pas de « déjà utilisé » à tort)');
  ok(used(n2.id) === '1' && logs(n2.id) === '1', 'base : toujours 1 entrée et 1 ligne de journal après le rejeu'); await next();
  await page.unroute('**/api/scan');

  // Session expirée : renouvellement automatique
  const n3 = newInv('Session Expirée', 1); let swapped = false; const a0 = authCalls;
  await page.route('**/api/scan', async (route) => { if (!swapped) { swapped = true; await route.continue({ headers: Object.assign({}, route.request().headers(), { authorization: 'Bearer ' + `eyJ.${fx.agent.id}.exp` }) }); } else await route.continue(); });
  await scanQueue(url(n3.qr));
  ok(await kind() === 'ok' && authCalls === a0 + 1 && used(n3.id) === '1', 'jeton expiré (401) : session renouvelée automatiquement puis scan validé une seule fois'); await next();
  await page.unroute('**/api/scan');

  // Rechargement : session reprise, déconnexion
  await page.reload(); await page.waitForSelector('#v-scan:not([hidden])', { timeout: 8000 });
  ok(true, 'rechargement de la page : session reprise sans ressaisir le mot de passe');
  await page.click('#logout');
  ok(await page.isVisible('#login-form') && (await page.evaluate(() => sessionStorage.getItem('inv_refresh'))) === null, 'déconnexion : retour à la connexion, session effacée');
  await page.reload(); ok(await page.isVisible('#login-form'), 'après déconnexion et rechargement : connexion exigée');

  // Agent non affecté
  await page.fill('input[name=email]', fx.agent2.email); await page.fill('input[name=password]', 'test-pass'); await page.click('#login-form button');
  await page.waitForSelector('#v-events:not([hidden])');
  ok(/Aucun événement/.test(await page.textContent('#events-msg')), 'agent sans affectation : aucun événement proposé');

  // Sans détecteur de QR (ex. Safari) : repli sur la saisie
  const ctx2 = await browser.newContext({ viewport: { width: 375, height: 800 }, permissions: ['camera'] });
  const p2 = await ctx2.newPage(); await p2.goto(`${BASE}/scanner`);
  await p2.fill('input[name=email]', fx.agent.email); await p2.fill('input[name=password]', 'test-pass'); await p2.click('#login-form button');
  await p2.waitForSelector('#v-scan:not([hidden])');
  await p2.waitForFunction(() => /ne sait pas lire|indisponible/.test(document.getElementById('cam-msg').textContent), null, { timeout: 8000 }).then(() => ok(true, 'sans BarcodeDetector : message clair et saisie manuelle disponible'), () => ok(false, 'sans BarcodeDetector : message clair'));
  ok(await p2.isVisible('#manual'), 'champ de saisie manuelle présent');

  ok(problems.length === 0, 'aucune erreur console' + (problems.length ? ' : ' + problems.join(' | ') : ''));
  await browser.close();
  console.log(`\nRésultat scanner : ${pass} réussis, ${fail} échoués`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
