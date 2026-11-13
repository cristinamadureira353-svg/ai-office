// @ts-check
// The Host's own token ledger. The Bot store meters the Mini App's own turns; the real token
// counts of every model call live in the Host's runtime database, and the office panel shows
// them. That database belongs to the Host: it is only ever opened read-only, through the
// sqlite3 CLI, and a read that cannot happen is reported instead of thrown — a panel must
// still render when the ledger cannot be read.
import { execFile } from 'node:child_process';
import { stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** The Host's runtime state database; the token ledger is one table inside it. */
const DB_PATH = join(homedir(), '.minimax', 'v2', 'sqlite', 'runtime-state.sqlite');
/** Every call keeps its raw reply, so the file is gigabytes: a query is cut off, never awaited. */
const QUERY_TIMEOUT_MS = 3000;
/** One answer per day count is shared for this long, so a refresh does not re-scan the file. */
const CACHE_MS = 60_000;
/** A row whose model is NULL or empty is reported under this name. */
const UNRECORDED = '未记录';

/** @type {Map<number, { at: number, value: Promise<any> }>} */
const cache = new Map();

/** The ledger query: token counts per model since `since`, heaviest input first. */
const ledgerSql = (since) =>
  'SELECT model, COUNT(*), SUM(input_tokens), SUM(output_tokens),'
  + ' SUM(cache_read_tokens), SUM(cache_write_tokens)'
  + ` FROM local_runtime_token_usage WHERE ts >= ${since} GROUP BY model ORDER BY 3 DESC`;

/**
 * One read-only query against the Host's ledger. Rejects with a readable reason when the
 * database cannot be read: no sqlite3 on this machine, a query cut off by the timeout, or a
 * schema the statement no longer matches.
 * @param {string} sql
 * @returns {Promise<string>} the CLI's stdout
 */
function queryLedger(sql) {
  return new Promise((resolve, reject) => {
    execFile('sqlite3', ['-readonly', '-batch', '-noheader', DB_PATH, sql], { timeout: QUERY_TIMEOUT_MS }, (error, stdout) => {
      if (!error) {
        resolve(String(stdout ?? ''));
        return;
      }
      if (error.code === 'ENOENT') reject(new Error('sqlite3 命令不可用'));
      else if (error.killed) reject(new Error('查询超时'));
      else reject(new Error('查询失败'));
    });
  });
}

/** A SUM that came back NULL (every value in the group was NULL) counts as zero. */
const count = (value) => {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
};

/**
 * The CLI prints one `model|calls|input|output|cacheRead|cacheWrite` line per model; the
 * totals are the sums over those lines, so one scan answers both questions.
 * @param {string} stdout
 */
function readRows(stdout) {
  const total = { calls: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  const models = [];
  for (const line of stdout.split('\n')) {
    if (!line.trim()) continue;
    const [model, calls, input, output, cacheRead, cacheWrite] = line.split('|');
    // A line without the leading columns is not a data row (a notice, a torn write).
    if (calls === undefined || input === undefined || output === undefined) continue;
    const row = {
      model: String(model ?? '').trim() || UNRECORDED,
      calls: count(calls),
      input: count(input),
      output: count(output),
    };
    total.calls += row.calls;
    total.input += row.input;
    total.output += row.output;
    total.cacheRead += count(cacheRead);
    total.cacheWrite += count(cacheWrite);
    models.push(row);
  }
  return { total, models };
}

/**
 * One window of the ledger. Resolves with the answer or with `{ ok: false }`; it never
 * rejects, so a caller that only wants the numbers needs no error handling of its own.
 * @param {number} days @param {number} at
 * @returns {Promise<any>}
 */
async function readWindow(days, at) {
  const since = Math.trunc(at - days * 86_400_000);
  let info;
  try {
    info = await stat(DB_PATH);
  } catch {
    return { ok: false, error: '宿主用量数据库不存在' };
  }
  if (!info.isFile()) return { ok: false, error: '宿主用量数据库不可读' };
  let stdout;
  try {
    stdout = await queryLedger(ledgerSql(since));
  } catch (error) {
    return { ok: false, error: error.message };
  }
  const { total, models } = readRows(stdout);
  return { ok: true, since, total, models };
}

/**
 * What the Host's models were called with over the last `days` days: call counts and token
 * totals per model, read from the Host's own ledger.
 *
 * Never throws. A missing database, no sqlite3 on this machine, a cut-off query and a changed
 * schema all come back as `{ ok: false, error }`, because the caller is a panel that must
 * still render. Answers are shared for a minute per day count; a caller that pins `now` asks
 * for one specific window and is answered fresh.
 * @param {{ days?: number, now?: number }} [options]
 * @returns {Promise<any>}
 */
export async function readModelUsage({ days = 1, now } = {}) {
  const at = now ?? Date.now();
  const span = Number(days);
  if (!Number.isInteger(span) || span < 1 || span > 90 || !Number.isFinite(at)) {
    return { ok: false, error: 'days 须为 1 到 90 之间的整数' };
  }
  // A pinned `now` is a one-off window: it must not be answered from, or stored in, the cache.
  const pinned = now !== undefined;
  const cached = pinned ? undefined : cache.get(span);
  if (cached && Date.now() - cached.at < CACHE_MS) return cached.value;
  const value = readWindow(span, at);
  if (!pinned) cache.set(span, { at: Date.now(), value });
  return value;
}
