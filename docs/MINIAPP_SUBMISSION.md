# 投稿 MiniMax Code MiniApps

本项目的源码仓库与官方 MiniApp 集合是两个目标：源码仓库便于开发；官方集合需要可独立安装的完整插件。

官方入口：<https://github.com/MiniMax-AI/MiniMax-Code-MiniApps>。规则按 2026-10-15 的 CONTRIBUTING.md、docs/package-contract.md 核对；提交前重新查看当前规则。

1. 在本仓库构建完整 `build/miniapp/ai-office/`，运行隔离后端、客户端和 Web 交互测试。
2. 在真实 MiniMax Code 中安装并检查主要功能，记录客户端版本、操作系统、测试项和未验证项。源码准备与模拟回归不等于真实宿主验收。
3. Fork 官方仓库，将完整产物复制为 `plugins/<小写 GitHub 用户名>/ai-office/`，包含隐藏 `.minimax-plugin`、英文 README、可选中文 README、LICENSE、第三方声明及所有运行文件。不要复制虚拟环境、真实 Key、存档或日志。
4. 插件 id 在官方仓库中需唯一。确认 `ai-office` 未被其他作者占用；目录名与 `.minimax-plugin/plugin.json` 的 `name` 一致。若需更名，应同时更新清单、路由、文档和测试。
5. 在官方仓库的英文和中文根 README 表格各加一行，例如下列模板。替换作者占位符，再由官方维护者审阅。

```markdown
| [AI Office](plugins/GITHUB_USERNAME/ai-office/) | Manage five model-powered employees in a pixel office, with client tasks, chats, meetings and quota-aware offline states | [GITHUB_USERNAME](https://github.com/GITHUB_USERNAME) |
```

6. 在官方仓库用 Node.js 22+ 执行其 `npm run check`，确认完整检查无错误。单包检查可先运行：

```bash
node scripts/validate.mjs plugins/GITHUB_USERNAME/ai-office
```

7. PR 描述写清玩法、文件访问、模型网络、首次配置、真实测试环境和具体限制。截图使用模拟局面，不含真实对话或私人信息。

官方仓库当前采用手动复制安装；其 GitHub 插件导入入口不适用于此类 MiniApp。安装及更新时退出宿主，备份放在 `plugins/` 外。按照插件 README 保留私有配置和进度。

此文件仅准备投稿步骤，不表示官方仓库已接收，也没有自动创建外部仓库或 PR。
