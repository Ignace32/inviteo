'use strict';
// Accès serveur à Supabase (PostgREST + Storage) avec la clé service_role.
// Ce fichier ne s'exécute que sur Vercel : la clé ne doit jamais atteindre le navigateur.

function config() {
  const url = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
  if (!/^https?:\/\//.test(url) || !key) {
    const e = new Error('supabase_not_configured');
    e.code = 'not_configured';
    throw e;
  }
  return { url, key };
}

async function rpc(name, args) {
  const { url, key } = config();
  const res = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args || {}),
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) {
    const e = new Error(`rpc_${name}_${res.status}`);
    e.code = 'upstream';
    throw e;
  }
  return res.json();
}

// Appel d'une fonction au nom d'un utilisateur connecté (son jeton JWT) : les droits et la sécurité
// par ligne (RLS) de la base s'appliquent exactement comme s'il appelait lui-même.
async function rpcAs(jwt, name, args) {
  const url = (process.env.SUPABASE_URL || '').replace(/\/+$/, ''), anon = process.env.SUPABASE_ANON_KEY || '';
  if (!/^https?:\/\//.test(url) || !anon) { const e = new Error('supabase_not_configured'); e.code = 'not_configured'; throw e; }
  const res = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: anon, Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args || {}),
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) { const e = new Error(`rpc_${name}_${res.status}`); e.code = 'upstream'; e.status = res.status; throw e; }
  return res.json();
}

// URL signée (1 h) pour une photo du bucket privé « event-assets ». Renvoie null en cas d'échec :
// la page s'affiche alors sans la photo plutôt que de planter.
async function signAsset(path) {
  try {
    const { url, key } = config();
    if (typeof path !== 'string' || !/^[\w./-]{1,300}$/.test(path) || path.includes('..')) return null;
    const res = await fetch(`${url}/storage/v1/object/sign/event-assets/${path}`, {
      method: 'POST',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ expiresIn: 3600 }),
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return null;
    const j = await res.json();
    const rel = j.signedURL || j.signedUrl;
    if (!rel) return null;
    return rel.startsWith('http') ? rel : `${url}/storage/v1${rel.startsWith('/') ? '' : '/'}${rel}`;
  } catch (_) { return null; }
}

// Dépôt / suppression d'un fichier du bucket privé (clé service_role, jamais exposée au navigateur).
async function putAsset(path, buf, contentType) {
  const { url, key } = config();
  if (!/^[\w./-]{1,300}$/.test(path) || path.includes('..')) throw new Error('invalid_path');
  const res = await fetch(`${url}/storage/v1/object/event-assets/${path}`, {
    method: 'POST', headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': contentType, 'x-upsert': 'false', 'Cache-Control': 'max-age=3600' },
    body: buf, signal: AbortSignal.timeout(20000),
  });
  if (!res.ok) { const e = new Error(`storage_put_${res.status}`); e.code = 'upstream'; throw e; }
}
async function deleteAsset(path) {
  try {
    const { url, key } = config();
    if (typeof path !== 'string' || !/^[\w./-]{1,300}$/.test(path) || path.includes('..')) return false;
    const res = await fetch(`${url}/storage/v1/object/event-assets/${path}`, { method: 'DELETE', headers: { apikey: key, Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(8000) });
    return res.ok;
  } catch (_) { return false; }
}

module.exports = { rpc, rpcAs, signAsset, putAsset, deleteAsset };
