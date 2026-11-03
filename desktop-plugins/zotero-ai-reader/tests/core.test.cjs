const { test } = require('node:test');
const assert = require('node:assert/strict');
const C = require('../src/content/core.js');

test('endpoint normalization accepts HTTPS and loopback, rejects credentials and remote HTTP', () => {
  assert.equal(C.endpoint('https://api.deepseek.com/v1/'), 'https://api.deepseek.com/v1/chat/completions');
  assert.equal(C.endpoint('http://127.0.0.1:11434/v1/chat/completions'), 'http://127.0.0.1:11434/v1/chat/completions');
  assert.equal(C.endpoint('http://[::1]:11434/v1'), 'http://[::1]:11434/v1/chat/completions');
  for (const value of ['http://example.org/v1', 'https://user:pass@example.org/v1', 'https://example.org/v1?key=x', 'file:///tmp/test', 'javascript:alert(1)']) assert.throws(() => C.endpoint(value));
});

test('fragmented SSE preserves Chinese text, CRLF, content arrays and final reason', () => {
  const wire = ': heartbeat\r\n\r\ndata: {"choices":[{"delta":{"role":"assistant"}}]}\r\n\r\n' +
    'data: {"choices":[{"delta":{"content":"你好"}}]}\r\n\r\n' +
    'data: {"choices":[{"delta":{"content":[{"type":"text","text":"，世界"}]}}]}\n\n' +
    'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
  for (let size = 1; size <= 29; size++) {
    const d = new C.SSEDecoder();
    for (let i = 0; i < wire.length; i += size) d.feed(wire.slice(i, i + size));
    assert.deepEqual(d.finish(), { text: '你好，世界', finishReason: 'stop' });
    assert.equal(d.done, true);
  }
});

test('SSE surfaces structured errors and rejects malformed records', () => {
  assert.throws(() => new C.SSEDecoder().feed('data: {"error":{"message":"quota exhausted"}}\n\n'), /quota exhausted/);
  assert.throws(() => new C.SSEDecoder().feed('data: invalid\n\n'), /流式/);
});

test('nonstream completions accept text parts and expose truncation', () => {
  assert.deepEqual(C.parseCompletion(JSON.stringify({ choices: [{ message: { content: [{ type: 'text', text: '结果' }] }, finish_reason: 'length' }] })), { text: '结果', finishReason: 'length' });
  assert.throws(() => C.parseCompletion('{}'), /没有返回/);
});

test('document context is bounded, page labels preserved, UTF-16 not split', () => {
  const built = C.buildMessages({ metadata: { title: '测试论文' }, context: '[p. 2]\n' + 'a'.repeat(2100), question: '问题', maxContextChars: 2000 });
  assert.equal(built.excerpt.text.length, 2000);
  assert.equal(built.excerpt.truncated, true);
  assert.match(built.messages.at(-1).content, /\[p\. 2\]/);
  assert.match(built.messages.at(-1).content, /已截断/);
  assert.ok(built.messages.at(-1).content.endsWith('本轮问题：\n问题'));
  assert.equal(C.clip('A😀B', 2).text, 'A');
  const preclipped = C.buildMessages({ context: 'already clipped', contextTruncated: true, question: 'summary' });
  assert.match(preclipped.messages.at(-1).content, /已截断/);
  assert.ok(!built.messages[0].content.includes('测试论文'));
});

test('history includes complete bounded pairs only', () => {
  const history = Array.from({ length: 40 }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', content: String(i) }));
  const result = C.buildMessages({ history, question: 'new' }).messages;
  assert.equal(result.length, 14);
  assert.equal(result[1].role, 'user'); assert.equal(result.at(-2).role, 'assistant');
});

test('model-specific token field and settings validation', () => {
  const s = C.settings({ ...C.DEFAULTS, model: 'gpt-5-mini' });
  assert.equal(C.requestBody(s, []).max_completion_tokens, 2048);
  assert.equal(C.requestBody({ ...s, model: 'deepseek-chat' }, []).max_tokens, 2048);
  assert.throws(() => C.settings({ maxContextChars: 1 }), /2000/);
  assert.throws(() => C.settings({ timeout: NaN }), /整数/);
});

test('AI Markdown cannot introduce active HTML or links', () => {
  const html = C.markdown('# 标题\n**解释**\n<img src=x onerror=alert(1)>\n<script>alert(1)</script>\n[x](javascript:alert(1))\n```html\n</code><iframe src=x>\n```');
  assert.match(html, /<h2>标题<\/h2>/); assert.match(html, /<strong>解释<\/strong>/);
  assert.ok(!/<(?:script|img|iframe|a)\b/.test(html));
  assert.match(html, /&lt;img/);
});

test('error redaction removes actual keys and bearer tokens', () => {
  const out = C.redactError(new Error('Echo fixture-private-key; Authorization: Bearer value123; sk-proj-abc123'), 'fixture-private-key');
  assert.ok(!out.includes('fixture-private-key')); assert.ok(!out.includes('value123')); assert.ok(!out.includes('sk-proj-abc123'));
});
