# Web inventory bridge

The web shell lets an embedding page (the account site's Downloads page) list and manage the content this browser has downloaded, through `window.postMessage`. The logic is dot-cloud's `DotCloudInventoryBridge`; `client/tmc_inventory_link.gd` (`TmcInventoryLink`) is the transport.

## Enabling it

Off by default. `client/content.json` takes `"inventory_origins": ["https://example.org"]`, exact origins only. `*` and empty strings are dropped. With none listed the shell registers no listener at all.

## Messages

Request, posted to the shell's window (a JSON string or an object): `{"dot": "dot-inventory", "v": 1, "id": <any>, "op": <op>, ...}`.

| op | fields | value |
| --- | --- | --- |
| `list` | | array of `{id, version, kind (game, map, weapon, workshop), game, name, bytes, last_used, pinned, platform}` |
| `quota` | | `{free, quota, usage, quota_cause}`; cause is `partitioned`, `near-full`, `unreadable` or empty |
| `pin` | `pack`, `pinned` | the pack's new state |
| `pin_game` | `game`, `pinned` | packs touched |
| `delete` | `pack`, optional `version` | bytes freed |
| `clear` | | bytes freed, unpinned packs not in use |
| `clear_all` | | queues the shell's clear-on-restart |

Reply, posted to the sender's origin as a JSON string: `{"dot", "v", "id", "op", "ok": true, "value": ...}` or `{..., "ok": false, "error": {"code", "message"}}`. Branch on `error.code`: `INVALID` (unknown op or bad field), `VERSION` (unsupported `v`), `STATE` (the pack is mounted; delete it after a restart), `QUOTA`, `UNSUPPORTED`.

## Safety

- The sender's `event.origin` is checked against the allowlist before anything else is read. An unlisted origin gets no reply, so it cannot tell a bridge exists.
- Replies go to `event.origin`, never `*`. `DotWeb.post_to_parent` uses `*` and is not used here.
- A pack mounted in this session is never deleted live (a mounted pack cannot be unmounted); the reply is `STATE`, and `clear_all` takes effect on restart.
- The listener is a JS callback made through `DotWeb.create_callback` and attached with `window.addEventListener`; nothing is evaluated, because the game origin's CSP has no `unsafe-eval`.
