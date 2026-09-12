// Loads the exported client shell in a real browser, connects it to a real server,
// and reports what happened.
//
//   node tools/browser_check.mjs [pageUrl] [outPng]
//
// This is the only check in the repository that exercises the browser target, which is
// the claim the whole "click a link and play" story rests on and the one thing a
// headless Godot run cannot see: the WASM loading, the WebSocket handshake a browser
// performs, and whether anything is actually drawn.
// playwright-core is CommonJS, so it comes in through the default export. Importing
// { chromium } directly is a SyntaxError under Node's ESM loader.
import pw from '/home/christian/stack/website-city/node_modules/playwright-core/index.js';
const { chromium } = pw;

const args = process.argv.slice(2);
const positional = args.filter(a => !a.startsWith('--'));

const url = positional[0] ?? 'http://127.0.0.1:8099/embed.html?server=ws://127.0.0.1:6064';
const out = positional[1] ?? '/tmp/shot.png';

// Optionally change the game while the browser is connected, over RCON — which is how
// an admin actually does it, and the only way to see whether a client that is already
// playing follows. A shell that only ever built its scene once looks perfectly correct
// until somebody switches.
const switchTo = args.includes('--switch')
  ? args[args.indexOf('--switch') + 1]
  : '';

const browser = await chromium.launch({ headless: true, args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
// ignoreHTTPSErrors, because a development host serves a self-signed certificate and
// a browser that refuses it never reaches the page at all — which looks exactly like
// the page being broken.
const page = await browser.newPage({
  viewport: { width: 1280, height: 720 },
  ignoreHTTPSErrors: true,
});

const console_lines = [];
const failures = [];
const sockets = [];

page.on('console', m => console_lines.push(`${m.type()}: ${m.text()}`));
page.on('pageerror', e => failures.push(`pageerror: ${e.message}`));
page.on('requestfailed', r => failures.push(`requestfailed: ${r.url()} ${r.failure()?.errorText}`));
// The socket the page was TOLD to open, out of the query string. Anything else the
// client opens on its own is reported separately below rather than as a failure.
const wanted = (() => {
  try { return new URL(url).searchParams.get('server') ?? ''; } catch { return ''; }
})();

const otherSockets = [];

page.on('websocket', ws => {
  sockets.push(ws.url());

  // A server BROWSER queries servers that may be down, and a refused query is the
  // correct outcome of asking — game-playground seeds `127.0.0.1:27015` on a first run
  // because that is where a launcher puts a server, and nothing is listening there on a
  // developer's machine. Counting that as a failure made this check cry wolf, and a
  // check that always reports one failure is a check whose failures stop being read.
  //
  // Matched on host and port rather than on the whole string: the browser normalises
  // `ws://host:port` to `ws://host:port/`.
  const same = wanted !== '' && (() => {
    try {
      const a = new URL(wanted), b = new URL(ws.url());
      return a.host === b.host;
    } catch { return false; }
  })();

  ws.on('socketerror', e => {
    if (same || wanted === '') failures.push(`websocket error: ${ws.url()} ${e}`);
    else otherSockets.push(`${ws.url()} ${e}`);
  });
});

await page.goto(url, { waitUntil: 'load', timeout: 60000 });

// The engine downloads and instantiates several megabytes of WASM before it draws
// anything. Waited on by its own signal rather than by a fixed sleep: how long that
// takes depends on the machine, and a fixed wait is a check that passes on an idle box.
try {
  await page.waitForFunction(
    () => document.getElementById('status')?.classList.contains('hidden'),
    { timeout: 90000 }
  );
} catch {
  failures.push('the loading overlay never went away');
}

// Then time for the shell to open its socket, be taken through signon, and draw a game.
await page.waitForTimeout(12000);

await page.screenshot({ path: out });

let switched = null;

if (switchTo) {
  const { execFileSync } = await import('node:child_process');
  const before = console_lines.length;

  execFileSync('node', [new URL('rcon.mjs', import.meta.url).pathname,
                        `changelevel ${switchTo}`], { stdio: 'pipe' });

  // A change frees the server's scene, tells every client to load again, and puts them
  // back through LOADING. Waited on by the client's own log line rather than by a fixed
  // sleep, with the sleep as the ceiling.
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline
         && !console_lines.slice(before).some(l => l.includes('game loaded')
                                                || l.includes('room ready')
                                                || l.includes('hungry'))) {
    await page.waitForTimeout(500);
  }

  await page.waitForTimeout(8000);
  const second = out.replace(/(\.png)?$/, '') + '.after.png';
  await page.screenshot({ path: second });
  switched = { to: switchTo, screenshot: second };
}

console.log(JSON.stringify({
  connectedTo: wanted,
  websockets: sockets,
  // Sockets the client opened on its own that failed — a server browser querying a
  // server that is down belongs here, not in `failures`.
  otherSocketErrors: otherSockets,
  switched,
  failures,
  console: console_lines,
}, null, 2));

await browser.close();
process.exit(failures.length > 0 ? 1 : 0);
