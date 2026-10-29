'use strict';
// POST /api/ticket  (organisateur connecté)
//   { "guest_id": "<uuid>" }       → émet l'invitation de cet invité
//   { "invitation_id": "<uuid>" }  → réémet (l'ancienne est révoquée)
// Répond avec le billet PDF individuel (QR code inclus). Le jeton du QR n'existe en clair qu'à cet instant :
// il n'est stocké nulle part ; si le PDF est perdu, on réémet l'invitation.
const { rpcAs } = require('./_lib/supabase');
const { buildTicketPdf } = require('./_lib/pdf');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SITE = () => (process.env.PUBLIC_SITE_URL || 'https://inviteo-dun.vercel.app').replace(/\/+$/, '');
const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(obj)); };

async function readBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  let raw = '';
  for await (const c of req) { raw += c; if (raw.length > 2000) throw new Error('too_big'); }
  return JSON.parse(raw || '{}');
}
const safeName = (s) => String(s || 'invite').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'invite';

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
  const origin = req.headers.origin;
  if (origin) { try { if (new URL(origin).host !== req.headers.host) return json(res, 403, { error: 'forbidden' }); } catch (_) { return json(res, 403, { error: 'forbidden' }); } }
  const jwt = (/^Bearer ([\w-]+\.[\w-]+\.[\w-]+)$/.exec(req.headers.authorization || '') || [])[1];
  if (!jwt) return json(res, 401, { error: 'authentication_required' });
  let b;
  try { b = await readBody(req); } catch (_) { return json(res, 400, { error: 'invalid_request' }); }
  const byGuest = typeof b.guest_id === 'string' && UUID.test(b.guest_id), byInv = typeof b.invitation_id === 'string' && UUID.test(b.invitation_id);
  if (byGuest === byInv) return json(res, 400, { error: 'invalid_request' });

  try {
    const rows = byGuest ? await rpcAs(jwt, 'issue_invitation', { p_guest_id: b.guest_id })
                         : await rpcAs(jwt, 'reissue_invitation', { p_invitation_id: b.invitation_id });
    const row = Array.isArray(rows) ? rows[0] : rows;
    if (!row || !row.qr_token || !row.view_token) return json(res, 502, { error: 'issue_failed' });
    const ctx = await rpcAs(jwt, 'ticket_context', { p_invitation_id: row.invitation_id });
    const pdf = buildTicketPdf(Object.assign({}, ctx, { guest_name: ctx.guest_name, event_name: ctx.event_name, qrText: `${SITE()}/s/${row.qr_token}` }));
    res.writeHead(200, {
      'Content-Type': 'application/pdf',
      'Content-Disposition': `attachment; filename="invitation-${safeName(ctx.guest_name)}.pdf"`,
      'Content-Length': pdf.length,
      'Cache-Control': 'no-store',
      'X-Invitation-Id': row.invitation_id,
      'X-Invitation-Link': `${SITE()}/i/${row.view_token}#${row.qr_token}`,
      'Access-Control-Expose-Headers': 'X-Invitation-Id, X-Invitation-Link, Content-Disposition',
    });
    res.end(pdf);
  } catch (e) {
    if (e.code === 'not_configured') return json(res, 503, { error: 'unavailable' });
    const s = e.status;
    return json(res, s === 401 ? 401 : s === 403 || s === 404 ? 403 : s >= 400 && s < 500 ? 400 : 503, { error: s === 401 ? 'authentication_required' : s >= 400 && s < 500 ? 'refused' : 'unavailable' });
  }
};
