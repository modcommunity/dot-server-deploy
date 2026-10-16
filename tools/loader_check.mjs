// The loader's "this client is older than the game" panel, in headless Chromium.
//
//   node tools/loader_check.mjs
//
// No exported shell needed: a stub game page on a second origin posts the exact message
// the shell posts (client/shell.gd `_report_client_behind`), which is the loader half of
// the contract. The shell half (that the refusal comes before any pack download) is
// dot-cloud's delivered_scene_demo; seeing the two joined in a real export needs the
// release that bumps addons.lock.
import http from 'node:http';
import fs from 'node:fs';
const pw = (await import(process.env.PLAYWRIGHT_CORE ?? '/home/christian/stack/website-city/node_modules/playwright-core/index.js')).default;
const { chromium } = pw;

const loader = fs.readFileSync(new URL('../web/tmc-loader.js', import.meta.url), 'utf8');
const SENTENCE = 'This game needs dot-audio API level 4 or newer; this client has level 1.';
const cors = { 'Access-Control-Allow-Origin': '*' };

function listen(handler) {
  return new Promise(res => {
    const s = http.createServer(handler);
    s.listen(0, '127.0.0.1', () => res([s, s.address().port]));
  });
}

const [game, gamePort] = await listen((req, r) => {
  r.writeHead(200, { ...cors, 'Content-Type': 'text/html' });
  r.end(`<!doctype html><script>
    parent.postMessage({type:'tmc.auth.ready'}, '*');
    setTimeout(function () { parent.postMessage(${JSON.stringify({
      type: 'tmc.build.mismatch', reason: 'client_behind', message: SENTENCE, early: true,
    })}, '*'); }, 300);
  </script>`);
});

let pagePort = 0;
function pageFor(withNewer) {
  const builds = withNewer
    ? [{ url: `http://127.0.0.1:${gamePort}/new/embed.html`, signon: 'x', label: 'new' }]
    : [];
  return `<!doctype html><div id="tmc-game-canvas" style="position:relative;width:800px;height:500px"></div>
<script>
window.__TMC_GAME__ = { version: 1, app: {name: 'T'}, server: null, options: {},
  game: { url: 'http://127.0.0.1:${gamePort}/old/embed.html', origin: 'http://127.0.0.1:${gamePort}',
          base: 'http://127.0.0.1:${gamePort}/old', build: 'old' },
  builds: ${JSON.stringify(builds)} };
</script><script src="/tmc-loader.js"></script>`;
}
const [page, port] = await listen((req, r) => {
  if (req.url === '/tmc-loader.js') {
    r.writeHead(200, { 'Content-Type': 'text/javascript' });
    return r.end(loader);
  }
  r.writeHead(200, { 'Content-Type': 'text/html' });
  r.end(pageFor(req.url.includes('newer')));
});
pagePort = port;

const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM ?? undefined });
let failed = 0;
function check(ok, what) {
  console.log((ok ? '  ok   ' : '  FAIL ') + what);
  if (!ok) failed++;
}

for (const newer of [false, true]) {
  const p = await browser.newPage();
  await p.goto(`http://127.0.0.1:${pagePort}/${newer ? 'newer' : 'plain'}`);
  await p.waitForFunction(() => document.body.innerText.includes('newer version of the client'), null, { timeout: 8000 })
    .catch(() => {});
  const text = await p.evaluate(() => document.body.innerText);
  check(text.includes('This game needs a newer version of the client.'), `${newer ? 'with' : 'without'} a newer build: says so plainly`);
  check(text.includes(SENTENCE), '  and quotes the addon sentence');
  check(text.includes('Nothing was downloaded.'), '  and that nothing was downloaded');
  const btn = await p.$('button:has-text("Reload for the new client")');
  check(newer ? btn !== null : btn === null, newer ? '  and offers the reload' : '  and offers no reload');
  await p.close();
}

await browser.close();
game.close(); page.close();
console.log(failed ? `${failed} failed` : 'loader check passed');
process.exit(failed ? 1 : 0);
