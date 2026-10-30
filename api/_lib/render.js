'use strict';
// Rendu HTML de la page d'invitation. Tout texte venant de la base est échappé ;
// couleurs, polices et URL sont validées avant d'entrer dans le HTML ou le CSS.

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const COLOR = /^#[0-9a-fA-F]{6}$/;
const COVERS = ['envelope', 'ticket', 'curtain', 'seal'];
const ORNAMENTS = ['floral-fine', 'floral-soft', 'none', 'laurel', 'rule'];
const { DESIGNS, renderCard, splitNames, OWN_PROGRAM, FONTS, fmt, dateParts } = require('./designs');
const SITE = () => (process.env.PUBLIC_SITE_URL || 'https://inviteo-dun.vercel.app').replace(/\/+$/, '');

function safeColor(v, d) { return typeof v === 'string' && COLOR.test(v) ? v : d; }
function safeFont(v, d) { return Object.prototype.hasOwnProperty.call(FONTS, v) ? v : d; }
function safeHttps(u) { try { const x = new URL(u); return x.protocol === 'https:' ? x.href : null; } catch (_) { return null; } }


function ornament(kind) {
  if (kind === 'none') return '';
  if (kind === 'rule') return '<div class="orn orn-rule" aria-hidden="true"></div>';
  return `<svg class="orn orn-${esc(kind)}" viewBox="0 0 120 24" aria-hidden="true"><path d="M4 12h38M78 12h38" stroke="currentColor" stroke-width="1" fill="none"/><path d="M60 4c4 4 4 12 0 16-4-4-4-12 0-16Z M50 8c5 1 8 5 8 10-5-1-8-5-8-10Z M70 8c-5 1-8 5-8 10 5-1 8-5 8-10Z" fill="none" stroke="currentColor" stroke-width="1"/></svg>`;
}

function stateMessage(state, ev) {
  const m = {
    not_found: ['Invitation introuvable', "Ce lien ne correspond à aucune invitation. Vérifiez que vous l'avez copié en entier, ou contactez la personne qui vous l'a envoyé."],
    revoked: ['Invitation annulée', "Cette invitation n'est plus valable. Contactez l'organisateur si vous pensez qu'il s'agit d'une erreur."],
    expired: ['Invitation expirée', "La durée de validité de cette invitation est dépassée."],
    cancelled: ['Événement annulé', `${ev && ev.name ? esc(ev.name) + ' a été annulé.' : "Cet événement a été annulé."}`],
    event_closed: ['Événement terminé', `${ev && ev.name ? esc(ev.name) + ' est terminé.' : 'Cet événement est terminé.'}`],
    unavailable: ['Service momentanément indisponible', 'Réessayez dans quelques instants.'],
  }[state] || ['Invitation introuvable', ''];
  return m;
}

function shell(title, body, { head = '', bodyAttr = '', scripts = '', cssVars = '', after = '' } = {}) {
  return `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow, noarchive">
<meta name="referrer" content="no-referrer">
<title>${esc(title)}</title>
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
${head}
<link rel="stylesheet" href="/assets/invitation.css">
${after}
${cssVars ? `<style>${cssVars}</style>` : ''}
</head>
<body ${bodyAttr}>
${body}
${scripts}
</body>
</html>`;
}

function renderError(state, ev) {
  const [h, p] = stateMessage(state, ev);
  const body = `<main class="notice"><p class="brand">Invitéo</p><h1>${esc(h)}</h1><p>${p}</p></main>`;
  return shell(h, body, { bodyAttr: 'class="is-notice"' });
}


