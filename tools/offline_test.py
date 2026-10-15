"""Run one Python suite with temporary data and all HTTP requests blocked."""
import os
from pathlib import Path
import runpy
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python tools/offline_test.py <test.py>')
    test_file = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='ai-office-check-') as directory:
        sandbox = Path(directory)
        env_file = sandbox / 'empty.env'
        env_file.write_text('# isolated check\n')
        os.environ['AI_OFFICE_ENV_PATH'] = str(env_file)
        os.environ['AI_OFFICE_SAVE_DIR'] = str(sandbox / 'saves')
        for key in ('MINIMAX_API_KEY', 'LONGCAT_API_KEY', 'KIMI_API_KEY',
                    'STEPFUN_API_KEY', 'OPENROUTER_API_KEY'):
            os.environ[key] = ''
        import requests

        def denied(*args, **kwargs):
            raise AssertionError('Network requests are disabled in offline checks')

        requests.sessions.Session.request = denied
        sys.argv = [str(test_file)]
        runpy.run_path(str(test_file), run_name='__main__')


if __name__ == '__main__':
    main()
