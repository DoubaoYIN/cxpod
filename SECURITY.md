# Security Policy

## Secret Handling

- Do not commit real provider JSON files, `.env` files, OAuth files, logs, or anything under `~/.cxpod/`.
- Store real API keys in `~/.cxpod/env`; provider JSON should reference them with `env_key` or `${ENV:VAR_NAME}`.
- Treat `~/.cxpod/env` as a shell file: keep it to simple `NAME='value'` assignments, do not paste commands into it, and keep permissions at `600`.
- Run `scripts/check-no-secrets.sh` before publishing changes.

## Sensitive Runtime Behavior

- Menu bar balance checks use local API keys to call the configured provider `base_url` from your machine. They do not call a cxpod server. Auto-refresh starts after 5 minutes and then runs hourly. Disable it with `CXPOD_DISABLE_BALANCE=1` in `~/.cxpod/env`.
- Relay keys are sourced from window-local `provider.env` files with `600` permissions so they do not appear in tmux start commands.
- Context bridge is opt-in with `CXPOD_CONTEXT_BRIDGE=1`; writing bridge content into project `AGENTS.md` additionally requires `CXPOD_CONTEXT_BRIDGE_INJECT_AGENTS=1`.
- Codex.app GUI launchd environment injection is opt-in with `CXPOD_GUI_LAUNCHD_ENV=1`.
- `cx-app-switch` and the menu bar session organizer create local backups before rewriting Codex.app metadata.

## Reporting

Please open a GitHub issue with minimal public detail if you find a security problem, and ask for a private channel. Do not include real credentials, private provider URLs, local rollout contents, or OAuth files in the issue body.
