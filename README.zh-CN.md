<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

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

**升级：** 默认在启动时及运行期间每六小时后台检查正式发布版本，有新版时提示确认后安装；可以在主界面关闭自动检查，也可手动点 **检查更新…**。后台检查失败不会弹窗打断工作，同一版本每次运行最多自动提示一次。

**打开主界面：** 点击状态栏图标即可打开主界面；所有操作均集中在主窗口。主界面提供切换官方账号、保存并切换、使用并打开 Claude 等操作。切换通过修改 Claude 启动时读取的配置实现，尚不支持免重启热切换。「使用并打开 Claude」会在需要时重启客户端。

**模型列表认证失败：** HTTP 401 表示认证被拒绝，不能单凭此状态判断 Token 是否过期。界面会完整显示服务端错误及处理建议；模型留空不会修复认证问题。Claude Code 的账号 Token 是否能用于 Claude Desktop/模型接口仍需实际验证。

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

## v0.2.0 工作区与兼容性

总览、会话、用量、设置和账号操作都在主界面中，状态栏图标用于打开主界面。登录默认在后台运行官方 CLI，授权后自动回填完整 Token；终端登录是可选备用方式。旧版误拼接 `Store` 的凭据可通过修复操作备份并修正。

可选本地网关只监听本机，使用独立本地凭据。首次启用需要至少配置一个模型并重启 Claude；之后切换影响新请求，正在生成的请求保留原账号。使用期间保持切换器运行。切回官方登录模式仍需重启。网关流式响应与路由隔离已通过集成测试；桌面端直连另行实测通过。

会话页只读索引原始记录；导入助手备份配置后启用 Claude 自带导入/导出向导，并保留组织策略。实际迁移在 Claude 中预览并执行。不保证自定义侧边栏分组完整迁移。

用量页在凭据权限允许时读取官方用量。长期 `setup-token` 凭据可能缺少 `user:profile` 权限，此时显示无法读取，不会显示成零。应用不能重置服务端额度。

**已知桌面端行为：** 使用账号 OAuth 凭据时，Claude 的连接预检测可能显示 HTTP 429，而 Code 实际聊天仍成功。2026-11-19 已实测第二个账号返回 `DESKTOP_OK`，重启后原会话继续返回 `RESUME_OK`；第一个账号由官方 CLI 明确报告周额度耗尽。不能只根据预检测或模型列表判断账号是否可用。切换器不修改 Claude 内部预检测逻辑，也不改变其官方登录身份。
