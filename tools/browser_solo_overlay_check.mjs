// A solo game that needs addons the shell does not carry, in a real headless browser, from a tab in one of three states.
//
//   node tools/browser_solo_overlay_check.mjs --url <embed.html?solo=...> --state fresh|counter2|failed \
//       [--serve <web export dir> --port 8098 --content https://dotgames.org] [--lock addons.lock | --fp HEX] \
//       [--addons arena_weapons@1.4.46,zee_weapons@0.1.62] [--expect started,blocked] [--secs 240] [--shot out.png]
//       [--map <slug>] [--linger <secs>] [--map-loaded <regex>]
//
// The bug it was written for (2026-11-13): a tab that had restarted twice for PLAYLOT's weapon addons gave up and started
// the game without zee_weapons, so its scripts did not parse and the page stayed black. The shell now blocks such a game
// behind Retry, and keys the count and the failed mark by its own build. See docs/addon-packs.md.
//
// States, seeded on the page's origin before the shell loads:
//   fresh     a new profile: nothing stored.
//   counter2  sessionStorage tmc.addon_updates counting two restarts for the set, in the flat form shells kept up to
//             20261113-0522 (what the player's tab held), and in the keyed form when --fp is known.
//   failed    the overlay plan in IndexedDB (user://dot_cloud_addons/plan.json) marked failed for the set, stamped with the
//             page's shell build. Its `build` is --fp, or the fingerprint of --lock with the export's dot-only filter;
//             without either the mark names no build and every shell ignores it.
//
// --serve serves a local web export as /godot/<build>/ (the build from --url's path, so the shell reads a build id) with
// /content proxied to --content, because the CDN sends no CORS header to another origin. Without it --url is opened as is.
//
// Verdict, from the shell's console:
//   broken    the game started without its addons (the old "playing on this build's", a parse error, a script that did
//             not load). Always a failure.
//   started   "solo game started" with no broken sign.
//   blocked   "not starting it without them": the shell refused and offers Retry.
//   none      none of these within --secs.
// --map <slug> opens the page with &map=<slug> (the site's "Play map": a solo game on one map, fetching only that map's pack).
// A started game is then watched for --linger seconds (default 8, or 120 with --map: a downloaded map takes longer to load
// than the game takes to start) and the check ends early once the console matches --map-loaded (default
// "world built|map changed|map loaded|round began", case-insensitive). With --map, a map-loaded line that never shows is reported as
// `map: <slug> not seen` and fails the run (exit 1); --map-loaded '' turns that requirement off.
// Exit 0 when the verdict is in --expect, 1 otherwise, 2 on usage.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};

const state = opt('state', 'fresh');
const serve = opt('serve', '');
const port = +opt('port', '8098');
const upstream = opt('content', 'https://dotgames.org').replace(/\/$/, '');
const addonsArg = opt('addons', 'arena_weapons@1.4.46,zee_weapons@0.1.62');
const expect = opt('expect', 'started,blocked').split(',');
const secs = +opt('secs', '240');
const shot = opt('shot', path.join(os.tmpdir(), `browser_solo_overlay_${state}.png`));
const userDir = opt('userdir', '/userfs/godot/app_userdata/TMC server');
let url = opt('url', '');
const mapSlug = opt('map', '');
const lingerSecs = +opt('linger', mapSlug ? '120' : '8');
const mapLoadedSrc = opt('map-loaded', 'world built|map changed|map loaded|round began');
const mapLoaded = mapSlug && mapLoadedSrc ? new RegExp(mapLoadedSrc, 'i') : null;
if (mapSlug) {
  if (!/^[A-Za-z0-9_.-]+$/.test(mapSlug)) { console.error(`--map ${mapSlug}: not a map id`); process.exit(2); }
  if (url) { const u = new URL(url); u.searchParams.set('map', mapSlug); url = u.toString(); }
}

if (!url || !['fresh', 'counter2', 'failed'].includes(state)) {
  console.error('usage: --url <embed.html?solo=owner/repo...> --state fresh|counter2|failed [--serve dir] [--lock file | --fp hex]');
  process.exit(2);
}

