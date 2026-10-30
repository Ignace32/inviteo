'use strict';
// Générateur de billet PDF (A5) sans dépendance : écrit directement la structure PDF 1.4.
// Polices standard (Helvetica, Times) en WinAnsi ; le QR code est dessiné en VECTORIEL
// (rectangles), donc net à toute taille d'impression.
const AFM = require('./afm.json');
const QR = require('../../assets/qr.js');

const W = 419.53, H = 595.28; // A5 en points
const WIN = { 0x20AC: 128, 0x2018: 145, 0x2019: 146, 0x201C: 147, 0x201D: 148, 0x2013: 150, 0x2014: 151, 0x0152: 140, 0x0153: 156, 0x2026: 133 };

function toWin(s) {
  let out = '';
  for (const ch of String(s == null ? '' : s).normalize('NFC')) {
    const c = ch.codePointAt(0);
    if (c === 0x202F || c === 0x00A0) out += ' ';
    else if (c >= 32 && c < 127) out += ch;
    else if (c >= 160 && c <= 255) out += String.fromCharCode(c);
    else if (WIN[c]) out += String.fromCharCode(WIN[c]);
    else out += c < 32 ? ' ' : '?';
  }
  return out;
}
const width = (s, font, size) => { let w = 0; for (let i = 0; i < s.length; i++) w += AFM[font][s.charCodeAt(i)] || 500; return w * size / 1000; };
const pdfStr = (s) => '(' + s.replace(/[\\()]/g, '\\$&').replace(/[\r\n]/g, ' ') + ')';
const num = (n) => (Math.round(n * 100) / 100).toString();
const hex = (c) => [1, 3, 5].map((i) => num(parseInt(c.slice(i, i + 2), 16) / 255)).join(' ');

function wrap(text, font, size, maxW, maxLines) {
  const words = toWin(text).split(/\s+/).filter(Boolean), lines = [];
  let cur = '';
  for (let w of words) {
    while (width(w, font, size) > maxW) { // mot trop long : coupe
      let k = w.length; while (k > 1 && width(w.slice(0, k), font, size) > maxW) k--;
      if (cur) { lines.push(cur); cur = ''; }
      lines.push(w.slice(0, k)); w = w.slice(k);
    }
    const t = cur ? cur + ' ' + w : w;
    if (width(t, font, size) <= maxW) cur = t; else { lines.push(cur); cur = w; }
  }
  if (cur) lines.push(cur);
  if (lines.length > maxLines) { const l = lines.slice(0, maxLines); l[maxLines - 1] = l[maxLines - 1].replace(/\s*\S*$/, '') + '...'; return l; }
  return lines;
}

