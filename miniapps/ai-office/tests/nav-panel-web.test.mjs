import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { fixture } from './fixture.mjs';

async function until(predicate, label, tries = 200) {
  for (let i = 0; i < tries; i++) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error('Timed out waiting for ' + label);
}

test('the navigation helper targets the nearest same-origin ancestor', async t => {
  // 宿主面板里本页可能嵌在跨源外壳中；给 window.top 赋值既不报错也不生效。
  const f = await fixture();
  try {
    const html = await (await fetch(f.base + '/game/host.js')).text();
    assert.ok(html.includes('sameOriginAncestor'), 'the helper resolves the target window explicitly');
    assert.ok(html.includes("parent.location.origin"), 'it compares origins instead of trusting window.top');
    // 不能直接把 window.top 当成目标：那在跨源宿主里是静默失败的。
    assert.ok(!/window\.top\.location\.href\s*=/.test(html), 'it never assigns to window.top directly');
  } finally {
    await f.dispose();
  }
});

test('the bot panel gets a back link only when it was opened from the office', async t => {
  const f = await fixture();
  try {
    const plain = await fetch(f.base + '/bot');
    const plainHtml = await plain.text();
    assert.equal(plain.status, 200);
    assert.ok(!plainHtml.includes('office-back'), 'the official panel stays byte-identical without the flag');
    assert.ok(!plainHtml.includes('回到办公室'));

    const fromOffice = await fetch(f.base + '/bot?from=office');
    const officeHtml = await fromOffice.text();
    assert.equal(fromOffice.status, 200);
    assert.ok(officeHtml.includes('id="office-back"'), 'the back button is injected');
    assert.ok(officeHtml.includes('href="/ai-office"'), 'the back button points at the office');
    assert.ok(officeHtml.includes('aria-label="回到办公室"'), 'the back button is labelled');
    // 必须落在面板顶部的工具条里，而不是浮在页面上。
    const headerIndex = officeHtml.indexOf('<header class="side-top">');
    const buttonIndex = officeHtml.indexOf('id="office-back"');
    assert.ok(headerIndex >= 0, 'the official header is still there');
    assert.ok(buttonIndex > headerIndex, 'the back button sits inside the top bar');
    assert.ok(buttonIndex - headerIndex < 400, 'the back button is right next to the header');
    assert.ok(!officeHtml.includes('position:fixed'), 'it is not a floating overlay any more');
    // 官方内容必须仍然完整存在，不能因为注入被破坏。
    assert.ok(officeHtml.includes('<script type="module" src="/bot/app.js"></script>'));
    assert.ok(officeHtml.includes('id="side-list"'));
  } finally {
    await f.dispose();
  }
});

test('团队设置 lives in the employee panel, not the top bar', { timeout: 180000 }, async t => {
  const f = await fixture();
  const { chromium } = createRequire(join(process.env.AI_OFFICE_TEST_NODE_MODULES, 'package.json'))('playwright');
  const evidence = resolve(process.env.AI_OFFICE_TEST_EVIDENCE);
  await mkdir(evidence, { recursive: true });
  let browser;
  const errors = [];
  try {
    assert.equal((await (await f.post('/api/settings', f.settings)).json()).ok, true);
    browser = await chromium.launch({
      headless: true,
      executablePath: process.env.AI_OFFICE_TEST_CHROMIUM,
      args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
    });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });

    await page.goto(f.base + '/ai-office');
    const canvas = page.frameLocator('#game').locator('#canvas');
    await canvas.waitFor({ state: 'visible', timeout: 30000 });
    await page.waitForFunction(() => {
      const frame = document.querySelector('#game').contentWindow;
      return frame.AIOfficeStream && !frame.document.querySelector('#status');
    }, undefined, { timeout: 30000 });
    await page.waitForTimeout(2500);

    const { width, height } = page.viewportSize();
    const scale = Math.min(width / 1120, height / 720);
    // 员工面板工具区（游戏坐标）：最右三个按钮起点 list.end.x-400，宽度 128。
    // list = Rect2(24, size.y-172, size.x-48, 160)，size.x=1120 → list.end.x=1096。
    const listEndX = 24 + (1120 - 48);
    const listY = 720 - 172;
    const teamX = listEndX - 400 + 2 * 128 + 60;
    const teamY = listY + 12 + 16;
    await canvas.click({ position: { x: teamX * scale, y: teamY * scale } });
    await page.waitForTimeout(1500);

    // 点击后应当跳到 Bot 面板（带 from=office）。
    const ok = await page.evaluate(() => document.body.innerHTML.includes('office-back'));
    const url = page.url();
    assert.ok(ok || url.includes('/bot'), 'the office button reaches the bot panel, url=' + url);
    await page.screenshot({ path: join(evidence, 'nav-team-button-in-employee-panel.png') });
    assert.deepEqual(errors, [], 'no page errors or console errors');
  } finally {
    await browser?.close();
    await f.dispose();
  }
});

test('clicking 团队设置 in the office navigates to the bot panel and back', { timeout: 180000 }, async t => {
  const f = await fixture();
  const { chromium } = createRequire(join(process.env.AI_OFFICE_TEST_NODE_MODULES, 'package.json'))('playwright');
  const evidence = resolve(process.env.AI_OFFICE_TEST_EVIDENCE);
  await mkdir(evidence, { recursive: true });
  let browser;
  const errors = [];
  try {
    assert.equal((await (await f.post('/api/settings', f.settings)).json()).ok, true);
    browser = await chromium.launch({
      headless: true,
      executablePath: process.env.AI_OFFICE_TEST_CHROMIUM,
      args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
    });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });

    await page.goto(f.base + '/ai-office');
    const canvas = page.frameLocator('#game').locator('#canvas');
    await canvas.waitFor({ state: 'visible', timeout: 30000 });
    await page.waitForFunction(() => {
      const frame = document.querySelector('#game').contentWindow;
      return frame.AIOfficeStream && !frame.document.querySelector('#status');
    }, undefined, { timeout: 30000 });
    await page.waitForTimeout(2500);

    // 「团队设置」现在在员工面板工具区：list.end.x - 400 + 2*128，宽 120。
    const { width, height } = page.viewportSize();
    const scale = Math.min(width / 1120, height / 720);
    const click = async (x, y) => {
      await canvas.click({ position: { x: x * scale, y: y * scale } });
      await page.waitForTimeout(250);
    };
    const listEndX = 24 + (1120 - 48);
    await click(listEndX - 400 + 2 * 128 + 60, (720 - 172) + 12 + 16);

    await until(() => page.url().includes('/bot?from=office'), 'the office to navigate to the bot panel');
    assert.ok(page.url().includes('/bot?from=office'), 'top level moved to the bot panel, got ' + page.url());
    await page.waitForTimeout(1200);
    await page.screenshot({ path: join(evidence, 'nav-bot-panel-with-back.png') });

    const back = page.locator('#office-back');
    await back.waitFor({ state: 'visible', timeout: 10000 });
    await back.click();
    await until(() => page.url().includes('/ai-office'), 'the back link to return to the office');
    assert.ok(page.url().includes('/ai-office'), 'returned to the office, got ' + page.url());

    await page.waitForTimeout(2500);
    await page.screenshot({ path: join(evidence, 'nav-back-in-office.png') });
    assert.deepEqual(errors, [], 'no page errors or console errors');
  } finally {
    await browser?.close();
    await f.dispose();
  }
});
