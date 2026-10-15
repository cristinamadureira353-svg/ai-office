"""Default checks never run a game loop against real credentials or saves."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

from runtime import godot_path

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    print('+ ' + ' '.join(str(c) for c in command), flush=True)
    subprocess.run([str(c) for c in command], cwd=ROOT, check=True, **kwargs)


def run_godot(executable, *arguments):
    env = {**os.environ, 'AI_OFFICE_PORT': '65499'}
    result = subprocess.run([executable, '--headless', '--path', str(ROOT / 'godot'), *arguments],
                            cwd=ROOT, env=env, text=True, capture_output=True, timeout=120)
    output = re.sub(r'\x1b\[[0-9;]*m', '', result.stdout + result.stderr)
    print(output, flush=True)
    allowed = ('Parse JSON failed', 'ObjectDB instances leaked at exit', 'resources still in use at exit')
    relevant = '\n'.join(line for line in output.splitlines() if not any(a in line for a in allowed))
    if result.returncode or re.search(r'SCRIPT ERROR|Parse Error|Failed to load|ERROR:', relevant):
        raise SystemExit('Godot validation failed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--godot', action='store_true', help='Also import and run headless Godot tests')
    args = parser.parse_args()
    run([sys.executable, ROOT / 'tools/check_repository.py'])
    for test in sorted((ROOT / 'ai-model-party/tests').glob('test_*.py')):
        run([sys.executable, ROOT / 'tools/offline_test.py', test],
            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
    if args.godot:
        executable = godot_path()
        run_godot(executable, '--editor', '--import')
        for test in sorted((ROOT / 'godot/tests').glob('t_*.gd')):
            run_godot(executable, '--script', 'res://tests/' + test.name)
    print('All requested checks passed.', flush=True)


if __name__ == '__main__':
    main()
