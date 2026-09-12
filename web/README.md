# Playing it in a browser

The whole reason the client shell exists: **a link is the lowest-friction way to get somebody into a game**, and everything in the dot-* family that is awkward is awkward because of the browser.

```bash
./server export-web           # writes web/build/
cp web/embed.html web/build/  # the page that takes ?server= from the URL
```

Then serve `web/build/` and open

```
index.html?server=ws://your-host:6064
```

`embed.html` replaces Godot's generated `index.html`: it is smaller, it handles the device-pixel-ratio and touch-action problems, and it takes the server from the query string so **one export serves every server**.

## What the browser costs you

Every one of these is encoded somewhere in dot-core already; they are collected here because they are what a deployment has to answer for.

| Constraint | What it means here |
| --- | --- |
| **No UDP.** `ENetMultiplayerPeer` is not in the web template at all | The server listens on **WebSocket**, and then *all* its clients do — `DotTransportAuto.require_web_clients` defaults to true for this reason |
| **A tab cannot listen** | The web build is a client. The server is somewhere else, always, and the shell offers no Host button rather than one that fails |
| **No threads** unless the template was built for them | `DotScheduler` slices on the main thread inside a frame budget. The preset has thread support **off**: turning it on requires cross-origin isolation on every response and breaks every third-party embed on the page |
| **`user://` is an IndexedDB mirror** needing explicit flushes | Every write path calls `DotWeb.sync_filesystem()` |
| **Storage quota the user can refuse** | The lobby caches nothing. A downloaded game pack does, and `DotCloudStore` awaits `navigator.storage.estimate()` rather than assuming |
| **CORS, with `fetch()` refusing to say why it failed** | Serve the export and its assets from one origin, or set the headers below exactly |
| **An HTTPS page may not open a `ws://` socket** | `embed.html` checks for it and says so, because the browser's own error does not mention mixed content |
| **A mounted resource pack can never be unmounted** | dot-cloud namespaces content by `id/version`, so nothing ever needs replacing |

## The one that shapes what a delivered game may look like

**A mounted pack's `class_name` globals are not registered in the host.** Measured, not assumed. Every cross-file type reference inside a pack fails to compile: the pack mounts, its scenes load, and every script in it is dead — with no error until something tries to run.

```
class_name reference from a mounted pack    FAILS
preload("res://path.gd")                    works
extends "res://path.gd"                     works
```

So a game meant to be **delivered** references its own files by path. A game compiled into the shell has no such restriction, which is why the lobby is one.

## Headers

Serve everything from one origin if you possibly can — then none of this matters. If you cannot:

```
Access-Control-Allow-Origin: https://your-page-origin
Cross-Origin-Resource-Policy: cross-origin
Content-Type: application/wasm          # for index.wasm, or the browser refuses to stream it
Content-Encoding: gzip                  # if you pre-compress; the .pck is the big one
```

**The preset needs `include_filter="maps/*.bin"`.** `export_presets.cfg` is not in this repository — it is a local file, so a machine that has never opened this project in the editor does not have one — and the Web preset exports `all_resources`, which means every file the engine has a *loader* for. Godot 4 loads `.json`, so an imported map's manifest ships; nothing loads `.bin`, so the vertices do not, and a browser client then builds that map's spawn point, zone set, start line and pit over no geometry at all: it connects, signs on, spawns and draws sky. `include_filter` is the only thing that carries a non-resource. `./server export-web` greps the built pack for every `maps/**/*.bin` on disk and refuses to finish if one is missing, so this is a message rather than a silent hole — but a preset written from scratch wants the line.

With **Extensions Support on**, and only then, every response also needs `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`. Missing either one is a blank page, not a warning. The preset here has it off.

## TLS

A page on HTTPS cannot open `ws://`. Browsers report that as a generic connection failure with no mention of mixed content, which is why `embed.html` checks for it and says so itself.

Put a TLS terminator in front of the server and give the page `?server=wss://your-host:6064`. Nothing in this repository terminates TLS: certificates, a reverse proxy and a domain are deployment, not code.