// The shell build the page runs, read back from /godot/<id>/ exactly as client/shell_version.gd does.
const buildId = (new URL(url).pathname.match(/\/(\d{8}-\d{4})\//) || [])[1] || '';
const game = new URL(url).searchParams.get('solo') || '';

// The export's addons.lock fingerprint: tools/server.in's shell_lock_begin keeps comments, blanks and dot-* rows, and
// DotCloudAddonSet.build_fingerprint is the first 16 hex of its sha256.
let fp = opt('fp', '');
const lock = opt('lock', '');
if (!fp && lock) {
  const kept = fs.readFileSync(lock, 'utf8').split('\n').filter((l, i, all) => {
    if (i === all.length - 1 && l === '') return true;
    return /^[\s]*(#|$)/.test(l) || l.split('\t')[0].startsWith('dot-');
  });
  fp = crypto.createHash('sha256').update(kept.join('\n')).digest('hex').slice(0, 16);
}

const wanted = {};
for (const part of addonsArg.split(',').filter(Boolean)) {
  const [dir, version] = part.split('@');
  wanted[dir] = { version };
}
const attempt = `solo:${game}|${Object.keys(wanted).sort().map(d => `${d}@${wanted[d].version}`).join(',')}`;

const loadPlaywright = () => {
  const require = createRequire(import.meta.url);
  const tries = [
    process.env.PLAYWRIGHT_CORE,
    'playwright-core',
    path.join(os.homedir(), 'pw/node_modules/playwright-core'),
    path.join(os.homedir(), '.local/share/mcp/playwright-mcp/node_modules/playwright-core'),
  ].filter(Boolean);
  for (const t of tries) {
    try { return require(t); } catch { /* next */ }
  }
  console.error(`playwright-core not found; set PLAYWRIGHT_CORE. Tried: ${tries.join(', ')}`);
  process.exit(2);
};
const { chromium } = loadPlaywright();

let srv = null;
if (serve) {
  if (!fs.existsSync(path.join(serve, 'embed.html'))) { console.error(`--serve ${serve} has no embed.html`); process.exit(2); }
  const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json', '.png': 'image/png' };
  const prefix = `/godot/${buildId || 'local'}/`;
  srv = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    if (u.pathname.startsWith('/content/')) {
      const lib = upstream.startsWith('https:') ? https : http;
      const up = lib.request(upstream + u.pathname + u.search, {
        method: req.method,
        headers: { 'user-agent': 'browser_solo_overlay_check/1', ...(req.headers.range ? { range: req.headers.range } : {}) },
      }, r => { const h = { ...r.headers }; delete h['alt-svc']; res.writeHead(r.statusCode, h); r.pipe(res); });
      up.on('error', e => { res.writeHead(502); res.end(String(e)); });
      up.end();
      return;
    }
    if (!u.pathname.startsWith(prefix)) { res.writeHead(404, { 'content-type': 'text/html' }); res.end('<!doctype html>'); return; }
    const p = path.join(serve, decodeURIComponent(u.pathname.slice(prefix.length)));
    if (!p.startsWith(path.resolve(serve))) { res.writeHead(403); res.end(); return; }
    fs.readFile(p, (e, d) => {
      if (e) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'content-type': types[path.extname(p)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
      res.end(d);
    });
  });
  await new Promise(r => srv.listen(port, '127.0.0.1', r));
  const given = new URL(url);
  url = `http://127.0.0.1:${port}${prefix}embed.html${given.search}`;
}

// GPU_CDP_URL (set by dot-bootstrap's `gpu.sh cdp-run -- node tools/browser_solo_overlay_check.mjs ...`) drives a real
// GPU's Chrome on a staging box. Without it, Chrome here renders WebGL in software, and the shot can come out black
// while the game runs.
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'solo-overlay-profile-'));
const cdp = process.env.GPU_CDP_URL ? await chromium.connectOverCDP(process.env.GPU_CDP_URL) : null;
const ctx = cdp ? await cdp.newContext({ viewport: { width: 1280, height: 720 } }) : await chromium.launchPersistentContext(profile, {
  executablePath: process.env.CHROME || (fs.existsSync('/usr/bin/google-chrome') ? '/usr/bin/google-chrome' : undefined),
  headless: true,
  args: ['--use-angle=gl', '--enable-gpu', '--ignore-gpu-blocklist'],
  viewport: { width: 1280, height: 720 },
});
const page = ctx.pages()[0] || await ctx.newPage();

