"""Resolve developer tools without depending on one machine's paths."""
import os
from pathlib import Path
import shutil


def godot_path(requested=None):
    value = requested or os.environ.get('GODOT')
    if value:
        resolved = shutil.which(value) or str(Path(value).expanduser())
        if Path(resolved).is_file():
            return resolved
        raise SystemExit('Godot executable not found: ' + value)
    for command in ('godot', 'godot4'):
        if shutil.which(command):
            return shutil.which(command)
    for candidate in (Path('/Applications/Godot.app/Contents/MacOS/Godot'),
                      Path.home() / 'Applications/Godot.app/Contents/MacOS/Godot'):
        if candidate.is_file():
            return str(candidate)
    raise SystemExit('Install Godot 4.4.1; put it on PATH or set GODOT.')
