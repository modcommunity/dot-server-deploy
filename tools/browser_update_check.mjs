// The addon update-and-restart path, in a real browser, signed in as a member.
//
//   node tools/browser_update_check.mjs --build <dir> --server ws://127.0.0.1:6064 \
//       [--port 8099] [--content https://dotgames.org] [--secs 150]
//
// <dir> is a web export of the shell made from an OLDER addons.lock than the server's
// (doctor the lock, export the Web preset into a scratch directory, put the lock back),
// so the shell really has to update. The server must advertise its content at this
// tool's origin (`./server run --content-url http://127.0.0.1:<port>/content`): /content
// here is a proxy to --content, because the CDN sends no CORS header to a local page.
//
// What it plays, on one origin:
//   * /host.html, the site's player page in miniature: an iframe of embed.html that is
//     answered on every `tmc.auth.ready` with the same single-use handoff code, exactly as
//     tmc-loader.js does after the frame reloads itself.
//   * /mock-backbone/redeem, which accepts that code ONCE and refuses it after, as the
//     site does. Anything else under /mock-backbone/ is a 404.
//
// What it asserts, which is what a player saw go wrong in production:
//   1. load 1 updates and restarts, and there are exactly two loads (no loop);
//   2. load 2 mounts the overlay at boot and boots on the versions load 1 built;
//   3. load 2 downloads no addon pack (no request for a manifest load 1 fetched);
//   4. load 2 is signed in as the member load 1 was, with one redeem, not two;
//   5. load 2 joins the game.
// Exit 0 when all hold, 1 otherwise, 2 on usage.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createRequire } from 'node:module';

const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};

const build = opt('build', '');
const server = opt('server', 'ws://127.0.0.1:6064');
const port = +opt('port', '8099');
const upstream = opt('content', 'https://dotgames.org').replace(/\/$/, '');
const secs = +opt('secs', '150');
const shot = opt('shot', path.join(os.tmpdir(), 'browser_update_check.png'));

if (!build || !fs.existsSync(path.join(build, 'embed.html'))) {
  console.error('usage: --build <a web export with embed.html beside it> [--server ws://...] [--port N] [--content URL]');
  process.exit(2);
}

// playwright-core from wherever this box has it. It is CommonJS, so it comes in through
// require; a named ESM import of { chromium } is a SyntaxError under Node's loader.
const loadPlaywright = () => {
  const require = createRequire(import.meta.url);
  const tries = [
    process.env.PLAYWRIGHT_CORE,
    'playwright-core',
    path.join(os.homedir(), '.local/share/mcp/playwright-mcp/node_modules/playwright-core'),
    path.join(os.homedir(), 'stack/website-city/node_modules/playwright-core'),
  ].filter(Boolean);
  for (const t of tries) {
    try { return require(t); } catch { /* next */ }
  }
  console.error(`playwright-core not found; set PLAYWRIGHT_CORE. Tried: ${tries.join(', ')}`);
  process.exit(2);
};
const { chromium } = loadPlaywright();

const MEMBER = { id: '4242', username: 'whoz', name: 'WhoZ' };
const CODE = 'handoff-code-for-this-check';
let redeems = 0;
let redeemsAccepted = 0;

const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.pck': 'application/octet-stream', '.png': 'image/png', '.json': 'application/json' };
const origin = `http://127.0.0.1:${port}`;
const embed = `/embed.html?server=${encodeURIComponent(server)}`;

const hostPage = `<!doctype html><meta charset="utf-8"><title>host</title>
<body style="margin:0;background:#111"><iframe id="f" src="${embed}" style="width:1280px;height:720px;border:0" allow="autoplay; fullscreen"></iframe>
<script>
  const auth = { mode: 'member', signedIn: true, guest: false,
    handoff: { code: ${JSON.stringify(CODE)}, redeemUrl: ${JSON.stringify(origin + '/mock-backbone/redeem')}, expiresIn: 60 } };
  const f = document.getElementById('f');
  const send = () => f.contentWindow.postMessage({ type: 'tmc.auth', auth }, '*');
  f.addEventListener('load', send);
  addEventListener('message', e => { if (e.data && e.data.type === 'tmc.auth.ready') send(); });
</script>`;

