#!/usr/bin/env python3
"""导出独立 MiniApp，原素材、存档、API 配置及既有包均不覆盖。"""
import argparse
import gzip
import hashlib
import json
import mimetypes
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from runtime import godot_path
MODULES = ('game', 'game_app', 'providers', 'scheduler', 'save', 'relations',
           'stats', 'banter', 'blame_game', 'miniapp_bridge')


def run(command, log):
    result = subprocess.run([str(c) for c in command], capture_output=True, text=True, timeout=300)
    output = result.stdout + result.stderr
    log.write_text(output)
    if result.returncode or 'SCRIPT ERROR' in output or 'Parse Error' in output:
        raise RuntimeError('Godot 导出未通过，查看 ' + str(log))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--godot', help='Godot executable; defaults to GODOT or PATH')
    args = parser.parse_args()
    godot = godot_path(args.godot)
    output = args.output.resolve()
    if output.exists():
        raise SystemExit('输出目录已存在；请选择新目录以保留旧包。')
    output.mkdir(parents=True)
    plugin = output / 'ai-office'
    shutil.copytree(ROOT / 'miniapps/ai-office', plugin,
                    ignore=shutil.ignore_patterns('.DS_Store', '__pycache__', '*.pyc', 'node_modules'))
    shutil.copy2(ROOT / 'LICENSE', plugin / 'LICENSE')
    shutil.copy2(ROOT / 'THIRD_PARTY_NOTICES.md', plugin / 'THIRD_PARTY_NOTICES.md')
    shutil.copy2(ROOT / 'LICENSES/Godot-MIT.txt', plugin / 'LICENSE-GODOT.txt')
    shutil.copy2(ROOT / 'LICENSES/Godot-COPYRIGHT.txt', plugin / 'COPYRIGHT-GODOT.txt')
    export = output / 'web-export'
    export.mkdir()
    run([godot, '--headless', '--path', ROOT / 'godot', '--editor', '--import'], output / 'import.log')
    run([godot, '--headless', '--path', ROOT / 'godot', '--export-release',
         'MiniApp Web', export / 'game.html'], output / 'export.log')
    client = plugin / 'miniapp/client'
    game = client / 'game'
    game.mkdir(exist_ok=True)
    for file in export.iterdir():
        if file.is_file():
            shutil.copy2(file, game / file.name)
    shutil.copy2(export / 'game.icon.png', plugin / 'icon.png')
    shutil.copy2(ROOT / 'godot/assets/fonts/OFL.txt', plugin / 'LICENSE-NOTO.txt')
    backend = plugin / 'miniapp/node/backend'
    (backend / 'server').mkdir(parents=True)
    (backend / 'data').mkdir()
    for module in MODULES:
        shutil.copy2(ROOT / 'ai-model-party/server' / (module + '.py'), backend / 'server')
    shutil.copy2(ROOT / 'ai-model-party/data/office_layout_v2.json', backend / 'data')
    assets = {}
    for file in sorted(client.rglob('*')):
        if not file.is_file():
            continue
        relative = file.relative_to(client).as_posix()
        kind = 'application/wasm' if file.suffix == '.wasm' else (
            'application/octet-stream' if file.suffix == '.pck' else
            mimetypes.guess_type(file.name)[0] or 'application/octet-stream')
        raw = file.read_bytes()
        asset = {'type': kind, 'bytes': len(raw), 'file': relative}
        if file.suffix in ('.wasm', '.pck'):
            compressed = gzip.compress(raw, compresslevel=9, mtime=0)
            asset.update(gzip=True, bytes=len(compressed))
            file.unlink()
            if len(compressed) <= 16 * 1024 * 1024:
                target = file.with_suffix(file.suffix + '.gz')
                target.write_bytes(compressed)
                asset['file'] = target.relative_to(client).as_posix()
            else:
                asset.pop('file')
                asset['parts'] = []
                for i, offset in enumerate(range(0, len(compressed), 8 * 1024 * 1024)):
                    part = file.with_suffix(file.suffix + '.gz.part%03d' % i)
                    part.write_bytes(compressed[offset:offset + 8 * 1024 * 1024])
                    asset['parts'].append(part.relative_to(client).as_posix())
        assets['/' + relative] = asset
    (plugin / 'miniapp/node/assets.json').write_text(json.dumps(assets, indent=2))
    files = []
    for file in sorted(plugin.rglob('*')):
        if file.is_file():
            size = file.stat().st_size
            if size > 16 * 1024 * 1024:
                raise RuntimeError('单文件超过 MiniApp 限制：' + str(file))
            files.append({'path': file.relative_to(plugin).as_posix(), 'bytes': size,
                          'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
    total = sum(file['bytes'] for file in files)
    if len(files) > 1024 or total > 64 * 1024 * 1024:
        raise RuntimeError('安装包超过 MiniApp 限制')
    version = json.loads((plugin / 'package.json').read_text())['version']
    archive = output / ('ai-office-miniapp-' + version + '.zip')
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
        for file in files:
            package.write(plugin / file['path'], 'ai-office/' + file['path'])
    manifest = {'plugin': str(plugin), 'plugin_version': version, 'gameplay_version': 5, 'total_bytes': total,
                'file_count': len(files), 'files': files,
                'archive': str(archive), 'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}
    (output / 'build-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    print('MiniApp:', plugin)
    print('文件数:', len(files), '总大小:', total, 'bytes')
    print('ZIP:', archive)


if __name__ == '__main__':
    main()
