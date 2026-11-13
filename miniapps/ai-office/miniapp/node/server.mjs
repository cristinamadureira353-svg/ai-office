import { createServer } from 'node:http';
import { readFile, writeFile, rename, mkdir, stat } from 'node:fs/promises';
import { join, basename, isAbsolute } from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createBotBridge } from './bot_bridge.mjs';

// Bot 路由前缀：这些路径全部交给 Bot 桥接，其余仍走游戏链路。
const BOT_API_PREFIXES = ['/api/bot/', '/api/chats/', '/api/bots', '/api/groups', '/api/tasks/','/api/helpers/',
  '/api/models', '/api/memory/', '/api/schedules', '/api/usage', '/api/media', '/api/uploads', '/api/avatars',
  '/api/locale', '/api/approvals/', '/api/events', '/mcp/minimax-bot',
  // 办公室新增只读/私聊接口：精确路径，不用 '/api/office/' 前缀，
  // 这样 /api/office/panel、/api/office/task 等仍由下面显式处理，不受影响。
  '/api/office/stats', '/api/office/chat'];

const ROUTES = new Map([['/api/state','GET'], ['/api/saves','GET'], ['/api/command','POST'],
  ['/api/chat','POST'], ['/api/save','POST'], ['/api/load','POST'], ['/api/newday','POST'], ['/api/accept','POST']]);

