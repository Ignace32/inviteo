'use strict';
const { rpc } = require('./_lib/supabase');

const H = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
const out = (res, code, obj) => { res.writeHead(code, H); res.end(JSON.stringify(obj)); };
const STATUS = { not_found: 404, closed: 410, rsvp_disabled: 403, invalid_party_count: 422, invalid_request: 400 };

async function readBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  let raw = '';
  for await (const c of req) { raw += c; if (raw.length > 4000) throw new Error('too_big'); }
  return JSON.parse(raw || '{}');
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
  // Même origine uniquement : le formulaire est servi par ce site.
  const origin = req.headers.origin, host = req.headers.host;
  if (origin) { try { if (new URL(origin).host !== host) return out(res, 403, { ok: false, error: 'forbidden' }); } catch (_) { return out(res, 403, { ok: false, error: 'forbidden' }); } }
  if (!String(req.headers['content-type'] || '').startsWith('application/json')) return out(res, 415, { ok: false, error: 'invalid_request' });

  let b;
  try { b = await readBody(req); } catch (_) { return out(res, 400, { ok: false, error: 'invalid_request' }); }
  const token = typeof b.token === 'string' ? b.token : '';
  if (!/^[A-Za-z0-9_-]{20,200}$/.test(token) || typeof b.attending !== 'boolean') return out(res, 400, { ok: false, error: 'invalid_request' });
  const count = b.party_count == null ? null : Number(b.party_count);
  if (count !== null && !Number.isInteger(count)) return out(res, 422, { ok: false, error: 'invalid_party_count' });

  try {
    const r = await rpc('invitation_submit_rsvp', {
      p_view_token: token, p_attending: b.attending, p_party_count: count,
      p_song: typeof b.song === 'string' ? b.song : null, p_note: typeof b.note === 'string' ? b.note : null,
    });
    return out(res, r.ok ? 200 : (STATUS[r.error] || 400), r);
  } catch (_) { return out(res, 503, { ok: false, error: 'unavailable' }); }
};
