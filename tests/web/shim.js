'use strict';
// Relais de test : remplace UNIQUEMENT la couche HTTP de Supabase (PostgREST + GoTrue).
// Chaque appel /rest/v1/rpc/<fonction> exécute la VRAIE fonction SQL dans PostgreSQL via psql,
// avec le rôle service_role ou, pour un utilisateur, le rôle authenticated + son identifiant (RLS appliquée).
// Le faux GoTrue accepte le mot de passe « test-pass » : ce n'est PAS la vraie authentification Supabase.
const http = require('http'), { spawn } = require('child_process');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, TOK = /^[\w-]{1,200}$/;
const T = { uuid: (v) => UUID.test(String(v)), token: (v) => TOK.test(String(v)), 'text?': (v) => v == null || typeof v === 'string', rows: (v) => Array.isArray(v), obj: (v) => v && typeof v === 'object' && !Array.isArray(v), text: (v) => typeof v === 'string' && v.length < 400, int: (v) => Number.isInteger(v), 'text?x': () => true };
const sq = (v) => v == null ? 'null' : `'${String(v).replace(/'/g, "''")}'`;
const lit = (v) => v === null || v === undefined ? 'null' : typeof v === 'boolean' || typeof v === 'number' ? String(v) : `'${String(v).replace(/'/g, "''")}'`;

const SERVER_FN = {
  list_templates: {},
  invitation_public_view: { p_view_token: 'text' },
  invitation_submit_rsvp: { p_view_token: 'text', p_attending: 'boolean', p_party_count: 'int', p_song: 'text', p_note: 'text' },
};
const USER_FN = {
  issue_invitation: { a: { p_guest_id: 'uuid' }, sql: (a) => `select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.issue_invitation('${a.p_guest_id}'::uuid) t` },
  reissue_invitation: { a: { p_invitation_id: 'uuid' }, sql: (a) => `select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.reissue_invitation('${a.p_invitation_id}'::uuid) t` },
  ticket_context: { a: { p_invitation_id: 'uuid' }, sql: (a) => `select public.ticket_context('${a.p_invitation_id}'::uuid)` },
  my_assigned_events: { a: {}, sql: () => `select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.my_assigned_events() t` },
  organizer_events: { a: {}, sql: () => `select public.organizer_events()` },
  event_guests: { a: { p_event_id: 'uuid' }, sql: (a) => `select public.event_guests('${a.p_event_id}'::uuid)` },
  event_stats: { a: { p_event_id: 'uuid' }, sql: (a) => `select public.event_stats('${a.p_event_id}'::uuid)` },
  revoke_invitation: { a: { p_invitation_id: 'uuid', p_reason: 'text?' }, sql: (a) => `select public.revoke_invitation('${a.p_invitation_id}'::uuid, ${sq(a.p_reason)}); select '{}'` },
  import_guests: { a: { p_event_id: 'uuid', p_rows: 'rows' }, sql: (a) => `select public.import_guests('${a.p_event_id}'::uuid, ${sq(JSON.stringify(a.p_rows))}::jsonb)` },
  list_templates: { a: {}, sql: () => `select public.list_templates()` },
  my_agents: { a: {}, sql: () => `select public.my_agents()` },
  create_event: { a: { p_data: 'obj' }, sql: (a) => `select public.create_event(${sq(JSON.stringify(a.p_data))}::jsonb)` },
  update_event: { a: { p_event_id: 'uuid', p_data: 'obj' }, sql: (a) => `select public.update_event('${a.p_event_id}'::uuid, ${sq(JSON.stringify(a.p_data))}::jsonb)` },
  event_for_edit: { a: { p_event_id: 'uuid' }, sql: (a) => `select public.event_for_edit('${a.p_event_id}'::uuid)` },
  set_event_photo: { a: { p_event_id: 'uuid', p_kind: 'text', p_path: 'text', p_width: 'int', p_height: 'int', p_alt: 'text?' }, sql: (a) => `select public.set_event_photo('${a.p_event_id}'::uuid, ${sq(a.p_kind)}, ${sq(a.p_path)}, ${a.p_width}, ${a.p_height}, ${sq(a.p_alt)})` },
  remove_event_photo: { a: { p_asset_id: 'uuid' }, sql: (a) => `select public.remove_event_photo('${a.p_asset_id}'::uuid)` },
  scan_invitation: { a: { p_event_id: 'uuid', p_token: 'token', p_request_id: 'uuid' }, sql: (a) => `select public.scan_invitation('${a.p_event_id}'::uuid, '${a.p_token}', '${a.p_request_id}'::uuid)` },
};

function run(sql) {
  return new Promise((resolve, reject) => {
    const p = spawn('psql', ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', process.env.SHIM_DB || 'inviteo_web'], { env: process.env });
    let out = '', err = '';
    p.stdout.on('data', (d) => out += d); p.stderr.on('data', (d) => err += d);
    p.on('close', (c) => c === 0 ? resolve(out) : reject(new Error(err)));
    p.stdin.end(sql);
  });
}
const lastJson = (out) => out.trim().split('\n').filter((l) => l.startsWith('{') || l.startsWith('[')).pop();
const FILES = new Map();
const readRaw = (req) => new Promise((r) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => r(Buffer.concat(c))); });
const readBody = (req) => new Promise((r) => { let b = ''; req.on('data', (d) => b += d); req.on('end', () => r(b)); });
const send = (res, code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(body); };

