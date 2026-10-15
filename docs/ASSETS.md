# 素材来源与结构

当前客户端包含 19 张项目 AI 生成 PNG 图集、190 个 Godot 资源定义、10 个程序合成 OGG 文件，以及一份未修改的 Noto Sans CJK SC 字体。

图集分为建筑与地面、五个功能区家具、员工行走、客户、UI、小组件，以及五名员工的活动动作。项目仅借鉴温暖俯视像素经营游戏的表现方向，公开包中不包含商业游戏原始素材或原参考图片。

切片、脚底锚点、动作帧、资源名称和原图哈希见 `godot/assets/cozy_office/manifest.json`。后端碰撞及座位目标在 `ai-model-party/data/office_layout_v2.json`，客户端布局在 `godot/data/scene_layout.json`，这两份布局需要同步修改。

音频源代码在 `ai-model-party/tools/audio_gen.py`。正常开发使用已附带的 OGG 即可；只有重新合成时才需要另外安装 NumPy 和 FFmpeg，执行工具会重写项目音频。

项目代码、图片和音频适用根目录 LICENSE。字体保留 SIL OFL，Godot 运行时保留 MIT 及引擎第三方声明；完整说明见根目录 THIRD_PARTY_NOTICES.md。
