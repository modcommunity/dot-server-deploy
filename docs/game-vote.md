# The game vote: players choose the next game

`cfg/vote.yml` and `host/tmc_vote.gd`. dot-map votes for maps inside a game; this votes for what the SERVER runs next, which only exists because this project runs more than one game per server.

```
!game_nominate g2gfast   !game_rtv   !game_vote 2      !game_timeleft   !game_next
```

The engine is dot-vote, and the whole policy is `vote.yml`, a `DotVoteRules` layered `defaults < vote.yml < DOT_GAME_VOTE_* < --game-vote-*` ([configuration.md](configuration.md#prefixes-that-keep-two-copies-of-an-addon-apart)). `host/tmc_vote.gd` is only the wiring: who counts as a player and an admin, and where announcements go.

## The `game_` prefix is load-bearing

A loaded game may run its own map vote, and its module registers `rtv`, `nominate`, `timeleft` and `nextmap` before `TmcVote.install` runs. `DotConsole.register_command` keeps the first registration of a name, so an unprefixed server vote does not fail loudly: it gets four dead commands, a player nominating a game is told there is no such map, and the first `changelevel` unregisters the game's four for the rest of the process. For the same reason this director sets `register_service = false`: `dot_vote_director` in `DotRegistry` belongs to the loaded game's vote, and the registry is last-wins.

## This deployment's decisions

- **`vote_exclude` takes a game off the ballot** (empty by default). It is a TMC key, because which installed games players choose between is about this deployment.
- **A game's time limit lives in its own `game.yml`**, under `metadata: vote: time_limit_sec:`, not in a second table of game ids here. `metadata: map_vote:` rides with it and is the layer the game's own map vote reads between its code defaults and `user://cfg/<game>_vote.json`. The three keys this host sets (`kind`, `module`, `directory`) win over the block.
- **`begin_on_apply` is off.** Otherwise the director announces a change it made and the host announces the same change through `game_loaded`: two notifications, two history entries, every cooldown half as long. The host's signal is the right one because it also fires for an operator's manual `changelevel`. `examples/multigame.tscn` fails if it is flipped.

## One game on offer is no game vote

`TmcVote.install` returns null (no `!game_*` commands, no clock, no ballot) when fewer than two games are on offer after `vote_exclude`, and the game's own map vote is then the only vote.

- **Counted by content id**, not game id (`TmcVote.votable_count`): hungario's modes are several game ids over one `tmc/hungry`, and its own map vote already chooses between them.
- **And by the name on the ballot**: a built-in `g2gfast` beside a published `<owner>/game-g2gfast` is two content ids and one game. dot-vote also drops a choice named like the running one and holds no ballot when nothing else is left, at the time it falls due, so a game whose `min_players` stops being met does not leave a ballot of Extend alone.
- `multigame` asserts null over one game, one game installed twice under one name, and hungario alone.
- **mg-smash-copter and mg-buses-from-hell have votes of their own now** (layouts, bowls), so every game in the family has a vote when it runs alone.
With two or more games both votes run, each on its own clock; the prefix and the two ballot topics keep their commands and panels apart, and the next section keeps their ballots apart.

## The game's own vote and this one take turns

Every game in the family has a vote of its own (map, mode, layout, course or mountain), and none can name this one: a delivered game cannot reference `host/`, and this director is not in `DotRegistry`. So `TmcVote` finds them: every `DotVoteDirector` in the tree that is not its own (`game_directors()`), searched on every `game_loaded` and once a second for one built later.

- **Never two ballots at once.** This director's `busy_fn` is true while a votekick or the game's own ballot (or its countdown) is up, and each game director's `busy_fn` is wrapped so it is also true while this one is. The wrap is compared with what is stored in the director's meta, so a game that assigns `busy_fn` again is wrapped again.
- **A ballot that waits is owed, not dropped.** A time limit falling due waits through dot-vote's retry; a game's own `start_vote` refused for this one is owed the same way (dot-vote, since 2026-10-11). A minigame opens its round ballot once, so before that the game ballot on screen cost that round its ballot.
- **One choice per game.** A content id is one game: the first of its ids in `content/` stands for it on the ballot, and the running game's other ids are never offered (`_refresh_offer()`), because its own vote already chooses between them. Before, hungario's six modes were six choices among eighteen and a hungario mode was on 23 of 27 ballots. `!game_nominate` names the standing id (`hungry_classic`); the mode is hungario's own vote's to choose.
- **Rounds are heard from the game's vote.** A game director that is `round_based` forwards every `round_ended` to this one, which is then `round_based` too, so `time_up: finish_round` in `vote.yml` plays a round-based game's round out. Without it this director heard no round ever, and `finish_round` changed mid-round in every game. `examples/game_vote_rounds.tscn` runs it through real round ends in two games. A game without rounds (playground, g2gfast, lookatme) changes on time; its game vote is the clock alone, and `game_vote_all` shows it offered there like everywhere else.

`examples/game_vote_all.tscn` plays all of this through every game with a real shell: rock the vote, "don't change", the game's own ballot refused and then following, the time limit waiting for it, one entry per game, never two ballots in any physics frame, and a click on the next game played.

## On the HUD

The ballot, countdown and result reach chat through `announce_fn`, and also go out as dot-server `DotNotice`s that the shell's `TmcNoticeOverlay` (`client/notice_overlay.gd`) draws and plays. The shell talks to a server only through `DotClientLink` and `DotClientChat`, and a loaded game's wire is the game's, so a generic notice pair in dot-server was the way in. That pair moved the signon revision: every shell built before it is refused by a server built after it.

- **One HUD line, `NOTICE_TOPIC`, owned by TmcVote.** Each countdown second and the ballot replace it; the client counts the seconds between messages.
- **Taken down by a poll, not a signal.** `_sync_notice()` runs after every `advance` and clears the line when the director is neither counting down nor voting, because `DotVoteDirector.cancel_countdown` emits nothing.
- **Lines and ballots are one column down the right-hand side, under 110 px, a third of the frame wide (240 to 360 px); nothing is at the top centre.** The line used to be a bar across the top centre, where nearly every game draws its own second line (the round clock's, the map name, "between rounds", arena's portrait row); rendered over all thirteen games it hid one of them in ten. Judge a change with `game_vote_all -- --shot=<png>` at 1280x720 and a narrower frame.
- **The ballot names the line it stands for** (`data["line"] = NOTICE_TOPIC`), and the overlay does not draw that line while the ballot is open: the ballot already shows the title, the keys and the time. The line still exists (`line_text`), and a shell older than this ignores the field and draws both.
- **A late joiner is sent the line that is still true** from `client_spawned`; notices go to playing sessions only.
- **The cue ids are written twice and checked against each other.** `cfg.example/vote.yml` names them (`tmc_vote_start`, `tmc_vote_end`, `tmc_vote_warning`, `tmc_vote_count`) because the server decides what plays; `TmcNoticeOverlay.sound_catalogue()` has them because the client plays them and `host/` is not in the client build. `selftest` fails on a cue the overlay lacks (dot-audio plays an unknown id as silence) or one with no synthesised stand-in. Real sounds go in `client/sounds/<id>.ogg`.
- **The overlay does not register an audio manager or touch buses**: a delivered game registers its own `dot_audio` and sets its own volumes. It plays on `Master` because this project declares no bus layout.

## The ballot is drawn, and a click votes

`DotVoteBallotFeed` sends the open ballot as a notice's `data` under `TmcVote.BALLOT_TOPIC` (`game_ballot`) per playing session (each copy carries that session's voter id as `you`), and to a late joiner. Every game's map vote does the same under `map_ballot`. The overlay draws one dot-ui `DotBallotPanel` per topic: number keys, F3 to free the mouse and click, or both (`ballot_input`, the server's choice), with voters' avatars. A choice goes back as `/<command> <n>` through `link.send_chat`, so nothing new is on the wire. The two ballots are never open together (see above); if a shell ever met both, the number keys would belong to the one opened last. `game_vote_all -- --shot=<png>` under `xvfb-run` renders the drawn ballot over the first game. A shell older than this ignores `data` and still has the HUD line.

## Template changes do not reach existing deployments

`cfg.example/vote.yml` ships `vote_warning_sec: 10`, `runoff_warning_sec: 5` and the four cue ids. `cfg/` is never overwritten, so a deployment whose `vote.yml` predates them has the ballot line and no countdown or sound until those keys are uncommented there.

## A game that stops its map clock must stop its vote's clock too

A playground with `pg_map_seconds: "0"` still had the vote's thirty-minute clock and was put to a ballot at twenty-eight minutes. It sets `metadata: map_vote: {trigger: rtv_only, duration_sec: 0}`, and `selftest` fails any shipped game whose `*_map_seconds` is 0 while its vote still has a clock.
