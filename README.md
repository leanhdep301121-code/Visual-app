# Visual app — iOS 高尔夫挥杆分析

GoSwin 是一款 iOS 原生 app：用一段手机视频分析高尔夫挥杆——**全程端上推理、不依赖云端**——用大白话告诉你哪里有问题、在视频上指出**为什么**，并和职业球员对比。

它用端上 CoreML 跑姿态估计 + 挥杆事件检测，推导生物力学指标，再由一套**规则引擎**判定问题、按"根因优先"排序、把判断依据直接画在画面上。云端 LLM **只**用于可选的定性总结，**不参与诊断本身**——诊断完全可解释、可校准。

> 本仓库含端上 app 源码 **+ build 必须的两个小 CoreML 模型**。其余大资产（可选模型、测试视频、训练 notebook、研究目录）体积大，单独管理。

**当前进展（`Xbotgo-terminator` 分支）：** 正在从「纯分析」扩成「分析 + 拍摄 + 剪辑」，配套一根自带电源、带 pan 云台、可横竖屏的拍摄杆。已落地：实时**判光 + 人脸自动拉亮**（已并入分析流）、多摄/电影/对焦/动态保存的端侧 PoC + 实验台、真机能力探针。规划中：缓存策略重构、手势/语音、拍后集锦剪辑（端侧）、云台 BLE 控制。**全程仍端侧，视频从不出设备。**

---

## 目录

