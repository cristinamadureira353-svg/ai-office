# Third-party notices and asset provenance

Project code, project-prepared images and synthesized audio are offered under the root LICENSE. Third-party material retains the following licenses. Provider names and model names identify integrations; they do not imply endorsement or grant trademark rights.

## Godot Engine 4.4.1

The source project uses Godot. A built MiniApp also redistributes Godot's Web engine runtime. Godot is MIT licensed. Engine attribution and its third-party notices accompany the package as `LICENSE-GODOT.txt` and `COPYRIGHT-GODOT.txt`.

- Copyright (c) 2014-present Godot Engine contributors.
- Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
- License: LICENSES/Godot-MIT.txt
- Engine third-party notices: LICENSES/Godot-COPYRIGHT.txt
- Upstream: https://github.com/godotengine/godot/tree/4.4.1-stable
- https://godotengine.org/license/

## Noto Sans CJK SC Regular

`godot/assets/fonts/NotoSansCJKsc-Regular.otf` is unmodified Noto Sans CJK SC Regular. Its embedded copyright identifies Adobe, 2014–2021; Noto is a trademark of Google Inc. The font is distributed under SIL Open Font License 1.1, not the project's code license.

- Copyright 2014-2021 Adobe (http://www.adobe.com/).
- License: godot/assets/fonts/OFL.txt; copied into MiniApp packages as LICENSE-NOTO.txt.
- Upstream: https://github.com/notofonts/noto-cjk/tree/main/Sans

## Project artwork

The 19 PNG atlases under `godot/assets/cozy_office/atlases/` were generated with AI for this project and prepared into named Godot resources. They include architecture, furniture, UI, five employees, clients and activity frames. No Stardew Valley artwork or downloaded sample-game sprites are included in this source distribution.

`godot/assets/cozy_office/manifest.json` records asset names, regions and atlas hashes. See docs/ASSETS.md. No personal generation paths or original reference photographs are included.

## Project audio

The ten OGG files under `godot/assets/sfx/` are synthesized by `ai-model-party/tools/audio_gen.py`. The source distribution does not include downloaded music or sampled third-party recordings. Asset descriptions are in `godot/assets/sfx/AUDIO_LICENSES.md`.

## MiniMax Bot (merged engine and team panel)

The Bot engine and the team panel bundled with this MiniApp come from MiniMax Bot, an official
MiniMax Code plugin. They are redistributed unmodified except for the adaptation described below.

- Name: MiniMax Bot
- Version: 0.7.24
- Copyright (c) 2026 MiniMax
- License: MIT — full text in `miniapps/ai-office/LICENSE-MINIMAX-BOT.txt` (copied into built packages)
- Upstream: https://github.com/MiniMax-AI/MiniMax-Code-MiniApps/tree/main/plugins/minimax-ai/minimax-bot
- Merged baseline commit: `513895a1283649f3969ef37b013debfe4e4c7845`

Local adaptations (no task, memory, or scheduling logic was rewritten):

- The upstream Node entry is mounted as `miniapp/node/bot_bridge.mjs` instead of opening its own
  port, so the plugin keeps one listener on the Host-assigned address.
- Bot state is stored under `context.dataDir/bot/` so game settings and saves stay separate.
- The Bot snapshot is served at `GET /api/bot/state`; `GET /api/state` remains the game's.
- Four `../client/` imports were repointed to `../client/bot/` to match the merged layout.
- The panel declares a local favicon; its assets live under `miniapp/client/bot/`.

## Installed dependencies

Python and Node dependencies are installed separately and are not vendored in source or MiniApp packages. Preserve their own notices if redistributing an environment:

- Flask / Werkzeug: BSD-3-Clause — https://github.com/pallets/flask / https://github.com/pallets/werkzeug
- Requests: Apache-2.0 — https://github.com/psf/requests
- python-dotenv: BSD-3-Clause — https://github.com/theskumar/python-dotenv
- Playwright (development checks): Apache-2.0 — https://github.com/microsoft/playwright
- NumPy (optional audio regeneration): BSD-3-Clause — https://github.com/numpy/numpy
- FFmpeg (optional, installed separately): license depends on the selected build — https://ffmpeg.org/legal.html
