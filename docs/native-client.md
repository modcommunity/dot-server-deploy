# The native client: `./server export-native`

It builds the shell for Linux, Windows and macOS, writes one archive per platform into `build/`, and prints the command that publishes each. The desktop app installs a file, and before this the browser was the only way to play.

## The launch arguments need the bare `--`

`client/shell.gd` reads its arguments from `OS.get_cmdline_user_args()`, which is only what follows a `--`. **Godot 4 silently ignores an argument it does not recognise**, so `tmc.x86_64 --connect 127.0.0.1:6099` launches, renders the menu, and connects to nothing. The published argument template is:

```
--,--connect,{host}:{port},--udp,{host}:{udpPort}
```

The desktop app's builder drops a pair when its value is missing. `{udpPort}` is the server's own A2S `udp:<port>` keyword (spy records it as `meta.enetPort`; the site's app API hands it to the app as `udpPort`). Without it a native client tried UDP at the join port, which behind nginx is the TLS port, and fell back to WebSocket after 2.5 s. Other user arguments (`--locale-language de`, `--locale-pseudo true`) go after the same `--`.

## Presets

- **`export_presets.example.cfg` is tracked; `export_presets.cfg` is not.** The editor rewrites the real file, so it is gitignored like `cfg/`; `setup.sh` and `setup.ps1` copy the example in when there is none and never overwrite one.
- **One file per platform**: `binary_format/embed_pck=true` puts the pack inside the executable, so the archive holds exactly the one entry `--entry` names. The zips carry mode bits so the binary arrives executable.
- **It is the client, not the server.** Every preset excludes `host/*`, like the Web one. A native build that could also host is a different product.
- **It publishes under the ENGINE app**, as the web build does: a server can change which game it runs while players stay connected, so a Play press resolves the build from the engine app. Publishing the same shell under each game app is a copy per game.

## Two engine facts, set in `project.godot`

- **A universal or arm64 macOS export is refused while `textures/vram_compression/import_etc2_astc` is off.** This project has no VRAM-compressed textures, so turning it on reimports nothing; the alternative was an x86_64-only build under a `MACOS_UNIVERSAL` column.
- **The `.app` bundle is named from the project name**, which is the server tool's. `config/name.macos="TMC"` is a feature-tagged override, so the bundle is `TMC.app` and the entry `TMC.app/Contents/MacOS/TMC`.

Verified by exporting all three, unpacking the Linux archive the way the app does, and joining a real `./server` with the address arriving through `-- --connect`.
