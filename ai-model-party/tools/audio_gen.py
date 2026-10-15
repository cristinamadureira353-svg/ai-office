"""M4-1 音频生成：程序化合成 BGM + 办公室环境音

全部使用波形与噪声合成，不使用第三方录音。产物适用项目根目录 LICENSE。

合成的好处是这个游戏本来就需要的：
  · 8-bit 方波/三角波 = 像素风的正统音色，和 M3 那些手绘贴图是一套语言
  · 长度、速度、音量**全部可控**——"不吵、能长时间听"可以直接量化验证
  · 循环点精确：包络在循环边界前衰减到 0，噪声部分首尾交叉淡化，无缝

产出（$GODOT_PROJ/assets/sfx/）：
  bgm_office.ogg    46s 循环 BGM，Am-F-C-G，84 BPM
  amb_office.ogg    20s 循环环境音：风扇嗡鸣 + 空调气流 + 远处键盘
  key_1..3.ogg      键盘音（供 M4-2 距离衰减用），3 个可分辨变体

重新生成需要单独安装 NumPy 与 FFmpeg；工具会重写项目中的音频文件。

    .venv/bin/python tools/audio_gen.py
"""
import os
import subprocess
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(os.path.dirname(ROOT), "godot", "assets", "sfx")
SR = 22050          # 环境音/BGM 都不需要高保真，22050 让文件小一半
FFMPEG = "ffmpeg"
# BGM 与环境音统一到这个文件级响度；运行时 -18/-24dB 两个增益才是控制混音的那一层
TARGET_RMS_DB = -20.0

# ── 音乐参数 ────────────────────────────────────────────────────────────────
BPM = 84.0
BEAT = 60.0 / BPM          # 0.7143 s
BARS = 16
BAR = BEAT * 4             # 2.857 s
LOOP_SEC = BAR * BARS      # 45.71 s

# Am - F - C - G  每个和弦 4 小节，i-VI-III-VII
# 半音数（相对 A2=110Hz），配合根音频率
NOTE_A2, NOTE_C3, NOTE_D3, NOTE_E3, NOTE_F3, NOTE_G3 = 0, 3, 5, 7, 8, 10
PROG = [
    # (根音 offset, 和弦音 offsets, 小节数)
    (NOTE_A2, [0, 3, 7, 12], 4),      # Am
    (NOTE_F3 - 12, [0, 4, 7, 12], 4),  # F
    (NOTE_C3, [0, 4, 7, 12], 4),      # C
    (NOTE_G3 - 12, [0, 4, 7, 12], 4),  # G
]


def midi_hz(semi, base=110.0):
    """A2 = 110Hz，semi 是相对半音数。"""
    return base * (2.0 ** (semi / 12.0))


def adsr(n, a, d, s, r):
    """标准 ADSR 包络，长度 n（采样点）。"""
    env = np.zeros(n, dtype=np.float64)
    a_n, d_n = int(a * SR), int(d * SR)
    r_n = int(r * SR)
    s_n = max(0, n - a_n - d_n - r_n)
    i = 0
    for seg, val in ((a_n, 1.0), (d_n, None), (s_n, s), (r_n, None)):
        if seg <= 0:
            continue
        t = np.arange(seg) / SR
        if val is None and seg == d_n:
            env[i:i + seg] = np.linspace(1.0, s, seg)
        elif val is None:
            env[i:i + seg] = np.linspace(s, 0.0, seg)
        else:
            env[i:i + seg] = np.linspace(0.0, val, seg)
        i += seg
    env[i:] = 0.0
    return env


def osc(kind, n, freq, phase=0.0):
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * freq * t + phase)
    if kind == "sin":
        return x
    if kind == "tri":                      # 三角波：比方波柔，是"不吵"的主力
        return 2.0 / np.pi * np.arcsin(np.clip(x, -1, 1))
    if kind == "sq":
        return np.sign(x)
    raise ValueError(kind)


