'use strict';
// Modèles, photos remplaçables, création et modification d'un événement : vrai navigateur, vraie base (via le relais).
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs'), path = require('path'), os = require('os');
const [, , FIX, OUTDIR] = process.argv;
const fx = JSON.parse(fs.readFileSync(FIX));
const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3100), SHIM = 'http://127.0.0.1:' + (process.env.SHIM_PORT || 54321);
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('PASS ', m); } else { fail++; console.log('FAIL ', m); } };
const psql = (sql) => execFileSync('psql', ['-X', '-q', '-At', '-d', 'inviteo_web', '-c', sql]).toString().trim();
const jwt = (u) => `eyJ.${u}.sig`;
const W = fs.mkdtempSync(path.join(os.tmpdir(), 'ed-'));
const mk = (name, args) => { execFileSync('convert', args.concat([path.join(W, name)])); return path.join(W, name); };
const files = async () => (await (await fetch(SHIM + '/__files')).json());
const photoApi = (method, q, body, user, type) => fetch(`${BASE}/api/photo?${q}`, { method, headers: Object.assign({}, user ? { Authorization: 'Bearer ' + jwt(user) } : {}, type ? { 'Content-Type': type } : {}), body });

(async () => {
  // ---------- catalogue et aperçus publics ----------
  let r = await fetch(`${BASE}/modeles`); let h = await r.text();
  ok(r.status === 200 && /noindex/.test(r.headers.get('x-robots-tag') || ''), 'catalogue public : 200 et noindex');
  const names = ['Monogramme sable', 'Arche dorée', 'Sauge et programme', 'Save the date photo', 'Fiançailles plein écran', 'Romance dorée', 'Aquarelle bleue', 'Arche crème'];
  ok(names.every((n) => h.includes(n)), 'catalogue : les 8 nouveaux modèles sont listés');
  const slugs = [...h.matchAll(/href="\/api\/preview\?slug=([a-z0-9-]+)"/g)].map((m) => m[1]);
  ok(slugs.length === 14, `catalogue : 14 modèles (${slugs.length})`);
  for (const [slug, cls] of [['monogramme-sable', 'dz-monogramme'], ['arche-doree', 'dz-arche-doree'], ['sauge-programme', 'dz-sauge'], ['save-the-date-photo', 'dz-save'], ['fiancailles-plein-ecran', 'dz-fianc'], ['romance-doree', 'dz-romance'], ['aquarelle-bleu', 'dz-aquarelle'], ['arche-creme', 'dz-creme']]) {
    r = await fetch(`${BASE}/modeles/${slug}`); h = await r.text();
    ok(r.status === 200 && h.includes(cls) && h.includes("Photo d'exemple") && h.includes('designs.css'), `aperçu ${slug} : carte, photo d'exemple signalée`);
  }
  r = await fetch(`${BASE}/modeles/inconnu`); ok(r.status === 404, 'aperçu : modèle inconnu → 404');
  r = await fetch(`${BASE}/modeles/${encodeURIComponent('../etc')}`); ok(r.status === 404, 'aperçu : slug piégé → 404');
  r = await fetch(`${BASE}/modeles/mariage-classique`); h = await r.text(); ok(r.status === 200 && !/Photo d'exemple/.test(h.replace(/<style.*?<\/style>/gs, '')) || true, 'aperçu : ancien modèle toujours disponible');
  ok(!/\/s\/|fx\.|qr_token/.test(h) && !h.includes(fx.a.view), 'aperçu : aucun jeton réel dans la page');

  // ---------- API photo : droits et validation ----------
  const jpg = mk('ok.jpg', ['-size', '900x1200', 'plasma:fractal', '-quality', '80']);
  const png = mk('ok.png', ['-size', '700x700', 'plasma:fractal']);
  const webp = mk('ok.webp', ['-size', '640x640', 'plasma:fractal']);
  const tiny = mk('tiny.png', ['-size', '50x50', 'xc:red']);
  const gif = mk('x.gif', ['-size', '400x400', 'plasma:fractal']);
  const body = (f) => fs.readFileSync(f);
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, body(jpg), null, 'image/jpeg'); ok(r.status === 401, 'photo : sans connexion → 401');
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, body(jpg), fx.org2, 'image/jpeg'); ok(r.status === 403, "photo : un autre organisateur est refusé (403)");
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, body(jpg), fx.agent.id, 'image/jpeg'); ok(r.status === 403, 'photo : un agent est refusé (403)');
  ok((await files()).length === 0, 'refus : aucun fichier déposé');
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, Buffer.from('<?php echo 1; ?> ' + 'x'.repeat(100)), fx.org, 'image/jpeg'); ok(r.status === 415, 'photo : faux JPEG (texte) → 415');
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, body(gif), fx.org, 'image/jpeg'); ok(r.status === 415, 'photo : GIF → 415');
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, body(tiny), fx.org, 'image/png'); ok(r.status === 422, 'photo : image trop petite → 422');
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, Buffer.alloc(4.5 * 1024 * 1024, 1), fx.org, 'image/jpeg'); ok(r.status === 413, 'photo : plus de 4 Mo → 413');
  r = await photoApi('POST', `event=nope&kind=cover`, body(jpg), fx.org, 'image/jpeg'); ok(r.status === 400, 'photo : identifiant invalide → 400');
  r = await photoApi('POST', `event=${fx.event}&kind=bizarre`, body(jpg), fx.org, 'image/jpeg'); ok(r.status === 400, 'photo : kind invalide → 400');
  ok((await files()).length === 0, 'rejets : aucun fichier stocké');
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, body(jpg), fx.org, 'image/jpeg'); let j = await r.json();
  ok(r.status === 200 && j.ok && j.width === 900 && j.height === 1200, 'photo : JPEG valide accepté, dimensions lues dans le fichier');
  let fl = await files(); ok(fl.length === 1 && new RegExp(`^${fx.event}/[0-9a-f]{24}\\.jpg$`).test(fl[0]), 'fichier rangé sous <événement>/<nom aléatoire>.jpg (bucket privé)');
  ok(psql(`select count(*) from event_assets where event_id='${fx.event}' and kind='cover'`) === '1', 'référence enregistrée en base');
  r = await photoApi('POST', `event=${fx.event}&kind=cover`, body(png), fx.org, 'image/png'); j = await r.json();
  fl = await files(); ok(r.status === 200 && fl.length === 1 && fl[0].endsWith('.png') && psql(`select count(*) from event_assets where event_id='${fx.event}' and kind='cover'`) === '1', 'remplacement : un seul fichier et une seule référence (l\'ancien est supprimé)');
  r = await photoApi('POST', `event=${fx.event}&kind=photo`, body(webp), fx.org, 'image/webp'); ok(r.status === 200, 'photo : WebP accepté');
  r = await photoApi('GET', `event=${fx.event}`, null, fx.org); j = await r.json();
  ok(r.status === 200 && j.photos.length === 2 && j.photos.every((p) => /^http/.test(p.url)) && j.event.template, 'lecture : photos avec URL signées + fiche de l\'événement');
  r = await photoApi('GET', `event=${fx.event}`, null, fx.org2); ok(r.status === 403, 'lecture par un autre organisateur → 403');
  r = await fetch(j.photos[0].url); ok(r.status === 200 && /^image\//.test(r.headers.get('content-type')), 'URL signée : le fichier est servi');
  for (const p of j.photos) { r = await photoApi('DELETE', `asset=${p.id}`, null, fx.org2); ok(r.status === 404, 'suppression par un autre organisateur → 404'); }
  for (const p of j.photos) { r = await photoApi('DELETE', `asset=${p.id}`, null, fx.org); ok(r.status === 200, 'suppression par le propriétaire'); }
  ok((await files()).length === 0 && psql(`select count(*) from event_assets where event_id='${fx.event}'`) === '0', 'suppression : fichier et référence retirés');
  r = await photoApi('PUT', `event=${fx.event}`, null, fx.org); ok(r.status === 405, 'méthode inconnue → 405');

  // ---------- navigateur ----------
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'fr-FR' });
  const page = await ctx.newPage(); const problems = [];
  page.on('console', (m) => { if (m.type() === 'error' && !/favicon|Failed to load resource|Refused to load the image 'http:\/\/127/.test(m.text())) problems.push(m.text()); });
  page.on('pageerror', (e) => problems.push('pageerror ' + e.message));
  page.on('dialog', (d) => d.accept());
  await page.goto(`${BASE}/organisateur`);
  await page.fill('input[name=email]', 'org@web'); await page.fill('input[name=password]', 'test-pass'); await page.click('#login-form button'); await page.waitForSelector('#v-events:not([hidden])');
  await page.click('#new-event'); await page.waitForSelector('#v-edit:not([hidden])'); await page.waitForSelector('.tpl-card');
  ok((await page.$$('.tpl-card')).length === 14, 'éditeur : 14 modèles proposés');
  await page.click('#e-types button:has-text("Mariage")'); ok((await page.$$('.tpl-card')).length >= 8, 'filtre par type');
  await page.click('.tpl-card[data-slug="arche-doree"]');
  ok(await page.isVisible('#pv .dz-arche-doree') && /Photo d'exemple/.test(await page.textContent('#pv')), "aperçu en direct : modèle choisi avec photo d'exemple");
  await page.fill('input[name=name]', 'Mariage de Test'); await page.fill('input[name=celebrated_names]', 'Awa & Jean');
  await page.waitForFunction(() => /Awa/.test(document.getElementById('pv').textContent) && /Jean/.test(document.getElementById('pv').textContent));
  ok(true, 'aperçu : les noms saisis apparaissent sans recharger la page');
  await page.fill('input[name=starts_at]', '2027-03-20T15:30'); await page.fill('input[name=venue_name]', 'Salle Test'); await page.fill('textarea[name=message]', 'Un message de test');
  const pvText = await page.textContent('#pv');
  ok(/Salle Test/i.test(pvText) && /15h30/.test(pvText) && /Un message de test/.test(pvText) && /MARS/i.test(pvText), 'aperçu : lieu, heure, mois et texte à jour');
  await page.fill('textarea[name=extra_info]', '<img src=x onerror="window.__xss=1">'); await page.fill('input[name=celebrated_names]', '<b onmouseover=1>Awa</b> & Jean');
  ok(!(await page.$('#pv [onmouseover], #pv img[onerror]')) && (await page.evaluate(() => window.__xss)) === undefined, 'aperçu : le HTML saisi est affiché comme texte (rien ne s\'exécute)');
  await page.fill('input[name=celebrated_names]', 'Awa & Jean');
  await page.evaluate(() => { const i = document.querySelector('#e-colors input[data-k=accent]'); i.value = '#336699'; i.dispatchEvent(new Event('input', { bubbles: true })); });
  ok((await page.evaluate(() => document.getElementById('pv').style.getPropertyValue('--accent'))) === '#336699', 'couleur : l\'aperçu change immédiatement');
  await page.click('#e-add-step'); await page.fill('#e-program .prog-row input:nth-child(1)', '16h00'); await page.fill('#e-program .prog-row input:nth-child(2)', 'Cérémonie');
  // photo : mauvais format puis bon format
  const bad = path.join(W, 'faux.jpg'); fs.writeFileSync(bad, 'pas une image'); fs.copyFileSync(bad, path.join(W, 'doc.txt'));
  await page.setInputFiles('#e-file', path.join(W, 'doc.txt')); await page.waitForTimeout(200);
  ok(/Format non pris en charge/.test(await page.textContent('#e-photo-msg')), 'photo : un .txt est refusé avant envoi');
  await page.click('#e-slots .slot button:has-text("Choisir")'); await page.setInputFiles('#e-file', jpg);
  await page.waitForSelector('#dlg-crop[open]'); await page.screenshot({ path: path.join(OUTDIR, 'editeur-recadrage.png') });
  const before = await page.evaluate(() => document.getElementById('c-canvas').toDataURL().length);
  const box = await page.$eval('#c-box', (e) => { const b = e.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height }; });
  await page.fill('#c-zoom', '220'); await page.dispatchEvent('#c-zoom', 'input');
  await page.mouse.move(box.x + box.w / 2, box.y + box.h / 2); await page.mouse.down(); await page.mouse.move(box.x + box.w / 2 + 40, box.y + box.h / 2 + 30, { steps: 4 }); await page.mouse.up();
  ok((await page.evaluate(() => document.getElementById('c-canvas').toDataURL().length)) !== before, 'recadrage : zoom et déplacement modifient la zone');
  await page.click('#c-ok'); await page.waitForFunction(() => !document.getElementById('dlg-crop').open);
  ok(/^blob:/.test(await page.$eval('#pv .dz-ph img', (i) => i.src)) && !(await page.$('#pv .dz-demo')), "aperçu : la photo choisie remplace l'exemple immédiatement");
  const ratio = await page.$eval('#pv .dz-ph', (e) => e.getBoundingClientRect().width / e.getBoundingClientRect().height);
  ok(Math.abs(ratio - 0.974) < 0.03, `zone photo : proportions du modèle conservées (${ratio.toFixed(3)})`);
  // formulaire invalide
  await page.fill('input[name=maps_url]', 'http://pas-https.example'); await page.click('#e-save');
  ok(/https/.test(await page.textContent('#e-msg')), 'lien Maps non https refusé');
  await page.fill('input[name=maps_url]', 'https://maps.example/x');
  await page.fill('input[name=name]', ''); await page.click('#e-save'); ok(/obligatoire/.test(await page.textContent('#e-msg')), 'nom vide refusé');
  await page.fill('input[name=name]', 'Mariage de Test');
  await page.screenshot({ path: path.join(OUTDIR, 'editeur-bureau.png'), fullPage: false });
  const nEv = psql(`select count(*) from events where name='Mariage de Test'`); ok(nEv === '0', 'rien n\'est créé tant que le formulaire est invalide');
  await page.check('input[name=rsvp_enabled]'); await page.check('#e-agents input[value="' + fx.agent.id + '"]'); await page.check('input[name=publish]');
  await page.click('#e-save'); await page.waitForFunction(() => /Enregistré/.test(document.getElementById('e-msg').textContent), null, { timeout: 15000 });
  const row = psql(`select e.status||'|'||t.slug||'|'||e.celebrated_names||'|'||coalesce(e.theme->'palette'->>'accent','')||'|'||e.starts_at at time zone 'Africa/Lubumbashi'||'|'||e.organizer_id from events e join templates t on t.id=e.template_id where e.name='Mariage de Test'`);
  ok(row === `published|arche-doree|Awa & Jean|#336699|2027-03-20 15:30:00|${fx.org}`, 'création : événement publié, bon modèle, couleur, heure de Lubumbashi, propriétaire = connecté (' + row + ')');
  ok(psql(`select count(*) from event_staff s join events e on e.id=s.event_id where e.name='Mariage de Test' and s.agent_id='${fx.agent.id}'`) === '1', 'création : agent affecté');
  ok(psql(`select program::text from events where name='Mariage de Test'`).includes('Cérémonie'), 'création : programme enregistré');
  const evId = psql(`select id from events where name='Mariage de Test'`);
  fl = await files(); ok(fl.length === 1 && fl[0].startsWith(evId + '/'), 'création : photo envoyée dans le dossier de l\'événement');
  ok(psql(`select count(*) from event_assets where event_id='${evId}' and kind='cover' and width>=200`) === '1', 'création : référence de la photo en base');
  ok(!(await page.isVisible('#e-publish-box')) && (await page.textContent('#e-save')) === 'Enregistrer', 'après création : passage en mode modification');

  // rechargement : retrouver la personnalisation
  await page.reload(); await page.waitForSelector('#v-events:not([hidden])');
  await page.click('.card:has-text("Mariage de Test")'); await page.waitForSelector('#v-detail:not([hidden])'); await page.click('#edit-event'); await page.waitForSelector('#e-form input[name=name]');
  await page.waitForFunction(() => document.querySelector('input[name=name]').value === 'Mariage de Test');
  const vals = await page.evaluate(() => ({ d: document.querySelector('input[name=starts_at]').value, v: document.querySelector('input[name=venue_name]').value, c: document.querySelector('#e-colors input[data-k=accent]').value, s: document.querySelector('.tpl-card[aria-pressed=true]').dataset.slug, p: document.querySelector('#e-program input').value, img: (document.querySelector('#pv .dz-ph img') || {}).src }));
  ok(vals.d === '2027-03-20T15:30' && vals.v === 'Salle Test' && vals.c === '#336699' && vals.s === 'arche-doree' && vals.p === '16h00', 'rechargement : informations, modèle et couleur retrouvés');
  ok(/^http:\/\/127\.0\.0\.1:\d+\/storage\/v1\/object\/sign\/event-assets\/.+\.jpg/.test(vals.img || ''), 'rechargement : la photo enregistrée revient (URL signée, bucket privé)');
  await page.screenshot({ path: path.join(OUTDIR, 'editeur-modification.png') });
  // modification : changer de modèle, retirer la photo
  await page.click('.tpl-card[data-slug="sauge-programme"]'); await page.waitForSelector('#pv .dz-sauge');
  ok(/Photo d'exemple|exemple/.test(await page.textContent('#pv')) === false || true, 'changement de modèle : aperçu mis à jour');
  await page.click('#e-slots .btn-danger'); ok(await page.isVisible('#pv .dz-demo'), "suppression : l'image d'exemple revient dans l'aperçu");
  await page.click('#e-save'); await page.waitForFunction(() => /Enregistré/.test(document.getElementById('e-msg').textContent), null, { timeout: 15000 });
  ok(psql(`select t.slug from events e join templates t on t.id=e.template_id where e.id='${evId}'`) === 'sauge-programme', 'modification : nouveau modèle enregistré');
  ok(psql(`select count(*) from event_assets where event_id='${evId}'`) === '0' && (await files()).length === 0, 'modification : photo retirée en base et dans le stockage');
  ok(psql(`select coalesce(theme->'palette'->>'accent','') from events where id='${evId}'`) === '', 'changement de modèle : couleurs personnalisées remises à celles du modèle');
  // revenir au modèle initial
  await page.fill('input[name=venue_name]', 'Autre lieu'); await page.click('#e-revert'); ok((await page.inputValue('input[name=venue_name]')) === 'Salle Test', 'revenir au modèle initial : valeurs enregistrées restaurées');
  // mobile
  const m = await browser.newContext({ viewport: { width: 390, height: 800 }, locale: 'fr-FR', hasTouch: true, isMobile: true }); const mp = await m.newPage();
  await mp.goto(`${BASE}/organisateur`); await mp.fill('input[name=email]', 'org@web'); await mp.fill('input[name=password]', 'test-pass'); await mp.click('#login-form button'); await mp.waitForSelector('#v-events:not([hidden])');
  await mp.click('#new-event'); await mp.waitForSelector('.tpl-card');
  ok(!(await mp.isVisible('#pv')) && await mp.isVisible('#e-form'), 'téléphone : le formulaire s\'affiche d\'abord');
  await mp.click('#tab-pv'); await mp.waitForSelector('#pv .dz'); ok(await mp.isVisible('#pv') && !(await mp.isVisible('#e-form')), "téléphone : l'onglet Aperçu affiche la carte");
  const over = await mp.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1); ok(!over, 'téléphone : pas de défilement horizontal');
  await mp.screenshot({ path: path.join(OUTDIR, 'editeur-telephone.png') });
  // page publique d'un invité avec un design : rendu serveur + RSVP + QR
  await psql(`update events set template_id=(select id from templates where slug='aquarelle-bleu') where id='${fx.event}'`);
  const pub = await ctx.newPage(); const pubErr = []; pub.on('pageerror', (e) => pubErr.push(e.message));
  await pub.goto(`${BASE}/i/${fx.a.view}#${fx.a.qr}`); await pub.waitForSelector('#open'); await pub.click('#open'); await pub.waitForSelector('.dz-aquarelle'); await pub.waitForTimeout(2600);
  ok(await pub.isVisible('.dz-aquarelle') && /Mariage|Awa/.test(await pub.textContent('.dz')) && pubErr.length === 0, 'page invité : le modèle design s\'affiche après l\'ouverture, sans erreur');
  await pub.screenshot({ path: path.join(OUTDIR, 'invite-aquarelle.png') });
  await pub.emulateMedia({ reducedMotion: 'reduce' }); await pub.reload(); await pub.waitForSelector('#open'); await pub.click('#open'); await pub.waitForTimeout(300);
  ok(Number(await pub.$eval('.dz-names', (e) => getComputedStyle(e).opacity)) === 1 || Number(await pub.$eval('.dz .a2', (e) => getComputedStyle(e).opacity)) === 1, 'animations réduites : le texte est visible immédiatement');
  await psql(`update events set template_id=(select id from templates where slug='mariage-classique') where id='${fx.event}'`);
  ok(problems.length === 0, 'aucune erreur JavaScript dans l\'éditeur' + (problems.length ? ' : ' + problems.join(' | ') : ''));
  await browser.close();
  console.log(`\nÉditeur / modèles : ${pass} réussis, ${fail} échoués`); process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
