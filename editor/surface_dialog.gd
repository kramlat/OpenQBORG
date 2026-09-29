# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name SurfaceDialog
extends AcceptDialog
## Edits a world's web surfaces (<ext><srf>): pages, videos or SWFs across a
## run of wall faces or a rectangle of floor/ceiling. The editor shows them as
## dark screens; the player shows the live pages.

signal applied(defs: Array)

const KINDS := ["wall", "floor", "ceiling"]
const FACES := ["n", "s", "e", "w"]
const FACE_NAMES := ["North side (faces north)", "South side (faces south)", "East side (faces east)", "West side (faces west)"]

var _defs: Array = []
var _list: ItemList
var _fields := {}
var _current := -1


func open(defs: Array) -> void:
	_defs = defs.duplicate(true)
	title = "Web surfaces"
	ok_button_text = "Apply"
	add_cancel_button("Cancel")
	confirmed.connect(func(): _store(); applied.emit(_defs))
	_build()
	_refresh()
	if not _defs.is_empty():
		_select(0)


func _build() -> void:
	var root := HBoxContainer.new()
	add_child(root)
	var left := VBoxContainer.new()
	root.add_child(left)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(180, 280)
	_list.item_selected.connect(func(i): _store(); _select(i))
	left.add_child(_list)
	var row := HBoxContainer.new()
	left.add_child(row)
	for spec in [["Add", _add], ["Remove", _remove]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		row.add_child(b)

	var grid := GridContainer.new()
	grid.columns = 2
	root.add_child(grid)
	_line(grid, "id", "Name")
	_line(grid, "url", "Address (page, video or .swf)")
	_option(grid, "kind", "Kind", KINDS)
	_option(grid, "face", "Wall face (tile side)", FACE_NAMES)
	for spec in [["x", "X (tile)", 255], ["y", "Y (tile)", 255], ["len", "Length (tiles, wall)", 256],
			["z", "Bottom (px, wall)", 4096], ["h", "Height (px, wall)", 4096],
			["w", "Width (tiles, floor/ceiling)", 256], ["d", "Depth (tiles, floor/ceiling)", 256]]:
		_spin(grid, spec[0], spec[1], spec[2])
	var help := Label.new()
	help.text = "A wall surface covers LEN tiles from X,Y on the chosen side (running east for\nnorth/south faces, south for east/west faces). Relative addresses are relative\nto the world; .swf files play through Ruffle. 256 px = one tile."
	grid.add_child(Control.new())
	grid.add_child(help)


func _line(grid: GridContainer, key: String, label: String) -> void:
	grid.add_child(_label(label))
	var e := LineEdit.new()
	e.custom_minimum_size.x = 320
	grid.add_child(e)
	_fields[key] = e


func _option(grid: GridContainer, key: String, label: String, items: Array) -> void:
	grid.add_child(_label(label))
	var o := OptionButton.new()
	for it in items:
		o.add_item(it)
	grid.add_child(o)
	_fields[key] = o


func _spin(grid: GridContainer, key: String, label: String, hi: int) -> void:
	grid.add_child(_label(label))
	var s := SpinBox.new()
	s.max_value = hi
	grid.add_child(s)
	_fields[key] = s


static func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _refresh() -> void:
	_list.clear()
	for d in _defs:
		_list.add_item("%s (%s)" % [d.id, d.kind])


func _select(i: int) -> void:
	_current = i
	if i < 0 or i >= _defs.size():
		return
	_list.select(i)
	var d: Dictionary = _defs[i]
	_fields.id.text = d.id
	_fields.url.text = d.url
	_fields.kind.select(maxi(0, KINDS.find(d.kind)))
	_fields.face.select(maxi(0, FACES.find(d.face)))
	for k in ["x", "y", "len", "z", "h", "w", "d"]:
		_fields[k].value = d[k]


func _store() -> void:
	if _current < 0 or _current >= _defs.size():
		return
	var d: Dictionary = _defs[_current]
	d.id = _fields.id.text.strip_edges() if not _fields.id.text.strip_edges().is_empty() else "surface%d" % (_current + 1)
	d.url = _fields.url.text.strip_edges()
	d.kind = KINDS[_fields.kind.selected]
	d.face = FACES[_fields.face.selected]
	for k in ["x", "y", "len", "z", "h", "w", "d"]:
		d[k] = int(_fields[k].value)
	_list.set_item_text(_current, "%s (%s)" % [d.id, d.kind])


func _add() -> void:
	_store()
	_defs.append({"id": "screen%d" % (_defs.size() + 1), "url": "about:blank", "kind": "wall", "face": "s",
			"x": 1, "y": 0, "len": 4, "z": 32, "h": 200, "w": 2, "d": 2})
	_refresh()
	_select(_defs.size() - 1)


func _remove() -> void:
	if _current < 0 or _current >= _defs.size():
		return
	_defs.remove_at(_current)
	_current = -1
	_refresh()
	if not _defs.is_empty():
		_select(0)