def _butter(x, cutoff, order, kind, sr=SR):
    """FFT 域巴特沃斯滤波（零相位、非递归）。

    ★为什么不用递归双二阶：我第一版写成
        y = w @ b; ya = concat([y[0], y[0]], y); y = y - w2 @ fb
      看着像 Direct Form I，其实**反馈项吃的是前向值 y 而不是输出值**——
      那是前向滤波器，不是 IIR。表现是通带增益整体差 40dB
      （恒定输入 1.0 → 稳态 0.0104，应为 1.0），而频谱"形状"看着还挺像，
      差点被当成"就是这个音色"放过去。
      而向量化 IIR 本来就不能这么写：反馈是递归的，没有闭式解。

    改成直接在频域乘响应：
        |H(f)| = 1 / sqrt(1 + (f/fc)^(2n))          低通
        |H(f)| = (f/fc)^(2n) / (1 + (f/fc)^(2n))   高通
      非递归、可精确验证、零相位（离线生成素材不需要保持群延迟）。
    """
    n = len(x)
    f = np.fft.rfftfreq(n, 1.0 / sr)
    r = (f / float(cutoff)) ** (2 * order)
    H = 1.0 / np.sqrt(1.0 + r) if kind == "low" else r / (1.0 + r)
    return np.fft.irfft(np.fft.rfft(x) * H, n=n)


def biquad_lowpass(x, cutoff, order=4, sr=SR):
    """巴特沃斯低通：风扇嗡鸣只留低频、方波垫底削毛刺都用它。"""
    return _butter(x, cutoff, order, "low", sr)


def highpass(x, cutoff, order=4, sr=SR):
    """巴特沃斯高通：把棕噪的低频隆隆声切掉，只留空调气流的"嘶"。"""
    return _butter(x, cutoff, order, "high", sr)


def add(buf, sig, at):
    """把 sig 叠加到 buf 的 at 位置（采样点），越界自动截断。"""
    i = int(at)
    if i >= len(buf):
        return
    n = min(len(sig), len(buf) - i)
    if n > 0:
        buf[i:i + n] += sig[:n]


def note(freq, dur, kind="tri", amp=0.2, a=0.01, d=0.06, s=0.7, r=0.12,
         vib=0.0):
    n = int(dur * SR)
    if n <= 0:
        return np.zeros(0)
    x = osc(kind, n, freq)
    if vib:
        t = np.arange(n) / SR
        x *= (1.0 + vib * np.sin(2 * np.pi * 5.2 * t))
    return amp * adsr(n, a, d, s, r) * x


def build_bgm():
    """Am-F-C-G 循环，方波打底、三角波主旋律，留白为主——不吵是硬要求。"""
    n = int(LOOP_SEC * SR)
    buf = np.zeros(n, dtype=np.float64)

    for ci, (root, tones, half_bars) in enumerate(PROG):
        start_bar = ci * 4          # 每个和弦占 4 小节（prog 里写的 half_bars=8 → 4 bar）
        # 低音：每小节一个根音，5 度和弦音补一点
        for b in range(4):
            t0 = (start_bar + b) * BAR
            add(buf, note(midi_hz(root - 12), BEAT * 1.6, "tri", 0.16,
                          a=0.02, d=0.10, s=0.55, r=0.35), t0 * SR)
            add(buf, note(midi_hz(root), BEAT * 1.1, "tri", 0.085,
                          a=0.02, d=0.10, s=0.45, r=0.30), t0 * SR)
            add(buf, note(midi_hz(root + 7), BEAT * 1.1, "tri", 0.075,
                          a=0.03, d=0.12, s=0.40, r=0.30), t0 * SR)
        # 和弦垫：方波过一个低通，变成软软的 pad
        for b in range(4):
            t0 = (start_bar + b) * BAR
            for k, semi in enumerate(tones[:3]):
                v = note(midi_hz(root + 12 + semi), BAR * 0.92, "sq", 0.035,
                         a=0.25, d=0.35, s=0.6, r=0.40)
                add(buf, biquad_lowpass(v, 1400.0), t0 * SR)
        # 主旋律：五声音阶点缀，8 分音符网格上挑几个落点（确定性，不用随机）
        for b in range(4):
            for step in (0, 2, 4, 6):
                t0 = (start_bar + b) * BAR + step * BEAT / 2
                semi = tones[step % len(tones)] + 12
                amp = 0.10 if step in (2, 6) else 0.055
                add(buf, note(midi_hz(root + 12 + semi), BEAT * 0.42, "tri",
                              amp, a=0.015, d=0.07, s=0.5, r=0.16,
                              vib=0.004), t0 * SR)

    # ★按 RMS 归一，不按峰值：运行时 -18dB/-24dB 两个增益才是控制混音的那一层，
    #   文件本身的响度应该大致持平。第一版 BGM 归一到峰值 0.42、环境音归一到 0.33，
    #   结果环境音文件响度反而比 BGM 高 4.7dB，-24dB 增益只补回来 1.3dB——
    #   "底噪永远在音乐下面"这条根本没成立。
    buf = normalize_rms_peak(buf, TARGET_RMS_DB, 0.55)
    return fade_edges(buf, 0.004)


