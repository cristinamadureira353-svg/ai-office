"""Jev 未配置时不请求外网；已配置时保留现有调度。"""
import os,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock,patch
scratch=tempfile.TemporaryDirectory(prefix='ai-office-scheduler-')
env=Path(scratch.name)/'empty.env';env.write_text('# isolated test\n')
os.environ['AI_OFFICE_ENV_PATH']=str(env)
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import game as G

class OptionalSchedulerTests(unittest.TestCase):
    def test_missing_key_sends_no_request(self):
        with patch.dict(os.environ,{},clear=True),patch.object(G.requests,'post') as post:
            G.Game().jev_decide();post.assert_not_called()
    def test_empty_or_whitespace_key_sends_no_request(self):
        for key in ('','   '):
            with self.subTest(key=repr(key)),patch.dict(os.environ,{'OPENROUTER_API_KEY':key}),patch.object(G.requests,'post') as post:
                G.Game().jev_decide();post.assert_not_called()
    def test_configured_key_still_dispatches_the_model_choice(self):
        response=Mock(status_code=200);response.json.return_value={'answers':{'m3':{'choice':'desk'}}}
        with patch.dict(os.environ,{'OPENROUTER_API_KEY':'fake-test-key'}),patch.object(G.requests,'post',return_value=response) as post:
            game=G.Game();game.jev_decide();post.assert_called_once()
            self.assertEqual(game.workers['m3'].order,('goto',('desk','m3')))

if __name__=='__main__':
    try:unittest.main(verbosity=2)
    finally:scratch.cleanup()