const srv = http.createServer((req, res) => {
  const u = new URL(req.url, origin);
  if (u.pathname === '/host.html') {
    res.writeHead(200, { 'content-type': 'text/html' }); res.end(hostPage); return;
  }
  if (u.pathname === '/mock-backbone/redeem' && req.method === 'POST') {
    redeems++;
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      let code = '';
      try { code = JSON.parse(body).code; } catch { /* refused below */ }
      if (code === CODE && redeemsAccepted === 0) {
        redeemsAccepted++;
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ data: { accessToken: 'access-' + Date.now(), refreshToken: 'refresh-' + Date.now(), expiresIn: 3600, user: MEMBER } }));
      } else {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ ok: false, code: 'auth.handoff.used', message: 'That sign-in code has been used.' }));
      }
    });
    return;
  }
  if (u.pathname.startsWith('/mock-backbone/')) { res.writeHead(404); res.end(); return; }
  if (u.pathname.startsWith('/content/')) {
    const lib = upstream.startsWith('https:') ? https : http;
    // A User-Agent, because the CDN refuses a request without one.
    const up = lib.request(upstream + u.pathname + u.search, {
      method: req.method,
      headers: { 'user-agent': 'browser_update_check/1', ...(req.headers.range ? { range: req.headers.range } : {}) },
    }, r => { const h = { ...r.headers }; delete h['alt-svc']; res.writeHead(r.statusCode, h); r.pipe(res); });
    up.on('error', e => { res.writeHead(502); res.end(String(e)); });
    up.end();
    return;
  }
  const p = path.join(build, decodeURIComponent(u.pathname));
  if (!p.startsWith(path.resolve(build))) { res.writeHead(403); res.end(); return; }
  fs.readFile(p, (e, d) => {
    if (e) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'content-type': types[path.extname(p)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(d);
  });
});
await new Promise(r => srv.listen(port, '127.0.0.1', r));

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM || (fs.existsSync('/usr/bin/chromium') ? '/usr/bin/chromium' : undefined),
  headless: true,
  args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'],
});
// A fresh context is a fresh IndexedDB and sessionStorage: a first visit.
const ctx = await browser.newContext({ viewport: { width: 1300, height: 740 } });
const page = await ctx.newPage();

let load = 0;
const lines = [[], [], [], [], []];
const contentGets = [[], [], [], [], []];
const isGame = f => f.parentFrame() === page.mainFrame();

page.on('framenavigated', f => { if (isGame(f)) load++; });
page.on('console', m => { if (load > 0) (lines[Math.min(load, 4)]).push(m.text()); });
page.on('request', r => {
  const p = new URL(r.url()).pathname;
  if (p.startsWith('/content/') && load > 0) contentGets[Math.min(load, 4)].push(p);
});

await page.goto(origin + '/host.html', { waitUntil: 'load', timeout: 60000 });

const has = (n, s) => lines[n].some(l => l.includes(s));
const deadline = Date.now() + secs * 1000;
while (Date.now() < deadline && !(load >= 2 && has(2, 'game loaded'))) {
  await new Promise(r => setTimeout(r, 1000));
}
// Long enough for a third load to start if the cap were what stopped the loop.
await new Promise(r => setTimeout(r, 8000));
await page.screenshot({ path: shot }).catch(() => {});
await browser.close();
srv.close();

const field = (n, msg, key) => {
  const l = lines[n].find(x => x.includes(msg)) ?? '';
  const m = l.match(new RegExp(`${key}=("(?:[^"\\\\]|\\\\.)*"|\\S+)`));
  return m ? m[1] : '';
};
const manifests = n => new Set(contentGets[n].filter(p => p.endsWith('/manifest.json')).map(p => p.split('/').slice(2, 4).join('/')));
// Load 1 restarts before it syncs any game, so what it fetched is the addon packs.
const addonPacks = [...manifests(1)].filter(id => !lines[1].some(l => l.includes('syncing content') && l.includes(id)));
const again = addonPacks.filter(id => contentGets[2].some(p => p.startsWith(`/content/${id}/`)));

const built = field(1, 'addon overlay ready for the next start', 'addons');
const booted = field(2, 'booted on the addon overlay', 'addons');
const who1 = field(1, 'signed in member=', 'member');
const who2 = field(2, 'signed in member=', 'member');

const checks = [
  ['load 1 found newer addons and updated', has(1, 'updating before joining') && built !== ''],
  ['exactly two loads', load === 2],
  ['load 2 mounted the overlay at boot', has(2, '[dot_cloud boot] mounted the addon overlay')],
  [`load 2 booted on what load 1 built (${booted || 'nothing'})`, booted !== '' && booted === built],
  [`load 2 downloaded no addon pack (load 1 fetched ${addonPacks.length})`, addonPacks.length > 0 && again.length === 0],
  [`signed in as the same member on both loads (${who1 || '-'} / ${who2 || '-'})`, who1 === `backbone:${MEMBER.id}` && who2 === who1],
  [`the handoff was redeemed once (${redeemsAccepted} accepted of ${redeems})`, redeemsAccepted === 1],
  ['load 2 joined the game', has(2, 'game loaded')],
];

let failed = 0;
for (const [what, ok] of checks) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}`);
  if (!ok) failed++;
}
if (again.length) console.log(`  load 2 fetched again: ${again.join(', ')}`);
console.log(`${checks.length - failed}/${checks.length} checks passed; ${load} loads; screenshot ${shot}`);
process.exit(failed ? 1 : 0);
