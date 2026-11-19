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

**Update:** checks for stable releases at launch and every six hours while running, then asks before installing. Disable automatic checks in the main window or check manually at any time. Background failures are silent; each release is automatically offered at most once per app session.

**Open the main window:** click the menu bar icon. All controls are in the main window. The main window includes switching to the official account, Save & Switch, and Use & Open Claude. Direct settings are read by Claude at launch. Optional local-gateway switching is described below. Use & Open Claude restarts the client when needed.

**Model-list authentication errors:** HTTP 401 means authentication was rejected, not necessarily that a token expired. The full server message and recovery guidance are displayed. Leaving Models empty does not fix authentication. Model-list success does not prove that message generation is available.

The build is universal (Apple silicon and Intel) and needs macOS 14 or later. It is ad-hoc signed, not notarized; installing with `curl` avoids the Gatekeeper prompt a browser download would get.

## Use

1. Click the menu bar icon to open the main window, then add an account.
2. Fill it in and press **Save & Switch** or **Use & Open Claude**.
3. Switch accounts from the main window. **Official account** brings back your claude.ai sign-in.

For **Another Claude account**, press **Sign in with another account…**. `claude setup-token` runs in a background pseudo-terminal and a browser page opens: sign in with the *other* account there (log out first, or use a private window, if the browser is signed in to your main one). The token is picked up automatically. This needs the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) installed.

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

Your profiles live in `~/Library/Application Support/ClaudeSwitcher/profiles.json`. Switcher keys are stored in plain text with `0600` permissions. Claude Desktop may separately encrypt its own copy.

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

## v0.2.0 workspace and compatibility

Overview, Sessions, Usage, Settings and account editors are available in the main window. Background login automatically fills the completed token; Terminal login remains an explicit fallback. The old parser's appended `Store` suffix has a targeted, backed-up repair action.

Optional local gateway: listens on loopback with a private local credential. Initial activation requires a configured model and a Claude restart. Later profile switches affect new requests; in-flight streams keep their original account. Keep Switcher running. Switching to official signed-in mode still requires a restart. Streaming and route isolation are covered by an integration test; direct Desktop inference was verified separately.

Sessions indexes original local metadata without moving it. The import helper enables Claude's built-in import/export wizard with a backup and preserves organization policy. Preview and perform imports in Claude. Custom sidebar-group fidelity is not guaranteed.

Usage reads the provider's usage endpoint when the credential permits it. Long-lived `setup-token` credentials may lack `user:profile`; in that case usage is unavailable, not zero. Server allowance cannot be reset by this app.

**Known Desktop behavior:** with an account OAuth token, Claude's preflight may show a generic HTTP 429 while actual Code messages succeed. Verified on 2026-11-19: the second account returned `DESKTOP_OK`, then `RESUME_OK` after restarting. The first account's official CLI reported its weekly limit was exhausted. Do not infer account validity or remaining allowance solely from the preflight or model-list check. The switcher does not modify Claude's preflight implementation or change the official signed-in identity.