const t0 = Date.now();
const lines = [];
const log = s => { const l = `${((Date.now() - t0) / 1000).toFixed(1)} ${s}`; lines.push(l); console.log(l); };
page.on('console', m => log(`[${m.type()}] ${m.text()}`));
page.on('pageerror', e => log(`[pageerror] ${e.message}`));
page.on('framenavigated', f => { if (f === page.mainFrame()) log(`[nav] ${f.url()}`); });

// Seed on the origin before the shell's first load: same tab, so sessionStorage carries over.
const origin = new URL(url).origin;
if (state !== 'fresh') {
  await page.goto(`${origin}/solo-overlay-check-seed`).catch(() => {});
  const seeded = await page.evaluate(async ({ state, attempt, wanted, fp, buildId, userDir }) => {
    if (state === 'counter2') {
      // The flat form is what the player's tab held; the keyed one is what a shell after the fix writes for this build.
      const flat = { [attempt]: 2 };
      sessionStorage.setItem('tmc.addon_updates', JSON.stringify(fp ? { build: `${buildId}/${fp}`, counts: flat } : flat));
      return sessionStorage.getItem('tmc.addon_updates');
    }
    // The failed mark, as Emscripten's IDBFS keeps user://: one record per directory and file, keyed by path.
    const plan = JSON.stringify({ state: 'failed', build: fp, addons: wanted, shell: buildId });
    const db = await new Promise((ok, no) => {
      const r = indexedDB.open('/userfs', 21);
      r.onupgradeneeded = () => {
        const s = r.result.createObjectStore('FILE_DATA');
        s.createIndex('timestamp', 'timestamp', { unique: false });
      };
      r.onsuccess = () => ok(r.result);
      r.onerror = () => no(r.error);
    });
    const tx = db.transaction('FILE_DATA', 'readwrite');
    const store = tx.objectStore('FILE_DATA');
    const now = new Date();
    const dirs = [];
    for (let p = `${userDir}/dot_cloud_addons`; p.length > '/userfs'.length; p = p.slice(0, p.lastIndexOf('/'))) dirs.unshift(p);
    for (const d of dirs) store.put({ timestamp: now, mode: 0o40777 }, d);
    store.put({ timestamp: now, mode: 0o100666, contents: new TextEncoder().encode(plan) }, `${userDir}/dot_cloud_addons/plan.json`);
    await new Promise((ok, no) => { tx.oncomplete = ok; tx.onerror = () => no(tx.error); });
    db.close();
    return plan;
  }, { state, attempt, wanted, fp, buildId, userDir });
  log(`[seed] ${state}: ${seeded}`);
}

const BROKEN = [/playing on this build's/, /Parse Error/i, /Failed to load script/, /ZeeViewModel/, /follow_hands/];
const verdict = () => {
  const text = lines.join('\n');
  if (BROKEN.some(r => r.test(text))) return 'broken';
  if (/solo game started/.test(text)) return 'started';
  if (/not starting it without them/.test(text)) return 'blocked';
  return 'none';
};

await page.goto(url);
const deadline = Date.now() + secs * 1000;
while (Date.now() < deadline) {
  await page.waitForTimeout(2000);
  const v = verdict();
  if (v === 'broken' || v === 'blocked') break;
  if (v === 'started') {
    // A started game is given a few seconds more for the parse errors a game without its addons prints,
    // and with --map until its map has loaded.
    const until = Date.now() + lingerSecs * 1000;
    while (Date.now() < until && verdict() === 'started') {
      if (mapLoaded && mapLoaded.test(lines.join('\n'))) { await page.waitForTimeout(3000); break; }
      await page.waitForTimeout(1000);
    }
    break;
  }
}
await page.screenshot({ path: shot }).catch(() => {});
await ctx.close();
if (cdp) await cdp.close();
if (srv) srv.close();
fs.rmSync(profile, { recursive: true, force: true });

const v = verdict();
console.log(`\nverdict: ${v} (state ${state}, shell ${buildId || '?'}, expect ${expect.join('|')}) screenshot ${shot}`);
let mapOk = true;
if (mapLoaded && v === 'started') {
  mapOk = mapLoaded.test(lines.join('\n'));
  console.log(`map: ${mapSlug} ${mapOk ? 'loaded' : 'not seen'} (/${mapLoadedSrc}/i within ${lingerSecs} s of the start)`);
}
process.exit(expect.includes(v) && mapOk ? 0 : 1);