def rms(x):
    return float(np.sqrt((x ** 2).mean()))


def scale_rms(x, target):
    """按 **RMS** 缩放，不是按峰值。

    ★这是本模块第一版的真 bug：棕噪用 cumsum 出来是**峰值极大、RMS 极小**的
      （低频能量全堆在几个样本上）。按峰值归一化之后 RMS 只有 0.02 左右，
      风扇底噪其实比键盘声还轻——体检数据是「频谱重心 5012Hz、
      4kHz 以上占 71%」，即底噪被高频点击盖住，听着像静电不像办公室。
      改成按 RMS 定标，每一层的声音大小才是可控的。
    """
    r = rms(x)
    return x * (target / r) if r > 1e-9 else x


def build_ambient():
    """办公室底噪：50Hz 工频嗡鸣 + 风扇宽带噪声 + 空调气流 + 远处零星键盘声。

    频谱体检的验收线：重心落在 0.8~2.2kHz、4kHz 以上占比 <20%。
    风扇必须是最底层那层（按 RMS 定标），键盘要**闷**——"远处"两个字的
    物理含义就是高频被空气和距离吃掉了，所以点击要过 1.4kHz 低通。
    """
    dur = 20.0
    n = int(dur * SR)
    rng = np.random.default_rng(20261005)   # 固定种子，可复现

    # 风扇：棕噪过 260Hz 低通，再叠一个很慢的起伏
    brown = rng.standard_normal(n)
    brown = np.cumsum(brown)
    fan = scale_rms(biquad_lowpass(brown, 260.0), 0.105)
    fan *= 1.0 + 0.10 * np.sin(2 * np.pi * 0.07 * np.arange(n) / SR)

    # 工频嗡鸣 50Hz + 100Hz 谐波，很轻
    t = np.arange(n) / SR
    hum = (0.030 * np.sin(2 * np.pi * 50 * t)
           + 0.014 * np.sin(2 * np.pi * 100 * t + 0.7))

    # 空调气流：700~2600Hz 带通白噪，音量压到风扇的十分之一以下。
    # 频谱体检实测：这一层每抬高一档，环境音重心就跟着往上走——
    # 0.014/900Hz 时重心 2259Hz（超 800~2200 的验收线）。
    # 办公室的"嘶"应该是被厚地毯和墙吸过的，不是耳边吹的。
    hiss = scale_rms(highpass(biquad_lowpass(rng.standard_normal(n), 2600.0),
                              700.0), 0.0085)

    buf = fan + hum + hiss

    # 远处键盘：每 0.6~1.6 秒一簇，每簇 2~5 下。
    # 关键在低通截止：1.4kHz。"远处的键盘"如果按近处的高频去合成，
    # 它会变成整个环境音的频谱主体——第一版就是这么把底噪吃掉的。
    pos = 0.4
    while pos < dur - 0.5:
        pos += rng.uniform(0.6, 1.6)
        for _ in range(int(rng.integers(2, 6))):
            i = int(pos * SR)
            ln = int(0.006 * SR)
            click = rng.standard_normal(ln) * np.exp(-np.arange(ln) / (0.0012 * SR))
            click = biquad_lowpass(click, 1400.0) * 0.022
            add(buf, click, i + int(rng.integers(0, int(0.09 * SR))))
            pos += rng.uniform(0.07, 0.14)

    buf = normalize_rms_peak(buf, TARGET_RMS_DB, 0.55)
    return crossfade_loop(buf, 0.5)


