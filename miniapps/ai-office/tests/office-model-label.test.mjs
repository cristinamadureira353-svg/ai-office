import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './fixture.mjs';

/**
 * 办公室详情页只有一行写模型，宽度很窄。原来那一行拼的是原始 providerId：
 *   custom_provider:provider-8b66a2 / k3-256k · max
 * 太长被截成 "custom_provider:provider-8b…"，玩家看到的就是一串看不懂的东西。
 *
 * 期望：像模型选择器那样写模型名——宿主目录里有显示名就用显示名，
 * 没有就退到 modelId；内置厂商仍保留 "厂商 / 模型" 的写法。
 */
const CUSTOM = { providerId: 'custom_provider:provider-8b66a2', modelId: 'k3-256k', thinking: { effort: 'max' } };

/** The office panel's model line for one Bot, disposed on every path. */
async function labelFor(options) {
  const f = await fixture(options);
  try {
    const created = await (await f.post('/api/bots', { name: '前端', role: '员工' })).json();
    const id = created.bot.id;
    const patched = await fetch(f.base + '/api/bots/' + id, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: CUSTOM }),
    });
    assert.equal(patched.status, 200, 'the model was saved');
    const panel = await f.panel();
    const row = (panel.staff ?? []).find((item) => item.bot_id === id);
    assert.ok(row, 'the Bot shows up on the office panel');
    return row.model_label;
  } finally {
    await f.dispose();
  }
}

test('the office names the model instead of printing the raw provider id', async () => {
  const label = await labelFor();
  assert.doesNotMatch(label, /custom_provider:/, 'no internal provider id: ' + label);
  assert.equal(label, 'k3-256k · max', 'model id plus effort, nothing else');
});

test('a catalog display name wins over the model id', async () => {
  const label = await labelFor({
    models: [{ providerId: CUSTOM.providerId, modelId: CUSTOM.modelId, displayName: 'K3-256k' }],
  });
  assert.equal(label, 'K3-256k · max');
});
