/* ==========================================================================
   Modèle d'invitation d'anniversaire — comportement de la démonstration
   - Le prénom de l'invité vient de l'adresse (?invite=Prénom), affiché en texte brut.
   - La réponse (RSVP) est SIMULÉE : rien n'est envoyé ni enregistré.
   ========================================================================== */
(function () {
  'use strict';

  var EVENT_DATE = new Date('2027-01-16T18:00:00+02:00'); // Lubumbashi, UTC+2
  var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function $(s, r) { return (r || document).querySelector(s); }
  function $all(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }

  /* ---------- Prénom de l'invité ---------- */
  function guestName() {
    var raw = '';
    try { raw = new URLSearchParams(window.location.search).get('invite') || ''; } catch (e) { raw = ''; }
    // Texte brut uniquement : lettres, espaces, apostrophes, tirets. 30 caractères maximum.
    var clean = raw.replace(/[^\p{L}\p{M}\s'’-]/gu, '').replace(/\s+/g, ' ').trim().slice(0, 30);
    return clean;
  }

  function initGuest() {
    var name = guestName();
    if (!name) { return; }
    $all('[data-guest]').forEach(function (el) { el.textContent = name; });
  }

  /* ---------- Compte à rebours ---------- */
  function remaining(now, target) {
    var diff = target.getTime() - now.getTime();
    if (diff <= 0) { return { done: true, days: 0, hours: 0, minutes: 0, seconds: 0 }; }
    var s = Math.floor(diff / 1000);
    return {
      done: false,
      days: Math.floor(s / 86400),
      hours: Math.floor((s % 86400) / 3600),
      minutes: Math.floor((s % 3600) / 60),
      seconds: s % 60
    };
  }

  function two(n) { return n < 10 ? '0' + n : String(n); }

  function initCountdown() {
    var wrap = $('#countdown');
    if (!wrap) { return; }
    var doneEl = $('#countdown-done');
    var srEl = $('#countdown-sr');
    var nodes = {};
    $all('[data-cd]', wrap).forEach(function (el) { nodes[el.getAttribute('data-cd')] = el; });
    var lastMinute = -1;

    function tick() {
      var r = remaining(new Date(), EVENT_DATE);
      if (r.done) {
        wrap.hidden = true;
        doneEl.hidden = false;
        window.clearInterval(timer);
        return;
      }
      nodes.days.textContent = String(r.days);
      nodes.hours.textContent = two(r.hours);
      nodes.minutes.textContent = two(r.minutes);
      nodes.seconds.textContent = two(r.seconds);
      // Annonce pour lecteurs d'écran : une fois par minute, pas à chaque seconde.
      if (r.minutes !== lastMinute) {
        lastMinute = r.minutes;
        srEl.textContent = 'Il reste ' + r.days + ' jours, ' + r.hours + ' heures et ' + r.minutes + ' minutes.';
      }
    }
    var timer = window.setInterval(tick, 1000);
    tick();
  }

  /* ---------- Couverture : bulles, déchirure, confettis ---------- */
  function initBubbles() {
    var box = $('.cover__bubbles');
    if (!box || reduced) { return; }
    for (var i = 0; i < 14; i++) {
      var b = document.createElement('span');
      var size = 8 + Math.round(Math.random() * 22);
      b.className = 'bubble';
      b.style.width = b.style.height = size + 'px';
      b.style.left = Math.round(Math.random() * 100) + '%';
      b.style.animationDuration = (9 + Math.random() * 9).toFixed(1) + 's';
      b.style.animationDelay = (-Math.random() * 12).toFixed(1) + 's';
      box.appendChild(b);
    }
  }

  function burstConfetti() {
    var box = $('#confetti');
    if (!box || reduced) { return; }
    var colors = ['#4A7FA7', '#F6FAFD', '#FFFFFF', '#1A3D63'];
    for (var i = 0; i < 46; i++) {
      var p = document.createElement('i');
      var angle = Math.random() * Math.PI * 2;
      var dist = 90 + Math.random() * 230;
      p.style.setProperty('--dx', Math.round(Math.cos(angle) * dist) + 'px');
      p.style.setProperty('--dy', Math.round(Math.sin(angle) * dist * 0.9 + 140) + 'px');
      p.style.setProperty('--rot', Math.round(Math.random() * 720 - 360) + 'deg');
      p.style.background = colors[i % colors.length];
      p.style.animationDelay = (Math.random() * 0.15).toFixed(2) + 's';
      box.appendChild(p);
    }
  }

  function initCover() {
    var cover = $('#cover');
    var btn = $('#open-btn');
    var main = $('#invitation');
    if (!cover || !btn) { document.body.classList.remove('is-locked'); return; }

    var opened = false;
    function finish() {
      cover.classList.add('is-gone');
      document.body.classList.remove('is-locked');
      cover.setAttribute('aria-hidden', 'true');
      if (main) { main.focus({ preventScroll: true }); window.scrollTo(0, 0); }
      window.setTimeout(function () { cover.hidden = true; }, 600);
    }

    btn.addEventListener('click', function () {
      if (opened) { return; }
      opened = true;
      btn.disabled = true;
      cover.classList.add('is-tearing');
      burstConfetti();
      window.setTimeout(finish, reduced ? 0 : 1500);
    });

    btn.focus();
    // Échap ouvre aussi (accessibilité clavier).
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !opened) { btn.click(); }
    });
  }

  /* ---------- RSVP simulé ---------- */
  function initRsvp() {
    var form = $('#rsvp-form');
    if (!form) { return; }
    var result = $('#rsvp-result');
    var resultText = $('#rsvp-result-text');
    var countField = $('#field-count');
    var songField = $('#field-song');
    var count = $('#r-count');
    var eAnswer = $('#e-answer');
    var eCount = $('#e-count');

    function setErr(el, input, msg) {
      el.textContent = msg || '';
      el.hidden = !msg;
      if (input) { if (msg) { input.setAttribute('aria-invalid', 'true'); } else { input.removeAttribute('aria-invalid'); } }
    }

    function selected() {
      var r = $('input[name="answer"]:checked', form);
      return r ? r.value : '';
    }

    form.addEventListener('change', function () {
      var yes = selected() !== 'non';
      countField.hidden = !yes;
      songField.hidden = !yes;
      setErr(eAnswer, null, '');
    });

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var answer = selected();
      var ok = true;
      setErr(eAnswer, null, '');
      setErr(eCount, count, '');

      if (!answer) { setErr(eAnswer, null, 'Choisissez une réponse.'); ok = false; }
      if (answer === 'oui') {
        var txt = String(count.value).trim();
        var n = /^\d+$/.test(txt) ? Number(txt) : 0;
        if (n < 1 || n > 6) { setErr(eCount, count, 'Indiquez un nombre de personnes entre 1 et 6.'); ok = false; }
      }
      if (!ok) {
        var first = !answer ? $('input[name="answer"]', form) : count;
        if (first) { first.focus(); }
        return;
      }

      resultText.textContent = answer === 'oui'
        ? 'Merci. Sur une vraie invitation, votre présence serait enregistrée et visible par l’organisateur (selon la formule). Ici, c’est une démonstration : rien n’a été envoyé.'
        : 'Merci de nous avoir prévenus. Sur une vraie invitation, votre réponse serait transmise à l’organisateur (selon la formule). Ici, c’est une démonstration : rien n’a été envoyé.';
      result.hidden = false;
      result.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'nearest' });
    });
  }

  function init() {
    initGuest();
    initBubbles();
    initCover();
    initCountdown();
    initRsvp();
  }

  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', init); } else { init(); }

  window.__demo = Object.freeze({ remaining: remaining, EVENT_DATE: EVENT_DATE });
})();
