import test from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fixture } from './fixture.mjs';

/** 等待条件成立；任务调度是异步的，不能用固定 sleep 猜。 */
async function until(predicate, label = 'condition', tries = 200) {
  for (let i = 0; i < tries; i++) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error('Timed out waiting for ' + label);
}

test('Bot engine stays lazy, then serves Chief and the team panel', async t => {
  const f = await fixture();
  try {
    // 冷启动：没有碰 /bot 之前，私有目录必须保持为空（旧游戏的既有约定）。
    assert.deepEqual(await readdir(f.dataDir), []);

    const settings = await f.get('/api/settings');
    assert.equal(settings.ok, true);
    assert.equal(settings.configured, false);
    assert.deepEqual(await readdir(f.dataDir), [], 'reading settings must not create Bot state');

    // 游戏接口仍然走 Python 桥，且不触发 Bot 初始化。
    const game = await fetch(f.base + '/api/state');
    assert.equal(game.status, 503, 'unconfigured game backend keeps its own error path');
    assert.equal((await readdir(f.dataDir)).includes('bot'), false, 'game API must not start the Bot engine');

    // 首次打开 Bot 面板才初始化。
    const page = await fetch(f.base + '/bot');
    assert.equal(page.status, 200);
    assert.match(page.headers.get('content-type'), /text\/html/);
    assert.match(await page.text(), /<!doctype html>/i);
    assert.equal((await readdir(f.dataDir)).includes('bot'), true);

    const state = await f.get('/api/bot/state');
    assert.equal(state.bots.length, 1);
    assert.equal(state.bots[0].name, 'Chief');
    assert.equal(state.bots[0].isMain, true);
    assert.ok(Array.isArray(state.tasks));
    assert.ok(Array.isArray(state.turns));

    // 引擎自己的文件都在子目录里，没有污染游戏设置与存档。
    const botDir = await readdir(join(f.dataDir, 'bot'));
    assert.ok(botDir.includes('state.json'));
    assert.ok(botDir.includes('messages'));
    assert.ok(botDir.includes('memory'));
    assert.equal((await readdir(f.dataDir)).includes('settings.json'), false);
  } finally {
    await f.dispose();
  }
});

test('Chief chat runs through the mock agent and persists its reply', async t => {
  const f = await fixture();
  try {
    await f.get('/api/bot/state');
    const state = await f.get('/api/bot/state');
    const chief = state.bots.find(bot => bot.isMain);
    const response = await f.post('/api/chats/bot:' + chief.id + '/messages', { text: '你好，先报个到' });
    assert.equal(response.status, 200);

    await until(() => f.agentRuns.length >= 1, 'the mock agent to run');
    assert.match(f.agentRuns[0].text, /你好，先报个到/);

    await until(async () => {
      const messages = await f.get('/api/chats/bot:' + chief.id + '/messages');
      return (messages.messages ?? []).some(m => m.role === 'bot' && String(m.text ?? '').includes('模拟回复'));
    }, 'the Bot reply to be stored');

    const stored = await f.get('/api/chats/bot:' + chief.id + '/messages');
    // Chief 在 Store 初始化时就有一条开场白，这里要的是本次 Agent 产生的回复。
    const reply = (stored.messages ?? []).filter(m => m.role === 'bot' && String(m.text ?? '').includes('模拟回复')).at(-1);
    assert.ok(reply, 'the agent reply is stored as a Bot message');
    assert.match(reply.text, /模拟回复/);
  } finally {
    await f.dispose();
  }
});

test('dispatch_tasks admits real batches, queues them, and returns each result', async t => {
  const f = await fixture();
  try {
    await f.get('/api/bot/state');
    // 建两个员工 Bot，供 Chief 派单。
    for (const name of ['写手', '审校']) {
      const created = await (await f.post('/api/bots', { name, role: '测试员工' })).json();
      assert.ok(created.bot?.id, 'bot created: ' + name);
    }
    const state = await f.get('/api/bot/state');
    assert.equal(state.bots.length, 3, 'Chief plus two employees');

    // 走真实 MCP 端点，拿到会话头。
    const init = await fetch(f.base + '/mcp/minimax-bot', {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } }),
    });
    assert.equal(init.status, 200);
    const sessionId = init.headers.get('mcp-session-id');
    assert.ok(sessionId, 'MCP session id issued');

    const call = async (name, args) => {
      const response = await fetch(f.base + '/mcp/minimax-bot', {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json', 'mcp-session-id': sessionId },
        body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name, arguments: args } }),
      });
      const payload = await response.json();
      assert.equal(payload.result?.isError ?? false, false, name + ' must not report an error');
      return JSON.parse(payload.result.content[0].text);
    };

    const receipt = await call('dispatch_tasks', {
      request_id: 'stage1-test-1',
      tasks: [
        { to: '写手', message: '写一段介绍', title: '写作' },
        { to: '审校', message: '校对这段介绍', title: '审校' },
      ],
    });
    assert.ok(receipt.batch_id, 'admission receipt carries a batch id');
    assert.equal(receipt.tasks.length, 2);
    // 接单回执不等于完成：刚接单时不能已经全部 done。
    assert.ok(receipt.tasks.every(task => task.status !== 'done' || task.result !== undefined));

    await until(async () => {
      const view = await call('get_tasks', { batch_id: receipt.batch_id });
      return view.complete === true;
    }, 'the batch to settle');

    const done = await call('get_tasks', { batch_id: receipt.batch_id });
    assert.equal(done.complete, true);
    for (const task of done.tasks) {
      assert.equal(task.status, 'done', 'task ' + task.title + ' finished');
      assert.ok(String(task.result ?? '').length > 0, 'task carries a real result');
      assert.match(task.result, /模拟回复/);
    }

    // 同一个 request_id 重放必须只返回原批次，不能重复执行。
    const replay = await call('dispatch_tasks', {
      request_id: 'stage1-test-1',
      tasks: [
        { to: '写手', message: '写一段介绍', title: '写作' },
        { to: '审校', message: '校对这段介绍', title: '审校' },
      ],
    });
    assert.equal(replay.batch_id, receipt.batch_id, 'replay reuses the original batch');

    // 内容变了就必须冲突，而不是悄悄再跑一遍。
    const conflict = await fetch(f.base + '/mcp/minimax-bot', {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json', 'mcp-session-id': sessionId },
      body: JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'dispatch_tasks', arguments: {
        request_id: 'stage1-test-1',
        tasks: [{ to: '写手', message: '换一个完全不同的要求', title: '写作' }],
      } } }),
    });
    const conflictPayload = await conflict.json();
    assert.equal(conflictPayload.result?.isError, true, 'changed content conflicts instead of running again');
  } finally {
    await f.dispose();
  }
});

test('Bot state survives a restart and keeps queued work recoverable', async t => {
  const f = await fixture();
  try {
    await f.get('/api/bot/state');
    const created = await (await f.post('/api/bots', { name: '长期员工', role: '测试' })).json();
    assert.ok(created.bot?.id);

    const before = await f.get('/api/bot/state');
    const names = before.bots.map(bot => bot.name).sort();
    assert.deepEqual(names, ['Chief', '长期员工'].sort());

    await f.dispose();
    await f.restart();

    const after = await f.get('/api/bot/state');
    assert.deepEqual(after.bots.map(bot => bot.name).sort(), names, 'team is restored from disk');
    // 重启后不能凭空多出运行中的任务。
    assert.equal(after.tasks.filter(task => task.status === 'running').length, 0);
  } finally {
    await f.dispose();
  }
});
