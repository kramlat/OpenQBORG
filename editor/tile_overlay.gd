# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name TileOverlay
extends Node3D
## Grid lines, a hover cursor, the start marker and a colour-coded MultiMesh
## for layers you can't otherwise see in 3D (links, sounds, triggers...).

const LIFT := 0.02

var _grid := MeshInstance3D.new()
var _cursor := MeshInstance3D.new()
var _start := MeshInstance3D.new()
var _cells := MultiMeshInstance3D.new()


func _ready() -> void:
	_grid.material_override = _line_material(Color(1, 1, 1, 0.25))
	add_child(_grid)
	var cursor_mesh := BoxMesh.new()
	cursor_mesh.size = Vector3(1, 0.04, 1)
	_cursor.mesh = cursor_mesh
	_cursor.material_override = _flat_material(Color(1, 0.85, 0.1, 0.45))
	_cursor.visible = false
	add_child(_cursor)
	var arrow := PrismMesh.new()
	arrow.size = Vector3(0.5, 0.7, 0.08)
	_start.mesh = arrow
	_start.material_override = _flat_material(Color(0.1, 1, 0.3, 0.9))
	add_child(_start)
	var quad := PlaneMesh.new()
	quad.size = Vector2(0.9, 0.9)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	_cells.multimesh = mm
	var cell_mat := _flat_material(Color.WHITE)
	cell_mat.vertex_color_use_as_albedo = true
	_cells.material_override = cell_mat
	add_child(_cells)


static func _flat_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.no_depth_test = false
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _line_material(c: Color) -> StandardMaterial3D:
	var m := _flat_material(c)
	m.no_depth_test = true
	return m


func set_grid(w: int, h: int) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for x in w + 1:
		im.surface_add_vertex(Vector3(x, LIFT, 0))
		im.surface_add_vertex(Vector3(x, LIFT, h))
	for y in h + 1:
		im.surface_add_vertex(Vector3(0, LIFT, y))
		im.surface_add_vertex(Vector3(w, LIFT, y))
	im.surface_end()
	_grid.mesh = im


func set_cursor(tile: Vector2i, valid: bool, height := 0.0) -> void:
	_cursor.visible = valid
	_cursor.position = Vector3(tile.x + 0.5, height + LIFT, tile.y + 0.5)


func set_start(pos: Vector2, yaw: float) -> void:
	_start.position = Vector3(pos.x, 0.4, pos.y)
	# Prism points up (+Y); tip it over to point along the facing direction.
	_start.rotation = Vector3(-PI / 2, yaw, 0)


## Shows every non-zero tile of `layer` as a coloured square (one hue per value).
func show_layer(level: BorgLevel, layer: String, empty_value: int) -> void:
	var mm := _cells.multimesh
	var cells: Array[Vector3i] = []
	if not layer.is_empty():
		for y in level.height:
			for x in level.width:
				var v := level.get_cell(layer, x, y)
				if v != empty_value:
					cells.append(Vector3i(x, y, v))
	mm.instance_count = cells.size()
	for i in cells.size():
		var c := cells[i]
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(c.x + 0.5, LIFT * 2, c.y + 0.5)))
		mm.set_instance_color(i, value_color(c.z))


static func value_color(v: int) -> Color:
	return Color.from_hsv(fmod(v * 0.61803, 1.0), 0.75, 1.0, 0.5)
