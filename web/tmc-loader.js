/*
 * The TMC web game loader for this server tool.
 *
 * website-city's in-browser player fetches this file, hands it a boot descriptor on
 * `window.__TMC_GAME__`, and expects the game to appear inside `#tmc-game-canvas`.
 * See `src/lib/game/loader.ts` and `src/app/_components/lib/game/player.tsx` there —
 * this file is the other half of that contract and nothing else here knows about it.
 *
 *   ./server stamp-loader --base https://host/path/
 *
 * writes it beside the engine with @ENGINE_BASE@ replaced.
 *
 * That stamp is now the FALLBACK. When website-city publishes a build itself it
 * sends `boot.game`, computed server-side from the deployment's game origin and the
 * app's published build id, and that wins — because the site gives every build its
 * own immutable prefix, so a baked base names last week's build after the next
 * publish. The stamp still covers the standalone deployment, where nginx serves the
 * engine from a fixed path and there is no site to ask.
 *
 * What is NOT a source, in either mode, is the app's play options: they are
 * player-facing, and the frame's origin must not be. See the note on ENGINE_BASE
 * below.
 *
 * ----------------------------------------------------------------- The iframe
 *
 * [b]The game runs in an iframe, and that is not laziness — it is the only way this
 * works.[/b] Godot's web runtime is a SINGLETON PER DOCUMENT: a second
 * `new Engine(...)` in the same page refuses with "The engine must be initialized
 * before it can be started", and there is no supported way to unmake the first one.
 *
 * A single-page app tears a component down and builds it again all the time — React
 * Strict Mode does it on every mount in development, and a player closing the modal
 * and opening it on another server does it in production. Loading the engine directly
 * into the host document means the first open works and every one after it shows that
 * error. Getting there took four separate fixes, each of which made the symptom
 * different and none of which made it go away:
 *
 *   - `executable` must carry the base URL, because the engine resolves what it
 *     fetches against the DOCUMENT, which here is the site's own page;
 *   - removing a <script> unloads nothing, and appending a second one for the same
 *     source evaluates it again — which index.js cannot survive;
 *   - a `typeof Engine` guard reads "not loaded" for a script that has finished
 *     loading, because that binding is not visible from here;
 *   - and deferring construction past the teardown fixes the double-build but not the
 *     singleton, because the runtime is poisoned either way.
 *
 * An iframe gets a fresh document per open, so the engine is created once in a place
 * where "once" is true, and removing the element genuinely destroys it — the socket
 * closes, the audio stops, the memory goes back. The page inside is `embed.html`,
 * which is the same page the standalone deployment serves and takes the server from
 * its query string.
 */
