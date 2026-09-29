class_name BorgMusic
extends Node
## Background music for `mid` regions: Standard MIDI Files played through a
## General MIDI SoundFont with godot-midi-player (third_party/, MIT).
##
## The original CYBERWORLD browser went through Windows' GS wavetable synth,
## so a GS-compatible bank (GeneralUser GS, tools/fetch-assets.sh soundfont)
## sounds closest. The SoundFont is parsed once, on a worker thread.

signal status_changed(text: String)

## Searched in order; the first existing .sf2 wins.
const SOUNDFONT_DIRS := ["user://soundfonts", "res://soundfonts",
		"/usr/share/soundfonts", "/usr/share/sounds/sf2", "/usr/local/share/soundfonts"]
const PREFERRED := ["GeneralUser-GS.sf2", "GeneralUser GS.sf2", "FluidR3_GM.sf2", "default.sf2"]

var volume_db := -12.0
var current := ""
var _player: MidiPlayer
var _bank: Bank
var _thread: Thread
var _bank_ready := false
var _pending_smf: SMF.SMFData


static func find_soundfont() -> String:
	var env := OS.get_environment("OPENQBORG_SOUNDFONT")
	if not env.is_empty() and FileAccess.file_exists(env):
		return env
	for dir_path in SOUNDFONT_DIRS:
		var abs := ProjectSettings.globalize_path(dir_path)
		var dir := DirAccess.open(abs)
		if dir == null:
			continue
		for name in PREFERRED:
			if dir.file_exists(name):
				return abs.path_join(name)
		for f in dir.get_files():
			if f.to_lower().ends_with(".sf2"):
				return abs.path_join(f)
	return ""


func _ready() -> void:
	_player = preload("res://addons/midi/MidiPlayer.tscn").instantiate()
	_player.loop = true
	_player.volume_db = volume_db
	add_child(_player)
	var sf := find_soundfont()
	if sf.is_empty():
		status_changed.emit("No SoundFont found: MIDI music is off (tools/fetch-assets.sh soundfont)")
		return
	_thread = Thread.new()
	_thread.start(_load_bank.bind(sf))


func _load_bank(path: String) -> void:
	var result := SoundFont.new().read_file(path)
	if result.error != OK:
		call_deferred("_on_bank_loaded", null, path)
		return
	var bank := Bank.new()
	bank.read_soundfont(result.data)
	call_deferred("_on_bank_loaded", bank, path)


func _on_bank_loaded(bank: Bank, path: String) -> void:
	_thread.wait_to_finish()
	if bank == null:
		status_changed.emit("Could not read SoundFont " + path.get_file())
		return
	_bank = bank
	_player.bank = bank
	_bank_ready = true
	if _pending_smf != null:
		_start(_pending_smf)
		_pending_smf = null


## Switches music; "" stops it. Same URL keeps playing without restarting.
func play_url(url: String, fetcher: BorgFetcher) -> void:
	if url == current:
		return
	current = url
	_pending_smf = null
	_player.stop()
	if url.is_empty():
		return
	var bytes := await fetcher.fetch(url)
	if url != current or bytes.is_empty():
		return
	var parsed := SMF.new().read_data(bytes)
	if parsed.error != OK:
		status_changed.emit("Unreadable MIDI file: " + url.get_file())
		return
	if _bank_ready:
		_start(parsed.data)
	else:
		_pending_smf = parsed.data


func _start(smf: SMF.SMFData) -> void:
	_player.smf_data = smf
	_player.play()


func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
