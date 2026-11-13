import { mkdtemp, writeFile, chmod, mkdir, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createServer } from 'node:net';
import { pathToFileURL } from 'node:url';

export async function fixture({relocate=false,client=false,resting=false,conflict=false,initialSave=''}={}) {
  let pluginRoot = resolve(process.env.AI_OFFICE_TEST_PLUGIN);
  const python = process.env.AI_OFFICE_TEST_PYTHON;
  if (!python) throw new Error('Set AI_OFFICE_TEST_PYTHON to the existing venv interpreter');
  const scratch = await mkdtemp(join(tmpdir(), 'ai-office-miniapp-test-'));
  if (relocate) {
    const relocated = join(scratch, 'New Player Installed App');
    await cp(pluginRoot, relocated, {recursive:true});
    pluginRoot = relocated;
  }
  const dataDir = join(scratch, 'private');
  await mkdir(dataDir);
  const pythonPath = join(scratch, 'python'), envFile = join(scratch, 'empty.env');
  await writeFile(envFile, '# isolated fake API configuration\n');
  await writeFile(pythonPath, `#!${python}
import json, os, pathlib, runpy, sys
if sys.argv[1:2] == ['-c']:
    exec(sys.argv[2])
    raise SystemExit(0)
bridge = pathlib.Path(sys.argv[2])
sys.path.insert(0, str(bridge.parent))
data = pathlib.Path(sys.argv[sys.argv.index('--data-dir') + 1])
os.environ['AI_OFFICE_ENV_PATH'] = sys.argv[sys.argv.index('--env-file') + 1]
os.environ['AI_OFFICE_SAVE_DIR'] = str(data / 'saves')
os.environ['OPENROUTER_API_KEY'] = ''
import providers as P
for item in P.PROVIDERS.values(): os.environ[item['key_env']] = 'fake-test-key'
import requests
def denied(*args, **kwargs):
    (data / 'network-attempt').write_text('blocked')
    raise AssertionError('No paid network requests permitted')
requests.sessions.Session.request = denied
def fake(who, text, **kwargs):
    with (data / 'calls.jsonl').open('a') as log:
        log.write(json.dumps({'who':who, 'text':text}, ensure_ascii=False) + '\\n')
    if who == 'kimi' and not (data / 'quota-restored').exists():
        yield P.error_event(who, 429, {'error':{'type':'exceeded_current_quota_error'}})
        return
    for text in ['在', '的，', '老板找我啥事']:
        yield {'type':'delta', 'who':who, 'text':text}
    yield {'type':'done', 'who':who}
P.stream_chat = fake
import game as G, game_app as API
API.boot = lambda: None
if ${resting ? 'True' : 'False'}:
    for who, spot in G.REST_SPOTS['slack'].items():
        employee = G.GAME.workers[who]
        employee.pos, employee.acting = spot, '在摸鱼'
        employee.path, employee.order = [], None
if ${client ? 'True' : 'False'}:
    customer = G.Client('帮我整理一份测试文档', 96, 200, 'document', 'normal')
    customer.status, customer.served_by, customer.slot = '服务中', 'm3', 0
    G.GAME.clients.append(customer)
    G.GAME.slots[0] = customer
    G.GAME.workers['m3'].job = customer.id
if ${conflict ? 'True' : 'False'}:
    def seed_conflict():
        with G.GAME._lock:
            G.GAME.clients.clear()
            G.GAME.conflicts.clear()
            for slot in G.GAME.slots: G.GAME.slots[slot] = None
            for employee in G.GAME.workers.values():
                employee.job, employee.order, employee.mood = None, None, 70
            customer = G.Client('帮我把这套流程跑通', 96, 200, 'document', 'normal')
            customer.status, customer.slot = '冲突中', 0
            G.GAME.clients.append(customer)
            G.GAME.slots[0] = customer
            G.GAME.conflicts[customer.id] = {
                'a':'m3', 'b':'flash', 'task':customer.task, 'client':customer.id, 'judged':False,
                'lines':[{'who':'m3','text':'我有现成模板，今晚就能跑通。'},
                         {'who':'flash','text':'我比他更合适，这单给我。'}]}
            for who in ('m3', 'flash'):
                employee = G.GAME.workers[who]
                employee.job, employee.acting = customer.id, '去理论'
    # 裁决仍走真实 Game.judge；仅隔离获胜后的付费交付线程。
    G.GAME._serve_client_thread = lambda *args: None
    seed_conflict()
    @API.app.before_request
    def fixture_requests():
        marker = data / 'reset-conflict'
        if marker.exists():
            marker.unlink()
            seed_conflict()
        if API.request.path == '/api/command':
            with (data / 'commands.jsonl').open('a') as log:
                log.write(json.dumps(API.request.get_json(silent=True), ensure_ascii=False) + '\\n')
(data / 'fixture-pid').write_text(str(os.getpid()))
sys.argv = [str(bridge)] + sys.argv[3:]
runpy.run_path(str(bridge), run_name='__main__')
`);
  await chmod(pythonPath, 0o700);
  const listen = { host:'127.0.0.1', port:await new Promise((resolvePort, reject) => {
    const socket = createServer(); socket.once('error', reject);
    socket.listen(0, '127.0.0.1', () => { const port = socket.address().port; socket.close(() => resolvePort(port)); });
  }) };
  const logs = [], signal = new AbortController();
  const logger = Object.fromEntries(['info','debug','warn','error'].map(level => [level, message => logs.push(message)]));
  const module = await import(pathToFileURL(process.env.AI_OFFICE_TEST_SERVER || join(pluginRoot, 'miniapp/node/server.mjs')));
  // Bot 引擎用的模拟 Agent：不联网、不调用真实模型，回复固定。
  // gate 用来把某次运行"卡住"在 turn.started 之后，好让画面里出现真实的 running/queued。
  const agentRuns = [];
  let gateClosed = false;
  let gateWaiters = [];
  const gate = {
    close() { gateClosed = true; },
    open() {
      gateClosed = false;
      const waiters = gateWaiters;
      gateWaiters = [];
      for (const release of waiters) release();
    },
    get closed() { return gateClosed; },
  };
  const agent = {
    async models() { return { models: [], default: { providerId: 'mock', modelId: 'mock-model' } }; },
    async run(input, options) {
      agentRuns.push({ text: input.text, sessionId: input.sessionId ?? null });
      const sessionId = input.sessionId ?? ('session-mock-' + agentRuns.length);
      const turnId = 'turn-mock-' + agentRuns.length;
      const reply = '（模拟回复）' + String(input.text ?? '').slice(0, 20);
      options?.onEvent?.({ type: 'turn.started', sessionId, turnId, model: { providerId: 'mock', modelId: 'mock-model' } });
      if (gateClosed) {
        await new Promise((release) => gateWaiters.push(release));
      }
      options?.onEvent?.({ type: 'text.delta', sessionId, turnId, text: reply });
      options?.onEvent?.({ type: 'message.committed', sessionId, turnId, text: reply });
      options?.onEvent?.({ type: 'turn.finished', sessionId, turnId, status: 'finished', text: reply });
      return { sessionId, turnId, status: 'finished', text: reply };
    },
    async reply() {},
    async answer() { return { sessionId: 'session-mock', status: 'finished', text: '（模拟回答）' }; },
  };
  const context = { pluginId:'ai-office', pluginRoot, dataDir, listen, logger, signal:signal.signal, agent };
  let runtime = await module.start(context);
  const base = 'http://' + listen.host + ':' + listen.port;
  const settings = { pythonPath, envFile, initialSave };
  const get = async path => (await fetch(base + path)).json();
  const post = (path, body) => fetch(base + path, { method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify(body) });
  const put = (path, body) => fetch(base + path, { method:'PUT', headers:{'content-type':'application/json'}, body:JSON.stringify(body) });
  const getText = async path => (await fetch(base + path)).text();
  /** 打开 MCP 会话，返回一个可直接调团队工具的 call(name, args)。 */
  const mcp = async () => {
    const init = await fetch(base + '/mcp/minimax-bot', {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } }),
    });
    const sessionId = init.headers.get('mcp-session-id');
    return async (name, args) => {
      const response = await fetch(base + '/mcp/minimax-bot', {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json', 'mcp-session-id': sessionId },
        body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name, arguments: args } }),
      });
      const payload = await response.json();
      if (payload.result?.isError) throw new Error(name + ' failed: ' + payload.result.content[0].text);
      return JSON.parse(payload.result.content[0].text);
    };
  };
  const panel = async () => (await get('/api/office/panel')).bot_panel;
  return { pluginRoot, scratch, dataDir, base, settings, get, post, put, getText, logs, agent, agentRuns, gate, mcp, panel,
    async resetConflict() {
      if (!conflict) throw new Error('Conflict fixture is required');
      await writeFile(join(dataDir, 'reset-conflict'), 'reset');
      return (await get('/api/state')).conflicts[0];
    },
    async dispose() { await runtime.dispose(); },
    async restart() { runtime = await module.start(context); }
  };
}
