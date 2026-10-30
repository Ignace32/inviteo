'use strict';
// GET /api/preview            → catalogue public des modèles (liste + liens d'aperçu)
// GET /api/preview?slug=<slug> → un modèle affiché avec des informations d'EXEMPLE (aucune donnée de client)
// Aucun jeton, aucune invitation réelle : la page est identique à celle d'un invité, avec un bandeau « exemple ».
const { rpc } = require('./_lib/supabase');
const { renderInvitation, renderError, esc } = require('./_lib/render');

const HEADERS = {
  'Content-Type': 'text/html; charset=utf-8',
  'Cache-Control': 'public, max-age=300',
  'X-Robots-Tag': 'noindex, nofollow',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: https:; connect-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'",
};
const send = (res, code, html) => { res.writeHead(code, HEADERS); res.end(html); };

// Photo d'exemple : un simple pictogramme neutre (jamais une vraie photo). Les clients mettent la leur.
const DEMO_PHOTO = 'data:image/svg+xml;utf8,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 560"><rect width="400" height="560" fill="#D9D2C7"/><rect y="330" width="400" height="230" fill="#C7BEB0"/>' +
  '<circle cx="150" cy="250" r="34" fill="#B8AE9E"/><path d="M96 420c0-52 24-86 54-86s54 34 54 86Z" fill="#B8AE9E"/>' +
  '<circle cx="256" cy="240" r="34" fill="#A99F8F"/><path d="M202 420c0-52 24-86 54-86s54 34 54 86Z" fill="#A99F8F"/></svg>');

// Photos d'exemple fournies par Invitéo, une par modèle (fichiers de assets/modeles/photos/).
const PHOTOS = new Set(['monogramme-sable', 'arche-doree', 'sauge-programme', 'save-the-date-photo', 'fiancailles-plein-ecran', 'romance-doree', 'aquarelle-bleu', 'arche-creme']);

function sampleData(tpl) {
  const d = new Date(Date.now() + 75 * 86400000); d.setUTCHours(13, 30, 0, 0); // 15 h 30 à Lubumbashi
  const birthday = tpl && tpl.event_type === 'birthday';
  return {
    state: 'ok',
    event: {
      name: birthday ? 'Anniversaire de Grâce' : 'Mariage de Awa et Jean',
      type: tpl ? tpl.event_type : 'wedding',
      celebrated_names: birthday ? 'Grâce' : 'Awa & Jean',
      starts_at: d.toISOString(), timezone: 'Africa/Lubumbashi',
      venue_name: 'Salle Les Jardins', address: 'Avenue Kasavubu, Lubumbashi', maps_url: null,
      program: [{ time: '15h30', title: 'Cérémonie' }, { time: '17h00', title: 'Réception' }, { time: '20h00', title: 'Soirée dansante' }],
      message: 'Nous serions heureux de partager avec vous ce moment de joie.',
      extra_info: 'Tenue élégante. Merci de confirmer votre présence.',
      theme: {}, rsvp_enabled: true, show_qr: false,
    },
    guest: { full_name: 'Invité(e) exemple', party_size: 1 },
    invitation: { max_entries: 1 },
    rsvp: null,
    template: tpl ? { slug: tpl.slug, name: tpl.name, config: tpl.config } : null,
  };
}

function catalogue(list) {
  const items = list.map((t) => `<li><a class="cat-card" href="/api/preview?slug=${encodeURIComponent(t.slug)}"><span class="cat-sw" aria-hidden="true">${['bg', 'paper', 'accent', 'text'].map((k) => `<i style="background:${/^#[0-9a-fA-F]{6}$/.test((t.config.palette || {})[k]) ? t.config.palette[k] : '#ccc'}"></i>`).join('')}</span><b>${esc(t.name)}</b><span>${esc(t.description || '')}</span><em>Voir l'aperçu</em></a></li>`).join('');
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow"><title>Modèles d'invitation — Invitéo</title><link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/assets/invitation.css"><link rel="stylesheet" href="/assets/catalogue.css"></head>
<body class="catalogue"><main class="cat"><p class="brand">Invitéo</p><h1>Nos modèles d'invitation</h1><p class="cat-lead">Ouvrez un modèle pour voir son rendu animé avec des informations d'exemple. Chaque photo se remplace par la vôtre.</p><ul class="cat-grid">${items}</ul><p class="cat-foot"><a href="/">Retour au site</a></p></main></body></html>`;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405, { Allow: 'GET, HEAD' }); return res.end(); }
  const slug = new URL(req.url, 'http://x').searchParams.get('slug');
  let list;
  try { list = await rpc('list_templates', {}); } catch (_) { return send(res, 503, renderError('unavailable')); }
  if (!Array.isArray(list)) return send(res, 503, renderError('unavailable'));
  if (slug == null) return send(res, 200, catalogue(list));
  const tpl = /^[a-z0-9-]{1,60}$/.test(slug) ? list.find((t) => t.slug === slug) : null;
  if (!tpl) return send(res, 404, renderError('not_found'));
  const open = new URL(req.url, 'http://x').searchParams.get('cover') !== '0';
  const html = renderInvitation(sampleData(tpl), 'preview', [], { sample: true, demoPhoto: PHOTOS.has(tpl.slug) ? '/assets/modeles/photos/' + tpl.slug + '.jpg' : DEMO_PHOTO, noCover: !open });
  return send(res, 200, html);
};
