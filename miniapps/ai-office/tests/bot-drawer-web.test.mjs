import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { fixture } from './fixture.mjs';

/**
 * 游戏里的对话抽屉：点员工聊天后，宿主页面从右侧滑出 876×760 的抽屉，
 * 里面是 Bot 面板的 embed 模式（单会话、像素皮肤、自带关闭按钮）。
 *
 * 这一条只测"有宿主桥"的路径；导出页自己的兜底面板在 web.test.mjs 里覆盖，
 * 两条路径互不替代。
 */
test('office chat drawer opens the Bot panel in embed mode and closes', {timeout:90000}, async () => {
  const f = await fixture();
  const {chromium} = createRequire(join(process.env.AI_OFFICE_TEST_NODE_MODULES, 'package.json'))('playwright');
  const evidence = process.env.AI_OFFICE_TEST_EVIDENCE;
  await mkdir(evidence, {recursive:true});
  let browser;
  const errors = [];
  try {
    browser = await chromium.launch({headless:true, executablePath:process.env.AI_OFFICE_TEST_CHROMIUM});
    const page = await browser.newPage({viewport:{width:1280,height:800}});
    page.on('pageerror', error => errors.push(error.message));

    await page.goto(f.base + '/ai-office');
    await page.waitForFunction(() => typeof window.AIOfficeChat === 'object', undefined, {timeout:20000});

    // 团队懒初始化：拿一个真实 Bot id，抽屉按这个 id 打开对应会话。
    const state = await f.get('/api/bot/state');
    const chief = state.bots.find(bot => bot.isMain);
    assert.ok(chief, 'Chief exists');

    const opened = await page.evaluate(id => window.AIOfficeChat.open(id), chief.id);
    assert.equal(opened, true, 'the host bridge accepts a Bot id');

    const rect = await page.evaluate(() => {
      const frame = document.querySelector('.chat-frame').getBoundingClientRect();
      return {width:Math.round(frame.width), height:Math.round(frame.height),
        hidden:document.getElementById('chat-drawer').hidden,
        src:document.getElementById('chat-frame').getAttribute('src')};
    });
    assert.equal(rect.hidden, false, 'drawer is visible');
    assert.equal(rect.width, 876, 'drawer keeps the approved width');
    assert.ok(rect.height > 700 && rect.height <= 760, 'drawer keeps the approved height');
    assert.match(rect.src, /\/bot\?embed=chat&bot=/, 'drawer loads the embed route');

    const chat = page.frameLocator('#chat-frame');
    await chat.locator('.compose-card textarea').waitFor({timeout:20000});
    const embed = await page.evaluate(() => {
      const doc = document.getElementById('chat-frame').contentDocument;
      return {
        skin: doc.documentElement.dataset.skin,
        rail: getComputedStyle(doc.querySelector('.rail')).display,
        side: getComputedStyle(doc.querySelector('.side')).display,
        close: Boolean(doc.querySelector('.embed-close')),
        name: doc.querySelector('.pill-name, .pill')?.textContent ?? '',
      };
    });
    assert.equal(embed.skin, 'pixel', 'embed mode wears the pixel skin');
    assert.equal(embed.rail, 'none', 'the filter rail is hidden in a drawer');
    assert.equal(embed.side, 'none', 'the chat list is hidden in a drawer');
    assert.equal(embed.close, true, 'the drawer can close itself');
    assert.match(embed.name, new RegExp(chief.name), 'the drawer shows the Bot it was opened for');
    await page.screenshot({path:join(evidence, 'drawer-open.png')});

    await chat.locator('.embed-close').click();
    await page.waitForFunction(() => document.getElementById('chat-drawer').hidden, undefined, {timeout:5000});
    assert.equal(await page.evaluate(() => document.getElementById('chat-frame').getAttribute('src')), null, 'closing drops the iframe');
    assert.deepEqual(errors, [], 'no page errors');
  } finally {
    await browser?.close();
    await f.dispose();
  }
});
