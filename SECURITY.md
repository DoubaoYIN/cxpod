# Security Policy

## Secret Handling

- Do not commit real provider JSON files, `.env` files, OAuth files, logs, or anything under `~/.cxpod/`.
- Store real API keys in `~/.cxpod/env`; provider JSON should reference them with `env_key` or `${ENV:VAR_NAME}`.
- Run `scripts/check-no-secrets.sh` before publishing changes.

## Sensitive Runtime Behavior

- Context bridge is opt-in with `CXPOD_CONTEXT_BRIDGE=1`; writing bridge content into project `AGENTS.md` additionally requires `CXPOD_CONTEXT_BRIDGE_INJECT_AGENTS=1`.
- Codex.app GUI launchd environment injection is opt-in with `CXPOD_GUI_LAUNCHD_ENV=1`.
- `cx-app-switch` and the menu bar session organizer create local backups before rewriting Codex.app metadata.

## Reporting

Please open a GitHub issue if you find a security problem. Do not include real credentials, private provider URLs, local rollout contents, or OAuth files in the issue body.
