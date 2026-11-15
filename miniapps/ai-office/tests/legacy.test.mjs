import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { fixture, legacySave, writeSave } from './fixture.mjs';

// 旧存档（v1 模拟经营玩法）现在只剩一件事要证明：
// 读得进、读得对、读档后旧玩法的东西一个都不复活。
const LEGACY_ID = 'legacy-v1-save';

test('legacy save: old clients and conflicts are dropped, the old economy is still listed, and the Web UI stays usable', {timeout:90000}, async t => {
  const f = await fixture();
  const evidence = resolve(process.env.AI_OFFICE_TEST_EVIDENCE);
  await mkdir(evidence, {recursive:true});
  let browser;
    const errors = [], selected = [];
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  try {
    assert.equal((await (await f.post('/api/settings', f.settings)).json()).ok, true);
    const fresh = await f.get('/api/state');
    // 手搓一份 v1 旧档：形状照旧 save.py 的 snapshot()，
    // 但客户/冲突/资金这些字段只能自己拼——新后端里已经没有 Game.Client 可用了。
    const legacy = legacySave(fresh.workers);
    // 先证明这份旧存档本身确实带着客户与冲突数据，否则"被清空"是无的放矢。
    assert.equal(legacy.clients.length, 3, 'the legacy save really carries three clients');
    assert.equal(legacy.conflicts.length, 1, 'the legacy save really carries one conflict id');
    assert.equal(legacy.finished.length, 1, 'the legacy save really carries one finished delivery');
    assert.equal(legacy.money, 869, 'the legacy save really carries the old money');
    assert.equal(legacy.rep, 59, 'the legacy save really carries the old reputation');
    await writeSave(f, LEGACY_ID, legacy);
    const legacyFile = join(f.dataDir, 'saves', LEGACY_ID + '.json');
    const legacyBytes = await readFile(legacyFile, 'utf8');

    const loaded = await (await f.post('/api/load', {id: LEGACY_ID})).json();
    assert.equal(loaded.ok, true, 'the legacy save still loads: ' + (loaded.msg || ''));
    const response = await fetch(f.base + '/api/state');
    assert.equal(response.status, 200, 'legacy conflict IDs must not break the entire state endpoint');
    const before = await response.json();
    // 经营玩法已停用（命令即工单）：读档一律清空客户、交付与冲突（防盗门），
    // 旧存档里的 3 个客户与冲突不借读档复活——所以这里是 0，不是 3。
    assert.deepEqual(before.clients, [], 'restore must drop every recovered client');
    assert.deepEqual(before.conflicts, [], 'a conflict id cannot resurrect a conflict once clients are cleared');
    // 客户/交付物整套下线后，这两个 key 直接不在状态契约里了。
    assert.equal('finished' in before, false, 'the deliveries key is gone from the state contract');
    assert.equal('neg_days' in before, false, 'the negative-days key is gone from the state contract');
    // 旧经济只剩墓碑：钱恒为 0、声誉恒为 50，旧档里的数字不复活。
    assert.equal(before.money, 0, 'money is a tombstone now, the legacy value is dropped');
    assert.equal(before.rep, 50, 'reputation is a tombstone now, the legacy value is dropped');
    assert.equal(before.game_over, null, 'the legacy bankruptcy reason must not surface');
    // 但队伍与旧档的其它内容必须原样保留，整个 /api/state 不能崩。
    assert.equal(before.workers.length, 5);
    assert.equal(before.day, 3);
    assert.ok(before.tick >= 81175, 'the legacy tick is restored, not rewound');
    for (const w of before.workers) {
      assert.equal(w.job, null, w.id + ' must not keep a job pointing at a dead client');
      assert.equal(w.eff, 1, w.id + ' must not keep the efficiency of a dead job');
      assert.doesNotMatch(w.acting, /接待处/, w.id + ' must not keep walking to the reception desk');
    }
    // 前端据此判"这是旧档"：存档列表里仍读得到旧的钱和旧的名声。
    const saves = await f.get('/api/saves');
    const listed = saves.saves.find(entry => entry.id === LEGACY_ID);
    assert.ok(listed, 'the legacy save is listed for the player');
    assert.equal(listed.money, 869, 'the save list still shows the old money');
    assert.equal(listed.rep, 59, 'the save list still shows the old reputation');
    assert.equal(listed.day, 3);

    await f.dispose();
    await f.restart();
    const reopened = await f.get('/api/state');
    assert.deepEqual(reopened.clients, [], 'reopening keeps recovered clients cleared');
    assert.deepEqual(reopened.conflicts, [], 'reopening keeps recovered conflicts cleared');
    assert.equal(reopened.money, 0);
    assert.equal(reopened.rep, 50);
    const {chromium} = createRequire(join(process.env.AI_OFFICE_TEST_NODE_MODULES,'package.json'))('playwright');
    browser = await chromium.launch({headless:true,executablePath:process.env.AI_OFFICE_TEST_CHROMIUM,
      args:['--use-angle=swiftshader', '--enable-unsafe-swiftshader']});
    const page = await browser.newPage({viewport:{width:1102,height:957}});
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => {
      if (message.type() === 'error' && !message.text().includes('status of 500')) errors.push(message.text());
    });
    await page.route(f.base+'/api/state', route => route.fulfill({status:500, contentType:'application/json',body:'{"ok":false,"error":"internal"}'}));
    await page.goto(f.base+'/ai-office');
    const canvas = page.frameLocator('#game').locator('#canvas');
    await canvas.waitFor({state:'visible'});
    await page.waitForFunction(() => document.querySelector('#game').contentWindow.AIOfficeStream && !document.querySelector('#game').contentWindow.document.querySelector('#status'));
    await pause(1000);
    await page.screenshot({path:join(evidence, 'state-unavailable-feedback.png')});
    await page.unroute(f.base+'/api/state');
    await pause(1400);
    await page.screenshot({path:join(evidence, 'legacy-state-ui-recovered.png')});
    await writeFile(join(f.dataDir,'quota-restored'), 'true');
    const scale = 1102/1120, width = 1120, height = 957/scale;
    const cardWidth = (width-128)/5;
    for (const [i,who] of ['m3','flash','longcat','kimi','step5'].entries()) {
      // 点击五张身份卡并向隔离模型发送，验证恢复后的交互路径。
      await canvas.click({position:{x:(44+i*(cardWidth+10)+cardWidth-37)*scale,y:(height-120+23)*scale}});
      await pause(180);
      const text = 'restored '+who;
      await page.keyboard.type(text, {delay:30});
      await page.keyboard.press('Enter');
      let delivered = false;
      for (let attempt=0; attempt<30; attempt++) {
        const calls = (await readFile(join(f.dataDir,'calls.jsonl'),'utf8').catch(()=>'')).trim().split('\n').filter(Boolean).map(JSON.parse);
        if (calls.some(call=>call.who===who && call.text.includes(text))) { delivered=true; break; }
        await pause(100);
      }
      assert.ok(delivered, who+' restored chat accepts input and reaches the isolated model');
      selected.push(who);
      await pause(150);
      await page.keyboard.press('Escape');
      await pause(100);
    }
    assert.equal(await readFile(legacyFile,'utf8'), legacyBytes, 'the legacy save file remains read-only');
    assert.equal((await readdir(f.dataDir)).includes('network-attempt'), false);
    assert.equal((await readFile(join(f.dataDir,'calls.jsonl'),'utf8')).trim().split('\n').length, 5, 'only five intentional fake chat calls');
    assert.deepEqual(errors, []);
    await writeFile(join(evidence,'legacy-state-web.json'),JSON.stringify({http:response.status,day:before.day,money:before.money,rep:before.rep,
      workers:before.workers.map(w=>w.id),clients:before.clients,conflicts:before.conflicts,selected,errors},null,2));
  } finally {
    await browser?.close();
    await f.dispose();
    await rm(f.scratch,{recursive:true,force:true});
  }
});
