'use strict';
// Serveur local qui reproduit le routage de vercel.json : fichiers statiques + fonctions api/.
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '../..');
const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png' };
const handlers = { i: require(ROOT + '/api/i.js'), rsvp: require(ROOT + '/api/rsvp.js'), ticket: require(ROOT + '/api/ticket.js'), auth: require(ROOT + '/api/auth.js'), organizer: require(ROOT + '/api/organizer.js'), scan: require(ROOT + '/api/scan.js'), 'my-events': require(ROOT + '/api/my-events.js'), preview: require(ROOT + '/api/preview.js'), photo: require(ROOT + '/api/photo.js') };
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  let m;
  if ((m = /^\/i\/([^/]+)$/.exec(u.pathname))) { req.query = { t: decodeURIComponent(m[1]) }; return handlers.i(req, res); }
  if ((m = /^\/api\/(auth|scan|my-events|organizer)$/.exec(u.pathname))) return handlers[m[1]](req, res);
  if (u.pathname === '/api/photo') return handlers.photo(req, res);
  if (u.pathname === '/api/preview') return handlers.preview(req, res);
  if (u.pathname === '/modeles') { req.url = '/api/preview'; return handlers.preview(req, res); }
  if ((m = /^\/modeles\/([^/]+)$/.exec(u.pathname))) { req.url = '/api/preview?slug=' + m[1] + (u.search ? '&' + u.search.slice(1) : ''); return handlers.preview(req, res); }
  if (u.pathname === '/api/ticket') return handlers.ticket(req, res);
  if (u.pathname === '/api/rsvp') return handlers.rsvp(req, res);
  let f = /^\/s\/[^/]+$/.test(u.pathname) ? '/s.html' : u.pathname === '/' ? '/index.html' : u.pathname === '/scanner' ? '/scanner.html' : u.pathname === '/organisateur' ? '/organisateur.html' : u.pathname;
  if (!path.extname(f) && fs.existsSync(path.join(ROOT, f + '.html'))) f += '.html'; // cleanUrls
  const ignored = fs.readFileSync(path.join(ROOT, '.vercelignore'), 'utf8').split('\n').map((x) => x.trim()).filter(Boolean);
  if (ignored.some((x) => f === '/' + x || f.startsWith('/' + x + '/'))) { res.writeHead(404); return res.end('404'); }
  const p = path.join(ROOT, f);
  if (!p.startsWith(ROOT) || /\/(supabase|tests|api)\//.test(f) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); return res.end('404'); }
  const hd = { 'Content-Type': TYPES[path.extname(p)] || 'application/octet-stream' };
  res.writeHead(200, hd); fs.createReadStream(p).pipe(res);
}).listen(Number(process.env.PORT || 3100), '127.0.0.1');
