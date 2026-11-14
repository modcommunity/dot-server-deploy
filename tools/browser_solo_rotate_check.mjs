// A web match changes maps: the next level loads while the last one and its textures are freed, and that is where a wasm heap
// that only grows hits its limit (the zombie-zone and mg-wipeout crashes were out-of-memory). The solo overlay check loads one map
// per page; this one loads a rotation in ONE page and reports the wasm heap after each load.
//
//   gpu.sh cdp-run -- node tools/browser_solo_rotate_check.mjs --url <embed.html?solo=owner/repo> \
//       [--maps welcometomexicov6,dm-industrial-gamma,surf_xiv_v2a,welcometomexicov6] [--secs 240] [--per-map 150] \
//       [--serve <web export dir> --port 8099 --content https://dotgames.org]   (a local export, /content proxied to the live origin)
//       [--loaded 'map change map:{map} to playable'] [--cmd solo_map] [--max-growth-mb 400]
//
// Every map is typed into the game's local console as `solo_map <id>` once the match is live (backtick opens it; FC's
// command that runs the M menu's change, as the in-process match has no server console for dot-map's `map`). A map is loaded when the game logs --loaded (default
// "map change map:{map} to playable") after the command. After each load: the wasm heap (every WebAssembly.Memory the page made; it only grows),
// the JS heap (CDP Performance.getMetrics) and the browser's own tally when it gives one.
// Fails (exit 1) on an abort, an OOM, a RangeError, a wasm trap, a map that never loads, or a final wasm heap more than
// --max-growth-mb over the first one (0, the default, turns that off). Exit 2 on usage.
import fs from 'node:fs';
import { serveShell } from './local_shell_server.mjs';
import path from 'node:path';
import os from 'node:os';
import { createRequire } from 'node:module';

