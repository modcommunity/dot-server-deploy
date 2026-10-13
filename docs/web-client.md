# The client shell in a browser

`client/shell.tscn` is the client for every game: a menu, a connection, and whatever game the server sends. [web/README.md](../web/README.md) is how to export and publish it; [releases.md](releases.md) is when a new one is needed.

## What the web player signs in against

`client/auth.json`, shipped inside the export, read by `_sign_in()`, gitignored because it is a deployment's answer. `demo.sh` writes it before the export.

- **A browser has no environment and no argv**, so `DOT_AUTH_BACKBONE_URL` cannot reach a web client. Without the file it gets `DotAuthConfig`'s exported default.
- **A shipped file, not the page's query string**, for the same reason as `client/content.json`: this URL decides where a single-use sign-in code is redeemed, and a link that could aim it elsewhere would be a credential-forwarding link.
- **It is the SITE origin, not the game origin.** They are deliberately different registrable domains: the game origin is a sandbox that keeps the site's cookies and storage away from the engine. Pointing the backbone at it would send the site's handoff codes to the domain the separation protects them from.
- **The shell calls `try_web_handoff()`, never `DotAuthClient.sign_in()`.** `sign_in()` falls through to a device-code login, which this shell has nowhere to display; it cost two backbone requests on every bare page load.

## Refusals the shell says in words

- `CODE_VERSION` in a disconnect is a kinds or message-types mismatch between two builds that share a signon revision; the shell shows the server's sentence ("This server needs a newer game client.") rather than the build-mismatch message.
- `_cloud.host_role` is `"client"` in the shell and `"server"` in `TmcHost` and `install-games`, so a pack whose `requires.json` asks for more than a build has says which side is behind.

## The notice overlay and other shell views

`shell.gd`'s `_on_notice` routes the `admin_menu` and `loading_screen` topics to their views ([admin-menu.md](admin-menu.md)) and everything else to `TmcNoticeOverlay` (the game vote and map ballots: [game-vote.md](game-vote.md)). The party and friends clients are described in [operator-services.md](operator-services.md#party-matchmaking-and-locale).

## Clear downloaded content

A mounted pack cannot be unmounted, so a client holding something wrong (a cached object that fails its check, a failed mount, an old copy) is fixed by deleting the downloads and starting again. The menu has a "Clear downloaded content…" button under the status line, and in a game a `FAILED` phase from the shell's content client opens `show_content_failed` with the reason, Dismiss and the same button (mouse freed while it is up).

- It asks first with the size (`downloaded_bytes()`), then `request_clear()` writes `user://dot_cloud_clear_pending` and restarts. **It deletes nothing in the running process**: mounted packs are merged into `res://`, and on Windows an open `.pck` cannot be deleted.
- `clear_pending()` runs first thing in `_ready`, before anything mounts: dot-cloud's `DotCloudStore.clear_all()` and the other cache directories.
- Restart by capability (`DotPlatform.can_self_restart`). A browser reloads through `DotWeb.get_global("location").reload()` a second after asking IndexedDB to flush; **call `reload()` as a method, not `.call("reload")`**, which asks JavaScript for a method named `call`. A desktop build uses `OS.set_restart_on_exit(true, OS.get_cmdline_args())`; `--headless` is not passed on, so testing the relaunch needs a display.

## Layout traps the shell has hit

- **`set_anchors_preset` does not set offsets.** A `Control` built in code keeps the zero size it was created with until something resizes it, so a whole interface can be invisible while correctly configured.
- **A shell feature is a `client/` change**, and `host/` is not in the client build: anything both sides need (cue ids, URL safety) is written twice and a suite checks the copies agree.

## The shell's project.godot

The shell's `project.godot` must keep `audio/driver/enable_input=true`: it is read when the driver starts, so no delivered game can open a microphone without it. The loader's iframe carries `allow="... microphone"`, and a parent page must delegate `microphone` to the game's origin in its own `Permissions-Policy`. [dot-voice design](../../dot-voice/docs/design.md#the-device-layer-and-the-browser)

The shell's `project.godot` carries no comments: the editor drops them, and default-valued keys, the first time it saves the file, so a checkout would show it modified. Its reasons live here: the main scene is `client/boot.tscn` because this project, double-clicked, is the client shell (an operator runs `./server`, which names the host scene), and boot names no addon class because a script compiled before the overlay is mounted keeps its old code for the life of the process ([addon packs](addon-packs.md)); the renderer is `gl_compatibility` because the browser is the whole point of the shell; the two macOS settings are in [native client](native-client.md#two-engine-facts-set-in-projectgodot).

## TLS

A page on HTTPS cannot open `ws://`. Certificates and the reverse proxy are deployment and live in `deploy/`: `issue-letsencrypt.sh` (HTTP-01 out of a webroot, out of nginx, or standalone; DNS-01 through a certbot plugin, the only method that issues a wildcard) and `install-server-tls.sh`. `setup.sh --full` asks whether to do both, and **binds the game to 127.0.0.1 when the answer is yes**: left on 0.0.0.0 the game port stays open beside the TLS one and a client that finds it connects in plaintext. nginx does not carry UDP, so the ENet port (`net_enet_port`, by default the game port number over UDP, shared with A2S and DQP) is reached directly and needs no certificate.

## The browser's audio ceiling

A web build in sample playback runs no bus effects, so dot-audio's Master limiter never runs in a browser, and a pile-up of sounds clipped at the speakers (+3.4 dBFS, 187 clipped samples in 40 s of arena). `export-web` copies dot-audio's `addons/dot_audio/web/dot_audio_ceiling.js` into `web/build/` and makes sure both pages load it before `index.js`: `embed.html` names it in its source, and `install_ceiling` puts the tag into the exported `index.html` (the presets are each box's own copy, so a head include there would reach only new boxes). The script wraps the page's `AudioContext` so the engine's `destination` is a limiter; the measurements are in dot-audio's [docs/loudness.md](../../dot-audio/docs/loudness.md#the-browsers-ceiling). A dot-audio older than the file makes `export-web` warn and build without it.

## Ports and transports

The game listens on `net_port` (6064 in the template) with `net_transport: dual`: browsers on WebSocket/TCP, native clients on ENet/UDP at the same number (`net_enet_port: 0`), with A2S and DQP sharing the UDP port. RCON defaults to the game port plus one. nginx does not carry UDP, so behind TLS the game binds 127.0.0.1 and the ENet port is reached directly. On a panel set every port explicitly. [TLS](#tls), [egg](pterodactyl.md#the-startup-command)
