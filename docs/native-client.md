# The native client: `./server export-native`

It builds the shell for Linux, Windows and macOS, writes one archive per platform into `build/`, and prints the command that publishes each. The desktop app installs a file, and before this the browser was the only way to play.

## The launch arguments need the bare `--`

`client/shell.gd` reads its arguments from `OS.get_cmdline_user_args()`, which is only what follows a `--`. **Godot 4 silently ignores an argument it does not recognise**, so `tmc.x86_64 --connect 127.0.0.1:6099` launches, renders the menu, and connects to nothing. The published argument template is:

```
--,--connect,{host}:{port},--udp,{host}:{udpPort}
```

The desktop app's builder drops a pair when its value is missing. `{udpPort}` is the server's own A2S `udp:<port>` keyword (spy records it as `meta.enetPort`; the site's app API hands it to the app as `udpPort`). Without it a native client tried UDP at the join port, which behind nginx is the TLS port, and fell back to WebSocket after 2.5 s. Other user arguments (`--locale-language de`, `--locale-pseudo true`) go after the same `--`.

## Signing in: `--auth-code`

A player signed into the desktop app should join as themselves, which a TICKET server with `allow_guests=false` requires. The app asks the site's `POST /play/launch` for a launch and gets a 60 s single-use handoff (`tmc_gh_...`, only when the viewer is signed in and the server signs in through TMC), then appends `--auth-code <code>` after the bare `--`. The shell redeems it with `DotAuthClient.redeem_handoff` at ITS OWN backbone (`client/auth.json` or `--auth-backbone-url`), never a URL named in argv. A refused or missing code leaves a guest. The site's `{authCode}` URI token carries the same value for a template that wants it.

## Presets

- **`export_presets.example.cfg` is tracked; `export_presets.cfg` is not.** The editor rewrites the real file, so it is gitignored like `cfg/`; `setup.sh` and `setup.ps1` copy the example in when there is none and never overwrite one.
- **One file per platform**: `binary_format/embed_pck=true` puts the pack inside the executable, so the archive holds exactly the one entry `--entry` names. The zips carry mode bits so the binary arrives executable.
- **It is the client, not the server.** Every preset excludes `host/*`, like the Web one. A native build that could also host is a different product.
- **It publishes under the ENGINE app**, as the web build does: a server can change which game it runs while players stay connected, so a Play press resolves the build from the engine app. Publishing the same shell under each game app is a copy per game.

## Phones: `--platform android` and `--platform ios`

- **`--platform all` stays the desktop three.** A phone build needs things a desktop build machine does not have (JDK 17 and the Android SDK, or a Mac with Xcode), and the site's publisher has no phone platform yet, so `all` building them would turn a working desktop export into a failing one. Ask for a phone by name.
- **Android is a debug APK, arm64-v8a, from the stock template** (gradle build off, so no Android source tree and no NDK): `build/android/tmc.apk`. `tools/fetch-android-sdk.sh` installs the pinned, digest-checked build-tools, platform-tools and cmdline-tools (to `$TMC_ANDROID_SDK`, by default under the Godot data dir), finds JDK 17 (`TMC_JAVA_HOME`, `JAVA_HOME`, or the usual install paths) and prints `ANDROID_HOME` and `JAVA_HOME`. Godot reads those two only when its editor settings file has no `export/android/android_sdk_path` or `java_sdk_path` key, and any editor that has saved its settings has both, often empty: the export then fails with "A valid Java SDK path is required in Editor Settings". So `export-native` runs the fetcher with `--editor-settings`, which writes both keys into the exporting Godot's `editor_settings-<major.minor>.tres` (server.ps1 does the same from `ANDROID_HOME` and `JAVA_HOME`). Godot 4.7 targets SDK 36 and says it is using build-tools 35.0.1 instead; it signs and aligns with them. The fetcher runs on every Android export, so the first Android export installs the SDK the way the first export installs the templates. `TMC_NO_DOWNLOAD` makes a missing SDK an error.
- **Signing**: the debug APK is signed with the editor's debug keystore (Godot makes one with the JDK's keytool when there is none, at `export/android/debug_keystore`) or the one `GODOT_ANDROID_KEYSTORE_DEBUG_PATH`, `_USER` and `_PASSWORD` name. `TMC_ANDROID_RELEASE=1` exports a release APK with the `GODOT_ANDROID_KEYSTORE_RELEASE_*` keystore. No keystore is in this repository.
- **iOS is arm64 and needs a Mac with Xcode**: Godot writes an Xcode project and xcodebuild signs it. `export-native --platform ios` refuses on any other OS (exit 3) before it fetches or writes anything, and on a Mac refuses a preset without `application/app_store_team_id`, which is the developer account's and so empty in the tracked preset.
- **No native library on a phone yet.** No gs-* addon publishes an android or ios build, so `tools/fetch-natives.sh` says so and carries on, both presets exclude `*.gdextension` and `addons/*/bin/*`, and the build runs the GDScript twins.
- **An older `export_presets.cfg` gets the preset added**: a preset `export-native` is asked for and does not find is copied in from the example at the next free index. The lock and non-dot-addon patching applies to every preset, these included, and the artifact checks read the APK's entry list and any pck inside it.
- **Nothing publishes it**: the command ends with `adb install -r build/android/tmc.apk` (or Xcode and TestFlight for an IPA) instead of a publish command.
- **Verified 2026-11-17** on a Linux build box with Godot 4.7.2 and Temurin 17: the export installed the pinned SDK, made the debug keystore and wrote a 76 MB APK (`net.dotgames.tmc`, sdk 24, target 36, native-code `arm64-v8a`, signed). It carries `assets/addons.lock` and no non-dot addon, `host/` or `maps/imported/`. `--platform ios` refused with exit 3. Not yet installed on a phone, and iOS has not been run on a Mac.

## Two engine facts, set in `project.godot`

- **A universal or arm64 macOS export is refused while `textures/vram_compression/import_etc2_astc` is off.** This project has no VRAM-compressed textures, so turning it on reimports nothing; the alternative was an x86_64-only build under a `MACOS_UNIVERSAL` column.
- **The `.app` bundle is named from the project name**, which is the server tool's. `config/name.macos="TMC"` is a feature-tagged override, so the bundle is `TMC.app` and the entry `TMC.app/Contents/MacOS/TMC`.

Verified by exporting all three, unpacking the Linux archive the way the app does, and joining a real `./server` with the address arriving through `-- --connect`.
