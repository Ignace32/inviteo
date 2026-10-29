/* Invitéo — éditeur d'invitation : choix du modèle, informations, couleurs, photos remplaçables (recadrage), aperçu en direct.
   Rien n'est enregistré avant « Enregistrer » ; les photos passent par /api/photo (bucket privé), les textes par /api/organizer. */
(function () {
  'use strict';
  var A = window.__orgApi, D = window.InviteoDesigns;
  if (!A || !D) return;
  var $ = function (id) { return document.getElementById(id); }, el = A.el, st = A.st;
  var TZ = 'Africa/Lubumbashi';
  var TYPES = { wedding: 'Mariage', birthday: 'Anniversaire', baptism: 'Cérémonie familiale', graduation: 'Diplôme', corporate: 'Professionnel', other: 'Autre' };
  var PAL = [['bg', 'Fond'], ['paper', 'Papier'], ['text', 'Texte'], ['muted', 'Texte secondaire'], ['accent', 'Accent'], ['wash', 'Aquarelle']];
  var DEMO = 'data:image/svg+xml;utf8,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 560"><rect width="400" height="560" fill="#D9D2C7"/><rect y="330" width="400" height="230" fill="#C7BEB0"/><circle cx="150" cy="250" r="34" fill="#B8AE9E"/><path d="M96 420c0-52 24-86 54-86s54 34 54 86Z" fill="#B8AE9E"/><circle cx="256" cy="240" r="34" fill="#A99F8F"/><path d="M202 420c0-52 24-86 54-86s54 34 54 86Z" fill="#A99F8F"/></svg>');
  var ERR = { name_required: "Le nom de l'événement est obligatoire.", template_invalid: "Ce modèle n'est plus disponible.", type_invalid: "Type d'événement invalide.", date_invalid: 'La date est invalide.',
    invalid_field: 'Un champ est trop long ou invalide.', publish_requires_venue_and_names: 'Pour publier, renseignez le lieu et les personnes célébrées.', agent_not_allowed: "Un agent choisi n'est pas autorisé.",
    agent_duplicated: 'Un agent est sélectionné deux fois.', program_too_long: 'Le programme est trop long (30 étapes maximum).', event_locked: 'Cet événement est terminé ou annulé : il ne peut plus être modifié.',
    too_many_photos: 'Trop de photos.', file_too_big: 'La photo est trop lourde.', unsupported_type: 'Format non pris en charge (JPEG, PNG ou WebP).', image_too_small: 'La photo est trop petite (200 px minimum).', image_too_large: 'La photo est trop grande.' };

  var E = { mode: 'new', id: null, status: 'draft', templates: [], agents: [], tpl: null, filter: 'all', pal: {}, photo: null, saved: null, tab: 'form', timer: null };
  // E.photo : { url, blob?, id?, removed? }  — blob = recadrée, pas encore envoyée ; id = enregistrée ; removed = à retirer à l'enregistrement

  var form = $('e-form');
  function setMsg(t, err) { var m = $('e-msg'); m.className = 'msg' + (err ? ' err' : ''); m.textContent = t || ''; }
  function tplCfg() { var t = E.templates.filter(function (x) { return x.slug === E.tpl; })[0]; return t ? t.config || {} : {}; }
  function effPal() { return Object.assign({}, tplCfg().palette || {}, E.pal); }

  /* ---------- dates (heure de Lubumbashi) ---------- */
  function toLocalInput(iso) { try { return new Intl.DateTimeFormat('sv-SE', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace(' ', 'T'); } catch (_) { return ''; } }
  function fromLocalInput(v) { return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(v) ? v + ':00+02:00' : null; }

  /* ---------- modèles ---------- */
  function renderTypes() {
    var box = $('e-types'); box.textContent = '';
    var types = ['all']; E.templates.forEach(function (t) { if (types.indexOf(t.event_type) < 0) types.push(t.event_type); });
    types.forEach(function (k) {
      var b = el('button', null, k === 'all' ? 'Tous' : (TYPES[k] || k)); b.type = 'button'; b.setAttribute('aria-pressed', String(E.filter === k));
      b.addEventListener('click', function () { E.filter = k; renderTypes(); renderTemplates(); }); box.appendChild(b);
    });
  }
  function renderTemplates() {
    var box = $('e-templates'); box.textContent = '';
    E.templates.filter(function (t) { return E.filter === 'all' || t.event_type === E.filter; }).forEach(function (t) {
      var b = el('button', 'tpl-card'); b.type = 'button'; b.setAttribute('aria-pressed', String(t.slug === E.tpl)); b.dataset.slug = t.slug;
      var sw = el('span', 'sw'); ['bg', 'paper', 'accent', 'text'].forEach(function (k) { var i = document.createElement('i'); var c = (t.config.palette || {})[k]; if (/^#[0-9a-fA-F]{6}$/.test(c || '')) i.style.background = c; sw.appendChild(i); });
      b.appendChild(sw); b.appendChild(el('b', null, t.name)); b.appendChild(el('span', 'd', t.description || ''));
      b.addEventListener('click', function () { pickTemplate(t.slug); }); box.appendChild(b);
    });
  }
  function pickTemplate(slug) {
    E.tpl = slug; E.pal = {}; renderTemplates(); renderColors(); renderSlots(); preview();
    var t = E.templates.filter(function (x) { return x.slug === slug; })[0];
    if (t && E.mode === 'new' && TYPES[t.event_type]) $('f-type').value = t.event_type;
  }

  /* ---------- couleurs ---------- */
  function renderColors() {
    var box = $('e-colors'); box.textContent = ''; var base = tplCfg().palette || {}, eff = effPal();
    PAL.forEach(function (p) {
      if (!base[p[0]] && p[0] === 'wash') return;
      var l = el('label', null, p[1]), i = document.createElement('input'); i.type = 'color'; i.value = /^#[0-9a-fA-F]{6}$/.test(eff[p[0]] || '') ? eff[p[0]] : '#000000'; i.dataset.k = p[0];
      i.addEventListener('input', function () { E.pal[p[0]] = i.value; preview(); }); l.appendChild(i); box.appendChild(l);
    });
  }
  $('e-reset-colors').addEventListener('click', function () { E.pal = {}; renderColors(); preview(); });

  /* ---------- programme ---------- */
  function addStep(time, title) {
    var r = el('div', 'prog-row'), a = document.createElement('input'), b = document.createElement('input');
    a.maxLength = 10; a.placeholder = '15h30'; a.value = time || ''; a.setAttribute('aria-label', 'Heure'); b.maxLength = 120; b.placeholder = 'Cérémonie'; b.value = title || ''; b.setAttribute('aria-label', 'Étape');
    var x = el('button', 'btn btn-sm btn-line', '✕'); x.type = 'button'; x.setAttribute('aria-label', 'Retirer cette étape'); x.addEventListener('click', function () { r.remove(); preview(); });
    a.addEventListener('input', preview); b.addEventListener('input', preview); r.appendChild(a); r.appendChild(b); r.appendChild(x); $('e-program').appendChild(r);
  }
  $('e-add-step').addEventListener('click', function () { if ($('e-program').children.length < 30) addStep('', ''); });
  function readProgram() { var out = []; Array.prototype.forEach.call($('e-program').children, function (r) { var i = r.querySelectorAll('input'); if (i[1].value.trim()) out.push({ time: i[0].value.trim(), title: i[1].value.trim() }); }); return out; }

  /* ---------- données du formulaire ---------- */
  function read() {
    var f = form.elements;
    return { name: f.name.value.trim(), celebrated_names: f.celebrated_names.value.trim(), starts_at: fromLocalInput(f.starts_at.value), venue_name: f.venue_name.value.trim(), address: f.address.value.trim(), maps_url: f.maps_url.value.trim(),
      message: f.message.value.trim(), extra_info: f.extra_info.value.trim(), program: readProgram(), rsvp_enabled: f.rsvp_enabled.checked, show_qr_on_page: f.show_qr_on_page.checked, event_type: f.event_type.value };
  }
  function fill(d) {
    var f = form.elements;
    f.name.value = d.name || ''; f.celebrated_names.value = d.celebrated_names || ''; f.starts_at.value = d.starts_at ? toLocalInput(d.starts_at) : ''; f.venue_name.value = d.venue_name || ''; f.address.value = d.address || '';
    f.maps_url.value = d.maps_url || ''; f.message.value = d.message || ''; f.extra_info.value = d.extra_info || ''; f.rsvp_enabled.checked = !!d.rsvp_enabled; f.show_qr_on_page.checked = !!d.show_qr_on_page;
    f.event_type.value = d.event_type || 'wedding'; f.publish.checked = false;
    $('e-program').textContent = ''; (d.program || []).forEach(function (p) { addStep(p.time, p.title || p.label); });
  }

  /* ---------- aperçu en direct ---------- */
  var fontLink = null;
  function loadFonts(t) {
    var f = t.fonts || {}, names = []; ['display', 'body', 'script'].forEach(function (k) { if (f[k] && D.FONTS[f[k]] && names.indexOf(f[k]) < 0) names.push(f[k]); });
    var href = 'https://fonts.googleapis.com/css2?' + names.map(function (n) { return 'family=' + D.FONTS[n]; }).join('&') + '&display=swap';
    if (!names.length) return; if (!fontLink) { fontLink = document.createElement('link'); fontLink.rel = 'stylesheet'; document.head.appendChild(fontLink); }
    if (fontLink.href !== href) fontLink.href = href;
  }
  function safeFont(n, d) { return Object.prototype.hasOwnProperty.call(D.FONTS, n) ? n : d; }
  function preview(replay) {
    var pv = $('pv'), t = tplCfg(), d = read(), pal = effPal(), design = D.DESIGNS.indexOf(t.design) >= 0, fo = t.fonts || {};
    var sample = new Date(Date.now() + 75 * 86400000); sample.setUTCHours(13, 30, 0, 0);
    ['bg', 'paper', 'text', 'muted', 'accent', 'wash'].forEach(function (k) { var v = /^#[0-9a-fA-F]{6}$/.test(pal[k] || '') ? pal[k] : (k === 'wash' ? pal.accent : null); if (v) pv.style.setProperty('--' + k, v); });
    var fd = safeFont(fo.display, 'Fraunces'), fb = safeFont(fo.body, 'DM Sans'), fs = safeFont(fo.script, fd);
    pv.style.setProperty('--f-display', "'" + fd + "',Georgia,serif"); pv.style.setProperty('--f-script', "'" + fs + "','Snell Roundhand',cursive"); pv.style.setProperty('--f-body', "'" + fb + "',system-ui,sans-serif"); loadFonts(t);
    pv.classList.toggle('static', !replay); pv.textContent = '';
    var iso = d.starts_at || sample.toISOString(), names = d.celebrated_names || d.name || 'Awa & Jean';
    var hero = E.photo && !E.photo.removed && E.photo.url ? { url: E.photo.url, alt: '' } : { url: DEMO, alt: '', demo: true };
    if (design) {
      var wrap = document.createElement('div'); wrap.className = 'dz-wrap';
      wrap.innerHTML = D.renderCard(t.design, { names: D.splitNames(names, names), venue: d.venue_name || 'Nom du lieu', address: d.address, message: d.message, extra: d.extra_info, program: d.program,
        d: D.dateParts(iso, TZ), hero: hero, labels: t.labels || {} });
      pv.appendChild(wrap); $('pv-note').textContent = E.photo && !E.photo.removed ? '' : "La photo d'exemple sera remplacée par la vôtre.";
    } else {
      var s = el('div', 'pv-simple'); s.appendChild(el('p', null, d.name || "Nom de l'événement")); s.appendChild(el('h3', null, names)); s.appendChild(el('p', null, D.fmt(iso, TZ, { dateStyle: 'full', timeStyle: 'short' })));
      s.appendChild(el('p', null, d.venue_name || 'Nom du lieu')); pv.appendChild(s); $('pv-note').textContent = "Aperçu simplifié : ce modèle s'affiche avec la mise en page classique.";
    }
    var full = $('pv-full'); full.href = E.tpl ? '/modeles/' + encodeURIComponent(E.tpl) : '#';
    if (replay) { clearTimeout(E.timer); E.timer = setTimeout(function () { pv.classList.add('static'); }, 6500); }
  }
  document.documentElement.classList.add('js', 'is-open');
  form.addEventListener('input', function (e) { if (e.target.id !== 'e-file') preview(); });
  $('pv-replay').addEventListener('click', function () { preview(true); });

  /* ---------- plein écran et onglets ---------- */
  function closeFs() { $('pv').closest('.e-pv').classList.remove('fs'); }
  var fsBtn = el('button', 'btn btn-sm btn-line', 'Plein écran'); fsBtn.type = 'button'; $('pv-replay').after(fsBtn);
  fsBtn.addEventListener('click', function () { var a = $('pv').closest('.e-pv'); a.classList.toggle('fs'); fsBtn.textContent = a.classList.contains('fs') ? 'Fermer' : 'Plein écran'; });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && $('pv').closest('.e-pv').classList.contains('fs')) { closeFs(); fsBtn.textContent = 'Plein écran'; } });
  function tab(t) { E.tab = t; document.querySelector('.e-grid').dataset.tab = t; $('tab-form').setAttribute('aria-selected', String(t === 'form')); $('tab-pv').setAttribute('aria-selected', String(t === 'pv')); }
  $('tab-form').addEventListener('click', function () { tab('form'); }); $('tab-pv').addEventListener('click', function () { tab('pv'); preview(true); });

  /* ---------- photos : choix, recadrage, import ---------- */
  function slots() { var s = tplCfg().slots || {}; return Object.keys(s).map(function (k) { return { key: k, ratio: Number(s[k].ratio) || 1, label: s[k].label || 'Photo' }; }); }
  function renderSlots() {
    var box = $('e-slots'); box.textContent = '';
    var list = slots(); if (!list.length) { box.appendChild(el('p', 'hint', "Ce modèle n'a pas de zone photo principale.")); return; }
    list.forEach(function (s) {
      var row = el('div', 'slot'), th = el('div', 'th'), has = E.photo && !E.photo.removed && E.photo.url;
      th.style.backgroundImage = 'url("' + (has ? E.photo.url : DEMO) + '")'; row.appendChild(th);
      var tx = el('div', 'tx'); tx.appendChild(el('b', null, s.label)); tx.appendChild(el('small', null, has ? (E.photo.blob ? 'Nouvelle photo (à enregistrer)' : 'Votre photo') : "Photo d'exemple : remplacez-la")); row.appendChild(tx);
      var a = el('div', 'acts'), b = el('button', 'btn btn-sm', has ? 'Remplacer' : 'Choisir une photo'); b.type = 'button'; b.addEventListener('click', function () { E.slot = s; $('e-file').value = ''; $('e-file').click(); }); a.appendChild(b);
      if (has) { var r = el('button', 'btn btn-sm btn-danger', 'Supprimer'); r.type = 'button'; r.addEventListener('click', function () { removePhoto(); }); a.appendChild(r); }
      row.appendChild(a); box.appendChild(row);
    });
  }
  function removePhoto() {
    if (E.photo && E.photo.blob && E.photo.url) URL.revokeObjectURL(E.photo.url);
    if (E.photo && E.photo.id) E.photo = { id: E.photo.id, removed: true }; else E.photo = null;
    renderSlots(); preview(); $('e-photo-msg').textContent = "Photo retirée : l'image d'exemple est affichée.";
  }
  var C = { img: null, ratio: 1, w: 0, h: 0, scale: 1, min: 1, x: 0, y: 0, drag: null };
  function cropDraw() {
    var cv = $('c-canvas'), g = cv.getContext('2d'); g.fillStyle = '#222'; g.fillRect(0, 0, C.w, C.h);
    var iw = C.img.width * C.scale, ih = C.img.height * C.scale; g.drawImage(C.img, C.x, C.y, iw, ih);
  }
  function clampPos() { var iw = C.img.width * C.scale, ih = C.img.height * C.scale; C.x = Math.min(0, Math.max(C.w - iw, C.x)); C.y = Math.min(0, Math.max(C.h - ih, C.y)); }
  function openCrop(img) {
    C.img = img; C.ratio = E.slot.ratio; C.w = 480; C.h = Math.round(480 / C.ratio); if (C.h > 720) { C.h = 720; C.w = Math.round(720 * C.ratio); }
    var cv = $('c-canvas'); cv.width = C.w; cv.height = C.h; C.min = Math.max(C.w / img.width, C.h / img.height); C.scale = C.min; $('c-zoom').value = 100;
    C.x = (C.w - img.width * C.scale) / 2; C.y = (C.h - img.height * C.scale) / 2; $('c-msg').textContent = ''; cropDraw(); $('dlg-crop').showModal();
  }
  (function () {
    var box = $('c-box');
    function pos(e) { var r = box.getBoundingClientRect(); return { x: (e.clientX - r.left) * C.w / r.width, y: (e.clientY - r.top) * C.h / r.height }; }
    box.addEventListener('pointerdown', function (e) { C.drag = pos(e); box.setPointerCapture(e.pointerId); box.style.cursor = 'grabbing'; });
    box.addEventListener('pointermove', function (e) { if (!C.drag) return; var p = pos(e); C.x += p.x - C.drag.x; C.y += p.y - C.drag.y; C.drag = p; clampPos(); cropDraw(); });
    var end = function () { C.drag = null; box.style.cursor = 'grab'; }; box.addEventListener('pointerup', end); box.addEventListener('pointercancel', end);
    $('c-zoom').addEventListener('input', function () {
      var cx = (C.w / 2 - C.x) / C.scale, cy = (C.h / 2 - C.y) / C.scale; C.scale = C.min * Number($('c-zoom').value) / 100;
      C.x = C.w / 2 - cx * C.scale; C.y = C.h / 2 - cy * C.scale; clampPos(); cropDraw();
    });
  })();
  $('c-cancel').addEventListener('click', function () { $('dlg-crop').close(); });
  $('c-ok').addEventListener('click', function () {
    // zone visible de l'image d'origine → fichier JPEG (grand côté ≤ 1600 px, jamais agrandi)
    var sx = -C.x / C.scale, sy = -C.y / C.scale, sw = C.w / C.scale, sh = C.h / C.scale, k = Math.min(1, 1600 / Math.max(sw, sh));
    var out = document.createElement('canvas'); out.width = Math.max(1, Math.round(sw * k)); out.height = Math.max(1, Math.round(sh * k));
    out.getContext('2d').drawImage(C.img, sx, sy, sw, sh, 0, 0, out.width, out.height);
    out.toBlob(function (b) {
      if (!b || b.size > 4 * 1024 * 1024 || out.width < 200 || out.height < 200) { $('c-msg').textContent = out.width < 200 || out.height < 200 ? 'Photo trop petite : choisissez une image plus grande.' : 'La photo reste trop lourde : choisissez-en une autre.'; return; }
      if (E.photo && E.photo.blob && E.photo.url) URL.revokeObjectURL(E.photo.url);
      E.photo = { blob: b, url: URL.createObjectURL(b), id: E.photo && E.photo.id, removed: false }; $('dlg-crop').close(); renderSlots(); preview(); $('e-photo-msg').className = 'msg'; $('e-photo-msg').textContent = 'Photo prête. Cliquez sur « Enregistrer » pour la conserver.';
    }, 'image/jpeg', 0.88);
  });
  $('e-file').addEventListener('change', function (e) {
    var f = e.target.files[0], m = $('e-photo-msg'); if (!f) return; m.className = 'msg err';
    if (['image/jpeg', 'image/png', 'image/webp'].indexOf(f.type) < 0) { m.textContent = 'Format non pris en charge : choisissez une photo JPEG, PNG ou WebP.'; return; }
    if (f.size > 15 * 1024 * 1024) { m.textContent = 'Photo trop lourde (15 Mo maximum).'; return; }
    m.className = 'msg'; m.textContent = 'Ouverture de la photo…';
    var done = function (img) { m.textContent = ''; openCrop(img); }, fail = function () { m.className = 'msg err'; m.textContent = "Cette photo n'a pas pu être lue."; };
    if (window.createImageBitmap) createImageBitmap(f).then(done, fail);
    else { var u = URL.createObjectURL(f), i = new Image(); i.onload = function () { URL.revokeObjectURL(u); done(i); }; i.onerror = fail; i.src = u; }
  });

  /* ---------- réseau authentifié (GET / POST / DELETE) ---------- */
  function fetchAuthed(url, init) {
    function go() { var h = Object.assign({}, init.headers || {}, { Authorization: 'Bearer ' + st.access }); return fetch(url, Object.assign({}, init, { headers: h })); }
    return go().then(function (r) { return r.status !== 401 ? r : A.refresh().then(function (ok) { return ok ? go() : r; }); });
  }

  /* ---------- ouverture : nouveau / modification ---------- */
  function loadCommon() {
    return Promise.all([A.call('list_templates'), A.call('my_agents').catch(function () { return []; })]).then(function (r) { E.templates = r[0] || []; E.agents = r[1] || []; });
  }
  function firstTpl() { var d = E.templates.filter(function (t) { return t.config && D.DESIGNS.indexOf(t.config.design) >= 0; })[0]; return (d || E.templates[0] || {}).slug || null; }
  function reset() { E.pal = {}; E.photo = null; E.filter = 'all'; setMsg(''); $('e-photo-msg').textContent = ''; closeFs(); tab('form'); }
  function openNew() {
    reset(); E.mode = 'new'; E.id = null; E.status = 'draft'; $('e-title').textContent = 'Nouvel événement'; A.show('v-edit');
    loadCommon().then(function () {
      form.reset(); fill({ event_type: 'wedding', rsvp_enabled: true }); E.tpl = firstTpl(); renderTypes(); renderTemplates(); renderColors(); renderSlots();
      $('f-type').disabled = false; $('e-publish-box').hidden = false; $('e-save').textContent = 'Créer le brouillon';
      var ab = $('e-agents'); ab.textContent = ''; $('e-agents-box').hidden = !E.agents.length;
      E.agents.forEach(function (a) { var l = el('label', 'check'), c = document.createElement('input'); c.type = 'checkbox'; c.value = a.id; l.appendChild(c); l.appendChild(document.createTextNode(' ' + (a.full_name || a.email) + (a.email ? ' (' + a.email + ')' : ''))); ab.appendChild(l); });
      E.saved = null; preview(true);
    }, function () { setMsg('Impossible de charger les modèles.', true); });
  }
  function openEdit(ev) {
    reset(); E.mode = 'edit'; E.id = ev.id; $('e-title').textContent = 'Personnaliser : ' + ev.name; A.show('v-edit'); setMsg('Chargement…');
    Promise.all([loadCommon(), fetchAuthed('/api/photo?event=' + encodeURIComponent(ev.id), { method: 'GET' }).then(function (r) { if (!r.ok) throw new Error('load'); return r.json(); })]).then(function (r) {
      var d = r[1], e = d.event; E.status = e.status; E.tpl = e.template || (E.templates[0] || {}).slug; E.pal = Object.assign({}, e.palette || {});
      var c = (d.photos || []).filter(function (p) { return p.kind === 'cover'; })[0] || (d.photos || [])[0]; E.photo = c && c.url ? { id: c.id, url: c.url } : null;
      form.reset(); fill(e); E.saved = { data: e, pal: Object.assign({}, E.pal), tpl: E.tpl, photo: E.photo };
      E.filter = 'all'; renderTypes(); renderTemplates(); renderColors(); renderSlots(); $('f-type').disabled = true; $('e-agents-box').hidden = true;
      $('e-publish-box').hidden = e.status !== 'draft'; $('e-save').textContent = 'Enregistrer'; setMsg(''); preview(true);
    }, function () { setMsg("Impossible de charger l'événement.", true); });
  }
  $('new-event').addEventListener('click', openNew);
  $('edit-event').addEventListener('click', function () { if (st.event) openEdit(st.event); });
  $('e-back').addEventListener('click', function () { if (E.mode === 'edit' && st.event) { A.openEvent(st.event); } else A.loadEvents(); });
  $('e-revert').addEventListener('click', function () {
    if (!confirm('Revenir au modèle initial ? Vos modifications non enregistrées seront perdues.')) return;
    if (E.photo && E.photo.blob && E.photo.url) URL.revokeObjectURL(E.photo.url);
    if (E.mode === 'edit' && E.saved) { E.pal = Object.assign({}, E.saved.pal); E.tpl = E.saved.tpl; E.photo = E.saved.photo; fill(E.saved.data); }
    else { E.pal = {}; E.photo = null; form.reset(); fill({ event_type: 'wedding', rsvp_enabled: true }); E.tpl = firstTpl(); }
    renderTemplates(); renderColors(); renderSlots(); preview(true); setMsg('');
  });

  /* ---------- enregistrement ---------- */
  function uploadPhoto(id) {
    if (!E.photo) return Promise.resolve();
    if (E.photo.removed) return fetchAuthed('/api/photo?asset=' + encodeURIComponent(E.photo.id), { method: 'DELETE' }).then(function (r) { if (!r.ok && r.status !== 404) throw new Error('photo'); E.photo = null; });
    if (!E.photo.blob) return Promise.resolve();
    return fetchAuthed('/api/photo?event=' + encodeURIComponent(id) + '&kind=cover', { method: 'POST', headers: { 'Content-Type': 'image/jpeg' }, body: E.photo.blob })
      .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { if (!r.ok || !j.ok) { var e = new Error(j.error || 'photo'); e.photoErr = true; throw e; } URL.revokeObjectURL(E.photo.url); E.photo = { id: j.id, url: j.url }; }); });
  }
  form.addEventListener('submit', function (e) {
    e.preventDefault(); var d = read(), btn = $('e-save');
    if (!d.name) { setMsg("Le nom de l'événement est obligatoire.", true); return; }
    if (!d.starts_at) { setMsg('Indiquez la date et l\'heure.', true); return; }
    if (d.maps_url && !/^https:\/\//i.test(d.maps_url)) { setMsg('Le lien Google Maps doit commencer par https://', true); return; }
    var publish = form.elements.publish.checked; btn.disabled = true; setMsg('Enregistrement…');
    var body = { name: d.name, celebrated_names: d.celebrated_names, starts_at: d.starts_at, venue_name: d.venue_name, address: d.address, maps_url: d.maps_url, message: d.message, extra_info: d.extra_info, program: d.program,
      rsvp_enabled: d.rsvp_enabled, show_qr_on_page: d.show_qr_on_page, template: E.tpl, publish: publish };
    var p;
    if (E.mode === 'new') {
      body.event_type = d.event_type; body.agent_ids = Array.prototype.map.call($('e-agents').querySelectorAll('input:checked'), function (c) { return c.value; });
      p = A.call('create_event', { p_data: body }).then(function (r) {
        if (!r || !r.ok) throw Object.assign(new Error((r && r.error) || 'error'), { app: true });
        E.id = r.id; E.mode = 'edit'; E.status = r.status; st.event = { id: r.id, name: d.name, starts_at: d.starts_at, venue_name: d.venue_name, status: r.status };
        return Object.keys(E.pal).length ? A.call('update_event', { p_event_id: r.id, p_data: { palette: E.pal } }) : null;
      });
    } else {
      body.palette = E.pal; delete body.publish; if (publish && E.status === 'draft') body.publish = true;
      p = A.call('update_event', { p_event_id: E.id, p_data: body }).then(function (r) { if (!r || !r.ok) throw Object.assign(new Error((r && r.error) || 'error'), { app: true }); E.status = r.status || E.status; });
    }
    p.then(function () { return uploadPhoto(E.id); }).then(function () {
      E.saved = { data: Object.assign({}, d, { starts_at: d.starts_at, template: E.tpl }), pal: Object.assign({}, E.pal), tpl: E.tpl, photo: E.photo };
      $('e-title').textContent = 'Personnaliser : ' + d.name; $('f-type').disabled = true; $('e-agents-box').hidden = true; $('e-publish-box').hidden = E.status !== 'draft'; form.elements.publish.checked = false; $('e-save').textContent = 'Enregistrer';
      st.event = Object.assign(st.event || {}, { id: E.id, name: d.name, starts_at: d.starts_at, venue_name: d.venue_name, status: E.status });
      renderSlots(); preview(); setMsg(E.status === 'published' ? 'Enregistré. L\'invitation est publiée.' : 'Enregistré (brouillon).', false);
    }, function (er) {
      if (er.photoErr) { renderSlots(); setMsg('Informations enregistrées, mais la photo n\'a pas été envoyée : ' + (ERR[er.message] || 'réessayez.'), true); }
      else if (er.status === 401) { /* session expirée : déjà gérée */ }
      else setMsg(er.app ? (ERR[er.message] || "L'enregistrement a échoué.") : er.status === 403 ? "Vous n'avez pas le droit de modifier cet événement." : "Pas d'enregistrement : service indisponible. Réessayez.", true);
    }).then(function () { btn.disabled = false; });
  });
  window.__editor = { read: read, state: E };
})();
