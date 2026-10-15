# AI Office MiniApp

[简体中文](README.zh-CN.md)

A pixel office management game featuring five model-powered employees: M3, Flash, LongCat, Kimi and Step5. Manage client tasks, review deliveries, chat with employees, organize breaks and meetings, and balance money, stamina and mood.

## Install and open

Use the complete built plugin, not the source template. Quit MiniMax Code and copy the entire `ai-office` directory, including hidden `.minimax-plugin/`, into your MiniMax data directory's `plugins/` folder (default: `~/.minimax/plugins/ai-office/`). Keep any old-plugin backup outside `plugins/`. Reopen the host and ask the Agent to open “AI 事务所”.

The first-run page provides a generic setup prompt. Send it to the Agent for step-by-step provider selection, key acquisition, Python setup and configuration. At least one employee provider is required. Jev is optional: reuse an existing OpenRouter key, obtain one through its official website, or skip it and keep local behavior rules. Later launches reuse the saved private configuration.

Python 3.9+ with Flask, requests and python-dotenv is required. The Agent can prepare an environment from `miniapp/node/requirements.txt`; no game source checkout or Godot installation is required for players.

## Keys and quota

`MINIMAX_API_KEY` serves M3 and Flash. Other employees use `LONGCAT_API_KEY`, `KIMI_API_KEY` (Kimi Code), and `STEPFUN_API_KEY` (Step Plan). Jev uses a separate `OPENROUTER_API_KEY`. Provider model names and access depend on current account permissions and availability.

Quota exhaustion, invalid credentials or unavailable models freeze the corresponding employee in a “brain offline” state. The employee stops work, movement and further model calls. After repairing the account or configuration, select the employee and use the manual reboot control for one short check. Temporary rate limits and network failures do not permanently freeze the employee.

## Data & access

- Keys are read only by the local Python backend, never sent to the game frontend or included in the package. Configuration APIs accept file paths and do not return keys.
- Settings and subsequent saves are stored in the Host-provided private `context.dataDir`. A player-selected existing JSON save may be read once for initial import. Original source saves are not overwritten.
- Node listens on the Host-provided loopback address and port, validates Host/Origin, serves fixed asset/API routes, and starts one configured Python process through a private JSON-lines protocol. It does not use the desktop development API port.
- Gameplay sends task and dialogue context to `api.minimaxi.com`, `api.longcat.chat`, `api.kimi.com`, and `api.stepfun.com` according to configured employee keys. Jev requests additionally use `openrouter.ai`. These requests consume the player's own provider quota.
- Reading first-run guidance does not launch model requests. Setup checks only local Python dependencies. The MiniApp does not read the host's login credentials, buy credits, or poll account balances.
- Closing the MiniApp saves private progress and stops its own Python child and request streams. No host restart or foreground game launch is automated.

## Tested environment

Version **0.5.10**. Source uses Godot 4.4.1 Web export and a local Python backend. In the source repository, run `python ai-model-party/tools/build_miniapp.py --output build/miniapp` from its root; use the generated complete `ai-office` folder for installation.

The local preparation uses isolated mock-provider tests and headless browsers. The original MiniApp contract was tested with MiniMax Code 3.0.73; the complete package is also checked against the official repository validator during preparation. Real paid-provider responses, Windows/Linux host play, Chinese IME interaction and long-term balance are not covered by those simulations. See the source repository's validation record for exact completed checks.

MIT applies to project code and assets; the bundled font and engine retain their own licenses. Preserve LICENSE, LICENSE-NOTO.txt, LICENSE-GODOT.txt, COPYRIGHT-GODOT.txt and THIRD_PARTY_NOTICES.md in complete packages. This game is independently developed and does not imply provider endorsement.
