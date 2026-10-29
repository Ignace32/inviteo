/* ==========================================================================
   Invitéo — script.js (JavaScript vanilla, sans dépendance)
   - Prix et numéro WhatsApp centralisés dans CONFIG / PLANS
   - Calculs en centimes entiers (aucune erreur d'arrondi)
   - Aucun envoi automatique : le client relit et envoie lui-même dans WhatsApp
   - Aucune donnée stockée (pas de LocalStorage, pas de cookie)
   ========================================================================== */
(function () {
  'use strict';

  /* ---------- Configuration centralisée ---------- */
  var CONFIG = Object.freeze({
    // Numéro de destination au format international, SANS le signe « + ».
    whatsappNumber: '243990228413',
    brand: 'Invitéo',
    maxQuantity: 10000,
    defaultPlan: 'plus'
  });

  // Prix unitaires en dollars américains (USD). Ne pas modifier sans accord.
  var PLANS = Object.freeze({
    simple:  Object.freeze({ key: 'simple',  name: 'Simple',  unitPrice: 0.60 }),
    plus:    Object.freeze({ key: 'plus',    name: 'Plus',    unitPrice: 0.70 }),
    premium: Object.freeze({ key: 'premium', name: 'Premium', unitPrice: 1.00 })
  });

  var NBSP = '\u00A0';

  /* ---------- Utilitaires de prix ---------- */
  function toCents(price) { return Math.round(price * 100); }

  function unitCents(planKey) { return toCents(PLANS[planKey].unitPrice); }

  function totalCents(planKey, quantity) { return unitCents(planKey) * quantity; }

  // Formate un montant en centimes : « 0,60 $ », « 70 $ », « 10 000 $ ».
  function formatAmount(cents, options) {
    var alwaysDecimals = !!(options && options.alwaysDecimals);
    var units = Math.floor(cents / 100);
    var rest = cents % 100;
    var intPart = String(units).replace(/\B(?=(\d{3})+(?!\d))/g, NBSP);
    var decimals = alwaysDecimals || rest !== 0;
    return intPart + (decimals ? ',' + String(rest).padStart(2, '0') : '') + NBSP + '$';
  }

  function formatUnit(planKey) { return formatAmount(unitCents(planKey), { alwaysDecimals: true }); }
  function formatTotal(planKey, quantity) { return formatAmount(totalCents(planKey, quantity)); }

  /* ---------- Validation de la quantité ---------- */
  function parseQuantity(raw) {
    var text = String(raw == null ? '' : raw).trim();
    if (text === '') {
      return { ok: false, message: 'Indiquez le nombre d’invitations.' };
    }
    if (!/^\d+$/.test(text)) {
      return { ok: false, message: 'Saisissez un nombre entier positif, sans virgule ni signe.' };
    }
    var value = Number(text);
    if (value < 1) {
      return { ok: false, message: 'Le nombre d’invitations doit être d’au moins 1.' };
    }
    if (value > CONFIG.maxQuantity) {
      return {
        ok: false,
        message: 'Au-delà de ' + String(CONFIG.maxQuantity).replace(/\B(?=(\d{3})+(?!\d))/g, NBSP) +
          ' invitations, contactez-nous directement sur WhatsApp.'
      };
    }
    return { ok: true, value: value };
  }

  /* ---------- WhatsApp ---------- */
  function plain(text) { return text.replace(/\u00A0/g, ' '); }

  function buildWhatsAppUrl(message) {
    return 'https://wa.me/' + CONFIG.whatsappNumber + '?text=' + encodeURIComponent(message);
  }

  function genericMessage(intent) {
    if (intent === 'question') {
      return 'Bonjour ' + CONFIG.brand + ' !\n\nJ’ai une question sur vos invitations numériques.\n\nMerci.';
    }
    return 'Bonjour ' + CONFIG.brand + ' !\n\nJe souhaite commander des invitations numériques.\n\n' +
      'Pouvez-vous m’expliquer les prochaines étapes ?\n\nMerci.';
  }

  // order = { plan, quantity, event, name, date?, people?, note?, model? }
  function buildOrderMessage(order) {
    var plan = PLANS[order.plan];
    var lines = [
      'Bonjour ' + CONFIG.brand + ' !',
      '',
      'Je souhaite commander des invitations numériques.',
      '',
      'Formule : ' + plan.name,
      'Prix unitaire : ' + plain(formatUnit(order.plan)),
      'Nombre d’invitations : ' + order.quantity,
      'Montant total estimé : ' + plain(formatTotal(order.plan, order.quantity)),
      'Type d’événement : ' + order.event,
      'Nom du client : ' + order.name
    ];
    if (order.model)  { lines.push('Modèle souhaité : ' + order.model); }
    if (order.date)   { lines.push('Date de l’événement : ' + order.date); }
    if (order.people) { lines.push('Organisateur(s) : ' + order.people); }
    if (order.note)   { lines.push('Précisions : ' + order.note); }
    lines.push(
      '',
      'Pouvez-vous m’expliquer les prochaines étapes pour finaliser ma commande ?',
      '',
      'Merci.'
    );
    return lines.join('\n');
  }

  /* ---------- Aides DOM ---------- */
  function $(selector, root) { return (root || document).querySelector(selector); }
  function $all(selector, root) { return Array.prototype.slice.call((root || document).querySelectorAll(selector)); }

  function localToday() {
    var d = new Date();
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  function formatDateFr(iso) {
    var parts = iso.split('-').map(Number);
    var date = new Date(parts[0], parts[1] - 1, parts[2]);
    return date.toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' });
  }

  /* ---------- Initialisations simples ---------- */
  function initYear() {
    var el = $('#year');
    if (el) { el.textContent = String(new Date().getFullYear()); }
  }

  // Les montants affichés dans la page sont synchronisés avec PLANS (source unique).
  function initPriceLabels() {
    $all('[data-price]').forEach(function (el) {
      var key = el.getAttribute('data-price');
      if (PLANS[key]) { el.textContent = formatUnit(key); }
    });
    $all('[data-example]').forEach(function (el) {
      var key = el.getAttribute('data-example');
      var qty = parseQuantity(el.getAttribute('data-qty'));
      if (PLANS[key] && qty.ok) { el.textContent = formatTotal(key, qty.value); }
    });
  }

  function initWhatsAppLinks() {
    $all('[data-wa]').forEach(function (link) {
      link.setAttribute('href', buildWhatsAppUrl(genericMessage(link.getAttribute('data-wa'))));
    });
  }

  function initMenu() {
    var toggle = $('.nav-toggle');
    var menu = $('#menu');
    if (!toggle || !menu) { return; }

    function setOpen(open) {
      menu.classList.toggle('is-open', open);
      toggle.setAttribute('aria-expanded', String(open));
      toggle.setAttribute('aria-label', open ? 'Fermer le menu' : 'Ouvrir le menu');
    }

    toggle.addEventListener('click', function () {
      setOpen(toggle.getAttribute('aria-expanded') !== 'true');
    });
    menu.addEventListener('click', function (event) {
      if (event.target.closest('a, button[data-order]')) { setOpen(false); }
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') {
        setOpen(false);
        toggle.focus();
      }
    });
    window.addEventListener('resize', function () {
      if (window.innerWidth >= 920) { setOpen(false); }
    });
  }

  function initReveal() {
    var items = $all('.reveal');
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (!items.length) { return; }
    if (reduced || !('IntersectionObserver' in window)) {
      items.forEach(function (el) { el.classList.add('is-visible'); });
      return;
    }
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target);
        }
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    items.forEach(function (el) { observer.observe(el); });
  }

  function initActiveNav() {
    if (!('IntersectionObserver' in window)) { return; }
    var links = $all('.nav__list a[href^="#"]');
    if (!links.length) { return; }
    var map = {};
    links.forEach(function (a) { map[a.getAttribute('href').slice(1)] = a; });
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) { return; }
        links.forEach(function (a) { a.removeAttribute('aria-current'); });
        var active = map[entry.target.id];
        if (active) { active.setAttribute('aria-current', 'true'); }
      });
    }, { rootMargin: '-40% 0px -55% 0px' });
    Object.keys(map).forEach(function (id) {
      var section = document.getElementById(id);
      if (section) { observer.observe(section); }
    });
  }

  /* ---------- Calculateur ---------- */
  function initCalculator() {
    var input = $('#calc-qty');
    if (!input) { return; }
    var errorEl = $('#calc-error');
    var chips = $all('.chip[data-qty]');

    function render() {
      var result = parseQuantity(input.value);
      if (!result.ok) {
        errorEl.textContent = result.message;
        errorEl.hidden = false;
        input.setAttribute('aria-invalid', 'true');
        $all('[data-calc-total]').forEach(function (el) { el.textContent = '—'; });
        $all('[data-calc-qty]').forEach(function (el) { el.textContent = '—'; });
        chips.forEach(function (c) { c.setAttribute('aria-pressed', 'false'); });
        return;
      }
      errorEl.hidden = true;
      errorEl.textContent = '';
      input.removeAttribute('aria-invalid');
      $all('[data-calc-total]').forEach(function (el) {
        el.textContent = formatTotal(el.getAttribute('data-calc-total'), result.value);
      });
      $all('[data-calc-qty]').forEach(function (el) { el.textContent = String(result.value); });
      chips.forEach(function (c) {
        c.setAttribute('aria-pressed', String(Number(c.getAttribute('data-qty')) === result.value));
      });
    }

    input.addEventListener('input', render);
    chips.forEach(function (chip) {
      chip.addEventListener('click', function () {
        input.value = chip.getAttribute('data-qty');
        render();
      });
    });
    render();
  }

  /* ---------- Fenêtre de commande ---------- */
  function initOrderDialog() {
    var dialog = $('#order-dialog');
    var form = $('#order-form');
    if (!dialog || !form) { return; }

    var stepForm = $('[data-step="form"]', dialog);
    var stepRecap = $('[data-step="recap"]', dialog);
    var planSelect = $('#f-plan');
    var nameInput = $('#f-name');
    var eventSelect = $('#f-event');
    var qtyInput = $('#f-qty');
    var dateInput = $('#f-date');
    var peopleInput = $('#f-people');
    var noteInput = $('#f-note');
    var liveTotal = $('#live-total');
    var modelChip = $('#order-model');
    var recapList = $('#recap-list');
    var recapMessage = $('#recap-message');
    var recapTitle = $('#recap-title');
    var sendLink = $('#wa-send');
    var copyBtn = $('#copy-message');
    var copyStatus = $('#copy-status');
    var currentModel = '';
    var currentMessage = '';

    // Options de formule générées depuis PLANS (prix toujours cohérents).
    Object.keys(PLANS).forEach(function (key) {
      var option = document.createElement('option');
      option.value = key;
      option.textContent = PLANS[key].name + ' — ' + plain(formatUnit(key)) + ' par invitation' +
        (key === 'plus' ? ' (recommandée)' : '');
      planSelect.appendChild(option);
    });

    function showStep(name) {
      stepForm.hidden = name !== 'form';
      stepRecap.hidden = name !== 'recap';
    }

    function setError(field, message) {
      var errorEl = $('#e-' + field);
      var input = { name: nameInput, event: eventSelect, qty: qtyInput, date: dateInput }[field];
      if (!errorEl || !input) { return; }
      if (message) {
        errorEl.textContent = message;
        errorEl.hidden = false;
        input.setAttribute('aria-invalid', 'true');
      } else {
        errorEl.textContent = '';
        errorEl.hidden = true;
        input.removeAttribute('aria-invalid');
      }
    }

    function clearErrors() { ['name', 'event', 'qty', 'date'].forEach(function (f) { setError(f, ''); }); }

    function updateLiveTotal() {
      var qty = parseQuantity(qtyInput.value);
      if (!qty.ok) { liveTotal.textContent = ''; return; }
      var plan = planSelect.value;
      liveTotal.innerHTML = '';
      liveTotal.appendChild(document.createTextNode('Montant total estimé : '));
      var strong = document.createElement('strong');
      strong.textContent = formatTotal(plan, qty.value);
      liveTotal.appendChild(strong);
      liveTotal.appendChild(document.createTextNode(' (' + formatUnit(plan) + ' × ' + qty.value + ')'));
    }

    function open(opts) {
      opts = opts || {};
      form.reset();
      clearErrors();
      copyStatus.textContent = '';
      showStep('form');

      planSelect.value = PLANS[opts.plan] ? opts.plan : CONFIG.defaultPlan;
      if (opts.event) { eventSelect.value = opts.event; }
      if (opts.qty) { qtyInput.value = String(opts.qty); }
      dateInput.min = localToday();

      currentModel = opts.model || '';
      var strong = $('strong', modelChip);
      if (currentModel) {
        strong.textContent = currentModel;
        modelChip.hidden = false;
      } else {
        modelChip.hidden = true;
      }
      updateLiveTotal();

      if (typeof dialog.showModal === 'function') {
        if (!dialog.open) { dialog.showModal(); }
      } else {
        dialog.setAttribute('open', '');
      }
      document.documentElement.classList.add('modal-open');
      nameInput.focus();
    }

    function close() {
      if (typeof dialog.close === 'function' && dialog.open) {
        dialog.close();
      } else {
        dialog.removeAttribute('open');
      }
      document.documentElement.classList.remove('modal-open');
    }

    dialog.addEventListener('close', function () { document.documentElement.classList.remove('modal-open'); });
    dialog.addEventListener('click', function (event) {
      if (event.target === dialog) { close(); } // clic sur le fond
    });
    $all('[data-close]', dialog).forEach(function (btn) { btn.addEventListener('click', close); });

    // Tous les boutons « Commander / Choisir / Commander un modèle similaire »
    document.addEventListener('click', function (event) {
      var trigger = event.target.closest('[data-order]');
      if (!trigger) { return; }
      var opts = {
        plan: trigger.getAttribute('data-plan'),
        event: trigger.getAttribute('data-event'),
        model: trigger.getAttribute('data-model')
      };
      if (trigger.hasAttribute('data-from-calc')) {
        var calc = parseQuantity(($('#calc-qty') || {}).value);
        if (calc.ok) { opts.qty = calc.value; }
      }
      open(opts);
    });

    planSelect.addEventListener('change', updateLiveTotal);
    qtyInput.addEventListener('input', function () { setError('qty', ''); updateLiveTotal(); });
    nameInput.addEventListener('input', function () { setError('name', ''); });
    eventSelect.addEventListener('change', function () { setError('event', ''); });
    dateInput.addEventListener('change', function () { setError('date', ''); });

    function validate() {
      var errors = [];
      var name = nameInput.value.trim();
      if (!name) {
        errors.push(['name', 'Indiquez votre prénom.']);
      }
      if (!eventSelect.value) {
        errors.push(['event', 'Choisissez un type d’événement.']);
      }
      var qty = parseQuantity(qtyInput.value);
      if (!qty.ok) {
        errors.push(['qty', qty.message]);
      }
      if (dateInput.value && dateInput.value < localToday()) {
        errors.push(['date', 'La date de l’événement ne peut pas être passée.']);
      }
      return { errors: errors, name: name, qty: qty };
    }

    form.addEventListener('submit', function (event) {
      event.preventDefault();
      clearErrors();
      var result = validate();

      if (result.errors.length) {
        result.errors.forEach(function (e) { setError(e[0], e[1]); });
        var first = { name: nameInput, event: eventSelect, qty: qtyInput, date: dateInput }[result.errors[0][0]];
        if (first) { first.focus(); }
        return;
      }

      var order = {
        plan: planSelect.value,
        quantity: result.qty.value,
        event: eventSelect.value,
        name: result.name,
        model: currentModel,
        date: dateInput.value ? formatDateFr(dateInput.value) : '',
        people: peopleInput.value.trim(),
        note: noteInput.value.trim()
      };

      renderRecap(order);
      showStep('recap');
      recapTitle.focus();
      dialog.scrollTop = 0;
    });

    function addRecapRow(label, value, extraClass) {
      var row = document.createElement('div');
      if (extraClass) { row.className = extraClass; }
      var dt = document.createElement('dt');
      dt.textContent = label;
      var dd = document.createElement('dd');
      dd.textContent = value;
      row.appendChild(dt);
      row.appendChild(dd);
      recapList.appendChild(row);
    }

    function renderRecap(order) {
      recapList.innerHTML = '';
      addRecapRow('Formule', PLANS[order.plan].name);
      addRecapRow('Prix unitaire', formatUnit(order.plan));
      addRecapRow('Nombre d’invitations', String(order.quantity));
      addRecapRow('Montant total estimé', formatTotal(order.plan, order.quantity), 'recap__total');
      addRecapRow('Type d’événement', order.event);
      addRecapRow('Prénom', order.name);
      if (order.model)  { addRecapRow('Modèle souhaité', order.model); }
      if (order.date)   { addRecapRow('Date de l’événement', order.date); }
      if (order.people) { addRecapRow('Organisateur(s)', order.people); }
      if (order.note)   { addRecapRow('Précisions', order.note); }

      currentMessage = buildOrderMessage(order);
      recapMessage.textContent = currentMessage;
      sendLink.setAttribute('href', buildWhatsAppUrl(currentMessage));
      copyStatus.textContent = '';
    }

    $('#back-to-form').addEventListener('click', function () {
      showStep('form');
      nameInput.focus();
    });

    // État de chargement bref à l'ouverture de WhatsApp (le lien s'ouvre dans un nouvel onglet).
    sendLink.addEventListener('click', function () {
      var label = $('[data-label]', sendLink);
      var original = label.textContent;
      sendLink.setAttribute('aria-busy', 'true');
      label.textContent = 'Ouverture de WhatsApp…';
      window.setTimeout(function () {
        sendLink.removeAttribute('aria-busy');
        label.textContent = original;
        copyStatus.textContent = 'Si WhatsApp ne s’est pas ouvert, utilisez « Copier le message » puis collez-le dans votre conversation.';
      }, 2500);
    });

    copyBtn.addEventListener('click', function () {
      function done(ok) {
        copyStatus.textContent = ok
          ? 'Message copié. Vous pouvez le coller dans WhatsApp.'
          : 'Copie impossible : sélectionnez le message dans l’aperçu et copiez-le manuellement.';
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(currentMessage).then(function () { done(true); }, function () { done(false); });
        return;
      }
      var area = document.createElement('textarea');
      area.value = currentMessage;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.opacity = '0';
      dialog.appendChild(area);
      area.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      dialog.removeChild(area);
      done(ok);
    });
  }

  /* ---------- Démarrage ---------- */
  function init() {
    initYear();
    initPriceLabels();
    initWhatsAppLinks();
    initMenu();
    initReveal();
    initActiveNav();
    initCalculator();
    initOrderDialog();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  // Exposé pour les tests automatisés (aucun effet sur le site).
  window.__inviteo = Object.freeze({
    CONFIG: CONFIG, PLANS: PLANS,
    parseQuantity: parseQuantity, totalCents: totalCents,
    formatTotal: formatTotal, formatUnit: formatUnit,
    buildOrderMessage: buildOrderMessage, buildWhatsAppUrl: buildWhatsAppUrl, genericMessage: genericMessage
  });
})();
