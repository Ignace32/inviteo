'use strict';
// Espace organisateur : vrai navigateur, vraie base (via le relais), vrais droits (rôle authenticated + RLS).
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs'), path = require('path'), os = require('os');
const [, , FIX, OUTDIR] = process.argv;
const fx = JSON.parse(fs.readFileSync(FIX));
const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3100);
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('PASS ', m); } else { fail++; console.log('FAIL ', m); } };
const psql = (sql) => execFileSync('psql', ['-X', '-q', '-At', '-d', 'inviteo_web', '-c', sql]).toString().trim();
const jwt = (u) => `eyJ.${u}.sig`;
const api = (fn, args, user) => fetch(`${BASE}/api/organizer`, { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, user ? { Authorization: 'Bearer ' + jwt(user) } : {}), body: JSON.stringify({ fn, args }) });

(async () => {
  // --- API : liste blanche et droits ---
  let r = await api('organizer_events', {}); ok(r.status === 401, 'API organisateur : sans connexion → 401');
  r = await api('scan_invitation', {}, fx.org); ok(r.status === 400, 'API : fonction hors liste blanche refusée (400)');
  r = await api('event_guests', { p_event_id: fx.event, x: 1 }, fx.org); ok(r.status === 400, 'API : argument inattendu refusé (400)');
  r = await api('event_guests', { p_event_id: 'nope' }, fx.org); ok(r.status === 400, 'API : identifiant mal formé refusé (400)');
  r = await api('import_guests', { p_event_id: fx.event, p_rows: [{ full_name: { a: 1 } }] }, fx.org); ok(r.status === 400, 'API : ligne d\'import imbriquée refusée (400)');
  r = await api('import_guests', { p_event_id: fx.event, p_rows: Array.from({ length: 2001 }, () => ({ full_name: 'x' })) }, fx.org); ok(r.status === 400, 'API : plus de 2000 lignes refusé (400)');
  r = await api('event_guests', { p_event_id: fx.event }, fx.agent.id); ok(r.status === 403, "API : un agent ne lit pas la liste des invités (403)");
  r = await api('event_guests', { p_event_id: fx.event }, fx.org2); ok(r.status === 403, "API : un autre organisateur est refusé (403)");
  r = await api('import_guests', { p_event_id: fx.event, p_rows: [{ full_name: 'Intrus' }] }, fx.org2); ok(r.status === 403, "API : import par un autre organisateur refusé (403)");
  ok(psql(`select count(*) from guests where full_name='Intrus'`) === '0', 'aucun invité créé par les refus');
  const vj = JSON.parse(fs.readFileSync(path.join(__dirname, '../../vercel.json')));
  const rule = vj.headers.find((h) => h.source === '/organisateur');
  ok(rule && /script-src 'self'/.test(rule.headers.find((x) => x.key === 'Content-Security-Policy').value) && rule.headers.some((x) => x.key === 'Cache-Control' && /no-store/.test(x.value)), 'vercel.json : CSP sans script en ligne et no-store pour /organisateur');

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 900 }, acceptDownloads: true, locale: 'fr-FR' });
  const page = await ctx.newPage(); const problems = [];
  page.on('console', (m) => { if (m.type() === 'error' && !/favicon|Failed to load resource/.test(m.text())) problems.push(m.text()); });
  page.on('pageerror', (e) => problems.push('pageerror ' + e.message));
  page.on('dialog', (d) => d.accept());
  const login = async (email, pw) => { await page.fill('input[name=email]', email); await page.fill('input[name=password]', pw); await page.click('#login-form button'); };

  await page.goto(`${BASE}/organisateur`);
  await login('org@web', 'mauvais'); await page.waitForFunction(() => /incorrect/.test(document.getElementById('login-msg').textContent));
  ok(!(await page.isVisible('#v-events')), 'mauvais mot de passe : pas d\'accès');
  await login('org@web', 'test-pass'); await page.waitForSelector('#v-events:not([hidden])');
  const cards = await page.$$eval('.card b', (n) => n.map((x) => x.textContent));
  ok(cards.includes('Mariage Awa & Jean') && !cards.includes('Autre fête'), 'liste : ses événements uniquement');
  await page.click('.card'); await page.waitForSelector('#v-detail:not([hidden])'); await page.waitForFunction(() => document.querySelectorAll('.guest').length > 0);

  // statistiques = base
  const total = psql(`select count(*) from guests where event_id='${fx.event}'`), ent = psql(`select coalesce(sum(entries_used),0) from invitations where event_id='${fx.event}'`);
  const tiles = await page.$$eval('.stat', (n) => n.map((x) => [x.querySelector('b').textContent, x.querySelector('span').textContent]));
  ok(tiles.find((t) => t[1] === 'invités')[0] === total, `tuile « invités » = base (${total})`);
  ok(tiles.find((t) => t[1] === 'entrées validées')[0].startsWith(ent + ' /'), `tuile « entrées validées » = base (${ent})`);
  ok((await page.$$('.guest')).length === Number(total), 'une ligne par invité');
  ok(!(await page.$('.guests b')), "noms affichés en texte : aucun HTML interprété (<b> du nom d'invité)");
  ok((await page.textContent('.guests')).includes("Marie <b>Kabila</b> O'Neil"), "nom à balises affiché tel quel");
  await page.screenshot({ path: path.join(OUTDIR, '7-organisateur.png'), fullPage: true });

  // recherche / filtre
  await page.fill('#search', 'kabila'); ok((await page.$$('.guest')).length === 1, 'recherche « kabila » (sans tenir compte de la casse)');
  await page.fill('#search', 'ELODIE'); ok((await page.$$('.guest')).length === 1, 'recherche sans accents : « ELODIE » trouve « Élodie »');
  await page.fill('#search', ''); await page.selectOption('#filter', 'none');
  const none = await page.$$eval('.guest .n:nth-child(1)', (n) => n.length);
  ok((await page.$$('.guest')).length === Number(psql(`select count(*) from guests g where event_id='${fx.event}' and not exists (select 1 from invitations i where i.guest_id=g.id and i.status in ('valid','used','expired'))`)), 'filtre « Sans invitation » = base');
  await page.selectOption('#filter', 'all');

  // import CSV
  const parse = await page.evaluate(() => window.__org.parseCsv('nom;tel\n"A, B ""x""";123\n'));
  ok(parse.rows && parse.rows[0].full_name === 'A, B "x"' && parse.rows[0].phone === '123', 'lecteur CSV : séparateur « ; » et guillemets doublés');
  ok((await page.evaluate(() => window.__org.parseCsv('foo;bar\n1;2\n'))).error, 'lecteur CSV : colonne « nom » obligatoire');
  const before = Number(total);
  await page.click('#open-import');
  const csv = 'Nom;Téléphone;E-mail;Personnes;Billet\n"Dupont, Jean ""JD""";+243 99 000 11 22;jd@exemple.cd;2;VIP\nÈve Kasongo;;;;\nPatrick Mwamba;;;1;standard\n;+243990000000;;1;\nTel Bad;abc;;1;\nTrop Grand;;;99;\n=1+1;;;1;\n';
  await page.fill('#i-text', csv); await page.waitForFunction(() => /7 ligne/.test(document.getElementById('i-preview').textContent));
  ok(true, 'aperçu : 7 lignes détectées (en-tête « Téléphone », « Personnes » reconnus)');
  await page.click('#i-go'); await page.waitForFunction(() => /ajouté/.test(document.getElementById('i-result').textContent));
  const res = await page.textContent('#i-result');
  ok(/3 invité\(s\) ajouté\(s\), 4 ligne\(s\) refusée\(s\)/.test(res), 'import : 3 ajoutés, 4 refusés');
  ok(/déjà dans la liste/.test(res) && /nom manquant/.test(res) && /téléphone invalide/.test(res) && /nombre de personnes invalide/.test(res), 'motifs de refus lisibles en français');
  ok(psql(`select count(*) from guests where event_id='${fx.event}'`) === String(before + 3), 'base : +3 invités');
  ok(psql(`select party_size||'|'||ticket_type from guests where full_name='Dupont, Jean "JD"'`) === '2|VIP', 'virgule et guillemets conservés, billet VIP, 2 personnes');
  ok(psql(`select count(*) from guests where full_name='=1+1'`) === '1', 'texte « =1+1 » stocké tel quel');
  await page.click('#i-close');

  // émission + PDF
  await page.fill('#search', 'Dupont'); await page.waitForFunction(() => document.querySelectorAll('.guest').length === 1);
  await page.click('.guest .btn:has-text("Émettre")');
  await page.waitForSelector('#dlg-ticket[open]');
  const link = await page.inputValue('#t-link');
  ok(/\/i\/[\w-]{20,}#[\w-]{20,}$/.test(link), 'dialogue : lien /i/<page>#<QR>');
  const wa = await page.getAttribute('#t-wa', 'href');
  ok(wa.startsWith('https://wa.me/243990001122?text='), 'WhatsApp : numéro nettoyé (chiffres seuls) et message encodé');
  ok(decodeURIComponent(wa.split('text=')[1]).includes(link) && decodeURIComponent(wa.split('text=')[1]).startsWith('Bonjour Dupont,'), 'WhatsApp : le message contient le lien');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#t-pdf')]);
  const pdfPath = path.join(os.tmpdir(), 'org-' + Date.now() + '.pdf'); await dl.saveAs(pdfPath);
  const buf = fs.readFileSync(pdfPath);
  ok(buf.slice(0, 5).toString() === '%PDF-' && /invitation-dupont-jean-jd\.pdf/.test(dl.suggestedFilename()), 'PDF téléchargé avec un nom de fichier sûr');
  ok(/Dupont, Jean "JD"/.test(execFileSync('pdftotext', [pdfPath, '-']).toString()), 'PDF : le nom de l\'invité y figure');
  const invOf = () => psql(`select i.status||'|'||i.id from invitations i join guests g on g.id=i.guest_id where g.full_name='Dupont, Jean "JD"' and i.status in ('valid','used')`);
  ok(invOf().startsWith('valid|'), 'base : invitation active créée');
  await page.click('#t-close'); await page.waitForFunction(() => /Invitation émise/.test(document.querySelector('.guest').textContent));
  ok(true, 'la ligne passe à « Invitation émise »');
  const oldView = link.match(/\/i\/([\w-]+)#/)[1];
  ok((await fetch(`${BASE}/i/${oldView}`)).status === 200, 'le lien émis ouvre la page');

  // réémission
  await page.click('.guest .btn:has-text("Réémettre")'); await page.waitForSelector('#dlg-ticket[open]');
  const link2 = await page.inputValue('#t-link'); await page.click('#t-close');
  ok(link2 !== link && (await fetch(`${BASE}/i/${oldView}`)).status === 410, 'réémission : ancien lien révoqué (410), nouveau lien différent');
  ok(psql(`select count(*) from invitations i join guests g on g.id=i.guest_id where g.full_name='Dupont, Jean "JD"' and i.status in ('valid','used')`) === '1', 'une seule invitation active');

  // révocation
  await page.click('.guest .btn:has-text("Révoquer")'); await page.waitForFunction(() => /Pas d'invitation/.test(document.querySelector('.guest').textContent));
  const v2 = link2.match(/\/i\/([\w-]+)#/)[1];
  ok((await fetch(`${BASE}/i/${v2}`)).status === 410 && psql(`select count(*) from invitations i join guests g on g.id=i.guest_id where g.full_name='Dupont, Jean "JD"' and i.status='revoked'`) === '2', 'révocation : lien inactif (410), 2 invitations révoquées en base');

  // RSVP / entrées visibles : invité « Marie » a un statut d'entrée issu des scans
  await page.fill('#search', 'kabila');
  const mt = await page.textContent('.guest');
  const used = psql(`select entries_used||'/'||max_entries from invitations where id='${fx.a.id}'`);
  ok(mt.includes('Entré(e) ' + used), `statut d'entrée visible (${used}) et premier passage affiché`);
  ok(/Ne vient pas|Vient|Pas de réponse/.test(mt), 'réponse RSVP visible');

  // session
  await page.reload(); await page.waitForSelector('#v-events:not([hidden])', { timeout: 8000 }); ok(true, 'rechargement : session reprise');
  await page.click('#logout'); ok(await page.isVisible('#login-form'), 'déconnexion');

  // autre organisateur
  await login('org2@web', 'test-pass'); await page.waitForSelector('#v-events:not([hidden])');
  const c2 = await page.$$eval('.card b', (n) => n.map((x) => x.textContent));
  ok(c2.includes('Autre fête') && !c2.includes('Mariage Awa & Jean'), "un autre organisateur ne voit que ses événements");

  ok(problems.length === 0, 'aucune erreur console' + (problems.length ? ' : ' + problems.join(' | ') : ''));
  await browser.close();
  console.log(`\nRésultat organisateur : ${pass} réussis, ${fail} échoués`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