- [接手文档](#接手文档)
- [功能](#功能)
- [处理流程](#处理流程)
- [目录结构（`Swin/`）](#目录结构swin)
- [模型](#模型)
- [安装](#安装)
- [使用示例](#使用示例)
- [设计原则](#设计原则)
- [贡献指南](#贡献指南)

---

## 接手文档

- [**`docs/xbotgo-terminator-handoff.md`**](docs/xbotgo-terminator-handoff.md) — **主交接**：要加的功能、技术路径决策、已查证的 iOS 原生接口目录、`Swin/Capture/` 逐文件现状、真机验证状态。
- [**`docs/colleague-setup-and-test.md`**](docs/colleague-setup-and-test.md) — 配 API key → 真机跑起来 → 端到端测一遍。
- [**`docs/capture-rig-plan.md`**](docs/capture-rig-plan.md) — 拍摄/剪辑+云台杆的初版设计（背景与可行性）。

---

## 功能

- **挥杆分析（上传或实时）** — 选一段视频（或实时录制），得到按严重度排序的问题列表，每条可点击在视频上查看。
- **可解释诊断** — 每个问题都来自明确的阈值 + 组合规则（例如"脊柱立起 AND 髋部抬高 ⇒ early extension"），不是黑盒分类器。问题按 根因 → 症状 排序，并连成因果链树。
- **点击即看依据的叠加层** — 高亮相关关节、画出教练式参考线（脊柱线、后侧髋线、头部圆圈…），以及转动类问题的实时俯视**转动表盘**。
- **职业叠加 & 并排对比** — 把内置的职业挥杆配准到你的动作上对比：可叠加（半透明职业 + 轮廓），也可在**同一挥杆相位并排**，两人身上画相同的问题标记。
- **视角感知** — 上传时可选 face-on 还是 down-the-line；指标的左右方向和可靠性会随机位自适应。
- **引导与课程** — 首次启动 + 每次 session 的引导（选 focus + 目标），以及把每个问题映射到公开教学视频的 drill 库。
- **Practice 主页** — 融合实时录制 + session 历史，带每节统计与趋势。

---

## 处理流程

```
 摄像头 / 上传的视频
        │
        ▼
 YOLO11n-pose (CoreML)          → 每帧 17 个关键点              [Pose/]
        │
        ▼
 PoseTCN 事件检测 (CoreML)      → 8 个挥杆事件 (Address…Finish)  [Events/]
        │
        ▼
 SwingMetrics + SwingDynamics   → 角度、转动、漂移、轨迹         [Metrics/]
        │
        ▼
 SwingFaultDetector (规则)      → 带严重度+置信度的问题          [Coaching/]
   → FaultRanker                → 根因优先排序 + 因果链树
        │
        ├─▶ FaultEvidence → 画在画面上的依据叠加层              [UI/]
        └─▶ 可选 LLM 定性总结                                   [Feedback/]
```

---

## 目录结构（`Swin/`）

| 分组 | 内容 |
|---|---|
| `App/` | App 入口、根 `ContentView`（tab 门控 / 引导）、品牌样式 |
| `Camera/` | 采集会话、实时预览、视频 + 深度录制 |
| `Pose/` | `PoseService` 协议、YOLO(CoreML) + Vision 两套姿态后端、叠加层 |
| `Events/` | PoseTCN + 启发式事件检测器、实时挥杆追踪 |
| `Metrics/` | `SwingMetrics` / `SwingDynamics` 计算、`SwingReport` |
| `Coaching/` | 问题定义 + 检测器、评分器、session 生命周期/统计/报告 |
| `Feedback/` | 编排器、云端 LLM 服务、规则模板 |
| `Reference/` | 内置职业参考 `ProReference` + `SwingAligner` 配准 |
| `Ball/` | 击球后球的轨迹检测 |
| `Speech/` | TTS（实时语音指导） |
| `Analysis/` | `VideoAnalyzer` — 上传（离线）分析管线 |
| `Capture/` | **拍摄杆方向**：多摄/电影引擎（`CaptureController`）、判光自动拉亮（`LightingAdvisor`/`SubjectFocusController`）、动态保存（`RollingClipKeeper`）、存相册、实验台。详见交接文档 |
| `UI/` | 分析页、叠加层、录制/上传界面、session 历史 |

其它顶层目录：`Resources/`（内置职业叠加资产——姿态 JSON、剪影 PNG 序列、参考片段）、`Assets.xcassets/`（图标/配色）、`Swin.xcodeproj/`、`project.yml`。

---

## 模型

app 运行时加载 CoreML 模型。**build 必须的两个已包含在仓库 `Models/` 里**（共 ~6.5MB），clone 下来即可 build：

| 文件 | 作用 | 状态 |
|---|---|---|
| `Models/yolo11n-pose.mlpackage` | 逐帧人体姿态 | ✅ 仓库内（必须） |
| `Models/PoseTCN_v3_1.mlpackage` | 实时挥杆事件检测（滑动窗口） | ✅ 仓库内（必须） |
| `Models/PoseTCN_v3.mlpackage` | 整段挥杆事件检测 | 可选，单独分发 |
| `Models/GolfBallYOLO11n.mlpackage` | 球检测（轨迹分析） | 可选，单独分发 |

---

## 安装

### 环境要求

| 项 | 要求 |
|---|---|
| macOS | 搭载 Apple Silicon 或 Intel 芯片的 Mac |
| Xcode | **16.0+** |
| iOS 真机 | **17.0+**（需要摄像头 + CoreML/ANE；姿态估计在较新 A 系列芯片上效果最佳。模拟器没有相机和 ANE，仅能验证编译） |
| Apple 开发者账号 | 自用真机**免费 Apple ID 即可**（签名 7 天有效期）；上 TestFlight / App Store 需付费开发者账号 |
| Swift | 5.9+（随 Xcode 16 提供） |

### 第 1 步：克隆仓库

```bash
git clone https://github.com/leanhdep301121-code/Visual-app.git
cd Visual-app
```

> 两个必需的 CoreML 模型（~6.5MB）已包含在 `Models/` 内，**clone 后无需再下载任何模型**即可 build。

### 第 2 步：配置 API Key（可选）

```bash
cp Resources/Secrets.plist.example Resources/Secrets.plist
```

然后用 Xcode 打开 `Resources/Secrets.plist`，按需填入：

| Key | 用途 | 没有时退化 |
|---|---|---|
| `DEEPSEEK_API_KEY` | 云端 LLM 教练（定性总结 / 报告 / 即时建议），**首选** | 退回**本地规则诊断**（完全离线可用） |
| `ELEVENLABS_API_KEY` | 实时语音教练（多语言 TTS），用量成本大头 | 退回系统语音 `AVSpeech`（能用，但没那么自然） |
| `KIMI_API_KEY` | 云端 LLM 备选（DeepSeek 为空时使用） | 同上 |

**不填任何 key 也能跑**——诊断走本地规则引擎，完全离线工作；只有 AI 定性总结和云端语音需要 key。LLM 输出语言跟随设备语言。

> ⚠️ `Secrets.plist` 已在 `.gitignore` 中，**不要 commit、不要 `git add -f`**。当前 app 直接使用这些 key（不经后端代理）；发版前应切换到后端代理隐藏密钥（见 `docs/colleague-setup-and-test.md` §1）。

### 第 3 步：Xcode 真机运行

1. 用 Xcode 打开工程：
   ```bash
   open Swin.xcodeproj
   ```
   （项目在 pbxproj 里用逐文件引用，**build 不需要 XcodeGen 步骤**；`project.yml` 仅作参考保留。只有你改动了 `project.yml` 才需要 `xcodegen generate`。）
2. 左侧选 target `Swin` → **Signing & Capabilities** → 勾选 *Automatically manage signing*，选择你自己的 Team（免费 Apple ID 登录 Xcode 后可添加 Personal Team）。
3. 接上 iPhone，首次连接需在手机上点「信任此电脑」，并在 iPhone **设置 → 隐私与安全性** 里允许开发者模式。
4. 顶部选择你的 iPhone 作为 destination，按 **⌘R** 运行。首次在真机启动若提示"不受信任的开发者"，去 iPhone **设置 → 通用 → VPN与设备管理** 信任该证书。

### 可选：命令行构建（模拟器验证编译）

```bash
xcodebuild -project Swin.xcodeproj -scheme Swin -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /tmp/visualapp-dd -destination 'platform=iOS Simulator,name=iPhone 16' build
```

> 注意：模拟器仅用于验证编译——真机测试（相机、CoreML、ANE、实时录制）才是有效验证。

### 常见问题

| 现象 | 处理 |
|---|---|
| 编译报缺模型 | 确认 `Models/yolo11n-pose.mlpackage` 和 `Models/PoseTCN_v3_1.mlpackage` 已随 clone 下来，且在 Xcode target 的 Build Phases 中有引用 |
| 签名失败 | Signing & Capabilities 里选自己的 Team；免费账号最多同时签 2 台设备、7 天过期，重新 ⌘R 即可续签 |
| 模拟器上崩溃 / 没有相机画面 | 预期行为，请用真机 |
| LLM 总结不出现 | 检查 `Secrets.plist` 的 key 是否填对；不填时会静默退回本地规则模板，属预期 |

---

## 使用示例

### 场景 1：上传视频分析（离线，最常用）

1. 启动 app，首次进入会引导你选**练习重点**（focus）和**目标**。
2. 进入**分析** tab → 选择一段竖屏挥杆视频（建议 1 次完整挥杆、机身与地面稳定）。
3. 选择机位视角：**face-on（正对）** 或 **down-the-line（侧后方）**——指标方向和可靠性会随机位自适应。
4. 等待分析进度完成后进入 `ProAnalysis` 页面：
   - **问题列表**按"根因优先"排序，例如先出现「重心逆转」（根因），再出现「early extension」（症状）。
   - **点击任一问题**，视频自动跳到对应帧，画面高亮相关关节、画出教练式参考线；转动类问题会显示俯视**转动表盘**，强调你与职业的差距。
   - 每条问题下方有对应的**训练 drill**（映射到公开教学视频）。

### 场景 2：实时录制 + 语音教练

1. 进入 **Practice** 主页 → **开始新一节**（session）→ 按引导选机位和惯用手。
2. 开始实时录制：端上模型逐帧跑姿态 + 事件检测，识别出挥杆事件后**实时语音教练**会按节奏开口提示（配置了 `ELEVENLABS_API_KEY` 时为云端音色，可在「我的」里切换 8 个预置音色；未配置时为系统语音）。
3. 录制结束自动生成**本节报告**，session 历史保留在主页，带每节统计与趋势（对照你自己的历史进步，不拿巡回赛数据当标尺）。

### 场景 3：与职业球员对比

1. 在分析结果页进入**职业对比**。
2. 内置的职业挥杆会被配准（`SwingAligner`）到你的动作上：
   - **叠加模式**：半透明职业姿态 + 轮廓叠在你的画面上；
   - **并排模式**：同一挥杆相位（Address / Top / Impact / Finish…8 个事件）左右并排，两人身上画相同的问题标记。
3. 拖动时间轴逐相位对比，直观看到差距出现在哪个环节。

### 场景 4：拍摄杆方向（`Xbotgo-terminator` 分支，实验性）

该分支把 app 从「纯分析」扩展到「分析 + 拍摄 + 剪辑」：多摄/电影引擎、判光 + 人脸自动拉亮、动态保存等能力已有端侧 PoC 和实验台入口。设计文档见 [`docs/capture-rig-plan.md`](docs/capture-rig-plan.md)，逐文件现状见 [`docs/xbotgo-terminator-handoff.md`](docs/xbotgo-terminator-handoff.md)。

---

## 设计原则

- **定性主导、定量支撑。** 给数字，但分三类：真实物理量 / 标准化指数 / 相对进步——不给伪精确的角度。2D 单视角本就低估真实转动，所以转动表盘强调**你与职业的差距**而非绝对度数。
- **两条非职业基线。** 问题判定对照"动作正确性边界"；进步判定对照用户自己的历史——不拿巡回赛数据当标尺。
- **阈值即校准，不是代码。** 所有 trigger/severe 值集中在一个 `FaultThresholds` 结构体里，用来对照专家标注的样本集调参。

---

## 贡献指南

欢迎贡献。开始之前请先阅读 [接手文档](#接手文档)——尤其是主交接文档里的技术路径决策和「不做什么」清单，避免与既有设计冲突。

### 开发环境

按上文 [安装](#安装) 一节配置：Xcode 16+、iOS 17.0+ 真机、（可选）三个 API key。**提交前请确保改动在真机上验证过**——相机、CoreML、ANE 相关逻辑在模拟器上无法有效验证。

### 工作流

1. **Fork / 分支**：从 `main` 切出功能分支，命名建议 `feat/<内容>`、`fix/<内容>`、`capture/<拍摄杆方向内容>`。
2. **改动范围**：
   - 新增诊断规则 → 在 `Coaching/` 的 `FaultThresholds` 中集中调阈值，**不要把魔法数字散落到代码里**；
   - 新增 UI → 遵循现有品牌样式（`App/`），支持中英双语（文案进 Localizable，不要硬编码）；
   - 新增模型引用 → 确认模型文件已按 `.gitignore` 白名单提交，且代码有降级路径。
3. **提交信息**：一句话说清「做了什么 + 为什么」，中文即可，例如 `Rename app to 'Visual app' in README`。
4. **PR 检查清单**（提交前自查）：
   - [ ] 真机 ⌘R 编译通过、核心流程（录制流 + 上传流）不回归
   - [ ] 中英双语各跑一遍，界面与教练话术无中英混杂
   - [ ] 未提交任何密钥（`Secrets.plist`）、大资产（可选模型 / 测试视频 / 训练产物）
   - [ ] 涉及诊断逻辑的改动，说明了阈值依据（对照专家标注样本，不是拍脑袋）
   - [ ] 涉及 `Capture/` 的改动，同步更新 `docs/xbotgo-terminator-handoff.md` 的对应小节

### 硬性约束（不接受违反的 PR）

- **端侧优先**：诊断链路（姿态 → 事件 → 指标 → 规则）**禁止引入云端依赖**；云端 LLM 只允许出现在可选的定性总结层（`Feedback/`）。
- **隐私红线**：视频与姿态数据从不出设备。任何把用户视频/数据上传到服务器的改动会被直接拒绝。
- **可解释性**：不允许用黑盒分类器替代规则引擎的诊断结论。
- **密钥安全**：任何密钥不得以任何形式进入仓库（包括 commit 历史）。

### 问题反馈

提 Issue 时请附：机型 + iOS 版本、Xcode 版本、复现步骤、是否配置了 API key、（涉及分析质量的）原视频机位与视角。涉及检测质量的 issue 请标注 8 个挥杆事件中哪些位置不对。

### 许可

当前仓库尚未附带 LICENSE 文件。在补充之前，默认保留所有权利；如需引用代码请先开 Issue 沟通。