def build_keyclicks():
    """键盘音 3 个变体，M4-2 用。短促、带机械感、**彼此要能分辨**。

    ★第一版三个变体只改了截止频率（2600/3400/2100），测出来的频谱重心是
      1608 / 1644 / 2040 Hz——前两个几乎重合，随机播听起来就是同一个音。
      现在连"键帽回弹的基频"和衰减长度一起拉开：一个清脆、一个中频、
      一个闷响，M4-2 随机换的时候才有听感差别。
    """
    rng = np.random.default_rng(7)
    out = []
    for (cut, decay, click_amp, body_hz, body_amp) in [
            (3200.0, 0.008, 0.55, 190.0, 0.22),   # 清脆哒
            (1800.0, 0.011, 0.50, 430.0, 0.34),   # 中频咔
            (1100.0, 0.016, 0.58, 150.0, 0.46),   # 闷响咚
    ]:
        n = int(0.090 * SR)
        t = np.arange(n) / SR
        noise = rng.standard_normal(n) * np.exp(-t / decay)
        noise = biquad_lowpass(noise, cut) * click_amp
        body = np.sin(2 * np.pi * body_hz * t) * np.exp(-t / (decay * 2.4)) * body_amp
        out.append(normalize_rms_peak(noise + body, -18.0, 0.78))
    return out


# 五个角色的"手感"（M4-2）。键击音的**音色**在这里，
# **节奏**由客户端按 interval_ms 排，两者分开才调得动。
# 力度/衰减/基频三项决定"重不重、脆不脆、干净不干净"；
# 手速差异主要靠 interval_ms（见 scripts/typing_audio.gd）。
TYPING = {
    #        力度  衰减   基频   截止    杂音   描述
    "m3":      (0.50, 0.009, 175.0, 3000.0, 0.55, "慢而稳，键程轻"),
    "flash":   (0.66, 0.007, 250.0, 3600.0, 0.62, "快而乱，键程重"),
    "longcat": (0.52, 0.010, 205.0, 2700.0, 0.50, "中等，平稳"),
    "kimi":    (0.42, 0.013, 145.0, 2100.0, 0.44, "犹豫，键程软有拖尾"),
    "step5":   (0.74, 0.008, 310.0, 3300.0, 0.58, "重而急，敲得实"),
}


def build_typing():
    """五个角色各一条键击音（单次按键，不是整段打字）。"""
    rng = np.random.default_rng(31415)
    out = {}
    for who, (amp, decay, base_hz, cut, noise_mix, _desc) in TYPING.items():
        n = int(0.10 * SR)
        t = np.arange(n) / SR
        # 触底：极短噪声脉冲
        noise = rng.standard_normal(n) * np.exp(-t / decay)
        noise = biquad_lowpass(noise, cut) * amp * noise_mix
        # 键帽回弹：基频越高敲得越"实"（Step5 310Hz vs Kimi 145Hz）
        body = np.sin(2 * np.pi * base_hz * t) * np.exp(-t / (decay * 2.6)) * amp * 0.55
        # 第二谐波：重手速角色的金属感
        h2 = np.sin(2 * np.pi * base_hz * 2.02 * t) * np.exp(-t / (decay * 1.3)) * amp * 0.16
        out[who] = normalize_rms_peak(noise + body + h2, -20.0, 0.85)
    return out


def normalize_rms_peak(x, rms_db, peak_cap):
    """先按 RMS 定标到 rms_db，再保证峰值不超 peak_cap。"""
    x = scale_rms(x, 10.0 ** (rms_db / 20.0))
    m = float(np.max(np.abs(x)))
    if m > peak_cap:
        x = x * (peak_cap / m)
    return x


def normalize(x, peak):
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 1e-9 else x


def fade_edges(x, sec):
    """首尾各淡入淡出，保证循环点无爆音。"""
    k = max(1, int(sec * SR))
    r = np.linspace(0.0, 1.0, k)
    x[:k] *= r
    x[-k:] *= r[::-1]
    return x


def crossfade_loop(x, sec):
    """首尾交叉淡化：把开头 k 个样本叠到结尾，循环点就完全连续。"""
    k = int(sec * SR)
    head = x[:k].copy()
    tail = x[-k:].copy()
    r = np.linspace(0.0, 1.0, k)
    mixed = tail * r + head * (1 - r)
    out = x[:-k].copy()
    out = np.concatenate((out, mixed))
    return out


