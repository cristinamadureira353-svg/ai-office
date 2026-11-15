import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './fixture.mjs';

const ROLES = ['m3', 'flash', 'longcat', 'kimi', 'step5'];
const NAMES = ['M3', 'Flash', 'LongCat', 'Kimi', 'Step5'];

async function until(predicate, label, tries = 400) {
  for (let i = 0; i < tries; i++) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error('Timed out waiting for ' + label);
}

async function seedTeam(f) {
  for (const name of NAMES) {
    const created = await (await f.post('/api/bots', { name, role: '员工' })).json();
    assert.ok(created.bot?.id, 'created ' + name);
  }
}

test('the office panel reflects real Bot bindings, never a second task source', async t => {
  const f = await fixture();
  try {
    // 第一次读面板才会初始化引擎；此时还没有员工 Bot。
    const first = await f.panel();
    assert.equal(first.ready, true);
    assert.equal(first.chief.name, 'Chief');
    assert.deepEqual(first.bindings, {});
    assert.deepEqual(first.roles, ROLES);

    await seedTeam(f);
    const bound = await f.panel();
    // 工位按团队顺序随机分配（不再按名字猜），五个成员 Bot 正好占满五个工位。
    assert.deepEqual(Object.keys(bound.bindings).sort(), [...ROLES].sort(), 'every member Bot takes a desk');
    for (const role of ROLES) {
      assert.ok(bound.bindings[role], role + ' is bound to a real bot id');
    }
    assert.equal(Object.values(bound.bindings).includes(bound.chief.bot_id), false,
      'the Chief supervises instead of taking a desk');
    assert.equal(bound.staff.length, 5, 'five staff rows');
    assert.deepEqual(bound.empty_slots, [], 'no desk is waiting to be filled');
  } finally {
    await f.dispose();
  }
});

test('an office request is attributed to the batch it really produced', async t => {
  const f = await fixture();
  try {
    await seedTeam(f);
    const submitted = await (await f.post('/api/office/task', { text: '帮我拆一下新品发布方案' })).json();
    assert.equal(submitted.ok, true);
    assert.match(submitted.request_id, /^office:/);
    assert.equal(submitted.bound, 5);

    const call = await f.mcp();
    const receipt = await call('dispatch_tasks', {
      request_id: 'office-sim-attribution',
      tasks: [
        { to: 'M3', message: '写框架', title: '框架' },
        { to: 'Flash', message: '写文案', title: '文案' },
        { to: 'Kimi', message: '审风险', title: '风险' },
      ],
    });

    await until(async () => {
      const panel = await f.panel();
      return panel.requests.some(item => item.request_id === submitted.request_id && item.batch_id === receipt.batch_id);
    }, 'the request to be attributed to its batch');

    const panel = await f.panel();
    const batch = panel.batches.find(item => item.batch_id === receipt.batch_id);
    assert.ok(batch, 'the batch appears in the panel');
    assert.equal(batch.tasks.length, 3);
    // 面板不认识的状态不会被改写；状态字符串直接来自调度器。
    const allowed = new Set(['queued', 'running', 'waiting_for_tasks', 'waiting_for_user', 'paused', 'done', 'failed', 'cancelled', 'unknown']);
    for (const task of batch.tasks) {
      assert.ok(allowed.has(task.status), 'verbatim status: ' + task.status);
      assert.ok(task.bot_id, 'task names its real bot');
      assert.ok(task.title, 'task keeps its title');
    }
    // 同一时刻最多两个 running，其余真实排队。
    const running = batch.tasks.filter(task => task.status === 'running').length;
    assert.ok(running <= 2, 'no more than two tasks run at once, saw ' + running);
  } finally {
    await f.dispose();
  }
});

test('finished tasks carry real results and a cancelled batch is not reported as done', async t => {
  const f = await fixture();
  try {
    await seedTeam(f);
    const call = await f.mcp();
    const done = await call('dispatch_tasks', {
      request_id: 'office-sim-done',
      tasks: [{ to: 'M3', message: '写一段介绍', title: '写作' }],
    });
    await until(async () => {
      const panel = await f.panel();
      const batch = panel.batches.find(item => item.batch_id === done.batch_id);
      return batch?.complete === true && batch.tasks.every(task => task.status === 'done');
    }, 'the batch to finish');
    const panel = await f.panel();
    const batch = panel.batches.find(item => item.batch_id === done.batch_id);
    assert.equal(batch.tasks[0].status, 'done');
    assert.match(batch.tasks[0].result_preview, /模拟回复/, 'the panel shows a real result preview');
    assert.ok(batch.tasks[0].result_preview.length <= 200, 'preview stays short');

    // 取消是真实状态，不能被当成完成。
    const cancelled = await call('dispatch_tasks', {
      request_id: 'office-sim-cancel',
      tasks: [{ to: 'Kimi', message: '写很长的东西', title: '长文' }],
    });
    await call('cancel_tasks', { batch_id: cancelled.batch_id });
    await until(async () => {
      const current = await f.panel();
      const entry = current.batches.find(item => item.batch_id === cancelled.batch_id);
      return entry && entry.tasks.every(task => task.status !== 'running' && task.status !== 'queued');
    }, 'the cancelled batch to settle');
    const afterCancel = await f.panel();
    const entry = afterCancel.batches.find(item => item.batch_id === cancelled.batch_id);
    assert.equal(entry.tasks.some(task => task.status === 'done'), false, 'a cancelled task is never "done"');
  } finally {
    await f.dispose();
  }
});

test('a deleted Bot leaves a stale role instead of silently rebinding', async t => {
  const f = await fixture();
  try {
    await seedTeam(f);
    const before = await f.panel();
    const kimiId = before.bindings.kimi;
    assert.ok(kimiId);

    const removed = await fetch(f.base + '/api/bots/' + kimiId, { method: 'DELETE' });
    assert.equal(removed.status, 200);

    const after = await f.panel();
    assert.equal(after.bindings.kimi, undefined, 'the binding is cleared');
    assert.equal(after.stale.kimi, kimiId, 'the role records which Bot went away');
    // 其余绑定保持不动。
    assert.equal(after.bindings.m3, before.bindings.m3);
  } finally {
    await f.dispose();
  }
});

test('the game snapshot gains bot_panel without changing its own contract', async t => {
  const f = await fixture();
  try {
    await seedTeam(f);
    await f.post('/api/settings', f.settings);
    await until(async () => {
      const response = await fetch(f.base + '/api/state');
      return response.status === 200;
    }, 'the game backend to come up');

    const response = await fetch(f.base + '/api/state');
    const payload = await response.json();
    assert.equal(payload.version, 1, 'the game contract version is untouched');
    assert.equal(payload.gameplay_version, 6);
    assert.ok(Array.isArray(payload.workers), 'original fields still present');
    assert.ok(payload.bot_panel, 'bot_panel is attached when the Bot engine is ready');
    assert.equal(payload.bot_panel.ready, true);
    assert.deepEqual(Object.keys(payload.bot_panel.bindings).sort(), [...ROLES].sort());
  } finally {
    await f.dispose();
  }
});
