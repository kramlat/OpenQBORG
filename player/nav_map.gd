# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name NavMap
extends Control
## The level's .nav overview image with a "you are here" marker.
## Clicking a spot activates that tile's link, like clicking it in 3D.

signal tile_clicked(tile: Vector2i)

var _texture: Texture2D
var _player := Vector2(-1, -1)
var _yaw := 0.0
var _grid := Vector2i(BorgLevel.CLASSIC_SIZE, BorgLevel.CLASSIC_SIZE)


func set_map(image: Image, grid_size: Vector2i) -> void:
	_grid = grid_size
	_texture = ImageTexture.create_from_image(image) if image != null else null
	queue_redraw()


func set_player(tile_pos: Vector2, yaw: float) -> void:
	if tile_pos.distance_squared_to(_player) > 0.0001 or absf(yaw - _yaw) > 0.001:
		_player = tile_pos
		_yaw = yaw
		queue_redraw()


func _map_rect() -> Rect2:
	# Fit the grid aspect into the control.
	var cell := minf(size.x / _grid.x, size.y / _grid.y)
	var s := Vector2(_grid) * cell
	return Rect2((size - s) / 2, s)


func _draw() -> void:
	var r := _map_rect()
	if _texture != null:
		draw_texture_rect(_texture, r, false)
	else:
		draw_rect(r, Color(0.1, 0.1, 0.12))
	if _player.x < 0:
		return
	var cell := r.size.x / _grid.x
	var p := r.position + _player * cell
	var facing := Vector2(-sin(_yaw), -cos(_yaw))
	draw_line(p, p + facing * cell * 1.2, Color.YELLOW, 2.0)
	draw_circle(p, maxf(3.0, cell * 0.25), Color.RED)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var r := _map_rect()
		if r.has_point(event.position):
			var t: Vector2 = (event.position - r.position) / (r.size.x / _grid.x)
			tile_clicked.emit(Vector2i(floori(t.x), floori(t.y)))
