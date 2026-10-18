# Not done yet

What is not built, published or verified yet. Each is unfinished work, not a design decision.

- Server enrollment is not verified on production (site deploy, `prisma db push`, box reinstalls). [enrollment](enrollment.md#verified-and-what-is-not)
- The site's party booking feed and player party routes are not known to be deployed. [services](operator-services.md#party-matchmaking-and-locale)
- The PowerShell launcher lacks the bash `pack` and is untested on Windows. [setup](setup.md#windows)
- Audio in a real browser is unheard; Ogg, MP3 and WebP loading-screen media never fed a real file. [admin](admin-menu.md#testing-it)
- A native build cannot sign in (`app-native-auth`, found under `workshop-shell-1`). The shell's only sign-in is the browser handoff (`DotAuthWebHandoff.supported()` is web only), so a desktop build is always a guest: the Subscriptions page says "Sign in to use your subscriptions" and a solo start syncs nothing. It needs a native sign-in that fills `DotAuthClient.store`; the Workshop's `token_fn` already reads it. [web-client](web-client.md#solo-play)
