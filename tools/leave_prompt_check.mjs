// The "Leave site?" prompt through the real loader, in headless Chromium.
//
//   node tools/leave_prompt_check.mjs
//
// The page guard dot-game's DotGameClient installs is lifted from its source and run in a stub
// game on a second origin, inside the frame tmc-loader.js builds. Closing the tab (with
// beforeunload run, as Ctrl+W does) must raise the dialog once the guard is armed and the
// player has clicked in the frame, must not before, and must not when the loader's frame
// sandbox lacks allow-modals (the control: that is how the prompt went missing on the site).
import http from 'node:http';
import fs from 'node:fs';
const pw = (await import(process.env.PLAYWRIGHT_CORE ?? '/home/christian/stack/website-city/node_modules/playwright-core/index.js')).default;
const { chromium } = pw;

const loader = fs.readFileSync(new URL('../web/tmc-loader.js', import.meta.url), 'utf8');
const clientGd = process.env.DOT_GAME_CLIENT
  ?? new URL('../../dot-game/addons/dot_game/runtime/dot_game_client.gd', import.meta.url);
const m = /const _GUARD_JS := """([\s\S]*?)"""/.exec(fs.readFileSync(clientGd, 'utf8'));
if (!m) { console.log('FAIL could not find _GUARD_JS in ' + clientGd); process.exit(1); }
const guardJs = m[1].replace(/\\\\/g, '\\');

function listen(handler) {
  return new Promise(res => {
    const s = http.createServer(handler);
    s.listen(0, '127.0.0.1', () => res([s, s.address().port]));
  });
}
const [game, gamePort] = await listen((req, r) => {
  r.writeHead(200, { 'Content-Type': 'text/html' });
  r.end(`<!doctype html><body style="margin:0"><button id=b style="width:100%;height:100%">play</button>
<script>parent.postMessage({type:'tmc.auth.ready'}, '*');
${guardJs}
document.getElementById('b').onclick = function () { window.__dotTabGuard.armed = true; };</script>`);
});
const pageHtml = `<!doctype html><div id="tmc-game-canvas" style="position:relative;width:800px;height:500px"></div>
<script>
window.__TMC_GAME__ = { version: 1, app: {name: 'T'}, server: null, options: {},
  game: { url: 'http://127.0.0.1:${gamePort}/embed.html', origin: 'http://127.0.0.1:${gamePort}',
          base: 'http://127.0.0.1:${gamePort}', build: 'b' }, builds: [] };
</script><script src="/tmc-loader.js"></script>`;
const [page, port] = await listen((req, r) => {
  if (req.url === '/tmc-loader.js') {
    r.writeHead(200, { 'Content-Type': 'text/javascript' });
    return r.end(req.headers.referer?.includes('nomodals') ? loader.replace(/ allow-modals/g, '') : loader);
  }
  r.writeHead(200, { 'Content-Type': 'text/html' });
  r.end(pageHtml);
});

const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM ?? undefined });
let failed = 0;
function check(ok, what) {
  console.log((ok ? '  ok   ' : '  FAIL ') + what);
  if (!ok) failed++;
}

async function closes(variant, click, arm) {
  const ctx = await browser.newContext();
  const p = await ctx.newPage();
  let dialogs = 0;
  p.on('dialog', d => { dialogs++; d.dismiss().catch(() => {}); });
  await p.goto(`http://127.0.0.1:${port}/${variant}`);
  const f = await p.waitForSelector('iframe').then(h => h.contentFrame());
  await f.waitForSelector('#b');
  if (click) await f.click('#b');
  if (!arm) await f.evaluate(() => { window.__dotTabGuard.armed = false; });
  await p.close({ runBeforeUnload: true });
  await ctx.close();
  return dialogs;
}

check(await closes('modals', true, true) === 1, 'armed, clicked, allow-modals: the Leave site? dialog is raised');
check(await closes('modals', true, false) === 0, 'disarmed (main menu): no dialog');
check(await closes('modals', false, true) === 0, 'armed but never clicked: Chromium suppresses it (needs a gesture in the frame)');
check(await closes('nomodals', true, true) === 0, 'control, frame without allow-modals: no dialog (the site bug)');
await browser.close();
game.close(); page.close();
console.log(failed ? `${failed} failed` : 'leave prompt check passed');
process.exit(failed ? 1 : 0);