## Where the game is served from, and why it is not the site's domain

The engine and everything it loads run on a **different origin** from the website, in a cross-origin `<iframe>`. That is a security boundary, not a deployment convenience, and it is worth knowing what it is holding back before somebody simplifies it away.

A delivered game pack can contain scripts — dot-cloud signs manifests precisely because it can. Script running in the **site's** origin can read every non-`HttpOnly` cookie and every `localStorage` key, call the site's API with the viewer's session *and read the responses*, read the DOM of a signed-in page, and register a service worker scoped to that origin, which outlives the tab and intercepts later requests. The same-origin policy is the only thing that stops all of that, and it is keyed on **scheme, host and port** — so serving the game from `/game/` on the site's own domain buys nothing at all. A path is not an origin.

Three things people get wrong about this:

- **A `<script src>` runs in the *document's* origin, not the script's.** Hosting `tmc-loader.js` somewhere else does not sandbox it — the loader is fully trusted code by construction. website-city's own player says so and withholds session tokens from the boot descriptor for exactly that reason. The **iframe** is what isolates, not the file's address.
- **`sandbox="allow-scripts allow-same-origin"` is safe only cross-origin.** Same-origin, that pair lets the frame reach the parent and strip its own sandbox. The separation is load-bearing for the attribute, which is the second reason not to collapse it.
- **A separate registrable domain beats a subdomain.** Host-only cookies do not reach a subdomain, but a subdomain can *set* a `Domain=.example.net` cookie the parent will receive. That is why user content lives on `googleusercontent.com`, `githubusercontent.com` and `dropboxusercontent.com` rather than on a subdomain.

## Setting the origin up

The vhost is a template in the repo, not a file that exists only on one box:

```bash
./deploy/install-game-origin.sh --domain games.example.com \
    --site-origins "https://example.com" \
    --cert /etc/letsencrypt/live/games.example.com/fullchain.pem \
    --key  /etc/letsencrypt/live/games.example.com/privkey.pem
```

Add `--self-signed` on a development box and it makes the certificate first. Every argument has an environment variable behind it (`TMC_GAME_DOMAIN`, `TMC_SITE_ORIGINS`, `TMC_GAME_WEB_ROOT`, `TMC_GAME_SSL_CERT`, `TMC_GAME_SSL_KEY`, `TMC_GAME_CACHE_CONTROL`), and the script refuses a game domain that is also one of the site origins.

`--site-origins` becomes the `frame-ancestors` list, so it has to name every origin the site is actually served from — including the development ones. A site on `http://localhost:3000` framing a game that only lists `https://example.com` is refused by the browser, and the only sign is a console line.

Then point the loader at it and re-upload it. This does not rebuild the engine:

```bash
./server stamp-loader --base https://games.example.com/game/
```

For this deployment the game is on `games.example.net` and the site on `example.com` — separate registrable domains. website-city's session cookies set no `Domain=`, so they are host-only and would not reach even a subdomain; the separate domain closes the reverse direction, where a sibling can *set* a `Domain=` cookie the site then receives.

## Letting the site publish it instead

The third shape, and the one that needs no stamping at all: upload the export to website-city (App → Party → **Web game build**) and let it publish. It writes every build to its own immutable prefix on the game content origin and hands the loader a `boot.game` block naming that build — which the loader now PREFERS over the stamped `@ENGINE_BASE@`.

That ordering is not a preference, it is a correctness requirement. A published build lives at `game/<app>/<build id>/`, so a baked base names one particular build and goes stale on the next publish — pointing at the previous one, with nothing anywhere saying so.

So for a site-published game:

```bash
./server export-web --zip                    # no --base needed; the site supplies it
```

`--zip` writes `web/build.zip` with the entries at the top level, which is what the publisher expects — zipped from one directory up it would find no entry point in a perfectly good archive. Upload it on the **Web game build** field.

