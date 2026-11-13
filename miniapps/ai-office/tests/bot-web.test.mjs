import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { fixture } from './fixture.mjs';

test('Bot team panel loads with Chief, sends a message, and reports no page errors', {timeout:90000}, async t => {
  const f = await fixture();
  const { chromium } = createRequire(join(process.env.AI_OFFICE_TEST_NODE_MODULES, 'package.json'))('playwright');
  const evidence = resolve(process.env.AI_OFFICE_TEST_EVIDENCE);
  await mkdir(evidence, { recursive: true });
  let browser;
  const errors = [];
  try {
    browser = await chromium.launch({ headless: true, executablePath: process.env.AI_OFFICE_TEST_CHROMIUM });
    const page = await browser.newPage({ viewport: { width: 1280, height: 820 } });
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });

    await page.goto(f.base + '/bot');
    // 团队列表出现 Chief，说明 /api/bot/state 与懒初始化都正常。
    await page.getByText('Chief', { exact: false }).first().waitFor({ state: 'visible', timeout: 20000 });
    await page.screenshot({ path: join(evidence, 'bot-panel-loaded.png') });

    const state = await f.get('/api/bot/state');
    const chief = state.bots.find(bot => bot.isMain);
    assert.ok(chief, 'Chief exists');

    // 直接调用页面自己的发送接口，验证 Agent 回复会被渲染。
    const response = await f.post('/api/chats/bot:' + chief.id + '/messages', { text: '面板测试：报个到' });
    assert.equal(response.status, 200);
    await page.waitForFunction(
      () => document.body.innerText.includes('模拟回复'),
      undefined,
      { timeout: 20000 },
    );
    await page.screenshot({ path: join(evidence, 'bot-panel-reply.png') });

    assert.deepEqual(errors, [], 'no page errors or console errors');
    await writeFile(join(evidence, 'bot-panel-web.json'), JSON.stringify({
      chief: chief.name,
      bots: state.bots.map(bot => bot.name),
      errors,
    }, null, 2));
  } finally {
    await browser?.close();
    await f.dispose();
  }
});