http.createServer(async (req, res) => {
  try {
    // --- Faux GoTrue ---
    const au = /^\/auth\/v1\/token\?grant_type=(password|refresh_token)$/.exec(req.url);
    if (au && req.method === 'POST') {
      if (req.headers.apikey !== process.env.ANON_KEY) return send(res, 401, '{}');
      const a = JSON.parse((await readBody(req)) || '{}'); let uid;
      if (au[1] === 'password') {
        if (a.password !== 'test-pass' || !/^[\w.@+-]{3,100}$/.test(a.email || '')) return send(res, 400, '{"error":"invalid_grant"}');
        uid = (await run(`select id from auth.users where email = '${a.email}'`)).trim();
      } else { const m = /^r\.([0-9a-f-]{36})\.x$/.exec(a.refresh_token || ''); uid = m && m[1]; }
      if (!uid || !UUID.test(uid)) return send(res, 400, '{"error":"invalid_grant"}');
      return send(res, 200, JSON.stringify({ access_token: `eyJ.${uid}.sig`, refresh_token: `r.${uid}.x`, expires_in: 3600 }));
    }

    // --- Faux Storage (bucket privé) : octets gardés en mémoire, URL signées à usage local ---
    const st = /^\/storage\/v1\/object\/(sign\/)?event-assets\/([\w./-]+?)(\?.*)?$/.exec(req.url);
    if (st) {
      const path = st[2];
      if (req.method === 'GET' && st[1]) { const f = FILES.get(path); if (!f) return send(res, 404, '{}'); res.writeHead(200, { 'Content-Type': f.type }); return res.end(f.buf); }
      if ((req.headers.authorization || '') !== 'Bearer ' + process.env.SERVICE_KEY) return send(res, 401, '{}');
      if (req.method === 'POST' && st[1]) return send(res, FILES.has(path) ? 200 : 400, JSON.stringify({ signedURL: `/object/sign/event-assets/${path}?token=t` }));
      if (req.method === 'POST') { const buf = await readRaw(req); FILES.set(path, { buf, type: req.headers['content-type'] || 'application/octet-stream' }); return send(res, 200, '{"Key":"ok"}'); }
      if (req.method === 'DELETE') { FILES.delete(path); return send(res, 200, '{}'); }
    }
    if (req.method === 'GET' && req.url === '/__files') return send(res, 200, JSON.stringify([...FILES.keys()]));

    const fn = /^\/rest\/v1\/rpc\/(\w+)$/.exec(req.url);
    if (!fn || req.method !== 'POST') return send(res, 404, '{}');
    const auth = req.headers.authorization || '';

    // --- Appels serveur (service_role) ---
    if (auth === 'Bearer ' + process.env.SERVICE_KEY && SERVER_FN[fn[1]]) {
      const spec = SERVER_FN[fn[1]], args = JSON.parse((await readBody(req)) || '{}');
      const named = Object.keys(args).map((k) => { if (!spec[k]) throw new Error('arg'); return `${k} => ${lit(args[k])}::${spec[k]}`; }).join(', ');
      const out = await run(`begin; set local role service_role; select public.${fn[1]}(${named}); commit;`);
      return send(res, 200, lastJson(out));
    }

    // --- Appels au nom d'un utilisateur : jeton de test eyJ.<uuid>.<sig> ; « exp » = jeton expiré ---
    const um = /^Bearer [\w-]+\.([0-9a-f-]{36})\.([\w-]+)$/.exec(auth);
    if (um && USER_FN[fn[1]]) {
      if (req.headers.apikey !== process.env.ANON_KEY || !UUID.test(um[1]) || um[2] === 'exp') return send(res, 401, '{}');
      const spec = USER_FN[fn[1]], a = JSON.parse((await readBody(req)) || '{}');
      if (Object.keys(a).some((k) => !(k in spec.a))) return send(res, 400, '{}');
      for (const [k, t] of Object.entries(spec.a)) if (!(t === 'text?' && a[k] === undefined) && !T[t](a[k])) return send(res, 400, '{}');
      try {
        const out = await run(`begin; select set_config('request.jwt.claim.sub','${um[1]}',true); set local role authenticated; ${spec.sql(a)}; commit;`);
        return send(res, 200, lastJson(out));
      } catch (e) { return send(res, /denied|not found|authentication/.test(String(e.message)) ? 403 : 400, JSON.stringify({ message: String(e.message).slice(0, 200) })); }
    }
    return send(res, 401, '{}');
  } catch (e) { send(res, 400, JSON.stringify({ message: String(e.message).slice(0, 200) })); }
}).listen(Number(process.env.SHIM_PORT || 54321), '127.0.0.1');
