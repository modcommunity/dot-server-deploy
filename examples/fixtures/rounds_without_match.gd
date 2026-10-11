extends Node

## A stand-in for a loaded game that plays rounds and keeps no `DotMatch` the game vote can find.
##
## Used by `examples/selftest.gd` ("finish_round in a game whose match the game vote cannot
## find"). Every game in the family keeps a dot-match match beside its own vote director, so
## `TmcVote.round_in_progress()` can ask it whether a round is LIVE and let a held change go the
## frame it is not. A game that keeps its rounds some other way leaves that question with no one
## to ask: it is answered true, and the change waits for the `round_ended` the game's own director
## says, which `TmcVote` forwards to the game vote. This is that game: one round-based
## `DotVoteDirector`, the shape a module builds for its map vote, and nothing else.

## The game's own vote, the director `TmcVote` finds in the tree and hears rounds from.
var director: DotVoteDirector = null


func _init() -> void:
	name = "RoundsWithoutAMatch"

	director = DotVoteDirector.new()
	director.name = "MapVote"
	# Its own clock is not what is under test, and the registry's vote service is not this one's.
	director.register_service = false
	director.round_based = true
	add_child(director)


func _ready() -> void:
	director.begin(&"standin_map")


## Ends a round the way a game does: its own director is told, and its clock says
## `round_ended` to whoever listens.
func end_round() -> void:
	var _over := director.note_round_end()