function fmtDate(iso, tz) {
  const o = (opt) => { try { return new Intl.DateTimeFormat('fr-FR', Object.assign({ timeZone: tz }, opt)).format(new Date(iso)); } catch (_) { return new Intl.DateTimeFormat('fr-FR', Object.assign({ timeZone: 'Africa/Lubumbashi' }, opt)).format(new Date(iso)); } };
  const d = o({ weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  return toWin(d.charAt(0).toUpperCase() + d.slice(1) + ' à ' + o({ hour: '2-digit', minute: '2-digit' }).replace(':', 'h'));
}

function buildTicketPdf(t) {
  // t : { guest_name, max_entries, event_name, celebrated_names, starts_at, timezone, venue_name, address, qrText }
  const ink = '#25221F', muted = '#6B655E', accent = '#E86D32', bg = '#FAF7F1';
  const ops = [];
  const F = { H: '/F1', HB: '/F2', T: '/F3', TB: '/F4' };
  const NAME = { '/F1': 'Helvetica', '/F2': 'Helvetica-Bold', '/F3': 'Times-Roman', '/F4': 'Times-Bold' };
  const text = (s, x, y, f, size, color, align) => {
    const w = width(s, NAME[f], size), px = align === 'c' ? x - w / 2 : x;
    ops.push(`BT ${hex(color)} rg ${f} ${size} Tf ${num(px)} ${num(y)} Td ${pdfStr(s)} Tj ET`);
  };
  const rect = (x, y, w, h, color) => ops.push(`${hex(color)} rg ${num(x)} ${num(y)} ${num(w)} ${num(h)} re f`);
  const cx = W / 2;

  rect(0, 0, W, H, bg);
  rect(28, 28, W - 56, H - 56, '#FFFFFF');
  ops.push(`${hex(accent)} RG 0.8 w 28 28 ${num(W - 56)} ${num(H - 56)} re S`);

  let y = H - 70;
  text(toWin('INVITÉO'), cx, y, F.TB, 11, accent, 'c'); y -= 16;
  rect(cx - 20, y, 40, 1.2, accent); y -= 36;

  for (const l of wrap(t.event_name, 'Times-Bold', 22, W - 110, 2)) { text(l, cx, y, F.TB, 22, ink, 'c'); y -= 26; }
  y -= 4;
  text(fmtDate(t.starts_at, t.timezone), cx, y, F.H, 10.5, ink, 'c'); y -= 15;
  for (const l of wrap(t.venue_name + (t.address ? ', ' + t.address : ''), 'Helvetica', 10, W - 110, 2)) { text(l, cx, y, F.H, 10, muted, 'c'); y -= 13; }

  y -= 22;
  text('Invitation pour', cx, y, F.H, 9.5, muted, 'c'); y -= 24;
  let size = 20, lines = wrap(t.guest_name, 'Times-Bold', size, W - 110, 2);
  if (lines.length > 1) { size = 17; lines = wrap(t.guest_name, 'Times-Bold', size, W - 110, 2); }
  for (const l of lines) { text(l, cx, y, F.TB, size, ink, 'c'); y -= size + 5; }
  const n = Number(t.max_entries) || 1;
  text(n > 1 ? `Valable pour ${n} personnes` : 'Valable pour 1 personne', cx, y - 2, F.H, 10, accent, 'c');

  // QR code vectoriel
  const m = QR.toMatrix(t.qrText, 'M'), quiet = 2, cells = m.size + quiet * 2, side = 150, cell = side / cells;
  const qx = cx - side / 2, qy = 120;
  rect(qx - 8, qy - 8, side + 16, side + 16, '#FFFFFF');
  ops.push('0 0 0 rg');
  for (let r = 0; r < m.size; r++) for (let c = 0; c < m.size; c++) {
    if (m.modules[r][c]) ops.push(`${num(qx + (c + quiet) * cell)} ${num(qy + side - (r + quiet + 1) * cell)} ${num(cell)} ${num(cell)} re`);
  }
  ops.push('f');
  ops.push(`${hex('#DDD6CB')} RG 0.6 w ${num(qx - 8)} ${num(qy - 8)} ${num(side + 16)} ${num(side + 16)} re S`);

  text(toWin("Présentez ce code à l'entrée. Il est personnel : ne le partagez pas."), cx, 96, F.H, 8.5, muted, 'c');
  text("Un seul passage par personne autorisée. Une copie n'ouvre pas une deuxième entrée.", cx, 84, F.H, 8.5, muted, 'c');
  text(toWin('Créé avec Invitéo'), cx, 52, F.H, 8, muted, 'c');

  const content = Buffer.from(ops.join('\n'), 'latin1');
  const objs = [];
  const add = (s) => { objs.push(s); return objs.length; };
  add('<< /Type /Catalog /Pages 2 0 R >>');
  add('<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  add(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${W} ${H}] /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R /F4 8 0 R >> >> /Contents 4 0 R >>`);
  add({ stream: content });
  for (const f of ['Helvetica', 'Helvetica-Bold', 'Times-Roman', 'Times-Bold']) add(`<< /Type /Font /Subtype /Type1 /BaseFont /${f} /Encoding /WinAnsiEncoding >>`);
  const title = toWin(`Invitation - ${t.guest_name} - ${t.event_name}`);
  add(`<< /Title ${pdfStr(title)} /Producer (Inviteo) /Creator (Inviteo) >>`);

  const parts = [Buffer.from('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n', 'latin1')], offsets = [];
  let pos = parts[0].length;
  objs.forEach((o, i) => {
    offsets.push(pos);
    const b = typeof o === 'string' ? Buffer.from(`${i + 1} 0 obj\n${o}\nendobj\n`, 'latin1')
      : Buffer.concat([Buffer.from(`${i + 1} 0 obj\n<< /Length ${o.stream.length} >>\nstream\n`), o.stream, Buffer.from('\nendstream\nendobj\n')]);
    parts.push(b); pos += b.length;
  });
  let xref = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offsets) xref += String(o).padStart(10, '0') + ' 00000 n \n';
  xref += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Info ${objs.length} 0 R >>\nstartxref\n${pos}\n%%EOF\n`;
  parts.push(Buffer.from(xref, 'latin1'));
  return Buffer.concat(parts);
}

module.exports = { buildTicketPdf };
