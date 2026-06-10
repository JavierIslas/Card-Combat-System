# Card Combat Engine
# Copyright (C) 2026 Javier Islas
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version. This program is distributed WITHOUT ANY WARRANTY; see the GNU
# AGPL for details: <https://www.gnu.org/licenses/>.
#
# A commercial license that exempts you from the AGPL is available: see
# LICENSE_COMMERCIAL.md or contact islasjavieralf@gmail.com.

extends SceneTree
## Headless compile gate for the whole engine source. Runs --check-only over every
## GDScript under the addon and fails (exit 1) if any one does not compile (parse or
## type error).
##
## Why this exists: the GUT suite only compiles the code its tests reach, so a parse
## error in an unreferenced file (examples/, benchmark/, tools/) would ship
## unnoticed. This gate covers the entire engine surface in one command.
##
## Why a subprocess instead of load()/reload(): in-process primitives are
## unreliable here. load() returns a non-null GDScript even for a file with a parse
## error (false negative); GDScript.reload() on isolated source fails to resolve the
## project's class_name registry and reports a parse error for valid files (false
## positive). Only `--check-only`, which loads the full project context, is exact —
## so the gate shells out to the running binary (OS.get_executable_path) per file.
##
## Scope note (honest limitation): the Godot headless runtime does NOT surface
## GDScript analyzer warnings (unused/shadowed/unsafe/...), only hard compile
## errors. Warning-as-error enforcement is therefore EDITOR-only (see the [debug]
## section in project.godot). This gate is the achievable CI half: no broken script
## ships, even if no test imports it.
##
## Run: godot --headless --path . --script addons/card_combat/tools/check_scripts.gd

const ENGINE_ROOT := "res://addons/card_combat"


func _initialize() -> void:
	var files: PackedStringArray = []
	_collect_gd(ENGINE_ROOT, files)
	files.sort()
	# Zero scripts means the gate did not actually check anything (missing/renamed
	# ENGINE_ROOT) — that is a failure, never a green run.
	if files.is_empty():
		printerr("=== COMPILE GATE FAILED: no scripts found under %s ===" % ENGINE_ROOT)
		quit(1)
		return
	print("=== Engine compile gate (%d scripts) ===" % files.size())

	var bin: String = OS.get_executable_path()
	var failed: PackedStringArray = []
	for path in files:
		if _compiles(bin, path):
			print("  ok    %s" % path)
		else:
			failed.append(path)
			print("  FAIL  %s" % path)

	if failed.is_empty():
		print("=== OK: all %d scripts compile ===" % files.size())
		quit(0)
	else:
		printerr("=== COMPILE GATE FAILED: %d script(s) did not compile ===" % failed.size())
		for f in failed:
			printerr("  - %s" % f)
		quit(1)


func _compiles(bin: String, path: String) -> bool:
	## True when `--check-only` accepts the script (exit 0). The subprocess inherits
	## the project (`--path .`) so cross-file class_name references resolve.
	var output: Array = []
	var code: int = OS.execute(bin, ["--headless", "--path", ".", "--check-only", "--script", path], output, true)
	return code == 0


func _collect_gd(dir_path: String, out: PackedStringArray) -> void:
	## Recurse the addon tree collecting every .gd, skipping hidden directories.
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		var full: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_collect_gd(full, out)
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