export async function start(context) {
  const clientRoot = join(context.pluginRoot, 'miniapp/client');
  const assets = JSON.parse(await readFile(join(context.pluginRoot, 'miniapp/node/assets.json'), 'utf8'));
  const setupGuide = (await readFile(join(context.pluginRoot, 'SETUP_PROMPT.md'), 'utf8')).trim();
  const settingsPath = join(context.dataDir, 'settings.json');
  await mkdir(context.dataDir, { recursive: true });
  let settings = null;
  try { settings = JSON.parse(await readFile(settingsPath, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') context.logger.warn('ai-office.settings.unreadable'); }
  let child = null, lines = null, starting = null, disposed = false, sequence = 0, savingSettings = false, checkingPython = null;
  const pending = new Map();
  const sockets = new Set();

  // Bot 引擎按需初始化：只有在真正访问 Bot 页面或接口时才创建，
  // 这样未玩 Bot 的玩家仍保持原游戏冷启动行为（dataDir 不被提前写入）。
  let botStarting = null;
  let botRuntime = null;
  function ensureBot() {
    if (disposed) throw new Error('disposed');
    if (botRuntime) return Promise.resolve(botRuntime);
    if (botStarting) return botStarting;
    botStarting = createBotBridge(context)
      .then(runtime => { botRuntime = runtime; return runtime; })
      .finally(() => { botStarting = null; });
    return botStarting;
  }
  const isBotPath = path => BOT_API_PREFIXES.some(prefix =>
    prefix.endsWith('/') ? path.startsWith(prefix) : (path === prefix || path.startsWith(prefix + '/')));
  const BOT_STATIC = /^\/bot\/(skins\/[a-z]+\.png|[a-z0-9-]+\.(js|css|svg|png))$/;

  function json(response, status, data) {
    response.writeHead(status, { 'content-type':'application/json; charset=utf-8', 'cache-control':'no-store' });
    response.end(JSON.stringify(data));
  }
  function rejectPending() {
    for (const response of pending.values()) {
      if (!response.headersSent) json(response, 503, { ok:false, msg:'游戏服务已停止，重新打开游戏即可继续。' });
      else response.end();
    }
    pending.clear();
  }
  async function backend() {
    if (disposed) throw new Error('disposed');
    if (starting) return starting;
    if (child && child.exitCode === null) return child;
    if (!settings) throw new Error('not_configured');
    starting = new Promise((resolve, reject) => {
      const args = ['-u', join(context.pluginRoot, 'miniapp/node/backend/server/miniapp_bridge.py'),
        '--data-dir', context.dataDir, '--env-file', settings.envFile];
      if (settings.initialSave) args.push('--initial-save', settings.initialSave);
      const process = spawn(settings.pythonPath, args, {
        cwd:join(context.pluginRoot, 'miniapp/node/backend'), shell:false, windowsHide:true,
        stdio:['pipe','pipe','pipe'], env:{ ...globalThis.process.env, PYTHONDONTWRITEBYTECODE:'1' }
      });
      child = process;
      let ready = false;
      const timer = setTimeout(() => { process.kill(); reject(new Error('backend_timeout')); }, 12000);
      process.stderr.on('data', () => {}); // 不把可能包含路径或凭据的依赖诊断发给页面或 Host。
      lines = createInterface({ input:process.stdout });
      lines.on('line', raw => {
        let frame;
        try { frame = JSON.parse(raw); } catch { return; }
        if (frame.type === 'ready') {
          ready = true; clearTimeout(timer); resolve(process); return;
        }
        const response = pending.get(frame.id);
        if (!response || response.destroyed) return;
        if (frame.type === 'head') response.writeHead(frame.status, {
          'content-type':frame.contentType, 'cache-control':'no-store', 'x-accel-buffering':'no'
        });
        else if (frame.type === 'data') response.write(frame.body);
        else if (frame.type === 'end') { pending.delete(frame.id); response.end(); }
        else if (frame.type === 'error') {
          pending.delete(frame.id);
          if (!response.headersSent) json(response, 503, { ok:false, msg:frame.message });
          else response.end();
        }
      });
      process.once('error', () => { clearTimeout(timer); reject(new Error('backend_start_failed')); });
      process.once('exit', () => {
        clearTimeout(timer); lines?.close();
        if (child === process) child = null;
        rejectPending();
        if (!ready) reject(new Error('backend_start_failed'));
      });
    }).finally(() => { starting = null; });
    return starting;
  }

  /**
   * Ask the Python backend once and buffer its reply, so a response can be enriched before it
   * reaches the client. Only used for small JSON routes such as /api/state.
   */
  async function proxyBuffered(path, method, body) {
    const process = await backend();
    if (disposed) throw new Error('disposed');
    const id = ++sequence;
    const collector = {
      status: 0, contentType: 'application/json; charset=utf-8', headersSent: false, destroyed: false,
      chunks: [],
      writeHead(status, headers) { this.status = status; this.headersSent = true; if (headers?.['content-type']) this.contentType = headers['content-type']; return this; },
      write(chunk) { this.chunks.push(Buffer.from(chunk)); return true; },
      end(chunk) { if (chunk) this.chunks.push(Buffer.from(chunk)); if (!this.finished) { this.finished = true; this.resolve?.(); } },
      on() {},
    };
    const done = new Promise((resolve, reject) => {
      collector.resolve = resolve;
      collector.reject = reject;
    });
    pending.set(id, collector);
    process.stdin.write(JSON.stringify({ id, method, path, body: body ?? {} }) + '\n');
    await done;
    return { status: collector.status, contentType: collector.contentType, text: Buffer.concat(collector.chunks).toString('utf8') };
  }

  async function bodyOf(request) {
    const chunks = []; let size = 0;
    for await (const chunk of request) {
      size += chunk.length;
      if (size > 65536) throw new Error('body_too_large');
      chunks.push(chunk);
    }
    const text = Buffer.concat(chunks).toString('utf8');
    const body = text ? JSON.parse(text) : {};
    if (!body || Array.isArray(body) || typeof body !== 'object') throw new Error('invalid_body');
    return body;
  }
  async function validateSettings(body) {
    const result = {};
    for (const key of ['pythonPath', 'envFile', 'initialSave']) {
      const value = body[key] || '';
      if (typeof value !== 'string' || value.includes('\0') || (!value && key !== 'initialSave') || (value && !isAbsolute(value)))
        throw new Error('invalid_settings');
      if (value && !(await stat(value)).isFile()) throw new Error('invalid_settings');
      result[key] = value;
    }
    if (!/^python(?:3(?:\.\d+)?)?(?:\.exe)?$/i.test(basename(result.pythonPath))) throw new Error('invalid_python');
    if (child) throw new Error('backend_already_running');
    await new Promise((resolve, reject) => {
      const probe = spawn(result.pythonPath, ['-c', 'import flask, requests, dotenv'], {
        shell:false, windowsHide:true, stdio:'ignore',
        env:{ ...globalThis.process.env, PYTHONDONTWRITEBYTECODE:'1' }
      });
      checkingPython = probe;
      const timer = setTimeout(() => { probe.kill('SIGKILL'); }, 8000);
      function finish(error) {
        clearTimeout(timer);
        if (checkingPython === probe) checkingPython = null;
        if (error) reject(new Error('python_not_ready')); else resolve();
      }
      probe.once('error', () => finish(true));
      probe.once('exit', code => finish(code !== 0));
      if (disposed) probe.kill('SIGKILL');
    });
    if (disposed) throw new Error('disposed');
    return result;
  }

  function setupPrompt() {
    const runtime = { configurationEndpoint:`http://${context.listen.host}:${context.listen.port}/api/settings`,
      pluginRoot:context.pluginRoot, dataDir:context.dataDir };
    return setupGuide + '\n\n本次运行信息（由 MiniApp 自动提供，供 AI 执行配置；保持页面打开直到配置完成）：\n'
      + JSON.stringify(runtime, null, 2);
  }

  /**
   * 把官方 bot.html 原样发出，只在 </body> 前注入一条固定的「回到办公室」条。
   * 注入内容是常量，不含任何用户数据；官方文件保持字节不变，便于日后同步上游。
   */
  async function sendBotPanelWithBackLink(runtime, response) {
    const source = join(clientRoot, 'bot/bot.html');
    let html = '';
    try {
      html = await readFile(source, 'utf8');
    } catch {
      return runtime.handle({ url: '/bot', method: 'GET', headers: {} }, response);
    }
    // 插进面板顶部的工具条，紧挨品牌名左侧。.side-top 是 flex 布局，所以窗口
    // 宽度变化时按钮会自然跟随，不会像固定浮层那样跑到奇怪的位置。
    const anchor = '<header class="side-top">';
    const button = [
      '<a id="office-back" href="/ai-office" title="回到办公室" aria-label="回到办公室"',
      ' style="display:inline-flex;align-items:center;justify-content:center;width:32px;height:32px;',
      'flex:0 0 auto;border-radius:50%;border:1px solid currentColor;color:inherit;',
      'text-decoration:none;font-size:17px;line-height:1">←</a>',
    ].join('');
    let patched = html;
    if (html.includes(anchor)) {
      patched = html.replace(anchor, anchor + button);
    } else {
      // 官方结构变了也要保证返回入口存在：退回成浮层。
      const fallback = [
        '<div id="office-back" style="position:fixed;left:12px;top:12px;z-index:9999">',
        '<a href="/ai-office" style="display:inline-block;padding:7px 14px;border-radius:6px;',
        'background:#35201e;border:1px solid #97572d;color:#f4e6c7;font:13px system-ui,sans-serif;',
        'text-decoration:none">← 回到办公室</a></div>',
      ].join('');
      patched = html.includes('</body>') ? html.replace('</body>', fallback + '</body>') : html + fallback;
    }
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    response.end(patched);
  }

  const server = createServer(async (request, response) => {
    try {
      const host = request.headers.host || '';
      if (![`${context.listen.host}:${context.listen.port}`, `localhost:${context.listen.port}`].includes(host))
        return json(response, 403, { ok:false, msg:'无效的本地请求' });
      const origin = request.headers.origin;
      if (origin && ![`http://${context.listen.host}:${context.listen.port}`, `http://localhost:${context.listen.port}`].includes(origin))
        return json(response, 403, { ok:false, msg:'无效的请求来源' });
      const url = new URL(request.url || '/', 'http://miniapp.local');
      if (request.method === 'GET' && url.pathname === '/api/settings')
        return json(response, 200, { ok:true, configured:!!settings, settings, backendRunning:!!child });
      if (request.method === 'GET' && url.pathname === '/api/setup')
        return json(response, 200, { ok:true, prompt:setupPrompt() });
      // Bot 面板入口：静态页面本身不需要引擎，但先初始化以便页面随后拿到状态。
      if (request.method === 'GET' && (url.pathname === '/bot' || url.pathname === '/bot/')) {
        // 从办公室跳过来时，顶部加一条「回到办公室」；官方 bot.html 一个字节都不改。
        if (url.searchParams.get('from') === 'office') {
          const runtime = await ensureBot();
          return sendBotPanelWithBackLink(runtime, response);
        }
        const runtime = await ensureBot();
        return runtime.handle(request, response);
      }
      if (request.method === 'GET' && BOT_STATIC.test(url.pathname)) {
        const runtime = await ensureBot();
        return runtime.handle(request, response);
      }
      // Bot 接口一律交给桥接；游戏自有接口（含 GET /api/state）仍在下面处理。
      if (isBotPath(url.pathname)) {
        const runtime = await ensureBot();
        return runtime.handle(request, response);
      }
      // 设置接口按方法分派：GET/POST 是游戏配置，PUT 是 Bot 设置。
      if (request.method === 'PUT' && url.pathname === '/api/settings') {
        const runtime = await ensureBot();
        return runtime.handle(request, response);
      }
      if (request.method === 'POST' && url.pathname === '/api/settings') {
        if (savingSettings) return json(response, 409, { ok:false, msg:'正在保存配置，请稍后再试' });
        savingSettings = true;
        try {
          const next = await validateSettings(await bodyOf(request));
          const temporary = settingsPath + '.tmp';
          await writeFile(temporary, JSON.stringify(next), { mode:0o600 });
          await rename(temporary, settingsPath); settings = next;
          return json(response, 200, { ok:true });
        } finally { savingSettings = false; }
      }
      // 办公室面板：只读聚合真实 Bot 状态。
      if (request.method === 'GET' && url.pathname === '/api/office/panel') {
        const runtime = await ensureBot();
        return json(response, 200, { ok: true, bot_panel: await runtime.buildOfficePanel() });
      }
      // 办公室派活：把玩家的一句话交给 Chief，立刻返回回执。
      if (request.method === 'POST' && url.pathname === '/api/office/task') {
        const runtime = await ensureBot();
        try {
          const body = await bodyOf(request);
          const receipt = await runtime.submitOfficeRequest(body?.text);
          return json(response, 200, { ok: true, ...receipt });
        } catch (error) {
          const msg = {
            chief_missing: '还没有 Chief，先打开 Bot 面板一次',
            empty_text: '说点什么吧',
            text_too_long: '太长了，一次最多 2000 字',
          }[error.message] ?? '这次没交出去，稍后再试';
          return json(response, 400, { ok: false, msg });
        }
      }
      // 办公室打回：把返工意见真的发回 Chief，由它重新派单（会消耗一次模型调用）。
      if (request.method === 'POST' && url.pathname === '/api/office/reject') {
        const runtime = await ensureBot();
        try {
          const body = await bodyOf(request);
          const result = await runtime.rejectOfficeRequest(body?.request_id, body?.reason);
          return json(response, 200, { ok: true, ...result });
        } catch (error) {
          const msg = {
            chief_missing: '还没有 Chief，先打开 Bot 面板一次',
            empty_reason: '写一句要返工的意见吧',
            reason_too_long: '太长了，一次最多 2000 字',
          }[error.message] ?? '这次没送出去，稍后再试';
          return json(response, 400, { ok: false, msg });
        }
      }
      // 游戏快照仍然由 Python 生成；Bot 就绪时在同一响应里附上只读面板。
      if (request.method === 'GET' && url.pathname === '/api/state' && botRuntime) {
        const upstream = await proxyBuffered('/api/state', 'GET', {});
        let payload = null;
        try { payload = JSON.parse(upstream.text); } catch { payload = null; }
        if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
          response.writeHead(upstream.status, { 'content-type': upstream.contentType, 'cache-control': 'no-store' });
          return response.end(upstream.text);
        }
        payload.bot_panel = await botRuntime.buildOfficePanel();
        return json(response, 200, payload);
      }
      if (ROUTES.get(url.pathname) === request.method) {
        if (pending.size >= 32) return json(response, 429, { ok:false, msg:'操作较多，请稍后再试' });
        const body = request.method === 'POST' ? await bodyOf(request) : {};
        const process = await backend();
        if (disposed || response.destroyed) return;
        const id = ++sequence;
        pending.set(id, response);
        response.on('close', () => {
          if (pending.delete(id) && !process.killed && process.stdin.writable)
            process.stdin.write(JSON.stringify({ type:'cancel', id }) + '\n');
        });
        process.stdin.write(JSON.stringify({ id, method:request.method, path:url.pathname, body }) + '\n');
        return;
      }
      const key = url.pathname === '/ai-office' ? '/index.html' : url.pathname;
      const asset = assets[key];
      if (asset && ['GET','HEAD'].includes(request.method)) {
        response.writeHead(200, { 'content-type':asset.type, 'cache-control':'no-cache',
          'content-length':asset.bytes, ...(asset.gzip ? { 'content-encoding':'gzip' } : {}) });
        if (request.method === 'GET') {
          for (const file of asset.parts || [asset.file]) {
            if (response.destroyed) break;
            const bytes = await readFile(join(clientRoot, file));
            if (!response.write(bytes)) await new Promise(resolve => {
              response.once('drain', resolve); response.once('close', resolve);
            });
          }
        }
        response.end(); return;
      }
      json(response, 404, { ok:false, msg:'找不到这个页面' });
    } catch (error) {
      if (!response.headersSent) json(response, 503, { ok:false, msg:error.message === 'python_not_ready'
        ? 'Python 依赖尚未准备好，请让 AI 安装 Flask、requests、python-dotenv 后重新保存配置。'
        : '请检查本地 Python 和 API 配置，重新打开后再试。' });
      else response.end();
    }
  });
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(context.listen.port, context.listen.host, resolve);
  });
  context.logger.info('ai-office.ready');
  const dispose = async () => {
    if (disposed) return;
    disposed = true;
    context.signal.removeEventListener('abort', onAbort);
    // Bot 先停：不再接新工作，等它的写入链落盘后再收尾 HTTP。
    const bot = botRuntime ?? (botStarting ? await botStarting.catch(() => null) : null);
    botRuntime = null;
    if (bot) await bot.dispose().catch(() => {});
    if (checkingPython && checkingPython.exitCode === null) {
      const probe = checkingPython;
      await new Promise(resolve => {
        probe.once('exit', resolve); probe.once('error', resolve); probe.kill('SIGKILL');
      });
    }
    const process = child;
    if (process && process.exitCode === null) {
      await new Promise(resolve => {
        const timer = setTimeout(() => process.kill('SIGTERM'), 5000);
        const force = setTimeout(() => process.kill('SIGKILL'), 7000);
        process.once('exit', () => { clearTimeout(timer); clearTimeout(force); resolve(); });
        if (process.stdin.writable) process.stdin.write('{"type":"shutdown"}\n');
      });
    }
    rejectPending(); lines?.close();
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
  };
  const onAbort = () => { void dispose(); };
  context.signal.addEventListener('abort', onAbort, { once:true });
  if (context.signal.aborted) await dispose();
  return { dispose };
}
