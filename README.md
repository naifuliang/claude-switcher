<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

# Claude Switcher

A macOS menu bar app that switches **Claude Desktop** between your signed-in claude.ai account and API-based inference — in one click.

[中文文档 →](README.zh-CN.md)

- **Official account** — Claude uses the claude.ai account you signed in with, and its subscription quota.
- **Third-party endpoint** — any Anthropic Messages API compatible base URL (gateway, proxy, provider) with your key and your own model list. One click fetches the model list from `/v1/models`.
- **Anthropic API key** — a `sk-ant-api…` key from the Claude Console, billed per token.
- **Another Claude account** — signs in with a second account through `claude setup-token` and uses its long-lived (about one year) token, so Claude Desktop spends that account's subscription quota.

Switching restarts Claude for you (you can turn that off). A `claude-switcher` command does the same from a terminal.

## Install

One line — downloads the latest release, checks its SHA-256, installs it into `/Applications` and starts it:

```sh
curl -fsSL https://raw.githubusercontent.com/naifuliang/claude-switcher/main/install.sh | sh
```

**Update:** run the same command again, or choose **Check for Updates…** in the menu.

The build is universal (Apple silicon and Intel) and needs macOS 14 or later. It is ad-hoc signed, not notarized; installing with `curl` avoids the Gatekeeper prompt a browser download would get.

## Use

1. Click the menu bar icon → **Manage Profiles…** → **Add Profile**.
2. Fill it in and press **Save & Use**. Claude restarts on the new setting.
3. Switch any time from the menu bar. **Official account** brings back your claude.ai sign-in.

For **Another Claude account**, press **Sign in with another account…**. A Terminal window runs `claude setup-token` and a browser page opens: sign in with the *other* account there (log out first, or use a private window, if the browser is signed in to your main one). The token is picked up automatically. This needs the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) installed.

### Command line

```sh
claude-switcher status
claude-switcher list
claude-switcher use official
claude-switcher use "My Gateway"     # or its number from `list`
claude-switcher use 2 --no-restart
```

The installer links the command into `~/.local/bin`.

## How it works

Claude Desktop has built-in support for third-party inference. It keeps those settings in `~/Library/Application Support/Claude-3p/`:

| File | What it holds |
| --- | --- |
| `claude_desktop_config.json` | `deploymentMode`: `"1p"` (claude.ai sign-in) or `"3p"` (third-party inference) |
| `configLibrary/_meta.json` | the list of saved configurations and the `appliedId` in use |
| `configLibrary/<id>.json` | one configuration: `inferenceProvider`, `inferenceGatewayBaseUrl`, `inferenceGatewayApiKey`, `inferenceAnthropicApiKey`, `inferenceModels`, … |

Claude Switcher writes each profile as one configuration in that library, sets `appliedId`, flips `deploymentMode`, and restarts Claude, which reads these files at launch. It does not patch or modify the Claude app. Profiles also appear in Claude's own third-party configuration editor.

Your profiles live in `~/Library/Application Support/ClaudeSwitcher/profiles.json`. Keys are stored in plain text with `0600` permissions — the same way Claude Desktop stores them in its own files.

If your Mac has an MDM-managed Claude profile (`/Library/Managed Preferences/com.anthropic.claudefordesktop.plist`), that profile takes precedence over anything set here.

## Build from source

```sh
git clone https://github.com/naifuliang/claude-switcher && cd claude-switcher
./scripts/make-app.sh          # → dist/Claude Switcher.app and a release zip
open "dist/Claude Switcher.app"
```

Requires Swift 5.9+. A universal build needs Xcode; with only the Command Line Tools you get a build for your own architecture.

Releases: `scripts/release.sh v0.2.0` builds and publishes with `gh`.

```
Sources/ClaudeSwitcher/
  App.swift            entry point, menu bar menu, manager window
  AppModel.swift       state, switching, alerts, updates
  ClaudeDesktop.swift  reads/writes Claude Desktop's settings, restarts Claude
  Profile.swift        profile model and storage
  ManagerView.swift    profile manager UI
  Terminal.swift       setup-token login, model fetching, updater
  CLI.swift            claude-switcher command
```

## Disclaimer

An independent open-source project, not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic. Using another account's token or a third-party endpoint is subject to the terms of whoever provides it.

## License

MIT
