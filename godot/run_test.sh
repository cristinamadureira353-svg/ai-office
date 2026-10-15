#!/bin/bash
# Godot headless 测试运行器
#
# 为什么需要它：Godot 的 --quit / --script 即使发生 SCRIPT ERROR 也会返回退出码 0，
# 意味着"测试通过"可能是假的。本包装器扫描输出里的错误标记，强制非零退出。
#
# 用法：
#   ./run_test.sh res://tests/t_pathfinding.gd      # 跑 T1
#   ./run_test.sh --scene                           # 只验证主场景能加载
#
# 退出码：0=通过  1=测试断言失败  2=脚本/解析错误  3=运行异常
#
# 放行名单（**逐条**列出，不许用 grep -v 之外的花样）：
#   1) 'Parse JSON failed' —— 来自 t_ui_smoke 里"故意喂坏 JSON"的负向用例，
#      是预期中的引擎日志，不是脚本问题。
#   2) 'ObjectDB instances leaked at exit' / 'N resources still in use at exit'
#      —— ★t_audio 才暴露出来的一条。Godot 的 AudioServer 在 **headless 下**
#      退出时不会释放 OggVorbis 的播放对象（AudioStreamPlaybackOggVorbis /
#      OggPacketSequencePlayback），--verbose 里能看到的清单清一色是这几个类型，
#      没有任何一条是本项目的脚本对象。
#      实测 t_audio 有 34/34 断言全过、`--verbose | grep -c 'SCRIPT ERROR|Parse Error'`
#      恒为 0，所以这条不是脚本错误；游戏正常退出时也不会出现（headless 专有）。
#      ★放行它**不等于**放弃检查：下面仍然会统计 SCRIPT ERROR 的条数，
#        只要有脚本错误照样 exit 2。这两条是精确串匹配，不是一刀切的 ERROR:。
#      加这条之前我先试过在脚本里 stop()/free()/多等两帧，全都不管用——
#      是引擎侧的，不是"我忘了清理"。

GODOT="${GODOT:-$HOME/Applications/Godot.app/Contents/MacOS/Godot}"
PROJ="${PROJ:-$(cd "$(dirname "$0")" && pwd)}"

case "${1:-}" in
  --scene)
    OUT=$("$GODOT" --headless --path "$PROJ" --quit 2>&1); CODE=$?
    ;;
  -h|--help)
    echo "用法: $0 res://tests/xxx.gd | $0 --scene"; exit 0 ;;
  *)
    if [ -z "$1" ]; then echo "缺参数"; exit 3; fi
    OUT=$("$GODOT" --headless --path "$PROJ" --script "$1" 2>&1); CODE=$?
    ;;
esac

echo "$OUT"

# ★先把 ANSI 颜色码剥掉再判：Godot 的输出是 [1;31mERROR:[0m 这种带色，
#   不剥的话 "^ERROR:" 之类的锚点一个都匹配不上，放行名单会整条失效。
CLEAN=$(echo "$OUT" | sed -e 's/\x1b\[[0-9;]*m//g')
SCRIPT_ERRS=$(echo "$CLEAN" | grep -cE 'SCRIPT ERROR|Parse Error|Failed to load')
FILTERED=$(echo "$CLEAN" \
  | grep -v 'Parse JSON failed' \
  | grep -v 'ObjectDB instances leaked at exit' \
  | grep -vE 'resources still in use at exit')

if [ "$SCRIPT_ERRS" -gt 0 ] || echo "$FILTERED" | grep -qE 'SCRIPT ERROR|Parse Error|Failed to load|ERROR:'; then
  echo "────────────────────────────"
  echo "✗ 检测到脚本/解析错误（Godot 本身仍返回 $CODE，此处强制判失败）"
  exit 2
fi

# 放行了引擎关停噪声时要**显式说出来**，不能悄悄吞掉——
# 否则以后真有泄漏，这条提示也不会有人看见。
if echo "$CLEAN" | grep -q 'ObjectDB instances leaked at exit'; then
  echo "────────────────────────────"
  echo "! 已放行 headless 音频关停噪声（ObjectDB / resources still in use）"
  echo "  脚本错误数：$SCRIPT_ERRS"
fi

if [ "$CODE" -ne 0 ]; then
  echo "────────────────────────────"
  echo "✗ 脚本返回非零退出码 $CODE"
  exit 1
fi

echo "────────────────────────────"
echo "✓ 通过（无错误标记，退出码 0）"
exit 0
