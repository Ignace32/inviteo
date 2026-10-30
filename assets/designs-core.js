/* Invitéo — compositions des modèles « design » (source unique).
   Utilisé par le serveur (page d'invitation, aperçu) ET par l'aperçu en direct de l'espace organisateur. */
(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api; else root.InviteoDesigns = api;
})(typeof self !== 'undefined' ? self : this, function () {
'use strict';
// Compositions graphiques des modèles « design » : huit cartes d'invitation dessinées pour Invitéo.
// Chaque carte est une composition HTML/CSS/SVG pilotée par des données : noms, date, lieu, texte, photos.
// Aucune image de démonstration n'est incrustée dans le dessin : les zones photo (.dz-ph) sont toujours
// remplaçables par le client. Les ornements (feuillages, fleurs, aquarelle, cadres) sont des SVG originaux.
// Tout texte venant des données passe par esc() ; aucune donnée n'entre dans un attribut non échappé.

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const DESIGNS = ['monogramme', 'arche-doree', 'sauge', 'save-the-date', 'fiancailles', 'romance', 'aquarelle-bleu', 'arche-creme'];

// Générateur pseudo-aléatoire déterministe : le même ornement est tracé à l'identique à chaque affichage.
function prng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const f1 = (n) => Math.round(n * 10) / 10;

/* ---------- ornements SVG ---------- */
function leafPath(len, w) { return `M0 0C${f1(w)} ${f1(-len * 0.3)} ${f1(w)} ${f1(-len * 0.75)} 0 ${f1(-len)}C${f1(-w)} ${f1(-len * 0.75)} ${f1(-w)} ${f1(-len * 0.3)} 0 0Z`; }

// Branche feuillue le long d'une courbe. style : 'line' (feuilles au trait, nervure) ou 'fill' (feuilles pleines).
function branch({ cls = '', leaves = 9, seed = 1, color = 'currentColor', style = 'line', bend = 18 }) {
  const r = prng(seed), H = 300, parts = [];
  const P = (t) => ({ x: 50 + bend * Math.sin(t * Math.PI) * 0.9 - bend * 0.2 * t, y: H - t * (H - 12) });
  let d = `M${f1(P(0).x)} ${H}`;
  for (let i = 1; i <= 24; i++) { const p = P(i / 24); d += `L${f1(p.x)} ${f1(p.y)}`; }
  parts.push(`<path d="${d}" fill="none" stroke="${color}" stroke-width="1.3" stroke-linecap="round"/>`);
  for (let i = 0; i < leaves; i++) {
    const t = 0.12 + (i / leaves) * 0.8, p = P(t), q = P(Math.min(1, t + 0.02));
    const ang = Math.atan2(q.x - p.x, p.y - q.y) * 180 / Math.PI; // direction de la tige
    const side = i % 2 ? 1 : -1, len = (46 - t * 22) * (0.85 + r() * 0.3), w = len * 0.34;
    const rot = f1(ang + side * (38 + r() * 14));
    const body = style === 'fill'
      ? `<path d="${leafPath(len, w)}" fill="${color}" fill-opacity=".85"/>`
      : `<path d="${leafPath(len, w)}" fill="none" stroke="${color}" stroke-width="1.1"/><path d="M0 0L0 ${f1(-len * 0.9)}" stroke="${color}" stroke-width=".8" fill="none"/>`;
    parts.push(`<g transform="translate(${f1(p.x)} ${f1(p.y)}) rotate(${rot})">${body}</g>`);
  }
  const tip = P(1);
  parts.push(`<g transform="translate(${f1(tip.x)} ${f1(tip.y)})"><path d="${leafPath(34, 11)}" ${style === 'fill' ? `fill="${color}" fill-opacity=".85"` : `fill="none" stroke="${color}" stroke-width="1.1"`}/></g>`);
  return `<svg class="dz-branch ${cls}" viewBox="0 0 100 300" aria-hidden="true" focusable="false">${parts.join('')}</svg>`;
}

// Fleur à pétales superposés (pivoine stylisée). tones : trois couleurs du centre vers l'extérieur.
function flower({ cls = '', seed = 3, tones = ['#FFFFFF', '#F6FAFD', '#B3CFE5'], petals = 9, center = '#4A7FA7', shadow = false }) {
  const r = prng(seed), g = [];
  [[1, 46, 0], [0.74, 36, 18], [0.5, 26, 7]].forEach(([k, len, off], layer) => {
    const n = petals - layer;
    for (let i = 0; i < n; i++) {
      const rot = f1((360 / n) * i + off + (r() - 0.5) * 10);
      g.push(`<ellipse cx="0" cy="${f1(-len * 0.56)}" rx="${f1(len * 0.42 * k + 5)}" ry="${f1(len * 0.62)}" transform="rotate(${rot})" fill="${tones[layer]}" stroke="${tones[2]}" stroke-width=".7" fill-opacity=".96"/>`);
    }
  });
  const dots = Array.from({ length: 9 }, () => `<circle cx="${f1((r() - 0.5) * 11)}" cy="${f1((r() - 0.5) * 11)}" r="${f1(1 + r() * 1.3)}" fill="${center}"/>`).join('');
  return `<svg class="dz-flower ${cls}" viewBox="-70 -70 140 140" aria-hidden="true" focusable="false">${shadow ? '<defs><filter id="fsh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="1.5" dy="3" stdDeviation="2.4" flood-color="#6b5a43" flood-opacity=".28"/></filter></defs>' : ''}<g${shadow ? ' filter="url(#fsh)"' : ''}>${g.join('')}${dots}</g></svg>`;
}

// Tache d'aquarelle (aplat irrégulier, bords déformés par un bruit fractal). Statique : aucun coût d'animation.
function wash({ cls = '', color = '#7C8A67', id = 'wc1', seed = 4, opacity = 0.42 }) {
  return `<svg class="dz-wash ${cls}" viewBox="0 0 200 200" aria-hidden="true" focusable="false"><defs><filter id="${id}" x="-20%" y="-20%" width="140%" height="140%"><feTurbulence type="fractalNoise" baseFrequency="0.018" numOctaves="3" seed="${seed}" result="n"/><feDisplacementMap in="SourceGraphic" in2="n" scale="46"/><feGaussianBlur stdDeviation="1.2"/></filter></defs><g filter="url(#${id})"><ellipse cx="100" cy="100" rx="78" ry="62" fill="${color}" fill-opacity="${opacity}"/><ellipse cx="86" cy="112" rx="52" ry="40" fill="${color}" fill-opacity="${f1(opacity * 0.6)}"/></g></svg>`;
}

const ICON = {
  pin: '<path d="M12 22s7-6.2 7-12a7 7 0 1 0-14 0c0 5.8 7 12 7 12Z"/><circle cx="12" cy="10" r="2.6"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5.2l3.2 2"/>',
  calendar: '<rect x="3.5" y="5" width="17" height="15.5" rx="2"/><path d="M3.5 10h17M8 3v4M16 3v4"/><path d="M8 14h2M12 14h2M16 14h.5M8 17h2M12 17h2" stroke-width="1.6"/>',
  rings: '<circle cx="9" cy="15" r="5.2"/><circle cx="15.5" cy="15" r="5.2"/><path d="M7 5.5l2-2.3 2 2.3-2 2.4Z"/>',
  glasses: '<path d="M4.5 3.5h6l-.9 8a2.1 2.1 0 0 1-4.2 0ZM5 7.6h5M7.5 13.6V20M5 20h5"/><path d="M13.5 3.5h6l-.9 8a2.1 2.1 0 0 1-4.2 0ZM14 7.6h5M16.5 13.6V20M14 20h5"/>',
  note: '<path d="M9 18V5.5l11-2V16"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>',
  heart: '<path d="M12 20.5s-8-5-8-10.6A4.4 4.4 0 0 1 12 7.2a4.4 4.4 0 0 1 8 2.7c0 5.6-8 10.6-8 10.6Z"/>',
  star: '<path d="M12 3.5l2.4 5.4 5.9.6-4.4 4 1.3 5.8L12 16.2 6.8 19.3l1.3-5.8-4.4-4 5.9-.6Z"/>',
};
function icon(name, cls = '') { return `<svg class="dz-ic ${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${ICON[name] || ''}</svg>`; }

function corner(cls) { // ornement d'angle doré (cadre)
  return `<svg class="dz-corner ${cls}" viewBox="0 0 60 60" aria-hidden="true" focusable="false"><g fill="none" stroke="currentColor" stroke-width="1"><path d="M2 58V14C2 7 7 2 14 2h44"/><path d="M8 58V18c0-5.5 4.5-10 10-10h40" opacity=".55"/><path d="M14 14c8 0 12 4 12 12-8 0-12-4-12-12Z"/><path d="M26 14c3-5 8-6 13-5-2 5-7 7-13 5Z" opacity=".8"/><path d="M14 26c-5 3-6 8-5 13 5-2 7-7 5-13Z" opacity=".8"/></g></svg>`;
}
function fleuron(cls = '') { return `<svg class="dz-fleuron ${cls}" viewBox="0 0 120 16" aria-hidden="true" focusable="false"><g fill="none" stroke="currentColor" stroke-width="1"><path d="M2 8h40M78 8h40"/><path d="M60 2l5 6-5 6-5-6Z"/><path d="M46 8c4-4 8-4 10 0M74 8c-4-4-8-4-10 0"/></g></svg>`; }

// Bord déchiré (effet pinceau) : polygone dont le bord gauche est irrégulier.
function tornPolygon(seed) {
  const r = prng(seed), pts = [];
  for (let y = 0; y <= 100; y += 1.6) pts.push(`${f1(2 + r() * 11 + (Math.sin(y / 9) + 1) * 3)}% ${f1(y)}%`);
  pts.push('100% 100%', '100% 0%');
  return `polygon(${pts.join(',')})`;
}

/* ---------- données de la carte ---------- */
function splitNames(celebrated, fallback) {
  const s = String(celebrated || fallback || '').trim();
  const m = s.split(/\s+(?:&|et|and|\+)\s+/i);
  return m.length >= 2 ? [m[0].trim(), m.slice(1).join(' et ').trim()] : [s, ''];
}
const initial = (s) => { const m = String(s || '').trim().match(/[\p{L}\p{N}]/u); return m ? m[0].toUpperCase() : ''; };

// Zone photo remplaçable. demo = vrai quand l'image est un exemple (aperçu) : un bandeau le signale.
function photo(ctx, extra = '') {
  const p = ctx.hero;
  const inner = p && p.url
    ? `<img src="${esc(p.url)}" alt="${esc(p.alt || '')}" decoding="async"${p.width && p.height ? ` width="${Number(p.width) | 0}" height="${Number(p.height) | 0}"` : ''}>`
    : '<span class="dz-ph-empty" aria-hidden="true"></span>';
  return `<div class="dz-ph ${extra}" data-slot="hero"${p && p.demo ? ' data-demo="1"' : ''}>${inner}${p && p.demo ? '<span class="dz-demo">Photo d\'exemple</span>' : ''}</div>`;
}

const L = (c, k, d) => esc((c.labels && c.labels[k]) || d);

/* ---------- les huit cartes ---------- */
const CARDS = {
  // 1. Monogramme éditorial : initiales, rubrique de date, photo à bord pinceau
  monogramme(c) {
    const [a, b] = c.names;
    return `<div class="dz dz-monogramme" style="--ar:1.4">
  <svg class="dz-shadowleaf" viewBox="0 0 200 200" aria-hidden="true" focusable="false"><g fill="currentColor">${[[30, 40, -30, 60], [60, 20, 10, 55], [90, 55, 40, 50], [20, 95, -50, 50], [75, 100, 25, 46], [45, 75, -10, 52]].map(([x, y, rot, l]) => `<path transform="translate(${x} ${y}) rotate(${rot})" d="${leafPath(l, 14)}"/>`).join('')}</g></svg>
  ${photo(c, 'dz-m-photo').replace('class="dz-ph', `style="clip-path:${tornPolygon(11)}" class="dz-ph`)}
  <div class="dz-m-text">
    <div class="dz-mono" aria-hidden="true"><span class="i1">${esc(initial(a) || '·')}</span><span class="slash"></span><span class="i2">${esc(initial(b) || '')}</span></div>
    <p class="dz-kick a1">${L(c, 'kicker', 'Ensemble pour la vie')}</p>
    <p class="dz-script a2">${L(c, 'script', 'nous disons oui.')}</p>
    ${icon('heart', 'dz-heart a3')}
    ${c.message ? `<p class="dz-msg a3">${esc(c.message)}</p>` : ''}
    <div class="dz-datebox a4"><div><span class="s">${esc(c.d.monthU)}</span><b>${esc(c.d.day)}</b><span class="s">${esc(c.d.year)}</span></div><i></i><div><span class="s">${esc(c.d.weekdayU)}</span><b>${esc(c.d.time)}</b><span class="s">${L(c, 'hour', 'Heure')}</span></div></div>
    <p class="dz-script small a5">${L(c, 'invited', 'Vous êtes invités')}</p>
    <p class="dz-venue-line a6">${icon('pin')}<b>${esc(c.venue)}</b>${c.address ? `<span>${esc(c.address)}</span>` : ''}</p>
  </div></div>`;
  },

  // 2. Arche dorée : photo en arche, branches dorées, rangée de date à trois colonnes
  'arche-doree'(c) {
    const [a, b] = c.names;
    return `<div class="dz dz-arche-doree" style="--ar:1.42">
  ${branch({ cls: 'bl', seed: 5, leaves: 10, color: 'var(--accent)' })}${branch({ cls: 'br', seed: 8, leaves: 10, color: 'var(--accent)' })}
  ${branch({ cls: 'bl2', seed: 12, leaves: 7, color: 'var(--accent)' })}${branch({ cls: 'br2', seed: 15, leaves: 7, color: 'var(--accent)' })}
  ${photo(c, 'dz-a-photo')}
  <div class="dz-a-text">
    <p class="dz-cap a1">${L(c, 'kicker', 'Le mariage de')}</p>
    <h2 class="dz-names a2">${esc(a)}${b ? ` <em>&amp;</em> ${esc(b)}` : ''}</h2>
    <p class="dz-cap sm a3">${c.message ? esc(c.message) : L(c, 'invited', 'Vous invitent à célébrer leur union')}</p>
    <div class="dz-cols a4"><span>${esc(c.d.monthU)}</span><i></i><b><small>${esc(c.d.weekdayU)}</small>${esc(c.d.day)}</b><i></i><span>${esc(c.d.year)}</span></div>
    <p class="dz-cap sm a5">${esc(c.d.time)} · ${esc(c.venue)}${c.address ? `<br>${esc(c.address)}` : ''}</p>
  </div></div>`;
  },

  // 3. Sauge : arche photo, aquarelle, programme en frise avec icônes
  sauge(c) {
    const [a, b] = c.names, prog = c.program.slice(0, 3), IC = ['rings', 'glasses', 'note'];
    return `<div class="dz dz-sauge" style="--ar:1.5">
  ${wash({ cls: 'w1', color: 'var(--accent)', id: 'wcs', seed: 6 })}
  ${flower({ cls: 'f1', seed: 2, tones: ['#FFFFFF', '#F6FAFD', '#B3CFE5'], petals: 8, shadow: false })}${branch({ cls: 'lf1', seed: 21, leaves: 8, color: 'var(--accent)', style: 'fill' })}${branch({ cls: 'lf2', seed: 22, leaves: 9, color: 'var(--accent)', style: 'fill' })}
  <div class="dz-s-arch"><span class="frame"></span>${photo(c, 'dz-s-photo')}</div>
  <div class="dz-s-text">
    <p class="dz-cap a1">${L(c, 'kicker', 'Invitation à notre mariage')}</p>
    <h2 class="dz-names a2"><span>${esc(a)}</span>${b ? `<em>et</em><span>${esc(b)}</span>` : ''}</h2>
    <div class="dz-rule a3"><i></i>${icon('heart')}<i></i></div>
    ${c.message ? `<p class="dz-msg a3">${esc(c.message)}</p>` : ''}
    <div class="dz-bigdate a4"><b>${esc(c.d.day)}</b><i></i><div><span>${esc(c.d.monthU)}</span><span>${esc(c.d.year)}</span><em>${esc(c.d.weekday)}</em></div></div>
    ${prog.length ? `<ol class="dz-tl a5">${prog.map((p, i) => `<li>${icon(IC[i])}<div><b>${esc(p.time)}</b><em>${esc(p.title || p.label)}</em></div></li>`).join('')}</ol>` : `<p class="dz-venue-line a5">${icon('pin')}<b>${esc(c.venue)}</b>${c.address ? `<span>${esc(c.address)}</span>` : ''}</p>`}
  </div>
  ${c.extra ? `<div class="dz-s-note a6"><p>${esc(c.extra)}</p></div>` : ''}</div>`;
  },

  // 4. Save the date : photo plein cadre, titre centré
  'save-the-date'(c) {
    const [a, b] = c.names;
    return `<div class="dz dz-save" style="--ar:1.78">
  ${photo(c, 'dz-full')}<div class="dz-veil"></div>
  <div class="dz-v-text">
    <p class="dz-big a1">${L(c, 'kicker', 'Notez')}</p>
    <p class="dz-script huge a2">${L(c, 'script', 'la date')}</p>
    ${icon('heart', 'dz-heart a3')}
    <p class="dz-nm a3">${esc(a)}${b ? ` <em>et</em> ${esc(b)}` : ''}</p>
    <div class="dz-rule a4"><i></i>${icon('heart')}<i></i></div>
    <p class="dz-dt a4">${esc(c.d.dayMonthYearU)}</p>
    ${c.message ? `<p class="dz-msg a5">${esc(c.message)}</p>` : ''}
  </div></div>`;
  },

  // 5. Fiançailles : plein écran vertical, texte blanc sur voile sombre
  fiancailles(c) {
    const [a, b] = c.names;
    return `<div class="dz dz-fianc" style="--ar:1.78">
  ${photo(c, 'dz-full')}<div class="dz-veil"></div>
  <div class="dz-f-text">
    <p class="dz-cap a1">${L(c, 'kicker', 'Vous êtes invités aux fiançailles de')}</p>
    <h2 class="dz-names a2">${esc(a)}${b ? `<em>&amp;</em>${esc(b)}` : ''}</h2>
    <div class="dz-f-date a3"><span class="mo">${esc(c.d.month)}</span><div><span>${esc(c.d.weekday)}</span><b>${esc(c.d.day)}</b><span class="t">${esc(c.d.time)}</span></div><span class="yr">${esc(c.d.year)}</span></div>
    <p class="dz-venue-line a4"><b>${esc(c.venue)}</b>${c.address ? `<span>${esc(c.address)}</span>` : ''}</p>
    <p class="dz-cap a5">${c.message ? esc(c.message) : L(c, 'closing', 'Nous avons hâte de célébrer avec vous !')}</p>
    <p class="dz-cap sm a6">${esc(c.d.numeric)}<br>${L(c, 'save', 'Notez la date')}</p>
  </div></div>`;
  },

  // 6. Romance dorée : photo lumineuse, script doré, informations avec icônes, pétales
  romance(c) {
    const [a, b] = c.names;
    const petals = Array.from({ length: 9 }, (_, i) => `<span style="--x:${[8, 22, 35, 50, 61, 72, 84, 92, 44][i]}%;--d:${[0, 2.2, 5, 1.1, 6.3, 3.4, 0.6, 4.4, 7.5][i]}s;--s:${[1, 0.8, 1.1, 0.7, 0.9, 1.2, 0.75, 1, 0.85][i]}"></span>`).join('');
    return `<div class="dz dz-romance" style="--ar:1.4">
  ${photo(c, 'dz-full')}<div class="dz-veil"></div><div class="dz-petals" aria-hidden="true">${petals}</div>
  <div class="dz-r-text">
    <p class="dz-cap sm a1">${L(c, 'kicker', "Avec beaucoup d'amour, nous vous invitons à célébrer notre")}</p>
    <p class="dz-big a1">${L(c, 'title', 'Mariage')}</p>
    ${fleuron('a1')}
    <h2 class="dz-names a2"><span>${esc(a)}</span>${b ? `<em>&amp;</em><span>${esc(b)}</span>` : ''}</h2>
    ${c.message ? `<p class="dz-msg a3">${esc(c.message)}</p>` : ''}
    <ul class="dz-info a4">
      <li>${icon('calendar')}<span>${esc(c.d.day)} <i>|</i> ${esc(c.d.monthU)} <i>|</i> ${esc(c.d.year)}</span></li>
      <li>${icon('clock')}<span>${L(c, 'at', 'À')} ${esc(c.d.timeU)}</span></li>
      <li>${icon('pin')}<span><b>${esc(c.venue)}</b>${c.address ? `<br>${esc(c.address)}` : ''}</span></li>
    </ul>
  </div></div>`;
  },

  // 7. Aquarelle bleue : cadre doré, fleurs bleues, médaillon, portrait en médaillon doux
  'aquarelle-bleu'(c) {
    const [a, b] = c.names;
    return `<div class="dz dz-aquarelle" style="--ar:1.5">
  ${wash({ cls: 'w1', color: 'var(--wash)', id: 'wca', seed: 9, opacity: 0.5 })}${wash({ cls: 'w2', color: 'var(--wash)', id: 'wcb', seed: 14, opacity: 0.5 })}
  ${flower({ cls: 'f1', seed: 4, tones: ['#F6FAFD', '#B3CFE5', '#4A7FA7'], petals: 8, center: '#1A3D63' })}${flower({ cls: 'f2', seed: 7, tones: ['#FFFFFF', '#F6FAFD', '#B3CFE5'], petals: 7, center: '#4A7FA7' })}
  ${flower({ cls: 'f3', seed: 6, tones: ['#F6FAFD', '#B3CFE5', '#4A7FA7'], petals: 8, center: '#1A3D63' })}${flower({ cls: 'f4', seed: 13, tones: ['#FFFFFF', '#F6FAFD', '#B3CFE5'], petals: 7, center: '#4A7FA7' })}
  ${branch({ cls: 'lf1', seed: 31, leaves: 7, color: '#4A7FA7', style: 'fill' })}${branch({ cls: 'lf2', seed: 32, leaves: 7, color: '#4A7FA7', style: 'fill' })}
  <span class="dz-frame"></span>${corner('c1')}${corner('c2')}${corner('c3')}${corner('c4')}
  <div class="dz-q-text">
    <div class="dz-crest a1" aria-hidden="true"><span>${esc(initial(a))}</span><i></i><span>${esc(initial(b))}</span></div>
    <p class="dz-cap sm a1">${L(c, 'kicker', 'Avec leurs familles')}</p>
    <h2 class="dz-names a2"><span>${esc(a)}</span>${b ? `<em>&amp;</em><span>${esc(b)}</span>` : ''}</h2>
    <p class="dz-cap sm a3">${L(c, 'invited', 'Vous invitent à célébrer leur mariage')}</p>
    <div class="dz-wd a4">${fleuron()}<div><span>${esc(c.d.weekdayU)}</span><b>${esc(c.d.day)}</b><span>${esc(c.d.monthU)}</span></div><p>${esc(c.d.year)}</p>${fleuron()}</div>
    <p class="dz-script gold a5">${esc(c.venue)}</p>
    ${c.address ? `<p class="dz-cap sm a5">${esc(c.address)}</p>` : ''}
    <p class="dz-cap xs a6">${esc(c.d.time)}${c.message ? `<br>${esc(c.message)}` : ''}</p>
  </div>
  ${photo(c, 'dz-q-photo')}</div>`;
  },

  // 8. Arche crème : fleurs en relief ton sur ton, panneau en arche, date / heure / lieu avec icônes
  'arche-creme'(c) {
    const [a, b] = c.names;
    return `<div class="dz dz-creme" style="--ar:1.78">
  ${flower({ cls: 'f1', seed: 41, tones: ['#FFFFFF', '#F6FAFD', '#B3CFE5'], petals: 9, center: '#4A7FA7', shadow: true })}${flower({ cls: 'f2', seed: 42, tones: ['#FFFFFF', '#F6FAFD', '#B3CFE5'], petals: 8, center: '#4A7FA7', shadow: true })}
  ${flower({ cls: 'f3', seed: 43, tones: ['#FFFFFF', '#F6FAFD', '#B3CFE5'], petals: 9, center: '#4A7FA7', shadow: true })}${flower({ cls: 'f4', seed: 44, tones: ['#FFFFFF', '#F6FAFD', '#B3CFE5'], petals: 7, center: '#4A7FA7', shadow: true })}
  ${branch({ cls: 'lf1', seed: 45, leaves: 7, color: '#B3CFE5', style: 'fill' })}${branch({ cls: 'lf2', seed: 46, leaves: 7, color: '#B3CFE5', style: 'fill' })}
  <div class="dz-c-panel"><span class="dash"></span>
    <p class="dz-script big a1">${L(c, 'script', 'Jour de mariage')}</p>
    <p class="dz-cap a2">${L(c, 'kicker', 'Invitation de mariage')}</p>
    <p class="dz-msg a2">${c.message ? esc(c.message) : L(c, 'invited', 'Nous serons heureux de partager avec vous ce moment de joie.')}</p>
    <div class="dz-lines a3"><span>${esc(a)}</span>${b ? `<em>&amp;</em><span>${esc(b)}</span>` : ''}</div>
    <ul class="dz-info a4">
      <li>${icon('calendar')}<span>${esc(c.d.numericLong)}</span></li>
      <li>${icon('clock')}<span>${esc(c.d.time)}</span></li>
      <li>${icon('pin')}<span><b>${esc(c.venue)}</b>${c.address ? `<br>${esc(c.address)}` : ''}</span></li>
    </ul>
    ${photo(c, 'dz-c-photo')}
  </div></div>`;
  },
};

// Les modèles qui affichent eux-mêmes le programme (frise) : la page n'ajoute pas de second bloc « Programme ».
const OWN_PROGRAM = new Set(['sauge']);

function renderCard(design, ctx) { return CARDS[design](ctx); }


// Polices autorisées (liste fermée) et dates : partagées par le serveur et l'aperçu en direct.
const FONTS = { 'Fraunces': 'Fraunces:wght@400;600', 'DM Sans': 'DM+Sans:wght@400;500;700', 'Playfair Display': 'Playfair+Display:ital,wght@0,400;0,600;1,400', 'Cormorant Garamond': 'Cormorant+Garamond:ital,wght@0,400;0,600;1,400', 'Lora': 'Lora:wght@400;600', 'Inter': 'Inter:wght@400;500;700',
  'Great Vibes': 'Great+Vibes', 'Pinyon Script': 'Pinyon+Script', 'Cinzel': 'Cinzel:wght@400;600', 'Bodoni Moda': 'Bodoni+Moda:ital,wght@0,400;0,600;1,400', 'Italiana': 'Italiana' };
function fmt(iso, tz, opts) {
  try { return new Intl.DateTimeFormat('fr-FR', Object.assign({ timeZone: tz }, opts)).format(new Date(iso)); }
  catch (_) { return new Intl.DateTimeFormat('fr-FR', Object.assign({ timeZone: 'Africa/Lubumbashi' }, opts)).format(new Date(iso)); }
}
function dateParts(iso, tz) {
  const wd = fmt(iso, tz, { weekday: 'long' }), mo = fmt(iso, tz, { month: 'long' }), day = fmt(iso, tz, { day: 'numeric' }), yr = fmt(iso, tz, { year: 'numeric' });
  const time = fmt(iso, tz, { hour: '2-digit', minute: '2-digit' }).replace(':', 'h');
  const num = fmt(iso, tz, { day: '2-digit', month: '2-digit', year: 'numeric' }).replace(/\//g, '.');
  return { weekday: wd, weekdayU: wd.toUpperCase(), month: mo, monthU: mo.toUpperCase(), day, year: yr, time, timeU: time.toUpperCase(),
    dayMonthYearU: `${day} ${mo} ${yr}`.toUpperCase(), numeric: num, numericLong: `${day} ${mo} ${yr}` };
}
return { FONTS: FONTS, fmt: fmt, dateParts: dateParts, DESIGNS: DESIGNS, renderCard: renderCard, splitNames: splitNames, initial: initial, OWN_PROGRAM: OWN_PROGRAM, esc: esc };

});
