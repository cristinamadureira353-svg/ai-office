import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './fixture.mjs';

/**
 * 「指令与待办」读的是面板里的 batches。面板原来只把**最后两个**批次发出去，
 * 于是更早的批次在界面上根本不存在——玩家滚到底也看不到。
 *
 * 这条守的是：有多少批次就发多少批次。
 */
test('the office panel carries every task batch, not only the last two', async () => {
  const f = await fixture();
  try {
    for (const name of ['前端', '后端', '审查']) {
      const created = await (await f.post('/api/bots', { name, role: '员工' })).json();
      assert.ok(created.bot?.id, 'created ' + name);
    }
    // 先读一次面板，让 reconcile 把工位分好，后面的派单才有地方去。
    await f.panel();

    const call = await f.mcp();
    for (const n of [1, 2, 3]) {
      await call('dispatch_tasks', {
        request_id: 'all-batches-' + n,
        tasks: [{ to: '前端', message: '第 ' + n + ' 件活', title: '第 ' + n + ' 件活' }],
      });
    }

    const panel = await f.panel();
    assert.equal((panel.batches ?? []).length, 3, 'all three batches reach the panel');
  } finally {
    await f.dispose();
  }
});
