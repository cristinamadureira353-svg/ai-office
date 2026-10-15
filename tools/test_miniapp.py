"""Run the standalone plugin tests with isolated mock providers."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--plugin', type=Path, default=ROOT / 'build/miniapp/ai-office')
    parser.add_argument('--chromium', help='Optional local browser executable, always launched headless')
    args = parser.parse_args()
    plugin = args.plugin.resolve()
    if not (plugin / 'miniapp/node/assets.json').is_file():
        raise SystemExit('Build a complete MiniApp first; see docs/DEVELOPMENT.md')
    node = shutil.which('node')
    if not node:
        raise SystemExit('Node.js 22+ is required')
    env = {**os.environ, 'AI_OFFICE_TEST_PLUGIN': str(plugin), 'AI_OFFICE_TEST_PYTHON': sys.executable,
           'AI_OFFICE_TEST_NODE_MODULES': str(ROOT / 'node_modules'),
           'AI_OFFICE_TEST_EVIDENCE': str(ROOT / 'build/test-evidence')}
    if args.chromium:
        env['AI_OFFICE_TEST_CHROMIUM'] = args.chromium
    elif not env.get('AI_OFFICE_TEST_CHROMIUM'):
        browser = subprocess.run([node, '-p', "require('playwright').chromium.executablePath()"],
                                 cwd=ROOT, capture_output=True, text=True, check=True)
        env['AI_OFFICE_TEST_CHROMIUM'] = browser.stdout.strip()
    tests = sorted((plugin / 'tests').glob('*.test.mjs'))
    subprocess.run([node, '--test', '--test-concurrency=1', *map(str, tests)], cwd=ROOT, env=env, check=True)


if __name__ == '__main__':
    main()
