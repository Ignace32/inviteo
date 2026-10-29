'use strict';
// Test de bout en bout de la page d'invitation : vraie base PostgreSQL (via le point d'accès simulé),
// vrai navigateur (Chromium), QR code relu par un décodeur indépendant (OpenCV).
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs'), path = require('path');
const [, , FIX, OUTDIR] = process.argv;
const fx = JSON.parse(fs.readFileSync(FIX));
const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3100);
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('PASS ', m); } else { fail++; console.log('FAIL ', m); } };
const psql = (sql) => execFileSync('psql', ['-X', '-q', '-At', '-d', 'inviteo_web', '-c', sql]).toString().trim();

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 375, height: 800 }, deviceScaleFactor: 2, locale: 'fr-FR' });
  const page = await ctx.newPage();
  const problems = [];
  page.on('console', (m) => { if (m.type() === 'error' && !/fonts\.(googleapis|gstatic)|ERR_(NAME|INTERNET|CONNECTION|TUNNEL|PROXY)/.test(m.text())) problems.push(m.text()); });
  page.on('pageerror', (e) => problems.push('pageerror ' + e.message));

  // 1. Page valide
  const r = await page.goto(`${BASE}/i/${fx.a.view}`, { waitUntil: 'domcontentloaded' });
  ok(r.status() === 200, 'invitation valide : HTTP 200');
  const h = r.headers();
  ok(/no-store/.test(h['cache-control']), 'Cache-Control privé, no-store');
  ok(/noindex/.test(h['x-robots-tag']), 'X-Robots-Tag noindex');
  ok(/script-src 'self'/.test(h['content-security-policy']) && !/unsafe-inline.*script|script-src[^;]*unsafe-inline/.test(h['content-security-policy']), 'CSP : aucun script en ligne autorisé');
  const html = await (await ctx.request.get(`${BASE}/i/${fx.a.view}`)).text();
  ok(!html.includes(fx.a.qr), 'le jeton du QR code ne figure jamais dans le HTML serveur');
  ok(!html.includes('<b>Kabila</b>') && html.includes('&lt;b&gt;Kabila&lt;/b&gt;'), "nom d'invité échappé (pas d'injection HTML)");
  ok((await page.textContent('.cover-guest')).includes("<b>Kabila</b> O'Neil"), "nom affiché tel quel, apostrophe comprise");
  ok(await page.isVisible('#cover') && (await page.getAttribute('#page', 'aria-hidden')) === 'true', 'couverture visible, page masquée aux lecteurs d\'écran avant ouverture');
  await page.screenshot({ path: path.join(OUTDIR, '1-couverture.png') });
  await page.click('#open');
  await page.waitForTimeout(1500);
  ok(!(await page.isVisible('#cover')), 'couverture retirée après ouverture');
  ok((await page.textContent('h1')).trim() === 'Awa & Jean', 'noms des célébrés');
  ok(/mariage|40|jours/i.test(await page.textContent('#countdown-block')) || await page.isVisible('#countdown-block'), 'compte à rebours affiché (événement futur)');
  ok((await page.textContent('.program')).includes('Cérémonie'), 'programme affiché');
  ok(await page.getAttribute('a[href^="https://maps"]', 'rel') === 'noopener noreferrer', "lien d'itinéraire https avec noopener");
  ok(!(await page.isVisible('#ticket')), 'sans fragment : aucun QR code affiché');
  const scrollW = await page.evaluate(() => document.documentElement.scrollWidth);
  ok(scrollW <= 375, `pas de défilement horizontal en 375 px (largeur ${scrollW})`);
  await page.evaluate(() => document.querySelectorAll('.reveal').forEach((e) => e.classList.add('in')));
  await page.screenshot({ path: path.join(OUTDIR, '2-page.png'), fullPage: true });

  // 2. QR via le fragment
  const p2 = await ctx.newPage();
  await p2.goto(`${BASE}/i/${fx.a.view}#${fx.a.qr}`);
  await p2.click('#open'); await p2.waitForTimeout(1500);
  ok(await p2.isVisible('#ticket svg'), 'avec le fragment : QR code tracé dans le navigateur');
  await p2.evaluate(() => document.querySelectorAll('.reveal').forEach((e) => e.classList.add('in')));
  const qrShot = path.join(OUTDIR, 'qr.png');
  await p2.locator('#qr').screenshot({ path: qrShot });
  await p2.screenshot({ path: path.join(OUTDIR, '3-billet.png'), fullPage: true });
  const dec = execFileSync('python3', ['-I', '-c', `
import cv2,sys
img=cv2.imread(sys.argv[1]); 
for s in (1.0,1.5,2.0):
    im=cv2.resize(img,None,fx=s,fy=s,interpolation=cv2.INTER_NEAREST) if s!=1.0 else img
    t=cv2.QRCodeDetectorAruco().detectAndDecode(im)[0]
    if t: print(t); break
`, qrShot]).toString().trim();
  ok(dec === `${process.env.PUBLIC_SITE_URL}/s/${fx.a.qr}`, `QR relu par OpenCV = ${dec.slice(0, 40)}…`);
  const p3 = await ctx.newPage();
  await p3.goto(`${BASE}/i/${fx.a.view}#${fx.a.view}`); await p3.click('#open'); await p3.waitForTimeout(300);
  ok(!(await p3.isVisible('#ticket')), 'le jeton de la page placé dans le fragment ne produit aucun QR');
  const p3b = await ctx.newPage();
  await p3b.goto(`${BASE}/i/${fx.a.view}#nimporte-quoi`); await p3b.click('#open'); await p3b.waitForTimeout(300);
  ok(!(await p3b.isVisible('#ticket')), 'fragment invalide : aucun QR');

  // 3. Mauvais jetons / états
  const st = async (t) => (await ctx.request.get(`${BASE}/i/${t}`, { failOnStatusCode: false })).status();
  ok(await st(fx.a.qr) === 404, 'le jeton du QR code ne donne pas accès à la page (404)');
  ok(await st('x'.repeat(43)) === 404, 'jeton inconnu bien formé : 404');
  ok(await st('court') === 404, 'jeton mal formé : 404');
  ok(await st(fx.revoked.view) === 410, 'invitation révoquée : 410');
  const rv = await (await ctx.request.get(`${BASE}/i/${fx.revoked.view}`, { failOnStatusCode: false })).text();
  ok(!rv.includes('Révoquée Test'), "invitation révoquée : le nom de l'invité n'est pas divulgué");

  // 4. RSVP
  const post = (b, hd) => ctx.request.post(`${BASE}/api/rsvp`, { data: b, headers: hd || {}, failOnStatusCode: false });
  let x = await post({ token: fx.a.view, attending: true, party_count: 2, song: 'Mario Mwamba', note: 'Avec joie' });
  ok(x.status() === 200 && (await x.json()).ok, 'RSVP présent (2 personnes) accepté');
  ok(psql(`select attending||'|'||party_count||'|'||song from rsvp_responses where invitation_id='${fx.a.id}'`) === 'true|2|Mario Mwamba', 'RSVP bien enregistré en base');
  x = await post({ token: fx.a.view, attending: true, party_count: 3 });
  ok(x.status() === 422, 'RSVP au-delà du quota (3 > 2) refusé : 422');
  x = await post({ token: fx.a.view, attending: false, song: 'ignorée' });
  ok(x.status() === 200, 'RSVP absent accepté (modification)');
  ok(psql(`select count(*)||'|'||string_agg(attending||'|'||party_count||'|'||coalesce(song,'-'),';') from rsvp_responses where invitation_id='${fx.a.id}'`) === '1|false|0|-', 'une seule ligne, mise à jour, chanson effacée');
  x = await post({ token: fx.a.qr, attending: true });
  ok(x.status() === 404, 'RSVP avec le jeton du QR code refusé');
  x = await post({ token: fx.revoked.view, attending: true });
  ok(x.status() === 410, 'RSVP sur invitation révoquée refusé');
  x = await post({ token: fx.a.view, attending: 'oui' });
  ok(x.status() === 400, 'RSVP mal formé refusé : 400');
  x = await post({ token: fx.a.view, attending: true }, { Origin: 'https://evil.example' });
  ok(x.status() === 403, "RSVP d'une autre origine refusé : 403");
  x = await ctx.request.get(`${BASE}/api/rsvp`, { failOnStatusCode: false });
  ok(x.status() === 405, 'RSVP en GET refusé : 405');
  ok(psql(`select count(*) from rsvp_responses`) === '1', "aucune réponse parasite créée par les tentatives refusées");

  // 5. Formulaire dans le navigateur
  const p4 = await ctx.newPage();
  await p4.goto(`${BASE}/i/${fx.b.view}`); await p4.click('#open'); await p4.waitForTimeout(1300);
  await p4.click('button[type=submit]');
  ok((await p4.textContent('#rsvp-msg')).includes('Choisissez'), 'formulaire : réponse obligatoire');
  await p4.check('input[value=yes]'); await p4.fill('input[name=song]', 'Fally Ipupa'); await p4.click('button[type=submit]');
  await p4.waitForFunction(() => /Merci/.test(document.querySelector('#rsvp-msg').textContent), null, { timeout: 5000 });
  ok(psql(`select attending||'|'||party_count from rsvp_responses where invitation_id='${fx.b.id}'`) === 'true|1', 'formulaire : réponse enregistrée en base');
  await p4.reload(); await p4.click('#open'); await p4.waitForTimeout(300);
  ok(await p4.isChecked('input[value=yes]'), 'après rechargement : la réponse est préremplie');

  // 6. Mouvement réduit
  const rc = await browser.newContext({ viewport: { width: 375, height: 800 }, reducedMotion: 'reduce' });
  const p5 = await rc.newPage(); await p5.goto(`${BASE}/i/${fx.b.view}`); await p5.click('#open'); await p5.waitForTimeout(200);
  ok(await p5.evaluate(() => getComputedStyle(document.querySelector('.reveal')).opacity) === '1', 'mouvement réduit : contenu visible sans animation');

  // 7. Page /s/
  const p6 = await ctx.newPage(); const sr = await p6.goto(`${BASE}/s/${fx.a.qr}`);
  ok(sr.status() === 200 && (await p6.textContent('h1')).includes('billet'), '/s/<jeton> : page statique explicative');
  ok(!(await p6.content()).includes(fx.a.qr), "/s/<jeton> : le jeton n'est pas répété dans la page");
  ok(psql(`select entries_used from invitations where id='${fx.a.id}'`) === '0', "ouvrir /s/<jeton> ne consomme aucune entrée");

  ok(problems.length === 0, 'aucune erreur console / CSP' + (problems.length ? ' : ' + problems.join(' | ') : ''));
  await browser.close();
  console.log(`\nRésultat page d'invitation : ${pass} réussis, ${fail} échoués`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
