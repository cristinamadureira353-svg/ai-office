import { mkdtemp, writeFile, chmod, mkdir, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createServer } from 'node:net';
import { pathToFileURL } from 'node:url';

export async function fixture({relocate=false,resting=false,initialSave=''}={}) {
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
# ★旧的客户/冲突玩法已下线：Game.Client、clients、slots、conflicts 都没了，
# 这里不再注入任何客户——想测旧档行为就手搓 v1 存档字典（见 legacySave）。
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
    async dispose() { await runtime.dispose(); },
    async restart() { runtime = await module.start(context); }
  };
}

/**
 * 手搓一份 v1（旧模拟经营玩法）格式的存档字典。
 *
 * 新后端把客户系统整个下线了（Game.Client / clients / slots / conflicts 都没了），
 * 没法再靠 Game 类造出一份"带客户和冲突"的旧档，只能按旧 save.py 的
 * snapshot() 形状直接拼一个 dict：
 *   · 3 个客户（含 1 个冲突中的）
 *   · 1 个冲突 id
 *   · money / rep / neg_days / game_over_reason（破产那套）
 *   · 员工身上指向客户的 job / working / need / busy / eff，和一条"去接待处"的指令
 *
 * @param workers 当前 /api/state 里的 5 个员工（用来取真实的站位与初始体力/心情）
 */
export function legacySave(workers, {day=3, tick=81175, money=869, rep=59}={}) {
  const client = (id, slot, status, servedBy, result=null) => ({
    id, task: '测试订单' + slot, kind: 'document', persona: 'normal',
    reward: 200, patience_max: 150, patience: 120, slot,
    served_by: servedBy, status, result, grab_tick: 0, pos: [3 + slot, 4],
  });
  return {
    format: 1,
    name: '旧版存档',
    auto: false,
    why: '旧版模拟经营存档',
    saved_at: Date.now() / 1000,
    saved_at_str: '2026-01-02 03:04:05',
    day, tick, day_start: 0,
    money, rep, neg_days: 3,
    game_over_reason: '资金为负连续 3 天',
    workers: workers.map((w, i) => ({
      who: w.id,
      pos: [w.x, w.y],
      stamina: w.stamina,
      mood: w.mood,
      // 前两个人手上还挂着客户的活，第三个人正准备去接待处接单
      job: i < 2 ? 'legacy-' + i : null,
      working: i < 2 ? 12 : 0,
      need: i < 2 ? 30 : 0,
      order: i === 2 ? ['goto', ['reception', null]] : null,
      acting: i < 2 ? '干活中' : (i === 2 ? '去接待处' : '在工位待命'),
      busy: i < 2,
      seated: false, seat_cmd: false,
      fatigue: 0, strike_days: 0, quit: false, strike: false,
      eff: i < 2 ? 0.8 : 1.0,
      worked_today: false, off_today: false,
      brain_down: false, brain_reason: '', brain_scope: 'model',
    })),
    clients: [
      client('legacy-0', 0, '服务中', 'm3'),
      client('legacy-1', 1, '待验收', 'longcat', '完整测试交付物1'),
      client('legacy-2', 2, '冲突中', null),
    ],
    finished: [client('legacy-3', 3, '已完成', 'step5', '完整测试交付物3')],
    slots: {'0': 'legacy-0', '1': 'legacy-1', '2': 'legacy-2'},
    conflicts: ['legacy-2'],
    conflict_data: {'legacy-2': {
      a: 'm3', b: 'flash', task: '测试订单2', client: 'legacy-2', judged: false,
      lines: [{who: 'm3', text: '我有现成模板，今晚就能跑通。'},
              {who: 'flash', text: '我比他更合适，这单给我。'}],
    }},
    relations: {}, cf_store: {}, bt_store: {}, blame_store: {},
    events: [], log: [], failures: [], banters: [],
    last_settle: null, meeting: null,
    rng: null,
  };
}

/**
 * 把一份存档字典写进 Host 数据目录的 saves/ 下，返回存档 id。
 * 存档目录由 miniapp_bridge.py 按 --data-dir 建，路径与 SAVE_DIR 一致。
 */
export async function writeSave(f, id, save) {
  const dir = join(f.dataDir, 'saves');
  await mkdir(dir, {recursive: true});
  await writeFile(join(dir, id + '.json'), JSON.stringify(save, null, 2), 'utf8');
  return id;
}
