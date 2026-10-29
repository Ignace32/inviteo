/* Invitéo — scanner d'entrée.
   Règle d'or : un écran vert n'apparaît QUE si le serveur a répondu « accepted ».
   Sans réponse (réseau coupé, erreur), on affiche « contrôle non confirmé », jamais un succès. */
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var TOKEN_RE = /^[A-Za-z0-9_-]{20,200}$/;
  var state = { access: null, exp: 0, refresh: null, events: [], event: null, stream: null, timer: null, busy: false, paused: false, ok: 0, refused: 0, pending: null };

  function store(k, v) { try { if (v == null) sessionStorage.removeItem(k); else sessionStorage.setItem(k, v); } catch (_) {} }
  function load(k) { try { return sessionStorage.getItem(k); } catch (_) { return null; } }
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    var b = crypto.getRandomValues(new Uint8Array(16)); b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
    var h = Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
    return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
  }
  function show(id) { ['v-login', 'v-events', 'v-scan'].forEach(function (v) { $(v).hidden = v !== id; }); $('logout').hidden = id === 'v-login'; }

  function api(path, opts) {
    opts = opts || {};
    var headers = { 'Content-Type': 'application/json' };
    if (opts.auth && state.access) headers.Authorization = 'Bearer ' + state.access;
    return fetch(path, { method: opts.method || 'POST', headers: headers, body: opts.body ? JSON.stringify(opts.body) : undefined })
      .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { status: r.status, body: j }; }); });
  }
  function setSession(b) {
    state.access = b.access_token; state.refresh = b.refresh_token; store('inv_refresh', b.refresh_token);
  }
  function refresh() {
    if (!state.refresh) return Promise.resolve(false);
    return api('/api/auth', { body: { refresh_token: state.refresh } }).then(function (o) {
      if (o.status === 200) { setSession(o.body); return true; }
      return false;
    }, function () { return false; });
  }
  // Appel authentifié : en cas de 401, un seul renouvellement de session puis nouvel essai.
  function authed(path, opts) {
    opts = Object.assign({ auth: true }, opts);
    return api(path, opts).then(function (o) {
      if (o.status !== 401) return o;
      return refresh().then(function (ok) { return ok ? api(path, opts) : o; });
    });
  }

  /* ---------- Connexion ---------- */
  $('login-form').addEventListener('submit', function (e) {
    e.preventDefault();
    var f = e.target, msg = $('login-msg'), btn = f.querySelector('button');
    msg.textContent = '';
    if (!f.email.value || !f.password.value) { msg.textContent = 'Saisissez votre e-mail et votre mot de passe.'; return; }
    btn.disabled = true;
    api('/api/auth', { body: { email: f.email.value, password: f.password.value } }).then(function (o) {
      if (o.status === 200) { f.password.value = ''; setSession(o.body); return loadEvents(); }
      msg.textContent = o.status === 401 ? 'E-mail ou mot de passe incorrect.' : 'Service indisponible. Réessayez.';
    }, function () { msg.textContent = 'Pas de connexion réseau.'; }).then(function () { btn.disabled = false; });
  });
  $('logout').addEventListener('click', function () { logout(''); });
  function logout(note) {
    stopCamera(); state.access = null; state.refresh = null; state.event = null; store('inv_refresh', null); store('inv_event', null);
    $('result').hidden = true; show('v-login'); $('login-msg').textContent = note || '';
  }

  /* ---------- Événements ---------- */
  function loadEvents() {
    return authed('/api/my-events', { method: 'GET' }).then(function (o) {
      if (o.status === 401) { logout('Session expirée. Reconnectez-vous.'); return; }
      if (o.status !== 200) { show('v-events'); $('event-list').textContent = ''; $('events-msg').textContent = 'Impossible de charger vos événements. Vérifiez le réseau.'; return; }
      state.events = o.body.events || [];
      var list = $('event-list'); list.textContent = '';
      $('events-msg').textContent = state.events.length ? '' : "Aucun événement ne vous est affecté pour le moment. Contactez l'organisateur.";
      state.events.forEach(function (ev) {
        var li = document.createElement('li'), b = document.createElement('button'), n = document.createElement('b'), s = document.createElement('span');
        b.type = 'button'; n.textContent = ev.name; s.textContent = ev.venue_name + ' · ' + new Date(ev.starts_at).toLocaleString('fr-FR', { dateStyle: 'medium', timeStyle: 'short' });
        b.appendChild(n); b.appendChild(s); b.addEventListener('click', function () { chooseEvent(ev); });
        li.appendChild(b); list.appendChild(li);
      });
      show('v-events');
      if (state.events.length === 1) chooseEvent(state.events[0]);
    }, function () { show('v-events'); $('events-msg').textContent = 'Pas de connexion réseau.'; });
  }
  function chooseEvent(ev) {
    state.event = ev; state.ok = 0; state.refused = 0; updateCount();
    $('evt-name').textContent = ev.name; show('v-scan'); startCamera();
  }
  $('change-event').addEventListener('click', function () { stopCamera(); state.event = null; show('v-events'); });
  function updateCount() { $('count').textContent = 'Cette session : ' + state.ok + ' entrée(s) validée(s), ' + state.refused + ' refus.'; }

  /* ---------- Caméra ---------- */
  function startCamera() {
    var msg = $('cam-msg'); msg.textContent = '';
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { msg.textContent = "Caméra indisponible sur cet appareil : saisissez le code ci-dessous."; return; }
    navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false }).then(function (stream) {
      if (!state.event) { stream.getTracks().forEach(function (t) { t.stop(); }); return; }
      state.stream = stream; var v = $('video'); v.srcObject = stream; v.play().catch(function () {});
      if (!('BarcodeDetector' in window)) { msg.textContent = "Ce navigateur ne sait pas lire les QR codes : utilisez Chrome sur Android, ou saisissez le code ci-dessous."; return; }
      var det; try { det = new window.BarcodeDetector({ formats: ['qr_code'] }); } catch (_) { msg.textContent = 'Lecture de QR code indisponible : saisissez le code ci-dessous.'; return; }
      msg.textContent = 'Cadrez le QR code du billet.';
      state.timer = setInterval(function () {
        if (state.busy || state.paused || v.readyState < 2) return;
        det.detect(v).then(function (codes) { if (codes && codes.length && !state.busy && !state.paused) handleCode(codes[0].rawValue); }, function () {});
      }, 250);
    }, function (err) {
      msg.textContent = (err && err.name === 'NotAllowedError') ? "Accès à la caméra refusé. Autorisez-la dans les réglages du navigateur, ou saisissez le code ci-dessous." : "Caméra introuvable : saisissez le code ci-dessous.";
    });
  }
  function stopCamera() {
    if (state.timer) { clearInterval(state.timer); state.timer = null; }
    if (state.stream) { state.stream.getTracks().forEach(function (t) { t.stop(); }); state.stream = null; }
    var v = $('video'); if (v) v.srcObject = null;
  }

  /* ---------- Lecture d'un code ---------- */
  function extractToken(text) {
    text = String(text || '').trim();
    var m = /\/s\/([A-Za-z0-9_-]{20,200})\/?(?:[?#].*)?$/.exec(text);
    if (m) return m[1];
    return TOKEN_RE.test(text) ? text : null;
  }
  $('manual-form').addEventListener('submit', function (e) { e.preventDefault(); var v = $('manual').value; if (v.trim()) handleCode(v); });

  function handleCode(text) {
    if (state.busy || !state.event) return;
    var token = extractToken(text);
    if (!token) { state.busy = true; state.paused = true; return display('warn', '?', 'CODE NON RECONNU', '', "Ce n'est pas un billet Invitéo."); }
    // Même billet + même requête tant qu'aucune réponse n'est arrivée : le rejeu ne compte pas deux fois.
    if (!state.pending || state.pending.token !== token || state.pending.event !== state.event.id) state.pending = { token: token, event: state.event.id, request: uuid() };
    submit();
  }
  function submit() {
    var p = state.pending; state.busy = true; state.paused = true;
    display('unknown', '…', 'VÉRIFICATION…', '', '');
    $('r-next').hidden = true; $('r-retry').hidden = true;
    authed('/api/scan', { body: { event_id: p.event, token: p.token, request_id: p.request } }).then(function (o) {
      if (o.status === 401) { logout('Session expirée. Reconnectez-vous puis scannez à nouveau.'); return; }
      if (o.status === 200 && o.body && typeof o.body.result === 'string') { state.pending = null; return render(o.body); }
      unconfirmed(o.status === 403 ? 'Accès refusé par le serveur.' : "Le serveur n'a pas confirmé le contrôle.");
    }, function () { unconfirmed('Pas de connexion réseau.'); });
  }
  function unconfirmed(why) {
    display('unknown', '?', 'CONTRÔLE NON CONFIRMÉ', '', why + "\nN'autorisez pas l'entrée sur la base de cet écran. Réessayez : le même scan ne sera pas compté deux fois.");
    $('r-retry').hidden = false; $('r-next').hidden = false; $('r-next').textContent = 'Annuler';
  }

  var REASONS = { not_assigned: "Vous n'êtes pas affecté à cet événement.", not_an_active_agent: "Votre compte agent n'est pas actif.", event_not_open: "Cet événement n'est pas ouvert au contrôle.", unknown_event: 'Événement inconnu.' };
  function hm(iso) { try { return new Date(iso).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }); } catch (_) { return ''; } }
  function render(r) {
    var n = r.guest_name || '', q = (r.entries_used != null && r.max_entries != null) ? r.entries_used + ' sur ' + r.max_entries : '';
    switch (r.result) {
      case 'accepted': state.ok++; return display('ok', '✓', 'ENTRÉE VALIDÉE', n, 'Entrée ' + q + (r.replayed ? '\n(réponse déjà enregistrée)' : ''));
      case 'already_used': state.refused++; return display('stop', '✕', 'DÉJÀ UTILISÉ', n, (q ? 'Entrées utilisées : ' + q + '\n' : '') + (r.first_scanned_at ? 'Premier passage à ' + hm(r.first_scanned_at) + (r.first_scanned_by ? ' (' + r.first_scanned_by + ')' : '') : ''));
      case 'revoked': state.refused++; return display('stop', '✕', 'INVITATION RÉVOQUÉE', n, "Ce billet n'est plus valable.");
      case 'expired': state.refused++; return display('warn', '!', 'INVITATION EXPIRÉE', n, 'Ce billet a expiré.');
      case 'invalid': state.refused++; return display('warn', '!', 'CODE INVALIDE', '', 'Billet inconnu ou illisible.');
      case 'wrong_event': state.refused++; return display('stop', '✕', 'AUTRE ÉVÉNEMENT', '', "Ce billet est pour un autre événement.");
      case 'forbidden': state.refused++; return display('stop', '✕', 'ACCÈS REFUSÉ', '', REASONS[r.reason] || 'Contrôle non autorisé.');
      default: return unconfirmed('Réponse inattendue du serveur.');
    }
  }
  function display(kind, icon, title, name, detail) {
    var el = $('result'); el.dataset.kind = kind; el.hidden = false;
    $('r-icon').textContent = icon; $('r-title').textContent = title; $('r-name').textContent = name; $('r-detail').textContent = detail;
    $('r-next').hidden = false; $('r-next').textContent = 'Scanner suivant'; $('r-retry').hidden = true;
    if (kind !== 'unknown' || title !== 'VÉRIFICATION…') { try { if (navigator.vibrate) navigator.vibrate(kind === 'ok' ? 80 : [120, 80, 120]); } catch (_) {} updateCount(); }
    if (title === 'VÉRIFICATION…') { $('r-next').hidden = true; } else { $('r-next').focus(); }
  }
  $('r-next').addEventListener('click', function () { $('result').hidden = true; $('manual').value = ''; state.busy = false; state.pending = null; setTimeout(function () { state.paused = false; }, 600); });
  $('r-retry').addEventListener('click', function () { if (state.pending) submit(); });

  /* ---------- Démarrage ---------- */
  window.__scanner = { handleCode: handleCode, extractToken: extractToken };
  var saved = load('inv_refresh');
  if (saved) { state.refresh = saved; refresh().then(function (ok) { if (ok) loadEvents(); else { store('inv_refresh', null); show('v-login'); } }); }
  else show('v-login');
})();
