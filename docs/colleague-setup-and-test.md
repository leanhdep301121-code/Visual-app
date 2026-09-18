# GoSwin 交接：配置 API + 端到端测试

> 给接手同事。目标：从 `main` 全新 clone → 配好 key → 真机跑起来 → 端到端测一遍。
> 最后更新：2026-06-14。本文写给人看（中文）。

---

## 0. 当前状态一句话

`main` 已可**全新 clone 直接 build**（之前 main 也是缺模型文件编译失败的状态，已修）。
本轮合入：液态玻璃 UI + 中英双语（含 AI 提示词按设备语言切换）+ 上传分析迁到最新 PoseTCN_v3_1。
**没做 / 待测**：后端代理未部署（app 暂时直接用本机 key）；英文教练话术机器翻译待母语复核；**3D 刚上、完全没测**（见 §4）。

---

## 1. 需要的 API / Key（配置）

**build 前要填的 key**，全放在 `Resources/Secrets.plist`（**gitignore，不进仓库**，从 `Resources/Secrets.plist.example` 复制后填）。**app 当前直接用这些 key（不经后端），所以现在不需要任何「后端 API / URL」。**

| Key | 用途 | 没有时退化 | 怎么拿 | 状态 |
|---|---|---|---|---|
| `DEEPSEEK_API_KEY` | 云端 LLM 教练（定性总结 / 报告 / 即时建议）。**首选** | 退回**本地规则诊断**（完全离线可用，只是没 AI 润色总结） | platform.deepseek.com | **已用真 key 实测通过**（直连 + 代理 + app 中英提示词都验过）；填自己的即可 |
| `ELEVENLABS_API_KEY` | 实时语音教练（多语言 TTS，中英都能说）。**用量成本大头，要盯** | 退回系统语音 AVSpeech（能用，没那么自然） | elevenlabs.io | **未测**（没拿到 key）。见下方音色注意 |
| `KIMI_API_KEY` | 云端 LLM 备选（DeepSeek 为空时用） | 同上 | platform.moonshot.cn | 选填 |

- LLM 输出语言**跟随设备语言**：中文设备→中文，英文设备→英文（教练说话 + 报告都跟着切）。
- **音色已在 app 里选好**：`CoachVoice` 预置 8 个音色（默认 Kevin），模型 `eleven_multilingual_v2`，每个音色的 style/speed 已调好，用户在「我的」里可切换。**不用再选语气。**
  - ⚠️ **但这 8 个 voiceID 是 ElevenLabs 账号专属的**——必须保证填进来的 key 所属账号的 Voice Library 里有这些 voice（`1fz2mW1imKTf5Ryjk5su` 等），否则 TTS 会失败。拿到 key 后**先测一条语音**确认音色 ID 在该账号下可用。
- **后端 API：现在不需要。** app 直接调 DeepSeek/ElevenLabs。后端代理（隐藏密钥）是发版前的独立步骤，那时才需要后端 URL + 把 3 个 key 设成 Fly secrets。
- ⚠️ key 填进 `Secrets.plist` 后别 commit（已 gitignore，别 `git add -f`）。

### 后端代理（可选，发版前做）
现在 app **直接**用 `Secrets.plist` 里的 key（密钥打包进 ipa，有泄露风险）。发版前应切到后端代理：
- 仓库 `Swi-backend`（FastAPI + Fly.io），`/llm/*` 已写好转发 DeepSeek/Kimi/ElevenLabs，key 只留服务端。
- 部署需要：**Fly.io token**（`flyctl auth token`）+ 上面三个 key（设成 Fly secrets）。
- 部署后把 app 的 `CloudLLMService` / `ElevenLabsTTS` 指到后端 `/llm`（task #12，**未做**）。
- **测试不依赖后端**——本地填 key 就能测全部功能。

---

## 2. 真机跑起来（步骤）

```bash
git clone -b launch-plan https://github.com/Swi-dev/Swi-app.git && cd Swi-app   # 最新代码在 launch-plan 分支
cp Resources/Secrets.plist.example Resources/Secrets.plist   # 然后填上面三个 key（不填也能跑，走离线/系统语音）
# 工程是 XcodeGen 生成的，但 Swin.xcodeproj 已提交，可直接打开；改了 project.yml 才需 `xcodegen generate`
open Swin.xcodeproj
```
在 Xcode 里：
1. 选 target `Swin` → Signing & Capabilities → **选你自己的 Apple 开发者 Team**（自用真机免费账号即可，7 天有效期）。
2. 接上 iPhone，选它做 destination，⌘R 跑。

