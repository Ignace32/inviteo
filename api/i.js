'use strict';
const { rpc, signAsset } = require('./_lib/supabase');
const { renderInvitation, renderError } = require('./_lib/render');

const HEADERS = {
  'Content-Type': 'text/html; charset=utf-8',
  'Cache-Control': 'private, no-store',
  'X-Robots-Tag': 'noindex, nofollow, noarchive',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: https:; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
};

function send(res, code, html) { res.writeHead(code, HEADERS); res.end(html); }

module.exports = async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405, { Allow: 'GET, HEAD' }); return res.end(); }
  const token = String((req.query && req.query.t) || new URL(req.url, 'http://x').searchParams.get('t') || '');
  if (!/^[A-Za-z0-9_-]{20,200}$/.test(token)) return send(res, 404, renderError('not_found'));

  let data;
  try { data = await rpc('invitation_public_view', { p_view_token: token }); }
  catch (_) { return send(res, 503, renderError('unavailable')); }

  switch (data && data.state) {
    case 'ok': {
      const photos = [];
      const wanted = (data.assets || []).filter((a) => a.kind === 'photo' || a.kind === 'cover').slice(0, 6);
      const urls = await Promise.all(wanted.map((a) => signAsset(a.path)));
      wanted.forEach((a, i) => { if (urls[i]) photos.push({ url: urls[i], alt: a.alt, width: a.width, height: a.height, kind: a.kind }); });
      return send(res, 200, renderInvitation(data, token, photos));
    }
    case 'revoked': case 'expired': case 'cancelled': case 'event_closed':
      return send(res, 410, renderError(data.state, data.event));
    default:
      return send(res, 404, renderError('not_found'));
  }
};
