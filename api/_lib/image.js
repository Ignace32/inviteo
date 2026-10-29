'use strict';
// Reconnaît JPEG / PNG / WebP d'après les octets du fichier (jamais d'après le nom ni l'en-tête annoncé)
// et lit leurs dimensions. Renvoie null si le fichier n'est pas une image valide de ces trois formats.
function sniff(b) {
  if (!Buffer.isBuffer(b) || b.length < 32) return null;
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m === 0xff) { i++; continue; }
      if (m === 0xd8 || (m >= 0xd0 && m <= 0xd7) || m === 0x01) { i += 2; continue; }
      const len = b.readUInt16BE(i + 2);
      if (len < 2) return null;
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
        const h = b.readUInt16BE(i + 5), w = b.readUInt16BE(i + 7);
        return w && h ? { type: 'image/jpeg', ext: 'jpg', w, h } : null;
      }
      i += 2 + len;
    }
    return null;
  }
  if (b.slice(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) && b.slice(12, 16).toString('latin1') === 'IHDR') {
    const w = b.readUInt32BE(16), h = b.readUInt32BE(20);
    return w && h ? { type: 'image/png', ext: 'png', w, h } : null;
  }
  if (b.slice(0, 4).toString('latin1') === 'RIFF' && b.slice(8, 12).toString('latin1') === 'WEBP') {
    const k = b.slice(12, 16).toString('latin1');
    let w, h;
    if (k === 'VP8 ') { w = b.readUInt16LE(26) & 0x3fff; h = b.readUInt16LE(28) & 0x3fff; }
    else if (k === 'VP8L') { const v = b.readUInt32LE(21); w = (v & 0x3fff) + 1; h = ((v >> 14) & 0x3fff) + 1; }
    else if (k === 'VP8X') { w = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1; h = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1; }
    return w && h ? { type: 'image/webp', ext: 'webp', w, h } : null;
  }
  return null;
}
module.exports = { sniff };
