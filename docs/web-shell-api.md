# Publishing the web shell through the site API

`tools/publish-web-shell.sh --api SITE` (or `SHELL_API=` in the env file) uploads the shell through the site instead of `aws s3`, so it works when games storage is storez and no S3 credentials exist. Without `--api` the S3 path is unchanged. Flags, `--dev`/`--env` selection and `--pin` behave the same; the script prints `build id: <id>` for the `WebGameBuild` registration.

It needs `SHELL_PUBLISH_TOKEN` (env or env file, never an argument; it reaches curl through a stdin config so `ps` never shows it) and `--app`.

## The contract it calls (website-city, proposed)

`POST {SITE}/api/app/v1/web/build`, `Authorization: Bearer <SHELL_PUBLISH_TOKEN>`, JSON.

1. `{"op":"begin","app","build","engine","files":[{"key","type","encoding","size","sha256"}]}` answers `{"puts":[{"key","url","headers":{}}]}`. Keys are relative to `game/<app>/`: `<build>/<path>` and the shared `engine/<hash>/<file>`. The headers (content-type, cache-control, content-encoding) are part of the presigned signature and the script sends exactly those.
2. The script PUTs each file (brotli, `Content-Encoding: br`) to its URL.
3. `{"op":"finalize","app","build","pin":bool,"manifest_json":"..."}` makes the site check the objects exist, and, with `pin`, write `game/<app>/latest.json`.

## Status

The site has no such route yet (checked 2026-11-01), so only a local mock has exercised this path: all files uploaded, brotli round trip hash-equal, shellcheck clean. See the report that came with this commit for what the site must add.
