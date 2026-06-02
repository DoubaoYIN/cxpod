# CxPod Menu Bar

macOS menu bar companion for cxpod.

## Build

```bash
cd menubar
bash build.sh            # produces build/CxPod.app
bash build.sh --install  # installs to /Applications or ~/Applications
```

Requires: Swift 5.9+ / macOS 13+.

## Features

- 📋 Lists all running cxpod tmux sessions (read from `~/.cxpod/state/*.json`).
- 🔀 Per-session submenu: attach / switch provider / close.
- 🚀 Launch new session: pick a directory + provider from the menu.
- ⚪/🟢/🔵/… Provider badges from `providers/*.json`.
- 🗂 Codex.app 会话整理：按项目分组、拖拽移动、新建/重命名/删除项目。

## How it talks to cxpod

The app is a thin UI layer; all state lives under `~/.cxpod/`:

| Source                               | Used for              |
|--------------------------------------|-----------------------|
| `~/.cxpod/state/cx-N.json`           | session list + badge  |
| `~/.cxpod/providers/*.json`          | user providers        |
| `<repo>/providers/*.json`            | bundled examples      |
| `cxstart` / `cxuse` CLIs             | all mutations         |

Locator order for the CLIs:
`~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`, `~/Projects/cxpod/bin`.

## Codex.app Session Organizer

入口：菜单栏弹窗里的 **Codex.app → 整理会话**。

这个窗口直接读取 `~/.codex/state_5.sqlite` 的 `threads` 表，并按 `cwd`
显示 Codex.app 左侧边栏里的项目分组。整理操作会同步更新：

- `threads.cwd`
- 对应 rollout JSONL 第一行里的 `payload.cwd`

安全规则：

- 修改前会自动备份 `~/.codex/state_5.sqlite`、`.codex-global-state.json` 和被改写的 rollout 首行。
- Codex.app 正在运行时可以先整理为“待同步”，不会立即写入 Codex 数据。
- 点击“同步到 Codex”时，如果 Codex.app 仍在运行，会提示先退出；待同步改动会保留。
- 删除项目只解除归属，不删除会话，也不删除真实文件夹；会话会进入“待整理-原项目已删除”。
- 同步完成后重新打开 Codex.app 才能看到最新分组。

## Autostart (optional)

Add CxPod.app to **System Settings → General → Login Items**.
