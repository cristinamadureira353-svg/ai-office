# 开发与验证

## 环境

- Python 3.9+，运行依赖见 `ai-model-party/requirements.txt`。
- Godot **4.4.1** 与同版本 Web 导出模板；仅后端检查不需要 Godot。
- Node.js 22+ 与锁定的 Playwright 开发依赖；仅完整 Web 交互测试需要浏览器。
- 音频已包含成品；重新合成才需要 NumPy、FFmpeg。

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r ai-model-party/requirements.txt
npm ci --ignore-scripts
```

Windows 使用 `.venv\Scripts\python.exe`。以下构建工具使用 Python 与参数数组，不依赖 shell；现有完整浏览器夹具会生成 POSIX 可执行 Python 包装器，因此完整 Web 测试目前在 macOS/Linux 运行，未验证 Windows 测试执行。

## 目录

```text
godot/                  客户端、贴图、字体、音频、地图及动作测试
ai-model-party/server/  本地游戏状态、模型、决策、存档与 MiniApp 桥接
ai-model-party/tests/   隔离的后端回归
ai-model-party/tools/   MiniApp 构建与可选音频合成
miniapps/ai-office/     MiniApp 源码模板、通用配置引导及交互测试
tools/                  公开边界检查与测试运行器
docs/                   安装、验证、素材来源和投稿说明
LICENSES/               第三方许可
```

目录名 `ai-model-party` 保留现有代码的相对结构，避免构建及资源路径发生无关迁移。历史开发日志、原始参考图、旧原型服务、原生启动器、真实存档和旧构建不属于公开源码。

## 默认检查：不使用真实 API

```bash
.venv/bin/python tools/check.py
```

先检查 Git 可提交文件中是否混入密钥格式、私人路径、依赖或构建产物，再逐个运行隔离后端测试。每个测试进程创建临时 `.env` 和存档目录，清空继承的模型 Key，并阻断 Requests 网络请求。此命令不启动实际游戏主循环。

覆盖额度耗尽与重启、未配置 Jev、旧冲突恢复、工作中断恢复、会议座位指令，以及 Jev 顺序是否被复盘会实际使用。请使用该入口，避免把真实 Key 的连通性测试混入自动检查。

## 客户端检查

```bash
# Godot 在 PATH 中，或设置 GODOT 为执行文件路径
.venv/bin/python tools/check.py --godot
```

在后台导入工程并运行客户端脚本。运行器扫描脚本/解析错误，不只依赖 Godot 的退出码；仅放行已有负向 JSON 用例和已知 headless 音频退出诊断。测试将后端端口设为 65499，不接入玩家的开发服务。

## 构建独立 MiniApp

在 Godot 编辑器的导出设置中安装 4.4.1 Web 模板，然后：

```bash
.venv/bin/python ai-model-party/tools/build_miniapp.py --output build/miniapp
# 也可：--godot /path/to/Godot
```

产物目录含完整插件、ZIP、文件哈希、导入/导出日志。输出目录必须不存在。打包使用白名单后端模块，不复制 `.env`、存档和依赖。大资源 gzip 压缩，必要时切片；每个文件不超过 16 MiB，插件不超过 64 MiB。

`miniapps/ai-office/` 是源码模板，缺少生成的 Web 和后端资源，不能直接复制安装。构建产物可以独立安装，不依赖本仓库。

## 完整 Web 交互回归

```bash
npm ci --ignore-scripts
npx --no-install playwright install chromium
.venv/bin/python tools/test_miniapp.py --plugin build/miniapp/ai-office
```

Linux 可能需要 Playwright 文档列出的浏览器系统依赖。也可用 `--chromium <本地 Chrome/Chromium 执行文件>`；浏览器始终以 headless 方式运行，不抢前台窗口。证据写入忽略的 `build/test-evidence/`。

测试使用临时 Host 数据目录和模拟模型响应，覆盖首次引导、配置持久化、重开、聊天、宕机、裁决、座位与尺寸。测试结束时关闭其自身进程。真实付费 API、长局平衡和真实宿主属于另外的验收范围。

## CI 与发布

GitHub Actions 对 Python 3.9 / 3.12 运行公开边界和隔离后端检查，并检查 Node 入口语法。它不自动发布 Release，不调用真实模型，也不声称覆盖真实 MiniMax 宿主。

发布前应在干净克隆中构建、运行完整 Web 回归，按官方校验器验证完整插件，并完成真实 MiniMax 安装实玩。只把源码提交到 Git；ZIP 放 GitHub Releases。GitHub 仓库名称、所有者和最终许可证在首次公开前确认。
