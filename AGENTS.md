# Working on AI Office

- Read README.md and docs/DEVELOPMENT.md before changing build or runtime behavior.
- Keep changes focused. Preserve local API configuration and player saves.
- Never run a live model request as a test. Use `python tools/check.py`; it prepares temporary configuration and blocks model network calls.
- Run Godot only with `--headless` for validation. Do not launch or replace an installed MiniApp unless the user requests it.
- API keys belong in backend environment files only. Never include them, player sessions, or personal screenshots in source or release artifacts.
- Game assets, Noto font license, and audio attribution must accompany distributions. Read THIRD_PARTY_NOTICES.md.
- Source under `miniapps/ai-office` is a template. Build the complete standalone plugin with `python ai-model-party/tools/build_miniapp.py --output build/miniapp`.
- Test consumer behavior when changing model decisions: a successful request is not proof the game used the returned choice.