CLI 构建参考（模拟器）：
```bash
xcodebuild -project Swin.xcodeproj -scheme Swin -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /tmp/swin-dd -destination 'platform=iOS Simulator,name=GoSwin-Dev' build
```

模型：仓库只提交两个 CoreML 模型（`Models/yolo11n-pose.mlpackage` + `PoseTCN_v3_1.mlpackage`），**够 build 了**，不用再去 ModelGarage 拉别的。

---

## 3. 端到端测试清单（iOS app）

真机为准（模拟器没相机/ANE/温度）。**中英各测一遍**（系统语言切英文验证 i18n）：

- [ ] **录制流**：练习 → 开始新一节 → 机位/惯用手 → 实时录制 → 实时语音教练有没有按节奏开口 → 出报告
- [ ] **上传流**：分析 tab → 选一段竖屏挥杆视频 → 进度 → 进 ProAnalysis（回放/骨架/指标/问题/职业对比）
- [ ] **事件检测质量**：⚠️ 上传分析这条路**刚从旧模型 v2 迁到最新 v3_1**，只验证了「编译 + 模型加载」，**没跑过真实视频确认检测质量**——重点拿真实挥杆视频核对 8 个挥杆事件（Address/Top/Impact/Finish…）位置对不对
- [ ] **诊断/报告**：问题清单、怎么改、训练库、本节报告措辞通顺、无中英混杂
- [ ] **语音**：填了 ElevenLabs key 时是云端音色；没填是系统音色；静音开关有效
- [ ] **英文环境**：设置→语言改 English，重开 app，界面 + 教练话术 + 报告应**全英文**
- [ ] **历史/我的**：会话卡、训练库、音色选择、关于

---

## 4. 3D（刚上，完全没测）⚠️

- **代码不在 app 仓库**，在 **`Swi-furnace`**（GoSwin 的 PC / 研究 / 训练分析器仓库，Python）。
- **iOS app 现在不消费 3D**（端上没有 SceneKit/RealityKit/3D 渲染）——3D 是 PC 侧的分析/可视化，独立于 app。
- 入口脚本（在 `Swi-furnace` 里）：
  - `research/golfpose_3d_*.py` —— `golfpose_3d_test.py`（出 `.npz`）→ `golfpose_3d_analyze.py`（算转髋/转肩/X-factor 等 3D 指标）/ `_render.py` / `_interactive.py` / `_sportsbox.py`
  - `analyzer/swing_analyze/` —— `pose3d.py`、`smpl_fit.py`、`render_smpl.py`、`render_three.py`、`viz3d.py`、`figure3d.py`
  - `research/depth_*.py` —— 深度估计/融合管线（depth-anchored 3D）
- **要测什么**：拿真实挥杆视频跑 3D 管线，看 2D→3D 重建（SMPL 人体拟合 + 深度）出来的 3D 姿态/指标是否合理、可视化是否正常。具体跑法看各脚本头部 docstring + `Swi-furnace/README.md`、`docs/`。
- 跨仓库契约见 `Swi-app/../ORG.md`（如本机没有，在 `Swi-brain` 仓库）。

---

## 5. 已知缺口 / 注意

1. **GitHub token 泄露**：之前 git remote URL 里明文嵌了 `ghp_…` PAT，**务必轮换**（GitHub Settings → Developer settings → 撤销重发），重配 remote。
2. **后端代理未部署**：key 还打包在 app 里，发版前应切后端（§1）。
3. **英文教练话术**是机器翻译 + 占位符校验，发版前找**懂高尔夫的英语母语者**复核诊断/训练话术。
4. **int8 量化模型**：`main` 之前往工程加过 `PoseTCN_v3_1_int8.mlpackage`（更小更快）的引用，但模型文件没提交、代码也没用，已在本轮去掉。要正式用 int8 是独立后续：提交模型文件（加进 `.gitignore` 白名单）+ 代码从 `PoseTCN_v3_1` 切到 `PoseTCN_v3_1_int8`。
5. **Apple 开发者账号**：真机自签能测；上 TestFlight / App Store 需要付费开发者账号（确认 team 里谁有）。

---

## 6. 相关仓库

| 仓库 | 作用 |
|---|---|
| `Swi-app` | iOS app 源码（端上）← 本仓库 |
| `Swi-furnace` | PC / 研究 / 训练分析器（**3D 在这**） |
| `Swi-backend` | 后端（FastAPI + Fly.io，LLM 密钥代理） |
| `Swi-ModelGarage` | 模型权重（Git LFS） |
| `Swi-brain` | 团队文档 / CLAUDE.md / ORG.md 源 |
