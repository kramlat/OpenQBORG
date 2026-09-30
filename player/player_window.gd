# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
extends Control
## The OpenQBORG Player window: one row with the menus and the tabs, and a
## PlayerTab (player_tab.gd) per tab. Tabs share the fetcher (and its caches),
## the loopback page server and the bookmarks; only the tab in front runs and
## makes sound.
##
## One window per user: launching the player again (a borg:// link, a .borg
## file from the desktop) opens the address as a tab here instead
## (SingleInstance). `--new-window` starts a separate player regardless.

const NEW_TAB := "New Tab"
const TAB_TITLE_MAX := 28

var fetcher := BorgFetcher.new()
var pages := LocalPageServer.new()
var bookmarks := Bookmarks.new()
var instance := SingleInstance.new()

var _tabs: TabBar
var _row: HBoxContainer
var _plus: Button
var _spacer: Control
var _holder: Control
var _bookmark_menu: PopupMenu
var _open_dialog: FileDialog


func _ready() -> void:
	var start := _startup_urls()
	# Test runs (OPENQBORG_SCREENSHOT) never hand off to the user's player.
	var separate := "--new-window" in OS.get_cmdline_user_args() or "--new-window" in OS.get_cmdline_args() \
			or not OS.get_environment("OPENQBORG_SCREENSHOT").is_empty()
	if not separate and SingleInstance.hand_off_all(start):
		get_tree().quit()
		return
	DisplayServer.window_set_min_size(Vector2i(800, 500))
	add_child(fetcher)
	add_child(pages)
	pages.fetcher = fetcher
	HtmlView.ruffle_base = pages.ruffle_base()
	HtmlView.swf_page = pages.swf_overlay_page
	bookmarks.load_or_seed()
	if not separate:
		add_child(instance)
		instance.start()
		instance.url_received.connect(func(url: String):
			print_verbose("OpenQBORG: handed over: ", url)
			new_tab(url)
			DisplayServer.window_move_to_foreground())
	_build_ui()
	if start.is_empty():
		new_tab()
	for i in start.size():
		new_tab(start[i], i > 0)


## Addresses to open, one tab each: after "--" anything goes (a world, a file,
## a web address); exported builds get them directly (file associations, %u).
func _startup_urls() -> PackedStringArray:
	var out := PackedStringArray()
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("-"):
			out.append(arg)
	if out.is_empty():
		for arg in OS.get_cmdline_args():
			var lower := arg.to_lower()
			if lower.begins_with("borg") or lower.begins_with("http") or lower.begins_with("file://") \
					or lower.ends_with(".borg"):
				out.append(arg)
	return out


# --- Tabs ------------------------------------------------------------------------

## Opens `url` ("" for an empty tab) in a new tab, in front unless `background`.
func new_tab(url := "", background := false) -> PlayerTab:
	var tab := PlayerTab.new()
	tab.fetcher = fetcher
	tab.pages = pages
	tab.set_anchors_preset(Control.PRESET_FULL_RECT)
	tab.set_active(false)
	_holder.add_child(tab)
	tab.title_changed.connect(func(_t: String): _update_tab_title(tab))
	tab.new_tab_requested.connect(func(u: String): new_tab(u))
	_tabs.add_tab(NEW_TAB)
	_tabs.set_tab_metadata(_tabs.tab_count - 1, tab)
	_fit_tabs.call_deferred()
	if not background or _tabs.tab_count == 1:
		_tabs.current_tab = _tabs.tab_count - 1
		_show_tab(_tabs.current_tab)
	if not url.is_empty():
		tab.open_url(url)
	elif not background:
		tab.focus_address()
	return tab


func active_tab() -> PlayerTab:
	if _tabs == null or _tabs.tab_count == 0:
		return null
	return _tabs.get_tab_metadata(_tabs.current_tab) as PlayerTab


func close_tab(index: int) -> void:
	if index < 0 or index >= _tabs.tab_count:
		return
	if _tabs.tab_count == 1:
		_quit() # closing the last tab closes the window, as browsers do
		return
	var tab := _tabs.get_tab_metadata(index) as PlayerTab
	_tabs.remove_tab(index)
	tab.queue_free()
	_fit_tabs.call_deferred()
	_show_tab(_tabs.current_tab)


func _show_tab(index: int) -> void:
	for i in _tabs.tab_count:
		var tab := _tabs.get_tab_metadata(i) as PlayerTab
		if tab != null: # TabBar announces a new tab before its metadata is set
			tab.set_active(i == index)
	_update_window_title()


func _update_tab_title(tab: PlayerTab) -> void:
	for i in _tabs.tab_count:
		if _tabs.get_tab_metadata(i) == tab:
			var t := tab.title if not tab.title.is_empty() else NEW_TAB
			_tabs.set_tab_title(i, t if t.length() <= TAB_TITLE_MAX else t.left(TAB_TITLE_MAX - 1) + "…")
			_tabs.set_tab_tooltip(i, t)
	_fit_tabs.call_deferred()
	_update_window_title()


func _update_window_title() -> void:
	var tab := active_tab()
	var t := tab.title if tab != null else ""
	DisplayServer.window_set_title("%s — OpenQBORG" % t if not t.is_empty() else "OpenQBORG")



