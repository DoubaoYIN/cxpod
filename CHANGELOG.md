# Changelog

## v0.1.4

- Rewrote the README as a zero-background user guide.
- Added plain-language explanations for Codex, provider, relay, `CODEX_HOME`, and tmux windows.
- Added a copy-paste first-run workflow, relay setup options, uninstall steps, architecture diagram, implementation notes, and FAQ.

## v0.1.3

- Added `CHANGELOG.md`, `CONTRIBUTING.md`, and `.gitattributes` for cleaner reuse and release archives.
- Made Git hook installation opt-in for normal users with `CXPOD_INSTALL_HOOKS=1`.
- Removed early internal probe notes and scripts from the public mainline.
- Documented a safer inspect-before-run install path in the README.

## v0.1.2

- Added a product-oriented README with a clear project explanation, first-run flow, and relay provider setup.
- Added one-line Mac install via `curl -fsSL https://raw.githubusercontent.com/DoubaoYIN/cxpod/main/install.sh | bash`.
- Updated `install.sh` to clone or update the repo, install CLI commands, create `~/.cxpod/`, and build/install `CxPod.app` when Swift is available.
- Updated menu bar app installation to use `/Applications` when writable and fall back to `~/Applications`.

## v0.1.1

- Hardened runtime secret handling and local file permissions.
- Disabled context bridge and GUI launchd environment injection by default.
- Prevented cxpod-only secret metadata from being rendered into Codex `config.toml`.
- Added local backups before rewriting Codex.app metadata.
- Added `SECURITY.md` and broadened repository secret scanning.

## v0.1.0

- Published a clean public snapshot with CLI provider switching and the macOS menu bar app.