(function () {
  'use strict';

  var ENGINE_BASE = '@ENGINE_BASE@';
  var MOUNT_ID = 'tmc-game-canvas';

  var boot = window.__TMC_GAME__ || {};
  var mount = document.getElementById(MOUNT_ID);

  if (!mount) {
    console.error('[TMC] no #' + MOUNT_ID + ' to mount into');
    return;
  }

  // Whatever a previous mount left behind. Cheap and total: there is no state to
  // preserve, because the state lives inside the iframe's own document.
  if (window.__TMC_GAME_API__ && window.__TMC_GAME_API__.destroy) {
    try {
      window.__TMC_GAME_API__.destroy();
    } catch (e) {
      console.warn('[TMC] tearing down the previous instance threw', e);
    }
  }

  function fail(message, detail) {
    mount.innerHTML = '';
    var box = document.createElement('div');
    box.style.cssText =
      'display:flex;flex-direction:column;gap:8px;align-items:center;' +
      'justify-content:center;height:100%;color:#e8eaee;text-align:center;' +
      'font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;padding:24px';
    var head = document.createElement('div');
    head.textContent = message;
    box.appendChild(head);
    if (detail) {
      var small = document.createElement('div');
      small.style.cssText = 'color:#8b919b;font-size:13px;max-width:44ch';
      small.textContent = detail;
      box.appendChild(small);
    }
    mount.appendChild(box);
    console.error('[TMC] ' + message, detail || '');
  }

  /*
   * Where to connect.
   *
   * `boot.server` is null when the player was opened for an APP rather than for a
   * server — the play centre's "launch this game" button — and there is nothing to
   * dial. The shell then shows its own address box, which is better than the loader
   * inventing a server: a link to your game becoming a link to somebody else's is how
   * that goes wrong.
   *
   * A server whose owner hid its address arrives with host and port nulled by
   * BuildGameBootDescriptor. That is deliberate on the site's side and the right
   * ceiling: the loader is no more capable than a visitor reading the page.
   */
  function serverAddress(frameProtocol) {
    var s = boot.server;
    if (!s) return '';

    var host = s.host || s.hostName || s.ip4 || '';
    var port = s.port;
    if (!host || !port) return '';

    /*
     * A page served over HTTPS may not open an insecure WebSocket: browsers block
     * it as mixed content and report a generic connection failure with no mention
     * of why. So the scheme comes from the page rather than from the server's own
     * configuration, which is what lets one upload serve a development site and a
     * real one.
     *
     * [b]But not from THIS page.[/b] This file runs in the site's document; the
     * socket is opened by the engine inside the IFRAME, whose document is the
     * engine origin. Mixed content is judged against the document doing the
     * connecting, so `location.protocol` here is the wrong page — it was right
     * only while the two were the same, which stopped being true the moment the
     * game moved to an origin of its own.
     *
     * It reads as a server-side fault from every angle: the site is fine, the
     * server is fine, and the game reports that it cannot reach a server that is
     * up. Seen for real on an http:// development site whose engine base is
     * https://, which is now the ordinary shape rather than a corner.
     */
    var scheme = frameProtocol === 'https:' ? 'wss' : 'ws';

    // IPv6 literals need brackets, or the port reads as part of the address and the
    // failure looks like a typo.
    if (host.indexOf(':') >= 0 && host.charAt(0) !== '[') host = '[' + host + ']';

    return scheme + '://' + host + ':' + port;
  }

  /*
   * Where the engine is served from.
   *
   * Two sources, in this order: `boot.game` if the site published one, otherwise the
   * `@ENGINE_BASE@` stamped in by `./server stamp-loader --base <url>`.
   *
   * NOT `boot.options.engine_base`, which is what this used to read. Play options are
   * the platform's mechanism for repointing something without regenerating a file —
   * but they repoint something a PLAYER chooses: every option is a field in the launch
   * dialog, and its value arrives here validated for shape and nothing else. Feeding
   * that to an iframe's src makes the origin of framed, script-executing content a
   * launch parameter, so a crafted launch link puts an arbitrary site inside a frame
   * on our own page — a convincing place to draw a login box. The site cannot bound it
   * either: `PlayOptionSchema` has no operator-only kind, so any channel it offers is a
   * channel the player also has.
   *
   * `boot.game` is a different thing wearing a similar shape, and the difference is
   * who can write it. The site COMPUTES it server-side from `NEXT_PUBLIC_GAME_ORIGIN`
   * and the app's published `webGameBuild` — deployment configuration and an
   * admin-queued publish. Nothing a player supplies reaches it, and no launch
   * parameter perturbs it. See `GameBuildLocation` in website-city's
   * `src/lib/game/loader.ts`.
   *
   * It has to be preferred over the stamp rather than merely allowed, because the
   * site publishes every build to its own immutable prefix
   * (`game/<app>/<build id>/`) so a CDN can cache it forever and a deploy can swap
   * atomically. A baked base names one of those prefixes, so it goes stale on the
   * next publish — pointing at the PREVIOUS build, with nothing anywhere saying so.
   *
   * The stamp stays as the fallback for the standalone deployment, where nginx
   * serves the engine from a fixed path and there is no site to ask.
   *
   * WHICHEVER WINS IS CHECKED THE SAME WAY BELOW. The origin test is what actually
   * holds the sandbox up, and it does not care where the URL came from.
   */
  var gameLoc = boot.game && typeof boot.game === 'object' ? boot.game : null;
  var publishedUrl =
    gameLoc && typeof gameLoc.url === 'string' && gameLoc.url ? gameLoc.url : '';

  var base = String(ENGINE_BASE || '');
  if (base && base.charAt(base.length - 1) !== '/') base += '/';

  var stampMissing = !base || base.indexOf('@ENGINE_BASE') === 0;

  if (!publishedUrl && stampMissing) {
    fail(
      'This game has no engine location configured.',
      'Publish a web game build for this app, or re-run ./server stamp-loader ' +
        '--base <url> and upload the loader it writes.'
    );
    return;
  }

  /*
   * The URL the frame will actually load. `boot.game.url` already names the entry
   * document the publish recorded (`embed.html` or `index.html` — Godot names the
   * HTML export after the preset, so the site stores which one it found rather than
   * requiring a name we invented).
   */
  var entryUrl = publishedUrl || base + 'embed.html';

  /*
   * And the invariant the sandbox attribute below depends on, CHECKED rather than
   * described. Everything under that comment is true only while the frame is
   * cross-origin, and the one way it stops being true — someone moves the engine to
   * a path on the site's own domain because it is one fewer DNS record — is a change
   * made far from here by someone who never read this file. It leaves every test
   * passing and the game visibly working, which is the whole problem: a boundary
   * that has silently become a no-op looks exactly like one that is holding.
   *
   * `new URL(entryUrl, location.href)` resolves a RELATIVE location against the page
   * too, so a stamp of "/game/" is caught by the same check rather than sailing
   * through as something that merely has no host of its own. That matters more now
   * that the location can also arrive from the site: a deployment that left
   * NEXT_PUBLIC_GAME_ORIGIN blank would otherwise produce a same-origin path here and
   * silently dissolve the boundary.
   */
  var entry;
  try {
    entry = new URL(entryUrl, window.location.href);
  } catch (e) {
    fail('This game has an unusable engine location.', String(entryUrl));
    return;
  }

  if (entry.origin === window.location.origin) {
    fail(
      'This game is not configured safely and was not started.',
      'The engine is on the same origin as the site, which turns the frame sandbox ' +
        'into a no-op. Serve it from its own domain' +
        (publishedUrl
          ? ' — check NEXT_PUBLIC_GAME_ORIGIN is a separate domain from the site.'
          : ' and re-stamp the loader.')
    );
    return;
  }

  /*
   * Cross-check the origin the site TOLD us against the one its URL actually has.
   *
   * `boot.game.origin` is what a loader is expected to target `postMessage` at, and
   * a mismatch between it and `boot.game.url` means one of the two is wrong. Which
   * one hardly matters: sending a single-use credential to an origin that does not
   * own the frame is the failure this whole contract exists to avoid, so it refuses
   * rather than picking a winner.
   */
  if (
    publishedUrl &&
    typeof gameLoc.origin === 'string' &&
    gameLoc.origin &&
    gameLoc.origin !== entry.origin
  ) {
    fail(
      'This game is not configured safely and was not started.',
      'The published game origin and build URL disagree.'
    );
    return;
  }

  var address = serverAddress(entry.protocol);
  var src = entry.href;
  if (address)
    src += (entry.search ? '&' : '?') + 'server=' + encodeURIComponent(address);

  var frame = document.createElement('iframe');
  frame.src = src;
  frame.title = boot.app && boot.app.name ? boot.app.name : 'Game';
  frame.style.cssText = 'display:block;width:100%;height:100%;border:0';
  /*
   * [b]THE GAME MUST BE ON A DIFFERENT ORIGIN FROM THE SITE, and this attribute is
   * why it is not merely tidy.[/b]
   *
   * `allow-scripts` together with `allow-same-origin` is the documented sandbox
   * escape — but only when the framed document is SAME-ORIGIN with the parent, in
   * which case the frame can reach into the parent and remove its own sandbox
   * attribute. Cross-origin the pair is both safe and necessary: the export fetches
   * its own .wasm and .pck relative to itself and keeps `user://` in IndexedDB, and
   * an opaque origin can do neither.
   *
   * So serving the engine from a path on the site's own domain — which looks like a
   * simplification and removes a DNS record — silently converts this from a boundary
   * into nothing. A path is not an origin. Scheme, host and port are.
   *
   * What the boundary is actually holding back: a delivered game pack can contain
   * scripts (dot-cloud signs manifests precisely because it can), and script running
   * in the site's origin can read every non-HttpOnly cookie and every localStorage
   * key, call the site's API with the viewer's session AND read the responses, read
   * the DOM of a signed-in page, and register a service worker scoped to that origin
   * — which outlives the tab and intercepts later requests.
   *
   * A separate registrable domain is stronger again than a subdomain, because a
   * subdomain can SET a `Domain=.example.net` cookie the parent will then receive.
   * That is why Google, GitHub and Dropbox serve user content from
   * googleusercontent.com, githubusercontent.com and dropboxusercontent.com rather
   * than from a subdomain of the site.
   */
  frame.setAttribute(
    'sandbox',
    'allow-scripts allow-same-origin allow-pointer-lock allow-downloads'
  );
  frame.setAttribute('allow', 'autoplay; gamepad; fullscreen; cross-origin-isolated');
  frame.setAttribute('allowfullscreen', 'true');

  frame.onerror = function () {
    fail('The game could not be loaded.', src);
  };

  /*
   * THE IDENTITY HANDOFF.
   *
   * `boot.auth` says who is playing and, for a member on a game that uses TMC
   * for identity, carries a single-use code the game exchanges for its own
   * session (see the site's `docs/api/web-game-loader.md`). Without this the
   * game meets somebody already signed into the site and asks them to sign in
   * again, inside the canvas.
   *
   * [b]Posted, not put in the URL.[/b] The frame is cross-origin by design, so
   * the only ways in are the URL and a message. A URL is the wrong one: this is
   * a credential, and a query string reaches history, the referrer of every
   * request the game makes, and any log that records frame sources. The code
   * lives sixty seconds, which shortens that exposure without making it
   * acceptable.
   *
   * Sent on frame load AND in reply to the frame's own ready ping, because
   * whichever of the two runs second is the one that lands: the engine's WASM
   * takes seconds and the load event does not wait for it, while a frame that
   * was already interactive never fires load again.
   *
   * Targeted at `baseOrigin` and never at `'*'` -- a wildcard target hands the
   * message to whatever document happens to occupy the frame, including one
   * that got there by a redirect we did not intend.
   */
  var auth = boot.auth || null;

  function sendAuth() {
    if (!auth || !frame.contentWindow) return;

    try {
      frame.contentWindow.postMessage(
        { type: 'tmc.auth', auth: auth },
        baseOrigin
      );
    } catch (e) {
      /* A frame that is gone or not yet navigated. The ping covers it. */
    }
  }

  frame.addEventListener('load', sendAuth);

  window.addEventListener('message', function (event) {
    if (event.origin !== baseOrigin) return;
    if (event.source !== frame.contentWindow) return;
    if (!event.data || event.data.type !== 'tmc.auth.ready') return;

    sendAuth();
  });

  mount.innerHTML = '';
  mount.appendChild(frame);

  /*
   * The hooks the player calls.
   *
   * `destroy` is the one that matters, and with an iframe it is honest: removing the
   * element ends the document, which closes the socket, stops the audio and frees the
   * WASM heap. Loading the engine into the host page could not offer that at any
   * price.
   */
  window.__TMC_GAME_API__ = {
    resize: function () {
      /* the iframe follows its container; nothing to do */
    },
    setVolume: function (volume) {
      // Best effort: same-origin, so the frame's own API is reachable when the export
      // exposes one. A game that does not is not an error.
      try {
        var api = frame.contentWindow && frame.contentWindow.__TMC_EMBED__;
        if (api && api.setVolume) api.setVolume(volume);
      } catch (e) {
        /* cross-origin, or not there */
      }
    },
    pause: function () {},
    resume: function () {},
    destroy: function () {
      if (frame && frame.parentNode) frame.parentNode.removeChild(frame);
      if (mount) mount.innerHTML = '';
    },
  };
})();
