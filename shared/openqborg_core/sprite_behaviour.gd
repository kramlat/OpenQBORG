# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name SpriteBehaviour
extends RefCounted
## Plays a CWS3 sprite's behaviour groups (see CWSprite.Group): the general
## animation, and the mouse-over, click and proximity animations that take
## over when the pointer rests on the sprite, it is clicked, or the viewer
## comes within its proximity distance.

const G := CWSprite.Group

var node: Sprite3D
var sprite: CWSprite
var tile: Vector2i

var group := -1
var frame := 0
var _time := 0.0
var _loops_left := 0
var _playing := false
var _hovered := false
var _near := false


func _init(p_node: Sprite3D, p_sprite: CWSprite, p_tile: Vector2i) -> void:
	node = p_node
	sprite = p_sprite
	tile = p_tile
	start(G.GENERAL)


func start(g: int) -> void:
	var grp: Dictionary = sprite.groups[g]
	group = g
	frame = grp.from
	_time = 0.0
	_loops_left = grp.repeat
	# The general group only moves if the sprite animates on load.
	_playing = grp.enabled and (g != G.GENERAL or sprite.animate_on_load) and \
			(grp.from != grp.to or grp.repeat > 0)
	_show()


func tick(ms: float) -> void:
	if not _playing:
		return
	var grp: Dictionary = sprite.groups[group]
	_time += ms
	var dur := _duration(frame)
	while _time >= dur:
		_time -= dur
		if frame == grp.to:
			if grp.repeat > 0:
				_loops_left -= 1
				if _loops_left <= 0:
					_finish(grp)
					return
			frame = grp.from
		else:
			frame += signi(grp.to - grp.from)
		dur = _duration(frame)
	_show()


func _finish(grp: Dictionary) -> void:
	_playing = false
	if grp.end >= 0:
		frame = grp.end
		_show()
	# end = -1, or "revert when it stops": back to the general animation.
	if group != G.GENERAL and (grp.end < 0 or grp.revert & CWSprite.REVERT_ON_STOP):
		start(G.GENERAL)


## Mouse-over: starts when the pointer arrives; reverts when it leaves if the
## group says so.
func set_hovered(on: bool) -> void:
	if on == _hovered:
		return
	_hovered = on
	_edge(G.MOUSE_OVER, on)


func set_near(on: bool) -> void:
	if on == _near:
		return
	_near = on
	_edge(G.PROXIMITY, on)


func click() -> void:
	if sprite.has_group(G.CLICK):
		start(G.CLICK)


func reacts_to_mouse() -> bool:
	return sprite.has_group(G.MOUSE_OVER) or sprite.has_group(G.CLICK)


func _edge(g: int, on: bool) -> void:
	if not sprite.has_group(g):
		return
	if on:
		# A click animation in progress isn't cut short by hovering.
		if not (group == G.CLICK and _playing):
			start(g)
	elif group == g and sprite.groups[g].revert & CWSprite.REVERT_ON_EXIT:
		start(G.GENERAL)


func _duration(f: int) -> float:
	var d := sprite.frame_durations
	return maxf(1.0, d[f % d.size()] if d.size() > 0 else sprite.default_duration)


func _show() -> void:
	node.frame = clampi(frame, 0, node.vframes - 1)
