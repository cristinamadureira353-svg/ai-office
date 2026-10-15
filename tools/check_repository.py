"""Check files eligible for publication; report paths/rules, never secret values."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {'.git', '.godot', '.venv', 'venv', 'node_modules', '__pycache__', 'build', 'dist'}


def publishable_files():
    result = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                            cwd=ROOT, capture_output=True)
    if result.returncode == 0:
        return sorted({ROOT / name.decode() for name in result.stdout.split(b'\0') if name})
    return sorted(p for p in ROOT.rglob('*') if p.is_file() and not any(part in IGNORED for part in p.relative_to(ROOT).parts))


def check():
    failures = []
    rules = {
        'private-machine-path': re.compile(rb'(?:/Users/|/home/)[A-Za-z0-9_.-]+/'),
        'provider-secret': re.compile(rb'\bsk-(?:or-v1-)?[A-Za-z0-9_-]{24,}'),
        'github-token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})'),
        'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    }
    files = publishable_files()
    local_username = Path.home().name
    username_pattern = None if local_username.lower() in {'root', 'runner', 'user', 'admin'} else re.compile(
        rb'(?<![A-Za-z0-9_-])' + re.escape(local_username.encode()) + rb'(?![A-Za-z0-9_-])', re.I)
    for path in files:
        relative = path.relative_to(ROOT)
        if path.is_symlink() or not path.is_file():
            failures.append((str(relative), 'symlink-or-missing-file'))
            continue
        if path.name in ('.DS_Store', '.env') or path.suffix in ('.log', '.pyc', '.pck', '.wasm', '.zip') \
                or any(part in IGNORED for part in relative.parts):
            failures.append((str(relative), 'private-or-generated-file'))
        data = path.read_bytes()
        if username_pattern and username_pattern.search(data):
            failures.append((str(relative), 'local-username'))
        if len(data) > 50 * 1024 * 1024:
            failures.append((str(relative), 'file-too-large-for-source'))
        for name, pattern in rules.items():
            if pattern.search(data):
                failures.append((str(relative), name))
        if path.name in ('.env.example', 'env.example'):
            for line in data.decode().splitlines():
                if line and not line.startswith('#') and '=' in line and line.split('=', 1)[1].strip():
                    failures.append((str(relative), 'nonempty-example-value'))
    for name in ('README.md', 'README.en.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'SECURITY.md'):
        if not (ROOT / name).is_file():
            failures.append((name, 'required-document-missing'))
    license_file = ROOT / 'LICENSE'
    if license_file.is_file() and ('No public redistribution' in license_file.read_text()):
        failures.append(('LICENSE', 'public-license-not-selected'))
    source = ROOT / 'godot/assets/cozy_office'
    manifest = json.loads((source / 'manifest.json').read_text())
    for atlas in manifest['png_atlases']:
        path = source / atlas['file']
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != atlas['sha256']:
            failures.append((str(path.relative_to(ROOT)), 'atlas-hash-mismatch'))
    for asset in manifest['assets']:
        if not (ROOT / 'godot' / asset['resource'].removeprefix('res://')).is_file():
            failures.append((asset['resource'], 'asset-resource-missing'))
    if (ROOT / 'godot/data/scene_layout.json').read_bytes() != (ROOT / 'ai-model-party/data/office_layout_v2.json').read_bytes():
        failures.append(('godot/data/scene_layout.json', 'backend-layout-mismatch'))
    versions = [json.loads((ROOT / name).read_text())['version'] for name in (
        'package.json', 'miniapps/ai-office/package.json', 'miniapps/ai-office/.minimax-plugin/plugin.json')]
    if len(set(versions)) != 1:
        failures.append(('package.json', 'version-mismatch'))
    for path, rule in failures:
        print('FAIL', rule, path)
    if failures:
        raise SystemExit(1)
    print('Repository checks passed:', len(files), 'publishable files; art/layout/version checks passed.')


if __name__ == '__main__':
    check()
