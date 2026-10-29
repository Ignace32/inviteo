'use strict';
// Billet PDF : émission authentifiée, PDF valide, texte, QR relu par OpenCV sur l'image rendue,
// jeton valable en base, réémission qui invalide l'ancien billet.
const { execFileSync } = require('child_process');
const fs = require('fs'), path = require('path'), os = require('os');
const [, , FIX, OUTDIR] = process.argv;
const fx = JSON.parse(fs.readFileSync(FIX));
const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3100), SITE = process.env.PUBLIC_SITE_URL;
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('PASS ', m); } else { fail++; console.log('FAIL ', m); } };
const psql = (sql) => execFileSync('psql', ['-X', '-q', '-At', '-d', 'inviteo_web', '-c', sql]).toString().trim();
const jwt = (uid) => `eyJ.${uid}.sig`;
const call = (body, hd) => fetch(`${BASE}/api/ticket`, { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, hd), body: JSON.stringify(body) });
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pdf-'));

function decodeQr(pdfFile) {
  execFileSync('pdftoppm', ['-r', '300', '-png', '-singlefile', pdfFile, pdfFile + '.page']);
  return execFileSync('python3', ['-I', '-c', `
import cv2,sys
img=cv2.imread(sys.argv[1])
d=cv2.QRCodeDetectorAruco()
for s in (1.0,0.7,0.5):
    im=cv2.resize(img,None,fx=s,fy=s,interpolation=cv2.INTER_AREA) if s!=1.0 else img
    t=d.detectAndDecode(im)[0]
    if t: print(t); break
`, pdfFile + '.page.png']).toString().trim();
}

(async () => {
  const H = { Authorization: 'Bearer ' + jwt(fx.org) };
  let r = await call({ guest_id: fx.guest });
  ok(r.status === 401, 'sans jeton de connexion : 401');
  r = await call({}, H); ok(r.status === 400, 'corps vide : 400');
  r = await call({ guest_id: fx.guest, invitation_id: fx.a.id }, H); ok(r.status === 400, 'guest_id ET invitation_id : 400');
  r = await call({ guest_id: 'pas-un-uuid' }, H); ok(r.status === 400, 'identifiant mal formé : 400');
  r = await call({ guest_id: fx.guest }, Object.assign({ Origin: 'https://evil.example' }, H)); ok(r.status === 403, 'autre origine : 403');
  r = await call({ guest_id: fx.guest }, { Authorization: 'Bearer ' + jwt(fx.org2) });
  ok(r.status === 403, "un autre organisateur ne peut pas émettre pour cet invité : 403");
  ok(psql(`select count(*) from invitations where guest_id='${fx.guest}'`) === '0', 'aucune invitation créée par les refus');

  r = await call({ guest_id: fx.guest }, H);
  ok(r.status === 200 && r.headers.get('content-type') === 'application/pdf', 'émission : PDF renvoyé (200)');
  ok(/no-store/.test(r.headers.get('cache-control')), 'PDF : Cache-Control no-store');
  const buf = Buffer.from(await r.arrayBuffer());
  const f1 = path.join(tmp, 'billet1.pdf'); fs.writeFileSync(f1, buf);
  ok(buf.slice(0, 5).toString() === '%PDF-' && buf.slice(-6).toString().includes('%%EOF'), 'en-tête %PDF et fin %%EOF');
  let chk = ''; try { chk = execFileSync('qpdf', ['--check', f1], { stdio: ['ignore', 'pipe', 'pipe'] }).toString(); } catch (e) { chk = String(e.stdout) + String(e.stderr); }
  ok(/No syntax or stream encoding errors found/.test(chk), 'qpdf --check : aucune erreur de structure');
  ok(/pages: 1|1 page/i.test(execFileSync('qpdf', ['--show-npages', f1]).toString() + ' 1 page') && execFileSync('qpdf', ['--show-npages', f1]).toString().trim() === '1', 'une seule page');
  const txt = execFileSync('pdftotext', ['-layout', f1, '-']).toString();
  ok(txt.includes('Mariage Awa & Jean') && txt.includes('Salle Les Jardins'), 'texte : événement et lieu');
  ok(/Élodie/.test(txt) && /Tshisekedi/.test(txt), 'texte : nom de l\'invité avec accents, nom long entier');
  ok(/Valable pour 3 personnes/.test(txt), 'texte : nombre de personnes');
  ok(/décembre|janvier|février|mars|avril|mai|juin|juillet|août|septembre|octobre|novembre/i.test(txt), 'texte : date en français');
  const link = r.headers.get('x-invitation-link'), invId = r.headers.get('x-invitation-id');
  const [, viewTok, qrTok] = /\/i\/([\w-]+)#([\w-]+)$/.exec(link) || [];
  ok(!!qrTok && viewTok !== qrTok, 'lien renvoyé : /i/<jeton page>#<jeton QR>');
  ok(!buf.toString('latin1').includes(qrTok), 'le jeton du QR n\'est pas écrit en clair dans le PDF');
  const dec = decodeQr(f1);
  ok(dec === `${SITE}/s/${qrTok}`, 'QR du PDF (rendu 300 dpi) relu par OpenCV = adresse /s/<jeton>');
  ok(psql(`select count(*) from invitation_secrets where invitation_id='${invId}' and qr_token_hash = public.hash_token('${qrTok}')`) === '1', 'le jeton du QR correspond au hachage stocké en base');
  ok((await fetch(`${BASE}/i/${viewTok}`)).status === 200, 'le lien de la page fonctionne');
  fs.copyFileSync(f1 + '.page.png', path.join(OUTDIR, '4-billet-pdf.png'));

  // Réémission
  r = await call({ invitation_id: invId }, H);
  ok(r.status === 200, 'réémission : nouveau PDF (200)');
  const buf2 = Buffer.from(await r.arrayBuffer()); const f2 = path.join(tmp, 'billet2.pdf'); fs.writeFileSync(f2, buf2);
  const [, view2, qr2] = /\/i\/([\w-]+)#([\w-]+)$/.exec(r.headers.get('x-invitation-link')) || [];
  ok(qr2 && qr2 !== qrTok, 'réémission : nouveau jeton QR différent');
  ok(decodeQr(f2) === `${SITE}/s/${qr2}`, 'nouveau PDF : QR relu = nouveau jeton');
  ok((await fetch(`${BASE}/i/${viewTok}`)).status === 410, "l'ancien lien de page est révoqué (410)");
  ok((await fetch(`${BASE}/i/${view2}`)).status === 200, 'le nouveau lien fonctionne');
  ok(psql(`select count(*) from invitations where guest_id='${fx.guest}' and status in ('valid','used')`) === '1', 'une seule invitation active pour cet invité');
  r = await call({ invitation_id: invId }, { Authorization: 'Bearer ' + jwt(fx.org2) });
  ok(r.status === 403, "un autre organisateur ne peut pas réémettre : 403");

  console.log(`\nRésultat PDF : ${pass} réussis, ${fail} échoués`);
  fs.rmSync(tmp, { recursive: true, force: true });
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
