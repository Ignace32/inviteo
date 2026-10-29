'use strict';
// Photos d'un événement (organisateur connecté, jeton de l'utilisateur).
//   GET    /api/photo?event=<uuid>                      → fiche de l'événement + photos avec URL signées (éditeur)
//   POST   /api/photo?event=<uuid>&kind=cover|photo     → corps = image JPEG/PNG/WebP (≤ 4 Mo) ; remplace la photo principale
//   DELETE /api/photo?asset=<uuid>                      → retire une photo
// Le propriétaire est vérifié par la base (RLS). Le fichier est contrôlé d'après ses octets, stocké dans le bucket
// PRIVÉ « event-assets » ; la base ne garde que sa référence. Si l'enregistrement en base échoue, le fichier est supprimé.
const crypto = require('crypto');
const { rpcAs, signAsset, putAsset, deleteAsset } = require('./_lib/supabase');
const { json, sameOrigin, bearer, upstreamError } = require('./_lib/http');
const { sniff } = require('./_lib/image');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX = 4 * 1024 * 1024;

async function body(req) {
  const chunks = []; let n = 0;
  for await (const c of req) {
    n += c.length;
    if (n <= MAX) chunks.push(c);            // au-delà de la limite on lit sans garder (réponse propre 413, pas de coupure)
    else if (n > 64 * 1024 * 1024) { req.destroy(); break; }
  }
  if (n > MAX) { const e = new Error('too_big'); e.big = true; throw e; }
  return Buffer.concat(chunks);
}

module.exports = async function handler(req, res) {
  const u = new URL(req.url, 'http://x'), q = u.searchParams;
  if (!['GET', 'POST', 'DELETE'].includes(req.method)) { res.writeHead(405, { Allow: 'GET, POST, DELETE' }); return res.end(); }
  if (req.method !== 'GET' && !sameOrigin(req)) return json(res, 403, { error: 'forbidden' });
  const jwt = bearer(req); if (!jwt) return json(res, 401, { error: 'authentication_required' });
  try {
    if (req.method === 'GET') {
      const ev = q.get('event'); if (!UUID.test(ev || '')) return json(res, 400, { error: 'invalid_request' });
      const d = await rpcAs(jwt, 'event_for_edit', { p_event_id: ev });
      const photos = await Promise.all((d.photos || []).map(async (p) => ({ id: p.id, kind: p.kind, width: p.width, height: p.height, alt: p.alt, url: await signAsset(p.path) })));
      return json(res, 200, { event: d.event, photos });
    }
    if (req.method === 'DELETE') {
      const id = q.get('asset'); if (!UUID.test(id || '')) return json(res, 400, { error: 'invalid_request' });
      const r = await rpcAs(jwt, 'remove_event_photo', { p_asset_id: id });
      if (!r || !r.ok) return json(res, 404, { error: 'not_found' });
      await deleteAsset(r.path);
      return json(res, 200, { ok: true });
    }
    // POST
    const ev = q.get('event'), kind = q.get('kind') || 'photo';
    if (!UUID.test(ev || '') || !['cover', 'photo'].includes(kind)) return json(res, 400, { error: 'invalid_request' });
    let buf; try { buf = await body(req); } catch (e) { return json(res, e.big ? 413 : 400, { error: e.big ? 'file_too_big' : 'invalid_request' }); }
    const img = sniff(buf);
    if (!img) return json(res, 415, { error: 'unsupported_type' });
    if (img.w < 200 || img.h < 200) return json(res, 422, { error: 'image_too_small' });
    if (img.w > 12000 || img.h > 12000) return json(res, 422, { error: 'image_too_large' });
    await rpcAs(jwt, 'event_for_edit', { p_event_id: ev });            // refuse (403) si l'événement n'est pas à lui
    const path = `${ev}/${crypto.randomBytes(12).toString('hex')}.${img.ext}`;
    await putAsset(path, buf, img.type);
    let r;
    try { r = await rpcAs(jwt, 'set_event_photo', { p_event_id: ev, p_kind: kind, p_path: path, p_width: img.w, p_height: img.h, p_alt: (q.get('alt') || '').slice(0, 200) }); }
    catch (e) { await deleteAsset(path); throw e; }
    if (!r || !r.ok) { await deleteAsset(path); return json(res, 409, { error: (r && r.error) || 'refused' }); }
    for (const old of r.replaced || []) await deleteAsset(old);
    return json(res, 200, { ok: true, id: r.id, kind, width: img.w, height: img.h, url: await signAsset(path) });
  } catch (e) { return upstreamError(res, e); }
};
