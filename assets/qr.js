/* ==========================================================================
   Invitéo — générateur de QR code (JavaScript pur, sans dépendance)
   Mode octets (UTF-8), niveaux de correction L / M / Q / H, versions 1 à 25.
   Fonctionne dans le navigateur (window.InviteoQR) et dans Node (module.exports).

   Conforme à la norme ISO/IEC 18004. Vérifié en décodant les codes produits avec
   un lecteur indépendant (OpenCV) : voir tests/qr/.
   ========================================================================== */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) { module.exports = factory(); }
  else { root.InviteoQR = factory(); }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var MAX_VERSION = 25;

  // Octets de correction par bloc et nombre de blocs, par niveau (L, M, Q, H) et par version.
  var ECC_PER_BLOCK = [
    [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26],
    [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28],
    [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30],
    [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30]
  ];
  var NUM_BLOCKS = [
    [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12],
    [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21],
    [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29],
    [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35]
  ];
  var LEVELS = { L: 0, M: 1, Q: 2, H: 3 };
  var FORMAT_BITS = [1, 0, 3, 2]; // L, M, Q, H

  function utf8Bytes(str) {
    if (typeof TextEncoder !== 'undefined') { return Array.prototype.slice.call(new TextEncoder().encode(str)); }
    var s = unescape(encodeURIComponent(str)), out = [];
    for (var i = 0; i < s.length; i++) { out.push(s.charCodeAt(i)); }
    return out;
  }

  function numRawDataModules(ver) {
    var r = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
      var n = Math.floor(ver / 7) + 2;
      r -= (25 * n - 10) * n - 55;
      if (ver >= 7) { r -= 36; }
    }
    return r;
  }
  function numDataCodewords(ver, ecl) {
    return Math.floor(numRawDataModules(ver) / 8) - ECC_PER_BLOCK[ecl][ver] * NUM_BLOCKS[ecl][ver];
  }

  // --- Reed-Solomon sur GF(256), polynôme 0x11D ---
  function gfMul(x, y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11D); z ^= ((y >>> i) & 1) * x; }
    return z;
  }
  function rsDivisor(degree) {
    var res = [], i, j, root = 1;
    for (i = 0; i < degree; i++) { res.push(0); }
    res[degree - 1] = 1;
    for (i = 0; i < degree; i++) {
      for (j = 0; j < degree; j++) {
        res[j] = gfMul(res[j], root);
        if (j + 1 < degree) { res[j] ^= res[j + 1]; }
      }
      root = gfMul(root, 2);
    }
    return res;
  }
  function rsRemainder(data, divisor) {
    var res = divisor.map(function () { return 0; });
    data.forEach(function (b) {
      var factor = b ^ res.shift();
      res.push(0);
      divisor.forEach(function (coef, i) { res[i] ^= gfMul(coef, factor); });
    });
    return res;
  }

  function charCountBits(ver) { return ver <= 9 ? 8 : 16; }

  function buildDataCodewords(bytes, ver, ecl) {
    var bits = [];
    function put(val, len) { for (var i = len - 1; i >= 0; i--) { bits.push((val >>> i) & 1); } }
    put(4, 4);                              // mode « octets »
    put(bytes.length, charCountBits(ver));
    bytes.forEach(function (b) { put(b, 8); });
    var cap = numDataCodewords(ver, ecl) * 8;
    put(0, Math.min(4, cap - bits.length)); // terminateur
    while (bits.length % 8 !== 0) { bits.push(0); }
    for (var pad = 0xEC; bits.length < cap; pad ^= 0xEC ^ 0x11) { put(pad, 8); }
    var out = [];
    for (var i = 0; i < bits.length; i += 8) {
      var v = 0;
      for (var k = 0; k < 8; k++) { v = (v << 1) | bits[i + k]; }
      out.push(v);
    }
    return out;
  }

  function addEccAndInterleave(data, ver, ecl) {
    var nb = NUM_BLOCKS[ecl][ver], eccLen = ECC_PER_BLOCK[ecl][ver];
    var raw = Math.floor(numRawDataModules(ver) / 8);
    var shortBlocks = nb - raw % nb, shortLen = Math.floor(raw / nb);
    var blocks = [], div = rsDivisor(eccLen), k = 0, i;
    for (i = 0; i < nb; i++) {
      var dat = data.slice(k, k + shortLen - eccLen + (i < shortBlocks ? 0 : 1));
      k += dat.length;
      var ecc = rsRemainder(dat, div);
      if (i < shortBlocks) { dat.push(0); }
      blocks.push(dat.concat(ecc));
    }
    var out = [];
    for (i = 0; i < blocks[0].length; i++) {
      blocks.forEach(function (blk, j) {
        if (i !== shortLen - eccLen || j >= shortBlocks) { out.push(blk[i]); }
      });
    }
    return out;
  }

  function alignmentPositions(ver) {
    if (ver === 1) { return []; }
    var n = Math.floor(ver / 7) + 2, size = ver * 4 + 17;
    var step = Math.ceil((ver * 4 + 4) / (n * 2 - 2)) * 2;
    var res = [6];
    for (var pos = size - 7; res.length < n; pos -= step) { res.splice(1, 0, pos); }
    return res;
  }

  function penalty(m, size) {
    var score = 0, x, y, run, dark = 0, c;
    // Règle 1 : séries de 5 modules identiques ou plus (lignes et colonnes)
    for (var dir = 0; dir < 2; dir++) {
      for (y = 0; y < size; y++) {
        run = 1;
        for (x = 1; x < size; x++) {
          var a = dir ? m[x][y] : m[y][x], b = dir ? m[x - 1][y] : m[y][x - 1];
          if (a === b) { run++; if (run === 5) { score += 3; } else if (run > 5) { score += 1; } } else { run = 1; }
        }
      }
    }
    // Règle 2 : blocs 2x2 de même couleur
    for (y = 0; y < size - 1; y++) {
      for (x = 0; x < size - 1; x++) {
        c = m[y][x];
        if (c === m[y][x + 1] && c === m[y + 1][x] && c === m[y + 1][x + 1]) { score += 3; }
      }
    }
    // Règle 3 : motifs ressemblant aux repères (1:1:3:1:1 avec 4 modules clairs)
    var p1 = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0], p2 = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
    function matches(get, p) { for (var i = 0; i < 11; i++) { if ((get(i) ? 1 : 0) !== p[i]) { return false; } } return true; }
    for (y = 0; y < size; y++) {
      for (x = 0; x <= size - 11; x++) {
        if (matches(function (i) { return m[y][x + i]; }, p1) || matches(function (i) { return m[y][x + i]; }, p2)) { score += 40; }
        if (matches(function (i) { return m[x + i][y]; }, p1) || matches(function (i) { return m[x + i][y]; }, p2)) { score += 40; }
      }
    }
    // Règle 4 : équilibre clair / sombre
    for (y = 0; y < size; y++) { for (x = 0; x < size; x++) { if (m[y][x]) { dark++; } } }
    var total = size * size;
    score += (Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;
    return score;
  }

  function maskBit(mask, x, y) {
    switch (mask) {
      case 0: return (x + y) % 2 === 0;
      case 1: return y % 2 === 0;
      case 2: return x % 3 === 0;
      case 3: return (x + y) % 3 === 0;
      case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0;
      case 5: return x * y % 2 + x * y % 3 === 0;
      case 6: return (x * y % 2 + x * y % 3) % 2 === 0;
      default: return ((x + y) % 2 + x * y % 3) % 2 === 0;
    }
  }

  /** Retourne { size, version, modules } ; modules[y][x] === true pour un module sombre. */
  function toMatrix(text, level) {
    var ecl = LEVELS[level || 'M'];
    if (ecl === undefined) { throw new Error('Niveau de correction inconnu : ' + level); }
    var bytes = utf8Bytes(String(text));
    var ver = 0, v;
    for (v = 1; v <= MAX_VERSION; v++) {
      if (4 + charCountBits(v) + bytes.length * 8 <= numDataCodewords(v, ecl) * 8) { ver = v; break; }
    }
    if (!ver) { throw new Error('Texte trop long pour un QR code (version ' + MAX_VERSION + ' maximum)'); }

    var size = ver * 4 + 17, x, y, i, j;
    var mod = [], fn = [];
    for (y = 0; y < size; y++) { mod.push([]); fn.push([]); for (x = 0; x < size; x++) { mod[y].push(false); fn[y].push(false); } }
    function setFn(px, py, dark) { mod[py][px] = dark; fn[py][px] = true; }

    // Motifs de synchronisation
    for (i = 0; i < size; i++) { setFn(6, i, i % 2 === 0); setFn(i, 6, i % 2 === 0); }
    // Repères de position (avec séparateurs)
    function finder(cx, cy) {
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          var d = Math.max(Math.abs(dx), Math.abs(dy)), xx = cx + dx, yy = cy + dy;
          if (xx >= 0 && xx < size && yy >= 0 && yy < size) { setFn(xx, yy, d !== 2 && d !== 4); }
        }
      }
    }
    finder(3, 3); finder(size - 4, 3); finder(3, size - 4);
    // Motifs d'alignement
    var al = alignmentPositions(ver), na = al.length;
    for (i = 0; i < na; i++) {
      for (j = 0; j < na; j++) {
        if ((i === 0 && j === 0) || (i === 0 && j === na - 1) || (i === na - 1 && j === 0)) { continue; }
        for (var ay = -2; ay <= 2; ay++) { for (var ax = -2; ax <= 2; ax++) { setFn(al[i] + ax, al[j] + ay, Math.max(Math.abs(ax), Math.abs(ay)) !== 1); } }
      }
    }
    function drawFormat(mask) {
      var data = FORMAT_BITS[ecl] << 3 | mask, rem = data, k;
      for (k = 0; k < 10; k++) { rem = (rem << 1) ^ ((rem >>> 9) * 0x537); }
      var bits = (data << 10 | rem) ^ 0x5412;
      function bit(n) { return ((bits >>> n) & 1) !== 0; }
      for (k = 0; k <= 5; k++) { setFn(8, k, bit(k)); }
      setFn(8, 7, bit(6)); setFn(8, 8, bit(7)); setFn(7, 8, bit(8));
      for (k = 9; k < 15; k++) { setFn(14 - k, 8, bit(k)); }
      for (k = 0; k < 8; k++) { setFn(size - 1 - k, 8, bit(k)); }
      for (k = 8; k < 15; k++) { setFn(8, size - 15 + k, bit(k)); }
      setFn(8, size - 8, true);
    }
    drawFormat(0);
    if (ver >= 7) {
      var rem = ver, k;
      for (k = 0; k < 12; k++) { rem = (rem << 1) ^ ((rem >>> 11) * 0x1F25); }
      var vbits = ver << 12 | rem;
      for (k = 0; k < 18; k++) {
        var b = ((vbits >>> k) & 1) !== 0, a2 = size - 11 + k % 3, b2 = Math.floor(k / 3);
        setFn(a2, b2, b); setFn(b2, a2, b);
      }
    }

    // Données + correction d'erreurs
    var all = addEccAndInterleave(buildDataCodewords(bytes, ver, ecl), ver, ecl);
    var idx = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right === 6) { right = 5; }
      for (var vert = 0; vert < size; vert++) {
        for (j = 0; j < 2; j++) {
          var px = right - j, upward = ((right + 1) & 2) === 0, py = upward ? size - 1 - vert : vert;
          if (!fn[py][px] && idx < all.length * 8) {
            mod[py][px] = ((all[idx >>> 3] >>> (7 - (idx & 7))) & 1) !== 0;
            idx++;
          }
        }
      }
    }

    function applyMask(mask) {
      for (var yy = 0; yy < size; yy++) { for (var xx = 0; xx < size; xx++) { if (!fn[yy][xx] && maskBit(mask, xx, yy)) { mod[yy][xx] = !mod[yy][xx]; } } }
    }
    var best = 0, bestScore = Infinity;
    for (var mk = 0; mk < 8; mk++) {
      applyMask(mk); drawFormat(mk);
      var sc = penalty(mod, size);
      if (sc < bestScore) { bestScore = sc; best = mk; }
      applyMask(mk);
    }
    applyMask(best); drawFormat(best);
    return { size: size, version: ver, level: level || 'M', mask: best, modules: mod };
  }

  /** SVG autonome : modules sombres sur fond blanc, zone de silence de 4 modules. */
  function toSvg(text, options) {
    options = options || {};
    var m = toMatrix(text, options.level || 'M'), border = options.border === undefined ? 4 : options.border;
    var dark = options.dark || '#0A1931', light = options.light || '#FFFFFF';
    var d = [], x, y, start;
    for (y = 0; y < m.size; y++) {
      x = 0;
      while (x < m.size) {
        if (m.modules[y][x]) {
          start = x;
          while (x < m.size && m.modules[y][x]) { x++; }
          d.push('M' + (start + border) + ',' + (y + border) + 'h' + (x - start) + 'v1h-' + (x - start) + 'z');
        } else { x++; }
      }
    }
    var dim = m.size + border * 2;
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + dim + ' ' + dim + '" shape-rendering="crispEdges"' +
      (options.title ? ' role="img" aria-label="' + String(options.title).replace(/[&<>"]/g, '') + '"' : ' aria-hidden="true"') + '>' +
      '<rect width="100%" height="100%" fill="' + light + '"/><path fill="' + dark + '" d="' + d.join('') + '"/></svg>';
  }

  return { toMatrix: toMatrix, toSvg: toSvg, MAX_VERSION: MAX_VERSION };
});
