# 参与开发

欢迎修复可玩性、界面、动作和配置问题。提交前说明触发条件、预期行为与实际行为，涉及 UI 时使用模拟局面截图，不包含真实对话或密钥。

1. 创建自己的分支，保持修改范围集中。
2. 运行 `python tools/check.py`；客户端修改再运行 `python tools/check.py --godot`。构建与完整交互检查见 docs/DEVELOPMENT.md。
3. 模型决策修改需验证结果如何被游戏使用。后端测试应阻断网络，使用临时存档。
4. 不提交 `.env`、玩家存档、日志、依赖、引擎缓存和构建包。分发 ZIP 放入 GitHub Releases。
5. 新增素材需注明来源、生成方式和适用许可证，保留第三方声明。

报告安全问题请按 SECURITY.md，避免在公开 Issue 中贴敏感信息。投稿 MiniMax 官方仓库前另按 docs/MINIAPP_SUBMISSION.md 完成独立安装检查。
