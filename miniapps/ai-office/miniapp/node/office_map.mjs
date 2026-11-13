// @ts-check
import { readFile, rename, writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';

/** The office roles the panel can bind a real Bot to, in display order. */
export const OFFICE_ROLES = ['m3', 'flash', 'longcat', 'kimi', 'step5'];

const EMPTY = () => ({ version: 1, bindings: {}, stale: {}, requests: {} });

/**
 * Who is who: a game role (m3…) bound to a real Bot id, plus which office request produced
 * which task batch. It never stores task state — that stays in the Bot store.
 */
export class OfficeMap {
  /** @param {string} dir the Bot data directory @param {{warn?: Function}} [logger] */
  constructor(dir, logger) {
    this.path = join(dir, 'office-map.json');
    this.logger = logger ?? { warn() {} };
    this.state = EMPTY();
    this.writeChain = Promise.resolve();
  }

  async init() {
    await mkdir(join(this.path, '..'), { recursive: true });
    let raw;
    try {
      raw = await readFile(this.path, 'utf8');
    } catch (error) {
      if (error.code !== 'ENOENT') this.logger.warn?.('ai_office.office_map.unreadable');
      return;
    }
    try {
      const parsed = JSON.parse(raw);
      this.state = {
        version: 1,
        bindings: parsed?.bindings && typeof parsed.bindings === 'object' ? { ...parsed.bindings } : {},
        stale: parsed?.stale && typeof parsed.stale === 'object' ? { ...parsed.stale } : {},
        requests: parsed?.requests && typeof parsed.requests === 'object' ? { ...parsed.requests } : {},
      };
    } catch {
      // A damaged map must not stop the game: keep a copy and start clean.
      await rename(this.path, this.path + '.corrupt-' + Date.now()).catch(() => {});
      this.logger.warn?.('ai_office.office_map.corrupt');
      this.state = EMPTY();
    }
  }

  save() {
    this.writeChain = this.writeChain.then(async () => {
      const temporary = this.path + '.tmp';
      await writeFile(temporary, JSON.stringify(this.state, null, 2));
      await rename(temporary, this.path);
    }).catch((error) => this.logger.warn?.('ai_office.office_map.write_failed'));
    return this.writeChain;
  }

  bindings() {
    return { ...this.state.bindings };
  }

  /** Bind a role to a Bot id; `null` clears it. */
  async bind(role, botId) {
    if (!OFFICE_ROLES.includes(role)) throw new Error('unknown_role');
    if (botId) this.state.bindings[role] = botId;
    else delete this.state.bindings[role];
    delete this.state.stale[role];
    await this.save();
  }

  /**
   * Give the real team its desks.
   *
   * The Chief never takes a desk — it supervises. Every other Bot fills a free desk in
   * roster order (the order the Bot team was created in), and the first time desks are
   * handed out the roster is shuffled, so two players never end up with the same pairing.
   * A binding is never silently replaced: once a Bot sits at a desk it keeps that desk,
   * so the character under a name never jumps around.
   *
   * When a Bot is deleted its desk is released and remembers who left, which the panel
   * shows as an empty desk waiting to be filled.
   * @param {Array<{id: string, name?: string, isMain?: boolean}>} bots
   */
  async reconcile(bots) {
    const ids = new Set(bots.map(bot => bot.id));
    let changed = false;
    for (const role of OFFICE_ROLES) {
      const bound = this.state.bindings[role];
      if (bound && !ids.has(bound)) {
        this.state.stale[role] = bound;
        delete this.state.bindings[role];
        changed = true;
      }
    }
    // One Bot can only sit at one desk.
    const claimed = new Set(Object.values(this.state.bindings));
    const members = bots.filter(bot => !bot.isMain && !claimed.has(bot.id));
    if (members.length) {
      const free = OFFICE_ROLES.filter(role => !this.state.bindings[role]);
      const shuffled = members.slice();
      for (let i = shuffled.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        const swap = shuffled[i];
        shuffled[i] = shuffled[j];
        shuffled[j] = swap;
      }
      shuffled.forEach((bot, index) => {
        const role = free[index];
        if (!role) return;
        this.state.bindings[role] = bot.id;
        delete this.state.stale[role];
        changed = true;
      });
    }
    if (changed) await this.save();
    return changed;
  }

  /** Remember an office request the moment the player submits it, before any batch exists. */
  async recordRequest(requestId, at) {
    this.state.requests[requestId] = { batch_id: null, at };
    await this.pruneRequests();
    await this.save();
  }

  /** Attach the batch a request actually produced once it is observed. */
  async recordBatch(requestId, batchId) {
    const entry = this.state.requests[requestId];
    if (entry && typeof entry === 'object') entry.batch_id = batchId;
    else this.state.requests[requestId] = { batch_id: batchId, at: Date.now() };
    await this.save();
  }

  requestOf(requestId) {
    const entry = this.state.requests[requestId];
    if (!entry) return undefined;
    return typeof entry === 'string' ? { batch_id: entry, at: 0 } : entry;
  }

  /** Requests that still wait for a batch, newest first. */
  pendingRequests() {
    return Object.entries(this.state.requests)
      .filter(([, entry]) => !(typeof entry === 'object' ? entry.batch_id : entry))
      .map(([requestId, entry]) => ({ requestId, at: typeof entry === 'object' ? entry.at : 0 }))
      .sort((a, b) => b.at - a.at);
  }

  /** Drop very old request records so the file cannot grow without bound. */
  async pruneRequests(keep = 40) {
    const entries = Object.entries(this.state.requests);
    if (entries.length <= keep) return;
    this.state.requests = Object.fromEntries(entries.slice(-keep));
  }
}
