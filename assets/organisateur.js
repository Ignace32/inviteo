/* Invitéo — espace organisateur : événements, invités, émission des invitations, import CSV, statistiques.
   Tout passe par /api/organizer et /api/ticket avec le jeton de l'utilisateur ; la base applique les droits. */
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var st = { access: null, refresh: null, events: [], event: null, guests: [], blobUrl: null, csvRows: null };
  var KEY = 'inv_org_refresh';
  function store(v) { try { if (v == null) sessionStorage.removeItem(KEY); else sessionStorage.setItem(KEY, v); } catch (_) {} }
  function stored() { try { return sessionStorage.getItem(KEY); } catch (_) { return null; } }
  function show(v) { ['v-login', 'v-events', 'v-detail'].forEach(function (x) { $(x).hidden = x !== v; }); $('logout').hidden = v === 'v-login'; }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function fmtDate(iso) { try { return new Date(iso).toLocaleString('fr-FR', { dateStyle: 'long', timeStyle: 'short' }); } catch (_) { return ''; } }

  /* ---- réseau ---- */
  function raw(path, opts) {
    var h = { 'Content-Type': 'application/json' }; if (st.access) h.Authorization = 'Bearer ' + st.access;
    return fetch(path, { method: 'POST', headers: h, body: JSON.stringify(opts.body) });
  }
  function refresh() {
    if (!st.refresh) return Promise.resolve(false);
    return fetch('/api/auth', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: st.refresh }) })
      .then(function (r) { return r.ok ? r.json() : null; }).then(function (j) { if (!j) return false; session(j); return true; }, function () { return false; });
  }
  function session(j) { st.access = j.access_token; st.refresh = j.refresh_token; store(j.refresh_token); }
  function authed(path, body) {
    return raw(path, { body: body }).then(function (r) { return r.status !== 401 ? r : refresh().then(function (ok) { return ok ? raw(path, { body: body }) : r; }); });
  }
  function call(fn, args) {
    return authed('/api/organizer', { fn: fn, args: args || {} }).then(function (r) {
      if (r.status === 401) { logout('Session expirée. Reconnectez-vous.'); var e = new Error('auth'); e.status = 401; throw e; }
      return r.json().catch(function () { return {}; }).then(function (j) { if (!r.ok) { var e = new Error(j.error || 'error'); e.status = r.status; throw e; } return j.data; });
    });
  }

  /* ---- connexion ---- */
  $('login-form').addEventListener('submit', function (e) {
    e.preventDefault(); var f = e.target, msg = $('login-msg'), b = f.querySelector('button'); msg.textContent = ''; msg.className = 'msg';
    if (!f.email.value || !f.password.value) { msg.className = 'msg err'; msg.textContent = 'Saisissez votre e-mail et votre mot de passe.'; return; }
    b.disabled = true;
    fetch('/api/auth', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: f.email.value, password: f.password.value }) })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, s: r.status, j: j }; }); })
      .then(function (o) { if (o.ok) { f.password.value = ''; session(o.j); return loadEvents(); } msg.className = 'msg err'; msg.textContent = o.s === 401 ? 'E-mail ou mot de passe incorrect.' : 'Service indisponible. Réessayez.'; },
        function () { msg.className = 'msg err'; msg.textContent = 'Pas de connexion réseau.'; })
      .then(function () { b.disabled = false; });
  });
  $('logout').addEventListener('click', function () { logout(''); });
  function logout(note) { st.access = st.refresh = null; st.event = null; store(null); show('v-login'); var m = $('login-msg'); m.className = note ? 'msg err' : 'msg'; m.textContent = note || ''; }

  /* ---- liste des événements ---- */
  var STATUS = { draft: 'Brouillon', pending_review: 'En validation', published: 'Publié', finished: 'Terminé', cancelled: 'Annulé' };
  function loadEvents() {
    return call('organizer_events').then(function (list) {
      st.events = list || []; var box = $('event-cards'); box.textContent = '';
      $('events-msg').textContent = st.events.length ? '' : "Vous n'avez pas encore d'événement. Contactez Invitéo pour en créer un.";
      st.events.forEach(function (ev) {
        var c = el('button', 'card'); c.type = 'button';
        c.appendChild(el('b', null, ev.name)); c.appendChild(el('span', null, fmtDate(ev.starts_at) + ' · ' + ev.venue_name));
        var p = el('span', 'pill ' + ev.status, STATUS[ev.status] || ev.status); c.appendChild(p);
        c.appendChild(el('span', 'nums', ev.guests_total + ' invités · ' + ev.invitations_active + ' invitations · ' + ev.entries_validated + ' entrées'));
        c.addEventListener('click', function () { openEvent(ev); }); box.appendChild(c);
      });
      show('v-events');
    }, function (e) { if (e.status !== 401) { show('v-events'); $('events-msg').textContent = 'Impossible de charger vos événements.'; } });
  }
  $('back').addEventListener('click', function () { st.event = null; loadEvents(); });

  /* ---- détail d'un événement ---- */
  function openEvent(ev) {
    st.event = ev; $('d-name').textContent = ev.name; $('d-sub').textContent = fmtDate(ev.starts_at) + ' · ' + ev.venue_name + ' · ' + (STATUS[ev.status] || ev.status);
    $('search').value = ''; $('filter').value = 'all'; show('v-detail'); refreshDetail();
  }
  function refreshDetail() {
    var id = st.event.id; $('d-msg').textContent = 'Chargement…';
    return Promise.all([call('event_stats', { p_event_id: id }), call('event_guests', { p_event_id: id })]).then(function (r) {
      renderStats(r[0], r[1]); st.guests = r[1] || []; renderGuests(); $('d-msg').textContent = '';
    }, function (e) { if (e.status !== 401) { $('d-msg').className = 'msg err'; $('d-msg').textContent = 'Impossible de charger les données.'; } });
  }
  function renderStats(s, guests) {
    var yes = 0, no = 0; (guests || []).forEach(function (g) { if (g.rsvp) { if (g.rsvp.attending) yes += g.rsvp.party_count || 0; else no++; } });
    var tiles = [
      [(guests || []).length, 'invités'], [s.invitations_total, 'invitations émises'], [s.entries_validated + ' / ' + s.entries_authorized, 'entrées validées'],
      [yes, 'personnes attendues (réponses)'], [no, 'refus de venir'], [s.duplicate_attempts, 'tentatives en double'], [s.refused_attempts, 'scans refusés']
    ];
    var box = $('stats'); box.textContent = '';
    tiles.forEach(function (t) { var d = el('div', 'stat'); d.appendChild(el('b', null, String(t[0]))); d.appendChild(el('span', null, t[1])); box.appendChild(d); });
    var pct = s.entries_authorized ? Math.min(100, Math.round(100 * s.entries_validated / s.entries_authorized)) : 0;
    $('bar').style.width = pct + '%'; $('bar-label').textContent = pct + ' % des entrées autorisées sont déjà validées.';
  }
  function norm(s) { return String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, ''); }
  function renderGuests() {
    var q = norm($('search').value), f = $('filter').value, box = $('guests'); box.textContent = '';
    var list = st.guests.filter(function (g) {
      if (q && norm(g.full_name).indexOf(q) < 0) return false;
      var s = g.invitation && g.invitation.status;
      if (f === 'none') return !g.invitation; if (f === 'valid') return s === 'valid'; if (f === 'used') return g.invitation && g.invitation.entries_used > 0; if (f === 'nr') return g.invitation && !g.rsvp;
      return true;
    });
    if (!list.length) { box.appendChild(el('p', 'sub', st.guests.length ? 'Aucun invité ne correspond.' : "Aucun invité pour l'instant : importez un fichier CSV.")); return; }
    list.forEach(function (g) {
      var d = el('div', 'guest'), a = el('div'); a.appendChild(el('div', 'n', g.full_name)); a.appendChild(el('div', 'm', [g.phone, g.party_size + ' pers.', g.ticket_type].filter(Boolean).join(' · '))); d.appendChild(a);
      var inv = g.invitation, s = el('div'), stTxt = !inv ? "Pas d'invitation" : inv.status === 'used' ? 'Entré(e) ' + inv.entries_used + '/' + inv.max_entries : inv.status === 'expired' ? 'Expirée' : inv.entries_used ? 'Entré(e) ' + inv.entries_used + '/' + inv.max_entries : 'Invitation émise';
      s.appendChild(el('div', 'n', stTxt)); if (inv && inv.first_used_at) s.appendChild(el('div', 'm', 'Premier passage ' + fmtDate(inv.first_used_at))); d.appendChild(s);
      var r = el('div'); r.appendChild(el('div', 'n', !g.rsvp ? 'Pas de réponse' : g.rsvp.attending ? 'Vient (' + g.rsvp.party_count + ')' : 'Ne vient pas')); d.appendChild(r);
      var acts = el('div', 'acts');
      if (!inv) acts.appendChild(btn('Émettre', 'btn btn-sm', function () { issue({ guest_id: g.id }, g); }));
      else {
        acts.appendChild(btn('Réémettre', 'btn btn-sm btn-line', function () { if (confirm('Réémettre l\'invitation de ' + g.full_name + ' ? Le lien et le QR actuels cesseront de fonctionner.')) issue({ invitation_id: inv.id }, g); }));
        acts.appendChild(btn('Révoquer', 'btn btn-sm btn-danger', function () { if (confirm('Révoquer l\'invitation de ' + g.full_name + ' ? Elle ne pourra plus servir.')) revoke(inv.id); }));
      }
      d.appendChild(acts); box.appendChild(d);
    });
  }
  function btn(t, cls, fn) { var b = el('button', cls, t); b.type = 'button'; b.addEventListener('click', fn); return b; }
  $('search').addEventListener('input', renderGuests); $('filter').addEventListener('change', renderGuests);

  function revoke(id) {
    call('revoke_invitation', { p_invitation_id: id, p_reason: 'révoquée depuis le tableau de bord' }).then(refreshDetail, function (e) { if (e.status !== 401) { $('d-msg').className = 'msg err'; $('d-msg').textContent = 'Révocation impossible.'; } });
  }

  /* ---- émission + PDF ---- */
  function issue(body, g) {
    $('d-msg').className = 'msg'; $('d-msg').textContent = 'Émission en cours…';
    authed('/api/ticket', body).then(function (r) {
      if (r.status === 401) { logout('Session expirée. Reconnectez-vous.'); return; }
      if (!r.ok) { $('d-msg').className = 'msg err'; $('d-msg').textContent = "L'invitation n'a pas pu être émise."; return; }
      var link = r.headers.get('X-Invitation-Link') || '';
      return r.blob().then(function (b) { $('d-msg').textContent = ''; showTicket(g, link, b); refreshDetail(); });
    }, function () { $('d-msg').className = 'msg err'; $('d-msg').textContent = 'Pas de connexion réseau : rien n\'a été émis.'; });
  }
  function showTicket(g, link, blob) {
    if (st.blobUrl) URL.revokeObjectURL(st.blobUrl);
    st.blobUrl = URL.createObjectURL(blob);
    $('t-name').textContent = g.full_name; $('t-link').value = link; $('t-msg').textContent = '';
    var pdf = $('t-pdf'); pdf.href = st.blobUrl; pdf.download = 'invitation-' + norm(g.full_name).replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) + '.pdf';
    var digits = (g.phone || '').replace(/\D/g, ''), first = g.full_name.split(/\s+/)[0];
    var msg = 'Bonjour ' + first + ', voici votre invitation : ' + link;
    $('t-wa').href = 'https://wa.me/' + (digits.length >= 8 ? digits : '') + '?text=' + encodeURIComponent(msg);
    $('dlg-ticket').showModal();
  }
  $('t-copy').addEventListener('click', function () {
    var i = $('t-link'); i.select();
    (navigator.clipboard ? navigator.clipboard.writeText(i.value) : Promise.reject()).then(function () { $('t-msg').textContent = 'Lien copié.'; }, function () { try { document.execCommand('copy'); $('t-msg').textContent = 'Lien copié.'; } catch (_) { $('t-msg').textContent = 'Sélectionnez le lien et copiez-le.'; } });
  });
  $('dlg-ticket').addEventListener('close', function () { if (st.blobUrl) { URL.revokeObjectURL(st.blobUrl); st.blobUrl = null; } $('t-link').value = ''; });

  /* ---- import CSV ---- */
  var ALIAS = { full_name: ['nom', 'noms', 'name', 'full_name', 'fullname', 'invite', 'nom complet', 'nom et prenom'], phone: ['telephone', 'tel', 'phone', 'whatsapp', 'mobile', 'numero'], email: ['email', 'e-mail', 'mail', 'courriel'], party_size: ['personnes', 'nombre', 'nombre de personnes', 'party_size', 'places', 'pers'], ticket_type: ['billet', 'ticket', 'ticket_type', 'type', 'categorie'], notes: ['notes', 'note', 'remarque', 'remarques'] };
  function parseCsv(text) {
    text = text.replace(/^﻿/, '');
    var first = text.split(/\r?\n/, 1)[0] || '', counts = { ';': 0, ',': 0, '\t': 0 };
    for (var i = 0; i < first.length; i++) if (counts[first[i]] !== undefined) counts[first[i]]++;
    var d = Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; })[0]; if (!counts[d]) d = ',';
    var rows = [], row = [], cur = '', q = false;
    for (var k = 0; k < text.length; k++) {
      var c = text[k];
      if (q) { if (c === '"') { if (text[k + 1] === '"') { cur += '"'; k++; } else q = false; } else cur += c; }
      else if (c === '"') q = true;
      else if (c === d) { row.push(cur); cur = ''; }
      else if (c === '\n' || c === '\r') { if (c === '\r' && text[k + 1] === '\n') k++; row.push(cur); cur = ''; if (row.some(function (x) { return x.trim(); })) rows.push(row); row = []; }
      else cur += c;
    }
    row.push(cur); if (row.some(function (x) { return x.trim(); })) rows.push(row);
    if (rows.length < 2) return { error: "Ajoutez une ligne d'en-tête puis au moins un invité." };
    var map = {}; rows[0].forEach(function (h, idx) { var n = norm(h).trim(); Object.keys(ALIAS).forEach(function (f) { if (ALIAS[f].indexOf(n) >= 0 && map[f] === undefined) map[f] = idx; }); });
    if (map.full_name === undefined) return { error: "Aucune colonne « nom » trouvée dans la ligne d'en-tête." };
    var out = rows.slice(1).map(function (r) { var o = {}; Object.keys(map).forEach(function (f) { o[f] = (r[map[f]] || '').trim(); }); return o; });
    if (out.length > 2000) return { error: 'Trop de lignes (' + out.length + ') : 2000 au maximum par import.' };
    return { rows: out };
  }
  var REASON = { name_required: 'nom manquant', name_too_long: 'nom trop long', phone_invalid: 'téléphone invalide', email_invalid: 'e-mail invalide', field_too_long: 'champ trop long', party_size_invalid: 'nombre de personnes invalide (1 à 20)', duplicate: 'déjà dans la liste' };
  $('open-import').addEventListener('click', function () {
    $('i-file').value = ''; $('i-text').value = ''; $('i-preview').textContent = ''; $('i-result').textContent = ''; $('i-go').disabled = true; st.csvRows = null;
    $('i-model').href = 'data:text/csv;charset=utf-8,' + encodeURIComponent('﻿nom;telephone;email;personnes;billet\nMarie Kabila;+243990000000;;2;standard\nPatrick Mwamba;;;1;VIP\n');
    $('dlg-import').showModal();
  });
  $('i-close').addEventListener('click', function () { $('dlg-import').close(); });
  function preview(text) {
    var p = parseCsv(text), box = $('i-preview'); $('i-result').textContent = ''; st.csvRows = null; $('i-go').disabled = true; box.className = 'msg';
    if (p.error) { box.className = 'msg err'; box.textContent = p.error; return; }
    st.csvRows = p.rows; box.textContent = p.rows.length + ' ligne(s) prête(s) à importer.'; $('i-go').disabled = false;
  }
  $('i-file').addEventListener('change', function (e) { var f = e.target.files[0]; if (!f) return; if (f.size > 600000) { $('i-preview').className = 'msg err'; $('i-preview').textContent = 'Fichier trop volumineux.'; return; } var rd = new FileReader(); rd.onload = function () { $('i-text').value = String(rd.result); preview(String(rd.result)); }; rd.readAsText(f, 'utf-8'); });
  $('i-text').addEventListener('input', function (e) { if (e.target.value.trim()) preview(e.target.value); });
  $('i-go').addEventListener('click', function () {
    if (!st.csvRows) return; var b = $('i-go'); b.disabled = true;
    call('import_guests', { p_event_id: st.event.id, p_rows: st.csvRows }).then(function (r) {
      var box = $('i-result'); box.textContent = ''; box.appendChild(el('p', 'strong', r.inserted + ' invité(s) ajouté(s), ' + r.rejected.length + ' ligne(s) refusée(s).'));
      if (r.rejected.length) { var t = el('table'); r.rejected.slice(0, 100).forEach(function (x) { var tr = el('tr'); tr.appendChild(el('td', null, 'Ligne ' + (x.row + 1))); tr.appendChild(el('td', null, REASON[x.reason] || x.reason)); t.appendChild(tr); }); box.appendChild(t); }
      st.csvRows = null; refreshDetail();
    }, function (e) { $('i-preview').className = 'msg err'; $('i-preview').textContent = e.status === 403 ? "Vous n'avez pas le droit d'importer pour cet événement." : "L'import a échoué. Rien n'a été ajouté si le message persiste."; b.disabled = false; });
  });

  /* ---- démarrage ---- */
  window.__org = { parseCsv: parseCsv };
  var s = stored();
  if (s) { st.refresh = s; refresh().then(function (ok) { if (ok) loadEvents(); else { store(null); show('v-login'); } }); } else show('v-login');
})();
