import test from 'node:test';
import assert from 'node:assert/strict';
import { mayRetryFailure } from '../miniapp/node/engine.mjs';
import strings from '../miniapp/node/strings.mjs';

/**
 * 「额度用尽」和「此刻限流」不是一回事：限流通常一分钟内自己好，
 * 额度用尽要等窗口恢复（这次是周窗口），重发只会把同样的大请求再打一遍。
 *
 * 宿主给的原因码是 usage_limit，应用这边原来只认 quota —— 两个名字对不上，
 * 于是既没有本地化文案（落到「模型服务繁忙」的兜底），又被当成可以自动重试。
 * 前端那条消息因此白重发了两次，每次 1.3 MB。
 */
test('a usage_limit failure is not retried', () => {
  assert.equal(mayRetryFailure({ thrown: false, reason: 'usage_limit' }), false);
});

test('quota keeps its existing no-retry behaviour', () => {
  assert.equal(mayRetryFailure({ thrown: false, reason: 'quota' }), false);
});

test('a plain rate limit is still retried: it clears on its own', () => {
  assert.equal(mayRetryFailure({ thrown: false, reason: 'rate_limited' }), true);
});

test('both languages explain a usage_limit failure in words the player understands', () => {
  for (const lang of ['zh', 'en']) {
    const text = strings[lang]['agentError.reason.usage_limit'];
    assert.equal(typeof text, 'string', lang + ' has a usage_limit message');
    assert.notEqual(text, 'agentError.reason.usage_limit', lang + ' message is real, not the bare key');
  }
  // 必须说清是额度，而不是笼统的「繁忙」。
  assert.match(strings.zh['agentError.reason.usage_limit'], /额度/);
  assert.match(strings.en['agentError.reason.usage_limit'], /quota|usage limit/i);
});
