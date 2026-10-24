# A server gets its own site credential by proving its address

**Why:** everything a server is to the site runs on the integration token in `data/listing.json`: the listing, stats and records, parties, and above all `auth.yml`'s `introspect`, which is how a signed-in member arrives as themselves. The token used to be made by hand and copied onto the box, and a box without one admitted every member as a guest (`guest:` uid) with nothing visibly wrong.

## How

`host/tmc_enroll.gd` (`TmcEnroll.at_boot`, called by `TmcHost` just before `TmcReport` reads the file):

1. When the file has no token, the server asks the site (`POST /api/integration/v1/server/enroll` with its public host and ports).
2. It publishes the returned challenge as the NOTIFY cvar `tmc_enroll`, so it is in the A2S rules.
3. It completes with the returned secret. The site queries the address IT already stores for that server row (`ip4`, `portQuery ?? port`), never one the request names, and issues a credential with the scopes this project calls only if the challenge is in the reply.
4. The token is written into `listing.json` (mode 0600), keeping whatever else is there, and the cvar is cleared.

The challenge is public once published, so it completes nothing alone; the secret completes nothing without the challenge at the stored address. Website-city's half is `src/lib/server/enroll.ts` and `a2s-rules.ts`.

## Rules

- **The server must be on the site and claimed.** An unknown address is a 404 and an unclaimed one a 409, each logged with the fix, and the boot carries on with no credential. An unclaimed listing is exactly the one a stranger could be squatting on.
- **It waits at most 30 s at boot**, because the game's identity layer looks for the credential as the first module loads. If it is late, it keeps asking until the enrollment expires and the host picks the token up live (`_on_enrolled_late`: the listing and sign-in checks at once; parties and avatar reads at the next restart or game change).
- **Re-enrolling rotates.** Delete the token and restart: the new credential revokes the last one enrollment made for that server (`Enrolled by the server`). An owner's hand-made integrations are never touched, and a token an operator put in the file is never replaced.
- **Only a command-line boot enrolls** (`enroll_with_site`, set by `_run`, not under `--selftest`). The suites embed the host through `start()` with fixture data and would otherwise each ask the production site who they are. `TMC_ENROLL=off` turns it off.
- **`TmcReport` defaults its config's strategy to `introspect`.** The listing borrows `DotAuthConfig` for its URL and token, and the default `ticket` strategy demands a `server_id` and key, so a file holding only a token (what enrollment writes) was refused.

## The same credential gives ticket mode its id and key

In `ticket` mode with no `server_id` or key file (the shipped `auth.yml`), `_hand_backbone_to_auth` hands the listing's client to the auth server, which asks `integration/v1/me` for its own server id, and fetches the issuer's public keys from `<backbone_url>/api/app/v1/auth/ticket-keys` over verified HTTPS. Both land in `data/ticket_trust.json`, so the next boot verifies tickets before the site answers; a cache written for another `backbone_url` is ignored. The keys are refetched every six hours and when a ticket names an unknown `kid` (at most once a minute). Never from a client and never from a game server being dialled: the URL is this server's own configured site. dot-auth's [tickets](https://github.com/modcommunity/dot-auth/blob/main/docs/tickets.md#the-backbones-own-issuer-by-dialled-address) has the mechanism; website-city's `docs/api/connect-tickets.md` the threat model.

## Verified, and what is not

Verified against a real `./server` over real UDP, with the site's routes served by its own enrollment code on the dev database: enrolled at the first completion, token saved 0600, listing started; a restart with the token did not enroll; a second enrollment revoked the first; a completion with nothing answering got 202 `no_answer`, a made-up secret 404, an unregistered port 404 with the boot carrying on.

**Not yet verified on production**: the site's routes need deploying and `prisma db push` for `ServerEnrollment`, and each box needs a checkout with this code (a reinstall; the lock did not move, so `when-needed` will not pull it).