function renderInvitation(data, token, signedPhotos, opts) {
  opts = opts || {};
  const ev = data.event, g = data.guest, t = (data.template && data.template.config) || {};
  const design = DESIGNS.includes(t.design) ? t.design : null;
  const pal = Object.assign({}, t.palette || {}, (ev.theme && ev.theme.palette) || {});
  const bg = safeColor(pal.bg, '#FAF7F1'), paper = safeColor(pal.paper, '#FFFFFF'), text = safeColor(pal.text, '#25221F');
  const muted = safeColor(pal.muted, '#6B655E'), accent = safeColor(pal.accent, '#E86D32'), washC = safeColor(pal.wash, accent);
  const fd = safeFont(t.fonts && t.fonts.display, 'Fraunces'), fb = safeFont(t.fonts && t.fonts.body, 'DM Sans'), fs = safeFont(t.fonts && t.fonts.script, fd);
  const cover = COVERS.includes(t.cover) ? t.cover : 'envelope';
  const orn = ORNAMENTS.includes(t.ornament) ? t.ornament : 'rule';
  const tz = ev.timezone || 'Africa/Lubumbashi';

  const fams = [...new Set([fd, fb, fs])].map((f) => 'family=' + FONTS[f]).join('&');
  const head = `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link rel="stylesheet" href="https://fonts.googleapis.com/css2?${fams}&display=swap">`;
  const cssVars = `:root{--bg:${bg};--paper:${paper};--text:${text};--muted:${muted};--accent:${accent};--wash:${washC};--f-display:'${fd}',Georgia,serif;--f-script:'${fs}','Snell Roundhand',cursive;--f-body:'${fb}',system-ui,sans-serif}`;

  const dateLong = fmt(ev.starts_at, tz, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  const timeStr = fmt(ev.starts_at, tz, { hour: '2-digit', minute: '2-digit' }).replace(':', 'h');
  const mapsUrl = ev.maps_url ? safeHttps(ev.maps_url) : null;

  const program = Array.isArray(ev.program) ? ev.program.slice(0, 30) : [];
  const programHtml = program.length ? `<section class="block reveal" aria-labelledby="h-prog"><h2 id="h-prog">Programme</h2><ol class="program">${program.map((p) => `<li><span class="p-time">${esc(p && p.time)}</span><span class="p-label">${esc(p && (p.title || p.label))}</span></li>`).join('')}</ol></section>` : '';

  // Photo principale (kind « cover », sinon la première photo) ; le reste forme la galerie.
  let heroPhoto = null, gallery = signedPhotos.slice();
  if (design) {
    const ci = gallery.findIndex((p) => p.kind === 'cover');
    const hi = ci >= 0 ? ci : (gallery.length ? 0 : -1);
    if (hi >= 0) heroPhoto = gallery.splice(hi, 1)[0];
    else if (opts.demoPhoto) heroPhoto = { url: opts.demoPhoto, alt: '', demo: true };
  }
  const photosHtml = gallery.length ? `<section class="block reveal" aria-label="Photos"><div class="photos n${Math.min(gallery.length, 6)}">${gallery.slice(0, 6).map((p) => `<img src="${esc(p.url)}" alt="${esc(p.alt || '')}" loading="lazy" decoding="async"${p.width && p.height ? ` width="${Number(p.width) | 0}" height="${Number(p.height) | 0}"` : ''}>`).join('')}</div></section>` : '';

  const rsvp = data.rsvp;
  const maxE = Number(data.invitation.max_entries) || 1;
  const rsvpHtml = ev.rsvp_enabled ? `<section class="block reveal" aria-labelledby="h-rsvp" id="rsvp"><h2 id="h-rsvp">Votre réponse</h2>
<form id="rsvp-form" novalidate data-max="${maxE}" data-default="${Number(g.party_size) || 1}">
<fieldset><legend class="sr-only">Serez-vous présent ?</legend>
<label class="choice"><input type="radio" name="attending" value="yes"${rsvp && rsvp.attending ? ' checked' : ''}><span>Je serai présent(e)</span></label>
<label class="choice"><input type="radio" name="attending" value="no"${rsvp && !rsvp.attending ? ' checked' : ''}><span>Je ne pourrai pas venir</span></label></fieldset>
${maxE > 1 ? `<label class="field" id="f-count">Nombre de personnes (maximum ${maxE})<input type="number" name="party_count" min="1" max="${maxE}" value="${rsvp && rsvp.attending ? Number(rsvp.party_count) : Number(g.party_size) || 1}" inputmode="numeric"></label>` : ''}
<label class="field" id="f-song">Une chanson pour la soirée ? (facultatif)<input type="text" name="song" maxlength="120" value="${esc(rsvp && rsvp.song)}" autocomplete="off"></label>
<label class="field">Un mot pour les hôtes (facultatif)<textarea name="note" maxlength="500" rows="3">${esc(rsvp && rsvp.note)}</textarea></label>
<button class="btn" type="submit">${rsvp ? 'Modifier ma réponse' : 'Envoyer ma réponse'}</button>
<p class="form-msg" id="rsvp-msg" role="status" aria-live="polite">${rsvp ? (rsvp.attending ? 'Réponse enregistrée : vous serez présent(e).' : 'Réponse enregistrée : vous ne serez pas présent(e).') : ''}</p>
</form></section>` : '';

  const qrHtml = ev.show_qr ? `<section class="block reveal ticket" aria-labelledby="h-qr" id="ticket" hidden><h2 id="h-qr">Votre billet d'entrée</h2>
<div id="qr" class="qr" role="img" aria-label="QR code d'entrée"></div>
<p class="ticket-note">Présentez ce code à l'entrée. Il est personnel : ne le partagez pas.${maxE > 1 ? ` Valable pour ${maxE} personnes au maximum.` : ''}</p></section>` : '';

  const guestLine = `<p class="greet-line reveal">Pour <b>${esc(g.full_name)}</b></p>`;
  let heroHtml, messageHtml, ownProgram = false;
  if (design) {
    const names = splitNames(ev.celebrated_names, ev.name);
    const card = renderCard(design, {
      names, venue: ev.venue_name || '', address: ev.address || '', message: ev.message || '', extra: ev.extra_info || '',
      program, d: dateParts(ev.starts_at, tz), hero: heroPhoto, labels: t.labels || {},
    });
    heroHtml = `<header class="dz-wrap">${card}</header>${guestLine}`;
    messageHtml = '';
    ownProgram = OWN_PROGRAM.has(design);
  } else {
    heroHtml = `<header class="hero reveal"><p class="eyebrow">${esc(ev.name)}</p><h1>${esc(ev.celebrated_names || ev.name)}</h1>${ornament(orn)}
  <p class="when"><time datetime="${esc(ev.starts_at)}">${esc(dateLong)} · ${esc(timeStr)}</time></p>
  <p class="greet">Cher(e) ${esc(g.full_name)},</p></header>`;
    messageHtml = ev.message ? `<section class="block reveal"><p class="message">${esc(ev.message).replace(/\n/g, '<br>')}</p></section>` : '';
  }

  const coverHtml = opts.noCover ? '' : `<div class="cover" id="cover" data-cover="${cover}">
  <div class="cover-inner"><p class="brand">Invitéo</p><p class="cover-to">Invitation pour</p><p class="cover-guest">${esc(g.full_name)}</p>
  <button class="btn btn-open" id="open" type="button">Ouvrir l'invitation</button></div>
</div>`;
  const body = `${opts.sample ? `<div class="pv-bar" role="note">Aperçu avec des informations d'exemple${opts.demoPhoto ? ' · la photo est un exemple, vous mettrez la vôtre' : ''}</div>` : ''}${coverHtml}
<main class="page${design ? ' is-design' : ''}" id="page" aria-hidden="true">
  ${heroHtml}
  ${messageHtml}
  <section class="block reveal" id="countdown-block" data-start="${esc(ev.starts_at)}" hidden><h2 class="sr-only">Compte à rebours</h2><div class="countdown" aria-live="off"><div><b data-u="d">0</b><span>jours</span></div><div><b data-u="h">0</b><span>heures</span></div><div><b data-u="m">0</b><span>minutes</span></div></div></section>
  <section class="block reveal" aria-labelledby="h-where"><h2 id="h-where">Lieu</h2><p class="venue">${esc(ev.venue_name)}</p>${ev.address ? `<p class="addr">${esc(ev.address)}</p>` : ''}${mapsUrl ? `<p><a class="btn btn-line" href="${esc(mapsUrl)}" target="_blank" rel="noopener noreferrer">Voir l'itinéraire</a></p>` : ''}</section>
  ${ownProgram ? '' : programHtml}${photosHtml}
  ${ev.extra_info && design !== 'sauge' ? `<section class="block reveal"><h2>À savoir</h2><p>${esc(ev.extra_info).replace(/\n/g, '<br>')}</p></section>` : ''}
  ${rsvpHtml}${qrHtml}
  <footer class="foot"><p>Invitation personnelle, ne la transmettez pas.</p><p class="brand-small">Créée avec Invitéo</p></footer>
</main>`;

  const scripts = `<script src="/assets/qr.js"></script><script src="/assets/invitation.js" data-token="${esc(token)}" data-site="${esc(SITE())}" data-show-qr="${ev.show_qr ? '1' : '0'}"${opts.sample ? ' data-preview="1"' : ''}></script>`;
  const designCss = design ? '<link rel="stylesheet" href="/assets/designs.css">' : '';
  return shell(`${ev.name} — invitation`, body, { head, after: designCss, scripts, cssVars, bodyAttr: `class="tpl-${design ? 'design ' + esc(design) : esc(orn)}"` });
}

module.exports = { renderInvitation, renderError, esc, dateParts };
