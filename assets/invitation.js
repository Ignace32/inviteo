/* Invitéo — comportement de la page d'invitation.
   Aucun secret ici : le jeton de la page vient de l'URL ; le jeton du QR code vient du fragment (#…),
   qui n'est jamais envoyé au serveur. */
(function () {
  'use strict';
  var me = document.currentScript;
  var TOKEN = me.getAttribute('data-token');
  var SITE = (me.getAttribute('data-site') || '').replace(/\/+$/, '');
  var SHOW_QR = me.getAttribute('data-show-qr') === '1';
  var TOKEN_RE = /^[A-Za-z0-9_-]{20,200}$/;
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var $ = function (s) { return document.querySelector(s); };

  document.documentElement.classList.add('js');
  var cover = $('#cover'), page = $('#page');

  function reveal() {
    var els = document.querySelectorAll('.reveal');
    if (reduce || !('IntersectionObserver' in window)) { els.forEach(function (e) { e.classList.add('in'); }); return; }
    var io = new IntersectionObserver(function (en) {
      en.forEach(function (x) { if (x.isIntersecting) { x.target.classList.add('in'); io.unobserve(x.target); } });
    }, { threshold: 0.12 });
    els.forEach(function (e) { io.observe(e); });
  }

  function openCover() {
    document.documentElement.classList.add('is-open');
    cover.classList.add('is-open');
    page.removeAttribute('aria-hidden');
    window.scrollTo(0, 0);
    setTimeout(function () { cover.hidden = true; var h = $('h1'); if (h) { h.setAttribute('tabindex', '-1'); h.focus({ preventScroll: true }); } }, reduce ? 0 : 1100);
    reveal();
  }
  var PREVIEW = me.getAttribute('data-preview') === '1';
  if (cover) {
    page.setAttribute('aria-hidden', 'true');
    $('#open').addEventListener('click', openCover);
  } else {
    // Sans couverture (aperçu) : la page est directement visible.
    document.documentElement.classList.add('is-open'); page.removeAttribute('aria-hidden'); reveal();
  }

  // Compte à rebours (affiché seulement avant le début).
  var cd = $('#countdown-block');
  if (cd) {
    var start = Date.parse(cd.getAttribute('data-start'));
    var tick = function () {
      var ms = start - Date.now();
      if (!(ms > 0)) { cd.hidden = true; return; }
      cd.hidden = false;
      var m = Math.floor(ms / 60000);
      cd.querySelector('[data-u=d]').textContent = Math.floor(m / 1440);
      cd.querySelector('[data-u=h]').textContent = Math.floor((m % 1440) / 60);
      cd.querySelector('[data-u=m]').textContent = m % 60;
    };
    tick(); setInterval(tick, 30000);
  }

  // QR code : tracé dans le navigateur à partir du fragment de l'URL.
  var qrBox = $('#qr'), ticket = $('#ticket');
  if (SHOW_QR && qrBox && ticket) {
    var qrTok = location.hash.replace(/^#/, '');
    if (TOKEN_RE.test(qrTok) && qrTok !== TOKEN && window.InviteoQR) {
      try {
        qrBox.innerHTML = window.InviteoQR.toSvg(SITE + '/s/' + qrTok, { level: 'M', border: 2, dark: '#000000', light: '#ffffff', title: "QR code d'entrée" });
        ticket.hidden = false;
      } catch (_) { ticket.hidden = true; }
    }
  }

  // Réponse (RSVP).
  var form = $('#rsvp-form');
  if (form) {
    var msg = $('#rsvp-msg'), fc = $('#f-count'), fs = $('#f-song');
    var sync = function () {
      var yes = form.elements.attending.value === 'yes';
      if (fc) fc.hidden = !yes;
      if (fs) fs.hidden = !yes;
    };
    form.addEventListener('change', sync); sync();
    var ERR = { closed: 'Les réponses sont closes pour cette invitation.', rsvp_disabled: "Les réponses ne sont pas ouvertes pour cet événement.",
      invalid_party_count: 'Nombre de personnes invalide.', not_found: 'Invitation introuvable.', unavailable: 'Service indisponible. Réessayez dans un instant.' };
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var v = form.elements.attending.value;
      msg.className = 'form-msg';
      if (!v) { msg.className = 'form-msg err'; msg.textContent = 'Choisissez une réponse.'; return; }
      var yes = v === 'yes', max = Number(form.getAttribute('data-max')) || 1, cnt = null;
      if (yes) {
        cnt = form.elements.party_count ? Number(form.elements.party_count.value) : Number(form.getAttribute('data-default')) || 1;
        if (!Number.isInteger(cnt) || cnt < 1 || cnt > max) { msg.className = 'form-msg err'; msg.textContent = 'Indiquez un nombre de personnes entre 1 et ' + max + '.'; return; }
      }
      if (PREVIEW) { msg.textContent = "Aperçu : votre réponse n'est pas envoyée."; return; }
      var btn = form.querySelector('button'); btn.disabled = true; msg.textContent = 'Envoi…';
      fetch('/api/rsvp', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token: TOKEN, attending: yes, party_count: cnt, song: yes && form.elements.song ? form.elements.song.value : null, note: form.elements.note.value })
      }).then(function (r) { return r.json().then(function (j) { return { ok: r.ok && j.ok, j: j }; }); })
        .then(function (o) {
          if (o.ok) { msg.textContent = yes ? 'Merci ! Votre présence est enregistrée.' : 'Merci de nous avoir prévenus.'; btn.textContent = 'Modifier ma réponse'; }
          else { msg.className = 'form-msg err'; msg.textContent = ERR[o.j && o.j.error] || "Votre réponse n'a pas pu être enregistrée."; }
        })
        .catch(function () { msg.className = 'form-msg err'; msg.textContent = ERR.unavailable; })
        .then(function () { btn.disabled = false; });
    });
  }
})();
