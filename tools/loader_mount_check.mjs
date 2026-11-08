// The loader's mount lookup, in headless Chromium: it must wait briefly for
// #tmc-game-canvas (the site appends the script from an effect that can run before the
// portal div is committed) and say so clearly if it never appears.
//
//   node tools/loader_mount_check.mjs
//
// CHROMIUM / PLAYWRIGHT_CORE as for tools/loader_check.mjs.
import http from 'node:http';
import fs from 'node:fs';
const pw = (await import(process.env.PLAYWRIGHT_CORE ?? '/home/core/projects/website-city/node_modules/playwright-core/index.js')).default;
const { chromium } = pw;

const loader = fs.readFileSync(new URL('../web/tmc-loader.js', import.meta.url), 'utf8');

function listen(handler) {
  return new Promise(res => {
    const s = http.createServer(handler);
    s.listen(0, '127.0.0.1', () => res([s, s.address().port]));
  });
}

// `mountAfter`: ms until the div is inserted (null = never).
function pageFor(mountAfter) {
  return `<!doctype html><body>
<script>
window.__TMC_GAME__ = { version: 1, app: {name: 'T'}, server: null, options: {},
  game: { url: 'about:blank', origin: 'null', base: 'about:blank', build: 'x' }, builds: [] };
${mountAfter === null ? '' : `setTimeout(function () {
  var d = document.createElement('div'); d.id = 'tmc-game-canvas';
  d.style.cssText = 'position:relative;width:400px;height:300px';
  document.body.appendChild(d);
}, ${mountAfter});`}
</script><script src="/tmc-loader.js"></script></body>`;
}

const [page, port] = await listen((req, r) => {
  if (req.url === '/tmc-loader.js') {
    r.writeHead(200, { 'Content-Type': 'text/javascript' });
    return r.end(loader);
  }
  const m = /^\/after(\d+)/.exec(req.url);
  r.writeHead(200, { 'Content-Type': 'text/html' });
  r.end(pageFor(m ? Number(m[1]) : null));
});

const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM ?? '/usr/bin/chromium' });
let failed = 0;
function check(ok, what) {
  console.log((ok ? '  ok   ' : '  FAIL ') + what);
  if (!ok) failed++;
}

async function open(path) {
  const p = await browser.newPage();
  const errors = [];
  p.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  await p.goto(`http://127.0.0.1:${port}${path}`);
  return [p, errors];
}

// Mount already there at evaluation is covered by tools/loader_check.mjs.
{
  const [p, errors] = await open('/after600');
  await p.waitForSelector('#tmc-game-canvas iframe', { timeout: 5000 }).catch(() => {});
  check((await p.$('#tmc-game-canvas iframe')) !== null, 'mount inserted 600 ms late: the frame still mounts');
  check(!errors.some(e => e.includes('no #tmc-game-canvas')), '  and no "no mount" error was logged');
  await p.close();
}
{
  const [p, errors] = await open('/never');
  await p.waitForTimeout(4000);
  check(errors.some(e => e.includes('no #tmc-game-canvas to mount into')), 'mount never inserted: the clear error is logged after the wait');
  await p.close();
}
{
  const [p, errors] = await open('/never');
  await p.waitForTimeout(1000);
  check(!errors.some(e => e.includes('no #tmc-game-canvas')), 'mount never inserted: no error yet at 1 s (it is still waiting)');
  await p.close();
}

await browser.close();
page.close();
console.log(failed ? `${failed} failed` : 'loader mount check passed');
process.exit(failed ? 1 : 0);
