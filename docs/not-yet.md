# Not done yet

What is not built, published or verified yet. Each is unfinished work, not a design decision.

- `zed_weapons` is not in `ADDONS_ALL`, `setup.ps1`, `addon_repo` or `addons.lock` until zed-dot-weapons is published; zee-dot-weapons needs a tag with `ZeeWeaponPack.add_source`. [releases](releases.md#pending-zed_weapons)
- `dot_bot` is not in `ADDONS_ALL`, `setup.ps1` or `addons.lock` until modcommunity/dot-bot is published and tagged; six games need it at their HEADs. [releases](releases.md#pending-dot_bot)
- Not in `setup.sh`'s `GAMES` (unreleased): deathrun, delivery, lookatme, prophunt, hideseek, zombiezone and their map packs.
- Server enrollment is not verified on production (site deploy, `prisma db push`, box reinstalls). [enrollment](enrollment.md#verified-and-what-is-not)
- The site's party booking feed and player party routes are not known to be deployed. [services](operator-services.md#party-matchmaking-and-locale)
- The PowerShell launcher lacks the bash `pack` and is untested on Windows. [setup](setup.md#windows)
- Audio in a real browser is unheard; Ogg, MP3 and WebP loading-screen media never fed a real file. [admin](admin-menu.md#testing-it)