## The + follows the last tab, as in current browsers; once the tabs don't fit,
## the strip takes the whole row and scrolls instead.
func _fit_tabs() -> void:
	if _tabs == null:
		return
	_tabs.clip_tabs = false
	var need := _tabs.get_combined_minimum_size().x
	var room := _row.size.x - _plus.size.x - (_row.get_child(0) as Control).size.x \
			- 3 * _row.get_theme_constant("separation")
	var overflow := need > room
	_tabs.clip_tabs = overflow
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL if overflow else Control.SIZE_FILL
	_spacer.visible = not overflow

# --- UI --------------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# Menus and tabs share one row.
	_row = HBoxContainer.new()
	var row := _row
	root.add_child(row)
	row.add_child(_build_menu())
	_tabs = TabBar.new()
	_tabs.max_tab_width = 240
	_tabs.drag_to_rearrange_enabled = true
	_tabs.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	_tabs.tab_changed.connect(_show_tab)
	_tabs.tab_close_pressed.connect(close_tab)
	_tabs.gui_input.connect(_on_tabs_input)
	row.add_child(_tabs)
	_plus = Button.new()
	_plus.text = "+"
	_plus.flat = true
	_plus.tooltip_text = "New tab (Ctrl+T)"
	_plus.pressed.connect(func(): new_tab())
	row.add_child(_plus)
	_spacer = Control.new()
	_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_spacer)
	row.resized.connect(_fit_tabs)

	_holder = Control.new()
	_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_holder)


## Middle-click closes a tab; double-click on the empty strip opens one.
func _on_tabs_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var i := _tabs.get_tab_idx_at_point(mb.position)
	if mb.button_index == MOUSE_BUTTON_MIDDLE and i >= 0:
		close_tab(i)
		_tabs.accept_event()
	elif mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click and i < 0:
		new_tab()
		_tabs.accept_event()


# --- Menus -----------------------------------------------------------------------

enum MenuId { NEW_TAB, CLOSE_TAB, OPEN_FILE, OPEN_ADDRESS, RELOAD, BACK, QUIT, ADD_BOOKMARK,
		REMOVE_BOOKMARK, CONTROLS, ABOUT, NEXT_TAB, PREV_TAB, BOOKMARK_BASE = 1000 }


func _build_menu() -> MenuBar:
	var bar := MenuBar.new()
	bar.prefer_global_menu = false
	bar.flat = true
	var file := PopupMenu.new()
	file.name = "File"
	for spec in [["New Tab", MenuId.NEW_TAB, KEY_MASK_CTRL | KEY_T],
			["Close Tab", MenuId.CLOSE_TAB, KEY_MASK_CTRL | KEY_W], [],
			["Open File…", MenuId.OPEN_FILE, KEY_MASK_CTRL | KEY_O],
			["Open Address…", MenuId.OPEN_ADDRESS, KEY_MASK_CTRL | KEY_L], [],
			["Reload", MenuId.RELOAD, KEY_F5],
			["Back to Previous World", MenuId.BACK, KEY_MASK_ALT | KEY_LEFT], [],
			["Quit", MenuId.QUIT, KEY_MASK_CTRL | KEY_Q]]:
		if spec.is_empty():
			file.add_separator()
			continue
		file.add_item(spec[0], spec[1])
		file.set_item_accelerator(file.get_item_index(spec[1]), spec[2])
	file.id_pressed.connect(_on_menu)
	bar.add_child(file)

	_bookmark_menu = PopupMenu.new()
	_bookmark_menu.name = "Bookmarks"
	_bookmark_menu.id_pressed.connect(_on_menu)
	_bookmark_menu.about_to_popup.connect(_refresh_bookmark_menu)
	bar.add_child(_bookmark_menu)
	bookmarks.changed.connect(_refresh_bookmark_menu)
	_refresh_bookmark_menu()

	var help := PopupMenu.new()
	help.name = "Help"
	help.add_item("Controls", MenuId.CONTROLS)
	help.add_item("About OpenQBORG", MenuId.ABOUT)
	help.id_pressed.connect(_on_menu)
	bar.add_child(help)

	_open_dialog = FileDialog.new()
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.use_native_dialog = true
	_open_dialog.filters = PackedStringArray(["*.borg ; QBORG worlds"])
	_open_dialog.file_selected.connect(func(p: String): active_tab().open_url(p))
	add_child(_open_dialog)
	return bar


## Quit (menu, Ctrl+Q, closing the last tab), saving anything not yet on disk.
func _quit() -> void:
	bookmarks.flush()
	instance.stop()
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		bookmarks.flush()
		instance.stop()


