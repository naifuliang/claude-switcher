# Claude Switcher

一个 macOS 菜单栏小工具：一键切换 **Claude Desktop** 是用你登录的 claude.ai 账号额度，还是走 API。

[English →](README.md)

- **官方账号** —— Claude 使用你在 App 里登录的 claude.ai 账号和它的订阅额度。
- **第三方 Endpoint** —— 任何兼容 Anthropic Messages API 的地址（中转 / 网关 / 第三方服务商），自定义 Key 和模型列表；可一键从 `/v1/models` 拉取模型。
- **Anthropic API Key** —— Claude Console 的 `sk-ant-api…` Key，按量计费。
- **另一个 Claude 账号** —— 通过 `claude setup-token` 用另一个账号登录，生成有效期约一年的长期 Token，让 Claude Desktop 消耗那个账号的订阅额度。

切换时会自动重启 Claude（可关闭）。也提供 `claude-switcher` 命令行。

## 安装

一行命令：下载最新版本、校验 SHA-256、安装到 `/Applications` 并启动：

```sh
curl -fsSL https://raw.githubusercontent.com/naifuliang/claude-switcher/main/install.sh | sh
```

**升级：** 再跑一次同样的命令，或者在菜单里点 **检查更新…**。

通用二进制（Apple 芯片和 Intel 都能用），需要 macOS 14 及以上。应用是 ad-hoc 签名、未公证；用 `curl` 安装不会触发浏览器下载时的 Gatekeeper 拦截。

## 使用

1. 点菜单栏图标 → **管理配置…** → **添加配置**。
2. 填好后点 **保存并使用**，Claude 会自动重启并切换。
3. 之后随时在菜单栏里切换；选 **官方账号** 即可回到 claude.ai 登录。

**另一个 Claude 账号**：点 **登录另一个账号生成 Token…**，会打开终端运行 `claude setup-token`，同时浏览器打开授权页——在浏览器里用**另一个**账号登录授权（如果浏览器里登录的是主账号，先退出或用无痕窗口）。Token 会被自动填回。需要先安装 [Claude Code CLI](https://docs.claude.com/en/docs/claude-code)。

### 命令行

```sh
claude-switcher status
claude-switcher list
claude-switcher use official
claude-switcher use "我的中转"        # 或 list 里的编号
claude-switcher use 2 --no-restart
```

安装脚本会把命令链接到 `~/.local/bin`。

## 原理

Claude Desktop 本身支持第三方推理，配置放在 `~/Library/Application Support/Claude-3p/`：

| 文件 | 内容 |
| --- | --- |
| `claude_desktop_config.json` | `deploymentMode`：`"1p"`（claude.ai 登录）或 `"3p"`（第三方推理） |
| `configLibrary/_meta.json` | 已保存的配置列表，以及当前生效的 `appliedId` |
| `configLibrary/<id>.json` | 单个配置：`inferenceProvider`、`inferenceGatewayBaseUrl`、`inferenceGatewayApiKey`、`inferenceAnthropicApiKey`、`inferenceModels` 等 |

Claude Switcher 把每个配置写成这个库里的一项，设置 `appliedId`、切换 `deploymentMode`，然后重启 Claude（它在启动时读取这些文件）。不修改、不打补丁 Claude 应用本身。这些配置也会出现在 Claude 自带的第三方配置编辑器里。

你的配置保存在 `~/Library/Application Support/ClaudeSwitcher/profiles.json`。Key 以明文存储，文件权限 `0600`——和 Claude Desktop 自己存放它们的方式相同。

如果你的 Mac 有 MDM 下发的 Claude 配置（`/Library/Managed Preferences/com.anthropic.claudefordesktop.plist`），它会优先于这里的设置。

## 从源码构建

```sh
git clone https://github.com/naifuliang/claude-switcher && cd claude-switcher
./scripts/make-app.sh          # → dist/Claude Switcher.app 和发布用 zip
open "dist/Claude Switcher.app"
```

需要 Swift 5.9+。通用二进制需要 Xcode；只有 Command Line Tools 时会构建本机架构。

发布：`scripts/release.sh v0.2.0` 会构建并用 `gh` 发布。

## 声明

独立开源项目，与 Anthropic 无关，也未获其认可。“Claude” 是 Anthropic 的商标。使用其他账号的 Token 或第三方 Endpoint 时，请遵守相应提供方的条款。

## 许可证

MIT
