import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { fixture } from './fixture.mjs';

const NAMES = ['前端', '后端', '审查'];

async function seedTeam(f) {
  for (const name of NAMES) {
    const created = await (await f.post('/api/bots', { name, role: '员工' })).json();
    assert.ok(created.bot?.id, 'created ' + name);
  }
}

/**
 * 「对 Chief 说」是派单入口，不是普通私聊：老板那句话由服务端包成工作指令
 * 再交给 Chief（包装逻辑在 bot_bridge.mjs，这条测不到）。
 * 这里只验到「请求打到了派单接口」这一层——真派不派活由服务端的调度逻辑决定，
 * 不在本测试的射程内。
 *
 * 这条直接打 embed 路由（不经过宿主按钮），测三件事：
 *   · Chief 的占位符写明这是派单
 *   · Chief 的消息走 /api/office/task（派单），不是 /api/chats（私聊）
 *   · 普通员工的消息仍走 /api/chats
 *
 * 判据不能依赖 Bot 面板的 bots 列表加载完成——早先的实现就是查
 * state.bots 的 isMain，面板刚起来那会儿 bots 还没到，Chief 会
 * 悄悄降级成普通私聊。所以这里额外测"bots 还没加载时也认得出 Chief"。
 */
test('a Chief message in the drawer is dispatched as work, not sent as a chat', {timeout:90000}, async () => {
  const f = await fixture();
  const {chromium} = createRequire(join(process.env.AI_OFFICE_TEST_NODE_MODULES, 'package.json'))('playwright');
  const evidence = process.env.AI_OFFICE_TEST_EVIDENCE;
  await mkdir(evidence, {recursive:true});
  let browser;
  const errors = [];
  try {
    browser = await chromium.launch({headless:true, executablePath:process.env.AI_OFFICE_TEST_CHROMIUM});
    await seedTeam(f);

    const state = await f.get('/api/bot/state');
    const chief = state.bots.find(bot => bot.isMain);
    const other = state.bots.find(bot => !bot.isMain);
    assert.ok(chief, 'Chief exists');
    assert.ok(other, 'an employee exists');

    const page = await browser.newPage({viewport:{width:876,height:760}});
    const officeTasks = [];
    const chats = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => {
      const url = request.url();
      if (url.endsWith('/api/office/task')) officeTasks.push(JSON.parse(request.postData() ?? '{}'));
      if (url.includes('/api/chats/') && url.endsWith('/messages')) chats.push(JSON.parse(request.postData() ?? '{}'));
    });

    // 记下抽屉画过的每一个输入框占位符。renderMain() 按 state.current 挂载，
    // 如果 boot 在定下目标会话之前就画了第一帧，这里会先记到别人的占位符——
    // 那就是「打开抽屉先闪一下 Chief 会话」的 bug，光看最后一帧是抓不住的。
    await page.addInitScript(() => {
      window.__composeFirstPaint = [];
      const record = () => {
        const el = document.querySelector('.compose-card textarea');
        if (!el) return;
        const seen = window.__composeFirstPaint;
        if (seen[seen.length - 1] !== el.placeholder) seen.push(el.placeholder);
      };
      new MutationObserver(record).observe(document, {childList:true, subtree:true});
      record();
    });

    // ── Chief ──
    await page.goto(f.base + '/bot?embed=chat&bot=' + encodeURIComponent(chief.id));
    await page.waitForSelector('.compose-card textarea', {timeout:20000});
    const placeholder = await page.locator('.compose-card textarea').getAttribute('placeholder');
    assert.match(placeholder, /拆给团队|下达工作/, 'the placeholder says the message becomes work');
    const chiefFirst = await page.evaluate(() => window.__composeFirstPaint);
    assert.match(chiefFirst[0] ?? '', /拆给团队|下达工作/, 'the first composer painted is the Chief dispatch one');

    await page.locator('.compose-card textarea').fill('把新品发布页做出来');
    await page.locator('.compose-card .send').click();
    for (let i = 0; i < 60 && officeTasks.length === 0; i++) {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.equal(officeTasks.length, 1, 'a Chief message goes to the dispatch endpoint');
    assert.equal(officeTasks[0].text, '把新品发布页做出来', 'the dispatch carries the text');
    assert.equal(chats.length, 0, 'a Chief message must not also go out as a plain chat');
    await page.screenshot({path:join(evidence, 'bot-chief-dispatch.png')});

    // ── 普通员工 ──
    await page.goto(f.base + '/bot?embed=chat&bot=' + encodeURIComponent(other.id));
    await page.waitForSelector('.compose-card textarea', {timeout:20000});
    const plainPlaceholder = await page.locator('.compose-card textarea').getAttribute('placeholder');
    assert.doesNotMatch(plainPlaceholder, /拆给团队/, 'an employee chat is not a dispatch');
    // 首帧护栏：抽屉不能在切到目标 Bot 之前先画一帧 Chief 的输入框。
    const plainFirst = await page.evaluate(() => window.__composeFirstPaint);
    assert.doesNotMatch(plainFirst[0] ?? '', /拆给团队|下达工作/, 'the drawer must not first paint the Chief composer');
    assert.match(plainFirst[0] ?? '', /前端/, 'the first composer painted belongs to the opened bot');

    await page.locator('.compose-card textarea').fill('在干嘛呢');
    await page.locator('.compose-card .send').click();
    for (let i = 0; i < 60 && chats.length === 0; i++) {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.equal(chats.length, 1, 'an employee message goes out as a chat');
    assert.equal(officeTasks.length, 1, 'an employee message must not be dispatched as work');

    assert.deepEqual(errors, [], 'no page errors');
  } finally {
    await browser?.close();
    await f.dispose();
  }
});

/**
 * 独立 /bot 页面不换皮、也不派单：那儿的 Chief 私聊就是普通聊天。
 * 占位符要是也写「会拆给团队」，就是在骗人——发出去其实只走 /api/chats。
 * 判据必须和真正派单的那行（submit 里的 EMBED_MODE && isChiefChat）一致。
 */
test('the standalone Bot page does not promise dispatch', {timeout:90000}, async () => {
  const f = await fixture();
  const {chromium} = createRequire(join(process.env.AI_OFFICE_TEST_NODE_MODULES, 'package.json'))('playwright');
  let browser;
  try {
    browser = await chromium.launch({headless:true, executablePath:process.env.AI_OFFICE_TEST_CHROMIUM});
    const state = await f.get('/api/bot/state');
    const chief = state.bots.find(bot => bot.isMain);
    assert.ok(chief, 'Chief exists');

    // 不带 embed 参数：就是团队面板本身，默认会话是 Chief。
    const page = await browser.newPage({viewport:{width:1200,height:900}});
    await page.goto(f.base + '/bot');
    await page.waitForSelector('.compose-card textarea', {timeout:20000});
    const placeholder = await page.locator('.compose-card textarea').getAttribute('placeholder');
    assert.doesNotMatch(placeholder, /拆给团队|下达工作/,
      'the standalone page must not promise dispatch: ' + placeholder);
  } finally {
    await browser?.close();
    await f.dispose();
  }
});