const argv = process.argv.slice(2);
const opt = (name, fallback) => { const i = argv.indexOf(`--${name}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback; };
const url0 = opt('url', '');
const maps = opt('maps', 'welcometomexicov6,dm-industrial-gamma,surf_xiv_v2a,welcometomexicov6').split(',').filter(Boolean);
const startSecs = +opt('secs', '240');
const perMap = +opt('per-map', '150');
const maxGrowth = +opt('max-growth-mb', '0');
const cmd = opt('cmd', 'solo_map');  // the game's local console command that changes the map (FC's; a solo console has no server `map`)
const loadedFmt = opt('loaded', 'map change map:{map} to playable');  // the game's line once a level is up; {map} is the id
const shot = opt('shot', path.join(os.tmpdir(), 'browser_solo_rotate.png'));
if (!url0 || maps.length < 2 || maps.some(m => !/^[A-Za-z0-9_.-]+$/.test(m))) {
  console.error('usage: --url <embed.html?solo=owner/repo> [--maps a,b,c,a] (at least two map ids)');
  process.exit(2);
}
const serve = opt('serve', '');  // a local web export (web/build) served as /godot/<build>/ with /content proxied to --content
const serveBuild = (new URL(url0).pathname.match(/\/(\d{8}-\d{4})\//) || [])[1] || '';
let srv = null, url1 = url0;
if (serve) {
  try { ({ srv, url: url1 } = await serveShell({ dir: serve, port: +opt('port', '8099'), buildId: serveBuild, upstream: opt('content', 'https://dotgames.org'), givenUrl: url0 })); }
  catch (e) { console.error(String(e.message)); process.exit(2); }
}
const u = new URL(url1); u.searchParams.delete('map');

const loadPlaywright = () => {
  const require = createRequire(import.meta.url);
  for (const t of [process.env.PLAYWRIGHT_CORE, 'playwright-core', path.join(os.homedir(), 'pw/node_modules/playwright-core')].filter(Boolean)) {
    try { return require(t); } catch { /* next */ }
  }
  console.error('playwright-core not found; set PLAYWRIGHT_CORE'); process.exit(2);
};
const { chromium } = loadPlaywright();
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'solo-rotate-profile-'));
const cdp = process.env.GPU_CDP_URL ? await chromium.connectOverCDP(process.env.GPU_CDP_URL) : null;
const ctx = cdp ? await cdp.newContext({ viewport: { width: 1280, height: 720 } }) : await chromium.launchPersistentContext(profile, {
  executablePath: process.env.CHROME || (fs.existsSync('/usr/bin/google-chrome') ? '/usr/bin/google-chrome' : undefined),
  headless: true, args: ['--use-angle=gl', '--enable-gpu', '--ignore-gpu-blocklist'], viewport: { width: 1280, height: 720 },
});
const page = ctx.pages()[0] || await ctx.newPage();
const t0 = Date.now();
const lines = [];
const log = s => { const l = `${((Date.now() - t0) / 1000).toFixed(1)} ${s}`; lines.push(l); console.log(l.slice(0, 400)); };
page.on('console', m => log(`[${m.type()}] ${m.text()}`));
page.on('pageerror', e => log(`[pageerror] ${e.message}`));
page.on('crash', () => log('[pageerror] the tab crashed (renderer out of memory)'));
const FATAL = /RangeError|out of memory|Aborted\(|\babort\(|memory access out of bounds|unreachable|Cannot enlarge memory|tab crashed|could not allocate|Parse Error|Failed to load script/i;
const fatal = () => lines.find(l => FATAL.test(l)) || '';

// Every WebAssembly.Memory the page makes (the engine's heap is the big one), in every frame, before any script runs.
await ctx.addInitScript(() => {
  const Orig = WebAssembly.Memory;
  window.__wasmMems = [];
  WebAssembly.Memory = function (d) { const m = new Orig(d); window.__wasmMems.push(m); return m; };
  WebAssembly.Memory.prototype = Orig.prototype;
  // A module that defines its own memory (or a build that hands it over as an import/export) never calls the constructor: take it from the instance too.
  const grab = (imports, inst) => {
    for (const ns of Object.values(imports || {})) if (ns && typeof ns === 'object') for (const v of Object.values(ns)) if (v instanceof Orig) window.__wasmMems.push(v);
    if (inst) for (const v of Object.values(inst.exports || {})) if (v instanceof Orig) window.__wasmMems.push(v);
  };
  const oi = WebAssembly.instantiate;
  WebAssembly.instantiate = async function (src, imports) { const r = await oi.call(WebAssembly, src, imports); grab(imports, r.instance || r); return r; };
  const ois = WebAssembly.instantiateStreaming;
  if (ois) WebAssembly.instantiateStreaming = async function (src, imports) { const r = await ois.call(WebAssembly, src, imports); grab(imports, r.instance); return r; };
});
const cdpSession = await ctx.newCDPSession(page).catch(() => null);
if (cdpSession) await cdpSession.send('Performance.enable').catch(() => {});
const heap = async () => {
  const wasm = await Promise.all(page.frames().map(f => f.evaluate(
    () => Math.max(0, ...(window.__wasmMems || []).map(m => m.buffer.byteLength))).catch(() => 0))).then(v => Math.max(0, ...v));
  let js = 0;
  if (cdpSession) {
    const r = await cdpSession.send('Performance.getMetrics').catch(() => null);
    js = r ? (r.metrics.find(x => x.name === 'JSHeapUsedSize') || { value: 0 }).value : 0;
  }
  const ua = await page.evaluate(async () => (window.crossOriginIsolated && performance.measureUserAgentSpecificMemory)
    ? (await performance.measureUserAgentSpecificMemory()).bytes : 0).catch(() => 0);
  return { wasm, js, ua };
};
const mb = n => (n / 1048576).toFixed(0);

const rows = [];
let failure = '';
const waitLoaded = async (from, secs, slug) => {
  const loadedRe = new RegExp(loadedFmt.replace('{map}', slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), 'i');
  const until = Date.now() + secs * 1000;
  while (Date.now() < until) {
    await page.waitForTimeout(1000);
    if (fatal()) return false;
    if (loadedRe.test(lines.slice(from).join('\n'))) return true;
  }
  return false;
};

await page.goto(u.toString());
for (let i = 0; i < maps.length && !failure; i++) {
  const from = lines.length;
  if (i === 0) {
    // The shell starts the game, then the game loads its first map and the match goes live; typing before that is swallowed by the cover.
    const until = Date.now() + startSecs * 1000;
    while (Date.now() < until && !/state from=COUNTDOWN .* to=LIVE|to=LIVE/.test(lines.join('\n')) && !fatal()) await page.waitForTimeout(1000);
  }
  {
    await page.mouse.click(640, 360).catch(() => {});
    await page.keyboard.press('Backquote');
    await page.waitForTimeout(500);
    await page.keyboard.type(`${cmd} ${maps[i]}`, { delay: 30 });
    await page.keyboard.press('Enter');
    await page.waitForTimeout(1500);
    await page.screenshot({ path: shot.replace(/\.png$/, `-${i + 1}.png`) }).catch(() => {});  // the console as typed, for a run that never loads
    await page.keyboard.press('Backquote');
    log(`[rotate] map ${maps[i]}`);
  }
  const secs = perMap;
  if (!await waitLoaded(from, secs, maps[i])) { failure = fatal() ? `fatal: ${fatal().slice(0, 200)}` : `map ${maps[i]} (#${i + 1}) not loaded within ${secs} s`; break; }
  await page.waitForTimeout(5000);
  if (fatal()) { failure = `fatal: ${fatal().slice(0, 200)}`; break; }
  const h = await heap();
  rows.push({ n: i + 1, map: maps[i], ...h });
  log(`[heap] #${i + 1} ${maps[i]}: wasm ${mb(h.wasm)} MB, js ${mb(h.js)} MB${h.ua ? `, ua ${mb(h.ua)} MB` : ''}`);
}
await page.screenshot({ path: shot }).catch(() => {});
await ctx.close();
if (cdp) await cdp.close();
fs.rmSync(profile, { recursive: true, force: true });

console.log('\n| # | map | wasm MB | js MB |\n| - | --- | --- | --- |');
for (const r of rows) console.log(`| ${r.n} | ${r.map} | ${mb(r.wasm)} | ${mb(r.js)} |`);
if (!failure && maxGrowth > 0 && rows.length > 1 && rows[0].wasm) {
  const g = (rows[rows.length - 1].wasm - rows[0].wasm) / 1048576;
  if (g > maxGrowth) failure = `wasm heap grew ${g.toFixed(0)} MB over the rotation (limit ${maxGrowth})`;
}
console.log(failure ? `\nrotate: FAIL ${failure}` : `\nrotate: ok (${rows.length} maps, screenshot ${shot})`);
if (srv) srv.close();
process.exit(failure ? 1 : 0);
