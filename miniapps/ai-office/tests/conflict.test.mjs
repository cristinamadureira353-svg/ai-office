import test from 'node:test';
import assert from 'node:assert/strict';
import { readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { fixture, legacySave, writeSave } from './fixture.mjs';

// ★旧的抢单冲突玩法整条下线了：Game.Client / clients / slots / conflicts 全没了，
// 冲突弹窗（四个鼠标选项 → Game.judge）也不存在了。
// 这个文件现在测的是**留下来的那条线**：旧存档里的客户和冲突一律不复活。
const LEGACY_ID = 'legacy-v1-save';

test('customer and conflict gameplay is gone: a legacy save never resurrects clients or conflicts', {timeout:60000}, async t => {
  const f = await fixture();
  try {
    await t.test('a fresh game carries no clients and no conflicts', async () => {
      assert.equal((await (await f.post('/api/settings', f.settings)).json()).ok, true);
      const fresh = await f.get('/api/state');
      assert.deepEqual(fresh.clients, [], 'clients are gone with the gameplay');
      assert.deepEqual(fresh.conflicts, [], 'conflicts are gone with the gameplay');
      assert.equal(fresh.workers.length, 5);
    });

    await t.test('loading a legacy save drops its clients, conflicts and economy', async () => {
      const fresh = await f.get('/api/state');
      // 手搓一份 v1 旧档：3 个客户 + 1 个冲突 id + money/rep + 指向客户的员工状态。
      const legacy = legacySave(fresh.workers);
      assert.equal(legacy.clients.length, 3, 'the legacy save really carries three clients');
      assert.equal(legacy.conflicts.length, 1, 'the legacy save really carries one conflict id');
      assert.equal(legacy.money, 869, 'the legacy save really carries the old money');
      assert.equal(legacy.rep, 59, 'the legacy save really carries the old reputation');
      await writeSave(f, LEGACY_ID, legacy);

      const loaded = await (await f.post('/api/load', {id: LEGACY_ID})).json();
      assert.equal(loaded.ok, true, 'the legacy save still loads: ' + (loaded.msg || ''));

      const after = await f.get('/api/state');
      assert.deepEqual(after.clients, [], 'restore must not resurrect legacy clients');
      assert.deepEqual(after.conflicts, [], 'restore must not resurrect legacy conflicts');
      // 状态契约里这两个 key 直接没了（客户与交付物整套下线）。
      assert.equal('finished' in after, false, 'the deliveries key is gone from the state contract');
      assert.equal('neg_days' in after, false, 'the negative-days key is gone from the state contract');
      // 旧经济只留墓碑：钱恒为 0，声誉恒为 50，旧档里的数字不复活。
      assert.equal(after.money, 0, 'money is a tombstone now, the legacy value is dropped');
      assert.equal(after.rep, 50, 'reputation is a tombstone now, the legacy value is dropped');
      // 破产机制已取消：旧档里那句"资金为负连续 3 天"不能显示出来。
      assert.equal(after.game_over, null, 'the legacy bankruptcy reason must not surface');
      // 旧档的其它内容照旧读回来（否则就不是"读档"，是"丢档"）。
      assert.equal(after.day, 3, 'the rest of the legacy save is restored');
      assert.ok(after.tick >= 81175, 'the legacy tick is restored, not rewound');
      assert.equal(after.workers.length, 5);
      for (const w of after.workers) {
        assert.equal(w.job, null, w.id + ' must not keep a job pointing at a dead client');
        assert.equal(w.eff, 1, w.id + ' must not keep the efficiency of a dead job');
        assert.doesNotMatch(w.acting, /接待处/, w.id + ' must not keep walking to the reception desk');
      }
    });

    await t.test('reopening inherits the legacy save without its clients', async () => {
      // dispose 时后端会自己存一份"关闭前进度"；删掉它，
      // 让重开时继承的就是那份旧档（重开路径走的是 miniapp_bridge 的自动继承）。
      const dir = join(f.dataDir, 'saves');
      for (const file of await readdir(dir)) {
        if (file !== LEGACY_ID + '.json') await rm(join(dir, file), {force: true});
      }
      await f.dispose();
      await f.restart();
      const reopened = await f.get('/api/state');
      assert.equal(reopened.day, 3, 'the reopened MiniApp inherited the legacy save');
      assert.deepEqual(reopened.clients, [], 'reopening keeps legacy clients cleared');
      assert.deepEqual(reopened.conflicts, [], 'reopening keeps legacy conflicts cleared');
      assert.equal(reopened.money, 0);
      assert.equal(reopened.rep, 50);
    });
  } finally {
    await f.dispose();
    await rm(f.scratch, {recursive: true, force: true});
  }
});
