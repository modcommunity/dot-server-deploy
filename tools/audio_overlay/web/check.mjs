// Page driver of tools/audio_overlay_web_proof.sh: load the exported proof page in headless Chromium, wait for the overlay build,
// the reload and the CHECK line, and assert the AudioContext ran through dot_audio_ceiling.js's limiter with signal on it.
//   node check.mjs URL
import pw from '/home/christian/.cache/pwcore/node_modules/playwright-core/index.js';
const url = process.argv[2];
const browser = await pw.chromium.launch({ headless: true, executablePath: '/usr/bin/chromium',
  args: ['--autoplay-policy=no-user-gesture-required', '--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
const page = await browser.newPage();
const logs = [];
page.on('console', m => logs.push(m.text()));
page.on('pageerror', e => logs.push('PAGEERROR ' + e.message));
// Runs before every document script, so before dot_audio_ceiling.js: records each context and taps the limiter's output.
await page.addInitScript(() => {
  const Base = window.AudioContext;
  window.__ao = { ctxs: [], peak: 0, taps: [] };
  function Rec(o) {
    const c = o === undefined ? new Base() : new Base(o);
    window.__ao.ctxs.push(c);
    return c;
  }
  Rec.prototype = Base.prototype;
  window.AudioContext = Rec;
  setInterval(() => {
    for (const c of window.__ao.ctxs) {
      if (c.__tap) continue;
      const d = c.destination;
      if (!(d instanceof DynamicsCompressorNode)) continue;
      const an = c.createAnalyser(); an.fftSize = 2048;
      d.connect(an); c.__tap = an;
    }
    for (const c of window.__ao.ctxs) if (c.__tap) {
      const b = new Float32Array(2048); c.__tap.getFloatTimeDomainData(b);
      for (const v of b) window.__ao.peak = Math.max(window.__ao.peak, Math.abs(v));
    }
  }, 20);
});
await page.goto(url);
const deadline = Date.now() + 240000;
while (Date.now() < deadline && !logs.some(l => l.startsWith('CHECK '))) await new Promise(r => setTimeout(r, 500));
const state = await page.evaluate(() => ({
  ceiling: window.AudioContext.dotCeiling === true || !!window.dotAudioCeiling,
  ctxs: window.__ao.ctxs.map(c => ({ state: c.state, time: c.currentTime, limiter: c.destination instanceof DynamicsCompressorNode })),
  peak: window.__ao.peak,
}));
await browser.close();
for (const l of logs) if (/^(AO |CHECK |PAGEERROR|\[dot_cloud)/.test(l) || /error/i.test(l)) console.log('LOG', l);
console.log('STATE', JSON.stringify(state));
const check = logs.find(l => l.startsWith('CHECK '));
const info = check ? JSON.parse(check.slice(6)) : {};
const fails = [];
const need = (ok, what) => { if (!ok) fails.push(what); };
need(logs.some(l => l.includes('AO BUILD ok=true')), 'overlay built in the browser');
need(logs.some(l => l.includes('AO first load')), 'first load was without stream_at');
need(info.has_stream_at === true && info['footstep_carpet_0.ogg'] === true && info['amb_indoor.ogg'] === true, 'stock streams loaded through the overlay');
need(info.overlay && info.overlay !== '', 'overlay mounted');
need(state.ceiling, 'dot_audio_ceiling.js installed');
need(state.ctxs.some(c => c.state === 'running' && c.time > 0.5 && c.limiter), 'AudioContext running behind the limiter');
need(state.peak > 0.001, 'signal reached the limiter output (peak ' + state.peak + ')');
console.log(fails.length ? 'FAIL ' + fails.join('; ') : 'PASS');
process.exit(fails.length ? 1 : 0);
