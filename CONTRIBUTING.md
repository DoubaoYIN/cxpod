# Contributing

Thanks for helping improve cxpod.

## Local Setup

```bash
git clone https://github.com/DoubaoYIN/cxpod.git
cd cxpod
bash install.sh
scripts/install-hooks.sh
```

## Before A Pull Request

Run the same lightweight checks used by maintainers:

```bash
bash -n install.sh uninstall.sh scripts/check-no-secrets.sh scripts/install-hooks.sh scripts/check-codex-session-organizer.sh bin/cxstart bin/cxuse bin/cxnow bin/cx-status bin/cx-app-switch bin/lib/common.sh menubar/build.sh
python3 -m py_compile bin/lib/extract-context.py
./scripts/check-no-secrets.sh
git diff --check
swift build -c release --package-path menubar
```

## Security Rules

- Do not commit real provider JSON, API keys, OAuth files, rollout files, logs, or anything under `~/.cxpod/`.
- Use `providers/relay.example.json` for examples and keep real provider files in `~/.cxpod/providers/`.
- Put real keys in `~/.cxpod/env`, not in tracked files.
- Keep user-specific paths and machine-specific probe output out of committed docs.
