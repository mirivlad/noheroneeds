class_name UiWindows
extends RefCounted
## The game's windows (UI 2.0, docs/design/UI_UX_2_0.md): which closes which,
## what Esc closes first, where they stand. Not an OS window manager: each
## window shows itself (show_for, open...); this only keeps the rules.
##
## - WORK (things, character, crafts, building, journal): one open at a time;
## - AT_THING (a chest, trade, talk, a lock): opened by the server's answer to
##   something done to a thing in the world; it closes the work windows;
## - POPUP (the actions menu): over all, closed first.

enum {WORK, AT_THING, POPUP}
## Where windows may stand: below the top indicators, above the quick slots.
var top := 52.0
var bottom := 60.0
var _windows: Array = []  # [Control, kind]


func add(w: Control, kind: int) -> void:
	_windows.append([w, kind])


## Before `w` shows itself: the windows it replaces are closed.
func opening(w: Control) -> void:
	var kind := _kind_of(w)
	for e: Array in _windows:
		var other: Control = e[0]
		if other != w and other.visible and (int(e[1]) in [WORK, AT_THING] and kind in [WORK, AT_THING]):
			other.hide()


## Opens `w` by `show` (its own way of showing) or closes it if open.
func toggle(w: Control, show: Callable) -> void:
	if w.visible:
		w.hide()
	else:
		opening(w)
		show.call()


## Esc: the popup, else a window at a thing, else a work window. Whether one was closed.
func close_top() -> bool:
	for kind: int in [POPUP, AT_THING, WORK]:
		for e: Array in _windows:
			if int(e[1]) == kind and (e[0] as Control).visible:
				(e[0] as Control).hide()
				return true
	return false


func close_all() -> void:
	for e: Array in _windows:
		(e[0] as Control).hide()


## Whether any window (of `kind`, or any) is open.
func any_open(kind := -1) -> bool:
	for e: Array in _windows:
		if (kind < 0 or int(e[1]) == kind) and (e[0] as Control).visible:
			return true
	return false


## The open windows (not popups) at their least size, in the middle between
## `top` and the quick slots, wholly on the screen of `area`.
func place(area: Vector2) -> void:
	for e: Array in _windows:
		var w: Control = e[0]
		if int(e[1]) == POPUP or not w.visible:
			continue
		w.size = w.get_combined_minimum_size()
		var room := maxf(0.0, area.y - bottom - top)
		w.position = Vector2(floorf(clampf((area.x - w.size.x) / 2.0, 0.0, maxf(0.0, area.x - w.size.x))),
			floorf(top + maxf(0.0, (room - w.size.y) / 2.0)))
		if w.position.y + w.size.y > area.y:  # taller than the room: as high as it can stand
			w.position.y = maxf(0.0, area.y - w.size.y)


func _kind_of(w: Control) -> int:
	for e: Array in _windows:
		if e[0] == w:
			return int(e[1])
	return WORK
