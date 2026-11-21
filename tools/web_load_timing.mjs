// Load timing of the exported client shell in a real browser: when each big file finishes downloading,
// when the first canvas is up, which WebGL renderer drew it, and what the page printed.
//
//   python3 -m http.server 8099 -d web/build &
//   dot-bootstrap/tools/gpu.sh cdp-run --serve 8099 -- node tools/web_load_timing.mjs [pageUrl] [--runs N]
//
// Run through gpu.sh cdp-run so Chrome has a real GPU (without GPU_CDP_URL it launches SwiftShader, which is
// software WebGL: the renderer line says so). The numbers are for before/after comparisons of an export change
// on one box: run the same build the same way twice and compare, and say which box. Exit 1 when the page errors,
// draws no canvas, or the renderer is software (SwiftShader / llvmpipe) while GPU_CDP_URL was set.
import fs from 'node:fs';

const tries = [process.env.PLAYWRIGHT_CORE, '/home/christian/stack/website-city/node_modules/playwright-core/index.js'].filter(Boolean);
const found = tries.find(t => fs.existsSync(t));
if (!found) { console.error(`playwright-core not found; set PLAYWRIGHT_CORE. Tried: ${tries.join(', ')}`); process.exit(2); }
const { chromium } = (await import(found)).default;

const args = process.argv.slice(2);
const runsAt = args.indexOf('--runs');
const runs = runsAt >= 0 ? Number(args[runsAt + 1]) : 1;
const url = args.find((a, i) => !a.startsWith('--') && args[i - 1] !== '--runs') ?? 'http://127.0.0.1:8099/embed.html';
const gpu = !!process.env.GPU_CDP_URL;

const cdp = gpu ? await chromium.connectOverCDP(process.env.GPU_CDP_URL) : null;
const browser = cdp ?? await chromium.launch({ headless: true, args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
let bad = 0;
const results = [];
for (let run = 0; run < runs; run++) {
  // A fresh context each run: an empty HTTP cache, so every run pays the whole download.
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 }, ignoreHTTPSErrors: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', e => errors.push(String(e.message)));
  await page.goto(url, { waitUntil: 'commit' });
  const first = await page.waitForFunction(() => {
    const c = document.querySelector('canvas');
    return c && c.width > 0 ? performance.now() : false;
  }, null, { timeout: 120000, polling: 100 }).then(h => h.jsonValue()).catch(() => -1);
  // Let it run a few seconds: a shader compile or a failed fetch shows up as an error line by then.
  await page.waitForTimeout(8000);
  const info = await page.evaluate(() => {
    const g = document.createElement('canvas').getContext('webgl2');
    const e = g && g.getExtension('WEBGL_debug_renderer_info');
    const res = performance.getEntriesByType('resource').filter(x => /\.(wasm|pck)$/.test(x.name))
      .map(x => ({ file: x.name.split('/').pop(), transfer: x.transferSize, decoded: x.decodedBodySize, ms: Math.round(x.responseEnd) }));
    return { renderer: e ? g.getParameter(e.UNMASKED_RENDERER_WEBGL) : 'no webgl2', res };
  });
  const soft = /swiftshader|llvmpipe|software/i.test(info.renderer);
  results.push({ canvas_ms: Math.round(first) });
  console.log(`run ${run + 1}: canvas ${Math.round(first)} ms  renderer "${info.renderer}"  errors ${errors.length}`);
  for (const f of info.res) console.log(`  ${f.file.padEnd(20)} done at ${String(f.ms).padStart(6)} ms  transfer ${f.transfer}  decoded ${f.decoded}`);
  for (const e of errors.slice(0, 5)) console.log(`  error: ${e.slice(0, 200)}`);
  if (first < 0 || errors.length || (gpu && soft)) bad = 1;
  await ctx.close();
}
const sorted = results.map(r => r.canvas_ms).sort((x, y) => x - y);
console.log(`median canvas ${sorted[Math.floor(sorted.length / 2)]} ms over ${runs} run(s); ${bad ? 'FAIL' : 'OK'}`);
if (!cdp) await browser.close();
process.exit(bad);
