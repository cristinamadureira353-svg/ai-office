"""Check that publication excludes secrets, including force-staged env files."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('publication_guard', ROOT / 'tools/check_repository.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class PublicationGuardTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='ai-office-publication-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for name in ('README.md', 'README.en.md', 'THIRD_PARTY_NOTICES.md', 'SECURITY.md'):
            self.write(name, 'Synthetic test document\n')
        self.write('LICENSE', 'MIT License\n')
        self.write('.gitignore', (ROOT / '.gitignore').read_text())
        for name in ('package.json', 'miniapps/ai-office/package.json', 'miniapps/ai-office/.minimax-plugin/plugin.json'):
            self.write(name, json.dumps({'version': '0.5.10'}))
        self.write('godot/assets/cozy_office/manifest.json', json.dumps({'png_atlases': [], 'assets': []}))
        for name in ('godot/data/scene_layout.json', 'ai-model-party/data/office_layout_v2.json'):
            self.write(name, '{}\n')
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def result(self):
        output = io.StringIO()
        code = 0
        with patch.object(guard, 'ROOT', self.root), redirect_stdout(output):
            try:
                guard.check()
            except SystemExit as error:
                code = error.code
        return code, output.getvalue()

    def test_clean_source_passes(self):
        self.assertEqual(self.result()[0], 0)

    def test_secret_in_regular_source_fails_without_echoing_value(self):
        secret = 'sk-or-v1-' + 'a' * 40
        self.write('example.txt', secret)
        code, output = self.result()
        self.assertEqual(code, 1)
        self.assertIn('provider-secret', output)
        self.assertNotIn(secret, output)

    def test_ignored_env_is_local_but_force_staged_env_fails(self):
        self.write('.env', 'MINIMAX_API_KEY=synthetic-local-value\n')
        self.assertEqual(self.result()[0], 0)
        subprocess.run(['git', 'add', '-f', '.env'], cwd=self.root, check=True)
        code, output = self.result()
        self.assertEqual(code, 1)
        self.assertIn('private-or-generated-file', output)
        self.assertNotIn('synthetic-local-value', output)

    def test_private_machine_path_fails(self):
        self.write('example.txt', '/Users/' + 'example-user/private/file.txt')
        code, output = self.result()
        self.assertEqual(code, 1)
        self.assertIn('private-machine-path', output)

    def test_nonempty_key_example_fails(self):
        self.write('ai-model-party/.env.example', 'MINIMAX_API_KEY=synthetic-value\n')
        code, output = self.result()
        self.assertEqual(code, 1)
        self.assertIn('nonempty-example-value', output)

    def test_local_username_literal_fails_without_echoing_it(self):
        username = 'synthetic-private-user-9'
        self.write('example.txt', username)
        with patch.object(guard.Path, 'home', return_value=Path('/home') / username):
            code, output = self.result()
        self.assertEqual(code, 1)
        self.assertIn('local-username', output)
        self.assertNotIn(username, output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
