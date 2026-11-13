import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { fixture } from './fixture.mjs';

const ROLES = ['m3', 'flash', 'longcat', 'kimi', 'step5'];
// 用真实 Bot 会有的名字：小人随机分配，名字与小人不对应是设计好的。
const TEAM = [
  { name: '前端', role: '前端开发' },
  { name: '后端', role: '后端开发' },
  { name: '审查', role: '代码审查' },
  { name: '测试', role: '测试' },
  { name: '运维', role: '运维' },
];

async function until(predicate, label, tries = 400) {
  for (let i = 0; i < tries; i++) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error('Timed out waiting for ' + label);
}

async function seedTeam(f) {
  for (const member of TEAM) {
    const created = await (await f.post('/api/bots', member)).json();
    assert.ok(created.bot?.id, 'created ' + member.name);
  }
}

/**
 * 这段跑的是本轮真实 Godot Web 导出：看板与徽标若没进构建，这里必然看不到。
 */
test('the office shows real queued/running badges and a Chief entry', { timeout: 180000 }, async t => {
  const f = await fixture();
  const { chromium } = createRequire(join(process.env.AI_OFFICE_TEST_NODE_MODULES, 'package.json'))('playwright');
  const evidence = resolve(process.env.AI_OFFICE_TEST_EVIDENCE);
  await mkdir(evidence, { recursive: true });
  let browser;
  const errors = [];
  const officePosts = [];
  const stamp = Date.now();
  const shot = (name) => ({ path: join(evidence, 'stage2-' + stamp + '-' + name + '.png') });
  try {
    assert.equal((await (await f.post('/api/settings', f.settings)).json()).ok, true);
    await seedTeam(f);

    // 工位按团队随机分配，但名字与角色一定是真实 Bot 的。
    const seeded = await f.panel();
    assert.equal(seeded.staff.length, 5, '每个成员 Bot 占一个工位');
    assert.deepEqual(seeded.staff.map(item => item.name).sort(), TEAM.map(member => member.name).sort(),
      '工位上显示的是真实 Bot 的名字');
    assert.deepEqual(seeded.staff.map(item => item.role).sort(),
      TEAM.map(member => member.role).sort(), '工位上显示的是真实 Bot 的角色');
    assert.deepEqual(seeded.empty_slots, [], '五个成员正好占满五个工位');
    assert.equal(seeded.chief.name, 'Chief');
    assert.equal(Object.values(seeded.bindings).includes(seeded.chief.bot_id), false,
      'Chief 主管全局，不占工位');

    browser = await chromium.launch({
      headless: true,
      executablePath: process.env.AI_OFFICE_TEST_CHROMIUM,
      args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
    });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
    page.on('request', request => {
      if (request.url() === f.base + '/api/office/task' && request.method() === 'POST') {
        officePosts.push(JSON.parse(request.postData() ?? '{}'));
      }
    });

    await page.goto(f.base + '/ai-office');
    const canvas = page.frameLocator('#game').locator('#canvas');
    await canvas.waitFor({ state: 'visible', timeout: 30000 });
    await page.waitForFunction(() => {
      const frame = document.querySelector('#game').contentWindow;
      return frame.AIOfficeStream && !frame.document.querySelector('#status');
    }, undefined, { timeout: 30000 });
    // 等 Godot 真正连上后端，画面才有游戏状态。
    await page.waitForTimeout(3000);

    // ── 场景一：真实 running / queued ──
    f.gate.close();
    const call = await f.mcp();
    const receipt = await call('dispatch_tasks', {
      request_id: 'stage2-visual-1',
      tasks: [
        { to: '前端', message: '写框架', title: '框架' },
        { to: '后端', message: '写文案', title: '文案' },
        { to: '审查', message: '审风险', title: '风险' },
      ],
    });
    await until(async () => {
      const panel = await f.panel();
      const batch = panel.batches.find(item => item.batch_id === receipt.batch_id);
      if (!batch) return false;
      const running = batch.tasks.filter(task => task.status === 'running').length;
      const queued = batch.tasks.filter(task => task.status === 'queued').length;
      return running === 2 && queued === 1;
    }, 'two running and one queued');

    const busyPanel = await f.panel();
    const busyBatch = busyPanel.batches.find(item => item.batch_id === receipt.batch_id);
    const busyStatuses = busyBatch.tasks.map(task => task.title + ':' + task.status);
    // 交给 Godot 轮询两轮以上再截图。
    await page.waitForTimeout(1600);
    await page.screenshot({ path: shot('running-and-queued').path });

    // ── 场景二：Chief 派活入口 ──
    // 「对 Chief 说」现在走 HTML 抽屉（游戏里按 B 打开），抽屉里的 Chief 发送时
    // 调 /api/office/task 把这句话派给团队。所以这一步要在抽屉的输入框里打字，
    // 不再是画布键盘。
    await page.keyboard.press('B');
    await page.waitForTimeout(400);
    const chat = page.frameLocator('#chat-frame');
    await chat.locator('.compose-card textarea').waitFor({ state: 'visible', timeout: 20000 });
    // 注意：Godot 网页端的中文输入要走系统输入法，Playwright 直接打字进不了画布，
    // 所以这里用 ASCII 验证"按键→输入框→发送"这条真实链路，中文由真机人工验证。
    const draft = 'chief dispatch e2e';
    await chat.locator('.compose-card textarea').fill(draft);
    await chat.locator('.compose-card .send').click();
    await until(() => officePosts.length > 0, 'the office dispatch request');
    assert.equal(String(officePosts[0].text ?? ''), draft);
    await page.waitForTimeout(1200);
    await page.screenshot({ path: shot('chief-entry').path });
    await page.evaluate(() => window.AIOfficeChat?.close());
    await page.waitForTimeout(300);

    // ── 场景三：完成 ──
    f.gate.open();
    await until(async () => {
      const panel = await f.panel();
      const batch = panel.batches.find(item => item.batch_id === receipt.batch_id);
      return batch?.complete === true && batch.tasks.every(task => task.status === 'done');
    }, 'the batch to finish');
    await page.waitForTimeout(1600);
    await page.screenshot({ path: shot('all-done').path });

    // ── 场景四：取消 ≠ 完成 ──
    f.gate.close();
    const longRun = await call('dispatch_tasks', {
      request_id: 'stage2-visual-cancel',
      tasks: [{ to: '测试', message: '这单会被取消', title: '取消演示' }],
    });
    await until(async () => {
      const panel = await f.panel();
      const batch = panel.batches.find(item => item.batch_id === longRun.batch_id);
      return batch?.tasks.some(task => task.status === 'running');
    }, 'the cancellable task to run');
    await call('cancel_tasks', { batch_id: longRun.batch_id });
    await until(async () => {
      const panel = await f.panel();
      const batch = panel.batches.find(item => item.batch_id === longRun.batch_id);
      return batch && batch.tasks.every(task => ['cancelled', 'done'].includes(task.status));
    }, 'the cancelled task to settle');
    const cancelledPanel = await f.panel();
    const cancelledBatch = cancelledPanel.batches.find(item => item.batch_id === longRun.batch_id);
    assert.equal(cancelledBatch.tasks.some(task => task.status === 'done'), false, '取消不会变成完成');
    f.gate.open();
    await page.waitForTimeout(1600);
    await page.screenshot({ path: shot('after-cancel').path });

    // ── 场景五：失效绑定 ──
    const bindings = (await f.panel()).bindings;
    const removed = await fetch(f.base + '/api/bots/' + bindings.kimi, { method: 'DELETE' });
    assert.equal(removed.status, 200);
    const stalePanel = await f.panel();
    assert.equal(stalePanel.bindings.kimi, undefined);
    assert.equal(stalePanel.stale.kimi, bindings.kimi, '角色记录丢失的 Bot，不静默换人');
    assert.equal(stalePanel.staff.length, 4, '走了一个 Bot，少一个工位');
    assert.equal(stalePanel.empty_slots.length, 1, '空出来的工位显示待招募');
    await page.waitForTimeout(1600);
    await page.screenshot({ path: shot('stale-binding').path });

    // ── 场景六：Chief 的主管位（会议室主桌一头）──
    await page.keyboard.press('E');
    await page.waitForTimeout(1600);
    await page.screenshot({ path: shot('chief-desk').path });

    await writeFile(join(evidence, 'stage2-' + stamp + '-visual.json'), JSON.stringify({
      batch_id: receipt.batch_id,
      busy_statuses: busyStatuses,
      office_posts: officePosts,
      cancelled_statuses: cancelledBatch.tasks.map(task => task.status),
      stale: stalePanel.stale,
      bindings: stalePanel.bindings,
      staff: stalePanel.staff.map(item => ({ slot: item.slot, name: item.name, role: item.role, status: item.status })),
      empty_slots: stalePanel.empty_slots,
      roles: ROLES,
      errors,
    }, null, 2));

    assert.deepEqual(errors, [], 'no page errors or console errors');
  } finally {
    await browser?.close();
    await f.dispose();
  }
});

test('a task still running when the runtime restarts becomes unknown, not done', async t => {
  const f = await fixture();
  try {
    await seedTeam(f);
    f.gate.close();
    const call = await f.mcp();
    const receipt = await call('dispatch_tasks', {
      request_id: 'stage2-unknown',
      tasks: [{ to: '运维', message: '跑到一半就重启', title: '重启演示' }],
    });
    await until(async () => {
      const panel = await f.panel();
      const batch = panel.batches.find(item => item.batch_id === receipt.batch_id);
      return batch?.tasks.some(task => task.status === 'running');
    }, 'the task to start running');

    await f.dispose();
    await f.restart();

    const after = await f.panel();
    const batch = after.batches.find(item => item.batch_id === receipt.batch_id);
    assert.ok(batch, 'the batch is still known after restart');
    assert.equal(batch.tasks.some(task => task.status === 'running'), false, 'nothing is left "running"');
    assert.equal(batch.tasks.some(task => task.status === 'done'), false, 'an interrupted task is never done');
    assert.equal(batch.tasks[0].status, 'unknown', 'it is reported as an unknown outcome');
  } finally {
    await f.dispose();
  }
});
