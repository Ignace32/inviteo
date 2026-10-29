// Génère des QR codes (JSON) pour un échantillon varié de textes et de niveaux.
const QR = require('../../assets/qr.js');
const out = [];
const levels = ['L', 'M', 'Q', 'H'];
function rnd(n, seed) { let s = seed, r = ''; const a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'; for (let i = 0; i < n; i++) { s = (s * 1103515245 + 12345) & 0x7fffffff; r += a[s % a.length]; } return r; }
const samples = [
  'A', 'Invitéo', 'https://inviteo-dun.vercel.app/s/' + rnd(43, 7), 'https://inviteo-dun.vercel.app/i/' + rnd(43, 9) + '#' + rnd(43, 11),
  'Élie — Grâce & David : « Chaque invitation ouvre un souvenir. »', '日本語のテキスト', '0123456789'
];
for (let n = 1; n <= 700; n += 23) samples.push(rnd(n, n));        // longueurs variées => versions 1 à ~22
for (const t of samples) for (const l of levels) {
  try { const m = QR.toMatrix(t, l); out.push({ text: t, level: l, version: m.version, size: m.size, rows: m.modules.map(r => r.map(c => c ? 1 : 0).join('')) }); }
  catch (e) { out.push({ text: t, level: l, error: String(e.message) }); }
}
require('fs').writeFileSync(process.argv[2], JSON.stringify(out));
console.log('codes générés :', out.length, '| erreurs attendues (trop long) :', out.filter(o => o.error).length);
