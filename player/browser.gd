# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name BrowserView
extends VBoxContainer
## The player's built-in web browser (browser.tscn): ordinary http(s) pages,
## full-view world pages (gtw doorways, pushTo2D) and anything typed into the
## address bar that isn't a world. It shares the player's toolbar; links to
## borg:// or .borg addresses on any page lead back into 3D.

signal page_request(msg: Dictionary)
signal address_changed(url: String)
signal title_changed(title: String)
## "Back to 3D" was pressed.
signal close_requested

var html: HtmlView
var _strip: HBoxContainer
var _back_to_world: Button
var _title: Label


func _ready() -> void:
	_strip = HBoxContainer.new()
	add_child(_strip)
	_back_to_world = Button.new()
	_back_to_world.text = "◀ Back to 3D"
	_back_to_world.visible = false
	_back_to_world.pressed.connect(func(): close_requested.emit())
	_strip.add_child(_back_to_world)
	_title = Label.new()
	_title.clip_text = true
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_strip.add_child(_title)
	html = HtmlView.new()
	html.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(html)
	html.page_request.connect(func(m): page_request.emit(m))
	html.address_changed.connect(func(u): address_changed.emit(u))
	html.title_changed.connect(func(t): _title.text = t; title_changed.emit(t))


func open(url: String) -> void:
	_title.text = ""
	html.navigate(url)


## Shows "Back to 3D" while a world is loaded behind the browser.
func set_world_available(available: bool) -> void:
	_back_to_world.visible = available


func url() -> String:
	return html.current_url


func page_title() -> String:
	return html.title


func can_go_back() -> bool:
	return html.can_go_back()


func can_go_forward() -> bool:
	return html.can_go_forward()


func go_back() -> void:
	html.go_back()


func go_forward() -> void:
	html.go_forward()


func reload() -> void:
	html.reload()