def write_ogg(name, samples, sr=SR):
    os.makedirs(OUT, exist_ok=True)
    raw = os.path.join(OUT, name + ".raw")
    ogg = os.path.join(OUT, name + ".ogg")
    x = np.clip(samples, -1.0, 1.0)
    pcm = (x * 32767.0).astype("<i2")
    with wave.open(raw, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())
    subprocess.run(
        [FFMPEG, "-y", "-loglevel", "error", "-i", raw,
         "-c:a", "libvorbis", "-q:a", "4", ogg], check=True)
    os.remove(raw)
    return ogg


def write_licenses(notes):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "AUDIO_LICENSES.md"), "w", encoding="utf-8") as f:
        f.write("# 音频素材来源与授权\n\n")
        f.write("**本目录全部音频由 `tools/audio_gen.py` 程序化合成，"
                "不含任何第三方录音。产物适用项目根目录 LICENSE。**\n\n")
        for n, why in notes:
            f.write("## %s\n\n%s\n\n" % (n, why))
        f.write("合成允许控制循环点、音量与时长；本目录不包含搜索结果或下载的音乐。\n")


def main():
    print("══ M4-1 音频生成 ══")
    print("  采样率 %d Hz" % SR)

    bgm = build_bgm()
    p = write_ogg("bgm_office", bgm)
    print("  BGM      %-18s %5.1fs  峰值 %.2f  %d 和弦 × %d 小节  %d BPM"
          % (os.path.basename(p), len(bgm) / SR, np.max(np.abs(bgm)),
             len(PROG), BARS // len(PROG), BPM))

    amb = build_ambient()
    p = write_ogg("amb_office", amb)
    print("  环境音   %-18s %5.1fs  峰值 %.2f（首尾交叉淡化 %.1fs）"
          % (os.path.basename(p), len(amb) / SR, np.max(np.abs(amb)), 0.5))

    for i, kc in enumerate(build_keyclicks(), 1):
        p = write_ogg("key_%d" % i, kc)
        print("  键盘音 %d %-16s %5.3fs  峰值 %.2f"
              % (i, os.path.basename(p), len(kc) / SR, np.max(np.abs(kc))))

    for who, sig in build_typing().items():
        p = write_ogg("type_" + who, sig)
        d = TYPING[who]
        print("  打字音 %-8s %-18s %5.3fs  力度%.2f 衰减%.3fs 基频%3.0fHz  %s"
              % (who, os.path.basename(p), len(sig) / SR, d[0], d[1], d[2], d[5]))

    write_licenses([
        ("bgm_office.ogg", "合成。A 小调 Am-F-C-G 循环，%d BPM，%d 小节。"
         "方波垫底过 1.4kHz 低通、三角波主旋律，无鼓。峰值 0.42，"
         "整体刻意压低——设计稿要求「不吵、能长时间听」。" % (BPM, BARS)),
        ("amb_office.ogg", "合成。50/100Hz 工频嗡鸣 + 棕噪风扇（220Hz 低通，"
         "0.07Hz 缓慢起伏）+ 2~3.2kHz 空调气流 + 每 0.6~1.6 秒一簇远处键盘声。"
         "首尾 0.5 秒交叉淡化，循环无缝。峰值 0.34。"),
        ("type_{m3,flash,longcat,kimi,step5}.ogg", "合成（M4-2）。单次键击："
         "极短噪声脉冲 + 键帽回弹基频衰减正弦 + 第二谐波。五个角色按"
         "力度/衰减/基频/截止频率区分手感（见 tools/audio_gen.py 的 TYPING 表）；"
         "**节奏由客户端按 interval_ms 排**，不烤进素材，所以手速可以单独调。"),
        ("key_1..3.ogg", "合成。短噪声脉冲 + 键帽回弹低频衰减正弦，"
         "3 个变体（截止频率/衰减时间/基频各不相同）供 M4-2 做距离衰减与随机。"),
    ])
    print("  授权说明 %s" % os.path.join(OUT, "AUDIO_LICENSES.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