and upload `web/tmc-loader.js` **as-is**, placeholder and all, on the loader field above it. The stamp stays the fallback for the two deployments below, where there is no site to ask.

The loader refuses either way if the resolved location is same-origin with the site — that check is what holds the frame sandbox up, and it does not care which source won. If `NEXT_PUBLIC_GAME_ORIGIN` is unset or points at the site's own domain, the game does not start and says so.

## Serving it from a bucket instead

nginx on this box is one of two shapes. The other is object storage behind a CDN, which is the better one for anything real: the engine is tens of megabytes that change only when you export, and serving it from the machine that also runs your game servers spends their bandwidth on downloads.

```bash
./server export-web --base https://games.example.net/game/
./deploy/publish-web-s3.sh --bucket my-games --prefix game/ \
    --public-base https://games.example.net/game/ --gzip
```

Credentials come from the environment (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, or `S3_ACCESS_KEY` / `S3_ACCESS_SECRET`), never from an argument — an argument is in your shell history and in `ps`. `--endpoint` points it at anything S3-compatible (MinIO, R2), `--use-cli` routes through `aws s3api` where that is installed, and `--dry-run` prints what it would send.

Four things the bucket does not do for you, in the order they bite:

- **Content types.** S3 stores what you tell it and infers nothing. `.wasm` must be `application/wasm` or `WebAssembly.instantiateStreaming` refuses the response and the game never starts, and `.pck` is unknown to every tool. The script sets both; `aws s3 sync` does not.
- **Read access.** A fresh bucket blocks public access, so every file 403s until a bucket policy grants `s3:GetObject` on the prefix or CloudFront reads it through an Origin Access Control. Writing is allowed long before reading is, which makes this look like a broken export rather than a permissions gap.
- **The headers.** The vhost above sends a CSP — including `frame-ancestors`, the only thing stopping another site embedding your player as its own — plus `Cross-Origin-Resource-Policy` and `nosniff`. A bucket cannot send any of them; they move to the CDN's response-headers policy. Skip this and the bucket is a *less* safe origin than the nginx one it replaced. The script prints the set to copy.
- **Compression.** S3 does not compress on the fly and a Godot `.wasm` is tens of megabytes uncompressed. Either `--gzip` (pre-compressed, `Content-Encoding` set) or let the CDN do it — one or the other, not both.

**COOP/COEP are not on that list**, and that is a fact about this export rather than about buckets: they are needed only with `variant/thread_support`, which the preset here has off. Turn threads on and a bare bucket stops being enough.

The origin is still a separate registrable domain, for every reason in the section above. A bucket does not change that — `games.example.net` in front of the bucket, never a path on the site's domain.

## Certificates on a development box

**A certificate error inside an iframe raises no interstitial.** The engine loads in a frame, so there is nothing to click through — the frame is blank and the console says almost nothing. Visiting the SITE and accepting its certificate does not help either; the exception has to exist for the GAME domain, and nothing ever prompts for it.

Two ways out. `--self-signed` issues a leaf, and then each browser has to be walked to `https://<game domain>/game/embed.html` once and told to accept it, per domain, per machine — and Firefox reports `MOZILLA_PKIX_ERROR_SELF_SIGNED_CERT` with copy that says there is nothing you can do (the "Accept the Risk and Continue" button is still there, under Advanced).

`--local-ca` is the better one. It makes a local certificate authority once and issues from it, so a machine trusts the ISSUER a single time and every name it ever signs is simply valid — this domain, the next one, and the site's own. The script prints the import steps for Firefox (which has its own store and ignores the system one), for Chrome and Brave, and for the OS.

The game origin is not the only thing behind TLS, and the failures elsewhere are quieter still — a bad certificate on the WebSocket the game dials produces no prompt and no interstitial at all, just a game reporting it cannot reach a server that is running. `deploy/issue-local-cert.sh` issues from the same CA for anything else:

```bash
./deploy/issue-local-cert.sh example.com '*.example.com' www.example.com
```

Neither belongs in production. Use a real certificate there.