func _refresh_bookmark_menu() -> void:
	var m := _bookmark_menu
	var tab := active_tab()
	var url: String = tab.current_url if tab != null else ""
	m.clear(true)
	var marked := bookmarks.index_of(url) >= 0
	m.add_item("Bookmark This World", MenuId.ADD_BOOKMARK)
	m.set_item_accelerator(0, KEY_MASK_CTRL | KEY_D)
	m.set_item_disabled(0, tab == null or tab.bookmark_target().is_empty() or marked)
	m.add_item("Remove This Bookmark", MenuId.REMOVE_BOOKMARK)
	m.set_item_disabled(1, not marked)
	if not bookmarks.items.is_empty():
		m.add_separator()
	# Folders (the defaults) as submenus, then the user's own bookmarks.
	for folder in bookmarks.folders():
		if folder.is_empty():
			continue
		var sub := PopupMenu.new()
		sub.id_pressed.connect(_on_menu)
		_add_bookmark_items(sub, folder)
		m.add_submenu_node_item(folder, sub)
	_add_bookmark_items(m, "")


func _add_bookmark_items(m: PopupMenu, folder: String) -> void:
	for i in bookmarks.items.size():
		var b: Dictionary = bookmarks.items[i]
		if b.folder == folder:
			m.add_item(b.title, MenuId.BOOKMARK_BASE + i)
			m.set_item_tooltip(m.get_item_count() - 1, BorgUrl.to_display(b.url))


func _on_menu(id: int) -> void:
	var tab := active_tab()
	match id:
		MenuId.NEW_TAB:
			new_tab()
		MenuId.CLOSE_TAB:
			close_tab(_tabs.current_tab)
		MenuId.NEXT_TAB:
			_tabs.current_tab = (_tabs.current_tab + 1) % _tabs.tab_count
		MenuId.PREV_TAB:
			_tabs.current_tab = (_tabs.current_tab + _tabs.tab_count - 1) % _tabs.tab_count
		MenuId.OPEN_FILE:
			_open_dialog.popup_centered_ratio(0.6)
		MenuId.OPEN_ADDRESS:
			tab.focus_address()
		MenuId.RELOAD:
			tab.reload()
		MenuId.BACK:
			tab.back()
		MenuId.QUIT:
			_quit()
		MenuId.ADD_BOOKMARK:
			var b := tab.bookmark_target()
			if not b.is_empty():
				bookmarks.add(b.title, b.url)
				tab.set_status("Bookmarked " + BorgUrl.to_display(b.url))
		MenuId.REMOVE_BOOKMARK:
			bookmarks.remove(tab.current_url)
		MenuId.CONTROLS:
			_show_dialog("Walk: ↑ ↓ or W S     Turn: ← →     Strafe: A D\nLook up/down: PgUp PgDn\n"
					+ "Click a tile (or the nav map) to follow its link.\n\n"
					+ "New tab: Ctrl+T     Close tab: Ctrl+W (or middle-click)\n"
					+ "Next / previous tab: Ctrl+Tab / Ctrl+Shift+Tab")
		MenuId.ABOUT:
			_show_dialog("OpenQBORG Player\nAn open source player for CYBERWORLD QBORG worlds.\n\n"
					+ "Free software under the GNU GPL v3 or later.\nhttps://github.com/kramlat/OpenQBORG\n\n"
					+ "Page engine: %s\nExtra audio formats: %s" % [
						"godot-cef (Chromium)" if HtmlView.cef_available() else "not installed",
						"FFmpeg " + ClassDB.class_call_static("FFmpegAudioDecoder", "ffmpeg_version")
								if BorgAudio.has_ffmpeg() else "not installed"])
		_:
			if id >= MenuId.BOOKMARK_BASE and id - MenuId.BOOKMARK_BASE < bookmarks.items.size():
				tab.open_url(bookmarks.items[id - MenuId.BOOKMARK_BASE].url)


func _show_dialog(text: String) -> void:
	var d := AcceptDialog.new()
	d.title = "OpenQBORG"
	d.dialog_text = text
	d.dialog_autowrap = true
	d.min_size = Vector2i(360, 0)
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)
	add_child(d)
	d.popup_centered()


func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k := event as InputEventKey
	var id := -1
	if k.ctrl_pressed and k.keycode == KEY_T:
		id = MenuId.NEW_TAB
	elif k.ctrl_pressed and k.keycode == KEY_W:
		id = MenuId.CLOSE_TAB
	elif k.ctrl_pressed and k.keycode == KEY_TAB:
		id = MenuId.PREV_TAB if k.shift_pressed else MenuId.NEXT_TAB
	elif k.ctrl_pressed and k.keycode == KEY_PAGEDOWN:
		id = MenuId.NEXT_TAB
	elif k.ctrl_pressed and k.keycode == KEY_PAGEUP:
		id = MenuId.PREV_TAB
	elif k.ctrl_pressed and k.keycode == KEY_O:
		id = MenuId.OPEN_FILE
	elif k.ctrl_pressed and k.keycode == KEY_L:
		id = MenuId.OPEN_ADDRESS
	elif k.ctrl_pressed and k.keycode == KEY_D:
		id = MenuId.ADD_BOOKMARK
	elif k.ctrl_pressed and k.keycode == KEY_Q:
		id = MenuId.QUIT
	elif k.keycode == KEY_F5:
		id = MenuId.RELOAD
	elif k.alt_pressed and k.keycode == KEY_LEFT:
		id = MenuId.BACK
	if id >= 0 and active_tab() != null:
		_on_menu(id)
		get_viewport().set_input_as_handled()
