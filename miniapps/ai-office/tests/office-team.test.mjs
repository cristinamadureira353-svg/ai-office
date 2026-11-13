import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { OfficeMap, OFFICE_ROLES } from '../miniapp/node/office_map.mjs';
import { fixture } from './fixture.mjs';

const MEMBERS = [
  { name: '前端', role: '前端开发' },
  { name: '后端', role: '后端开发' },
  { name: '审查', role: '代码审查' },
];

async function until(predicate, label, tries = 400) {
  for (let i = 0; i < tries; i++) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error('Timed out waiting for ' + label);
}

async function seedMembers(f) {
  const created = [];
  for (const member of MEMBERS) {
    const payload = await (await f.post('/api/bots', member)).json();
    assert.ok(payload.bot?.id, 'created ' + member.name);
    created.push(payload.bot);
  }
  return created;
}

async function freshMap(bots) {
  const dir = await mkdtemp(join(tmpdir(), 'ai-office-office-map-'));
  const map = new OfficeMap(dir);
  await map.init();
  await map.reconcile(bots);
  return map;
}

test('the Chief supervises and never takes a desk', async t => {
  const f = await fixture();
  try {
    const members = await seedMembers(f);
    const panel = await f.panel();

    assert.equal(panel.chief.name, 'Chief');
    assert.equal(panel.staff.length, 3, 'three member Bots, three desks');
    assert.equal(panel.empty_slots.length, 2, 'two desks are still free');
    assert.deepEqual(panel.staff.map(item => item.name).sort(), ['前端', '后端', '审查'].sort(),
      'the desk shows the real Bot name');
    assert.deepEqual(panel.staff.map(item => item.role).sort(), ['前端开发', '后端开发', '代码审查'].sort(),
      'the desk shows the real Bot role');
    // Chief 不占工位
    assert.equal(Object.values(panel.bindings).includes(panel.chief.bot_id), false,
      'the Chief is not bound to any desk');
    // 每个 Bot 一个工位，工位不重复
    const slots = panel.staff.map(item => item.slot);
    assert.equal(new Set(slots).size, slots.length, 'no desk is used twice');
    for (const slot of slots) assert.ok(OFFICE_ROLES.includes(slot), slot + ' is a real desk');
    const botIds = panel.staff.map(item => item.bot_id);
    assert.equal(new Set(botIds).size, botIds.length, 'no Bot sits at two desks');
    for (const bot of members) assert.ok(botIds.includes(bot.id), bot.name + ' has a desk');
    // 没配模型就是跟随宿主默认
    for (const item of panel.staff) {
      assert.equal(item.model_label, '跟随宿主默认', item.name + ' follows the Host default');
      assert.equal(item.status, 'idle', item.name + ' has no task yet');
    }
  } finally {
    await f.dispose();
  }
});

test('a desk keeps its Bot across a restart', async t => {
  const f = await fixture();
  try {
    await seedMembers(f);
    const before = await f.panel();
    assert.equal(before.staff.length, 3);

    await f.dispose();
    await f.restart();

    const after = await f.panel();
    assert.deepEqual(after.bindings, before.bindings, 'the desks are not shuffled again');
    assert.deepEqual(after.staff.map(item => item.slot), before.staff.map(item => item.slot));
    assert.deepEqual(after.staff.map(item => item.name).sort(), ['前端', '后端', '审查'].sort());
  } finally {
    await f.dispose();
  }
});

test('a deleted Bot releases its desk and it shows as waiting to be filled', async t => {
  const f = await fixture();
  try {
    await seedMembers(f);
    const before = await f.panel();
    const victim = before.staff.find(item => item.name === '审查');
    assert.ok(victim, '审查 has a desk');

    const removed = await fetch(f.base + '/api/bots/' + victim.bot_id, { method: 'DELETE' });
    assert.equal(removed.status, 200);

    const after = await f.panel();
    assert.equal(after.staff.length, 2, 'the desk is free');
    assert.equal(after.empty_slots.length, 3, 'the freed desk waits for someone');
    assert.ok(after.empty_slots.includes(victim.slot), 'the freed desk is the one that opened up');
    assert.equal(after.stale[victim.slot], victim.bot_id, 'the desk remembers who left');
    // 其余绑定不动
    for (const item of before.staff.filter(entry => entry.name !== '审查')) {
      assert.equal(after.bindings[item.slot], item.bot_id, item.name + ' keeps its desk');
    }
  } finally {
    await f.dispose();
  }
});

test('a rework note really reaches Chief', async t => {
  const f = await fixture();
  try {
    await seedMembers(f);
    const response = await f.post('/api/office/reject', {
      request_id: 'office-rework-1',
      reason: '文案不够好，换个说法',
    });
    const payload = await response.json();
    assert.equal(payload.ok, true);
    assert.equal(payload.delivered, true);
    assert.equal(payload.request_id, 'office-rework-1');

    await until(() => f.agentRuns.some(run => run.text.includes('上一版需要返工')),
      'the rework note to reach Chief');
    const run = f.agentRuns.find(entry => entry.text.includes('上一版需要返工'));
    assert.match(run.text, /文案不够好，换个说法/, 'Chief gets the player\'s own words');
  } finally {
    await f.dispose();
  }
});

test('an empty rework note is refused instead of sent', async t => {
  const f = await fixture();
  try {
    await seedMembers(f);
    const response = await f.post('/api/office/reject', { request_id: 'office-rework-2', reason: '   ' });
    assert.equal(response.status, 400);
    const payload = await response.json();
    assert.equal(payload.ok, false);
    assert.match(payload.msg, /返工|意见/);
    assert.equal(f.agentRuns.length, 0, 'nothing was sent to the model');
  } finally {
    await f.dispose();
  }
});

test('desks are handed out at random, and a binding is never reshuffled', async () => {
  const bots = [
    { id: 'bot_chief', name: 'Chief', isMain: true },
    { id: 'bot_a', name: '前端' },
    { id: 'bot_b', name: '后端' },
    { id: 'bot_c', name: '审查' },
    { id: 'bot_d', name: '测试' },
    { id: 'bot_e', name: '运维' },
  ];
  const pairings = new Set();
  for (let i = 0; i < 20; i++) {
    const map = await freshMap(bots);
    const bindings = map.bindings();
    assert.equal(Object.keys(bindings).length, 5, 'every member Bot gets a desk');
    assert.equal(Object.values(bindings).includes('bot_chief'), false, 'the Chief takes no desk');
    assert.equal(new Set(Object.values(bindings)).size, 5, 'no Bot sits at two desks');
    pairings.add(JSON.stringify(bindings));
  }
  assert.ok(pairings.size > 1, 'two offices do not get the same pairing');

  // 同一个办公室不会因为再看一次就换人。
  const map = await freshMap(bots);
  const first = map.bindings();
  await map.reconcile(bots);
  assert.deepEqual(map.bindings(), first, 'reading the roster again changes nothing');
});

test('a Bot that leaves frees its desk without moving anybody else', async () => {
  const map = await freshMap([
    { id: 'bot_chief', name: 'Chief', isMain: true },
    { id: 'bot_a', name: '前端' },
    { id: 'bot_b', name: '后端' },
  ]);
  const before = map.bindings();
  const slotOfA = Object.keys(before).find(role => before[role] === 'bot_a');
  assert.ok(slotOfA);

  await map.reconcile([
    { id: 'bot_chief', name: 'Chief', isMain: true },
    { id: 'bot_b', name: '后端' },
  ]);
  assert.equal(map.bindings()[slotOfA], undefined, 'the desk is free');
  assert.equal(map.state.stale[slotOfA], 'bot_a', 'the desk remembers who left');
  const slotOfB = Object.keys(map.bindings()).find(role => map.bindings()[role] === 'bot_b');
  assert.ok(slotOfB, 'the other Bot keeps a desk');
});
