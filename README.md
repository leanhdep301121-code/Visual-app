# Visual app — iOS 高尔夫挥杆分析

GoSwin 是一款 iOS 原生 app:用一段手机视频分析高尔夫挥杆——**全程端上推理、不依赖云端**——用大白话告诉你哪里有问题、在视频上指出**为什么**,并和职业球员对比。

它用端上 CoreML 跑姿态估计 + 挥杆事件检测,推导生物力学指标,再由一套**规则引擎**判定问题、按"根因优先"排序、把判断依据直接画在画面上。云端 LLM **只**用于可选的定性总结,**不参与诊断本身**——诊断完全可解释、可校准。

> 本仓库含端上 app 源码 **+ build 必须的两个小 CoreML 模型**。其余大资产(可选模型、测试视频、训练 notebook、研究目录)体积大,单独管理。

**当前进展(`Xbotgo-terminator` 分支):** 正在从「纯分析」扩成「分析 + 拍摄 + 剪辑」,配套一根自带电源、带 pan 云台、可横竖屏的拍摄杆。已落地:实时**判光 + 人脸自动拉亮**(已并入分析流)、多摄/电影/对焦/动态保存的端侧 PoC + 实验台、真机能力探针。规划中:缓存策略重构、手势/语音、拍后集锦剪辑(端侧)、云台 BLE 控制。**全程仍端侧,视频从不出设备。**

---

## 接手文档

- **[`docs/xbotgo-terminator-handoff.md`](docs/xbotgo-terminator-handoff.md)** — **主交接**:要加的功能、技术路径决策、已查证的 iOS 原生接口目录、`Swin/Capture/` 逐文件现状、真机验证状态。
- **[`docs/colleague-setup-and-test.md`](docs/colleague-setup-and-test.md)** — 配 API key → 真机跑起来 → 端到端测一遍。
- **[`docs/capture-rig-plan.md`](docs/capture-rig-plan.md)** — 拍摄/剪辑+云台杆的初版设计(背景与可行性)。

---

## 功能

- **挥杆分析(上传或实时)** — 选一段视频(或实时录制),得到按严重度排序的问题列表,每条可点击在视频上查看。
- **可解释诊断** — 每个问题都来自明确的阈值 + 组合规则(例如"脊柱立起 AND 髋部抬高 ⇒ early extension"),不是黑盒分类器。问题按 根因 → 症状 排序,并连成因果链树。
- **点击即看依据的叠加层** — 高亮相关关节、画出教练式参考线(脊柱线、后侧髋线、头部圆圈…),以及转动类问题的实时俯视**转动表盘**。
- **职业叠加 & 并排对比** — 把内置的职业挥杆配准到你的动作上对比:可叠加(半透明职业 + 轮廓),也可在**同一挥杆相位并排**,两人身上画相同的问题标记。
- **视角感知** — 上传时可选 face-on 还是 down-the-line;指标的左右方向和可靠性会随机位自适应。
- **引导与课程** — 首次启动 + 每次 session 的引导(选 focus + 目标),以及把每个问题映射到公开教学视频的 drill 库。
- **Practice 主页** — 融合实时录制 + session 历史,带每节统计与趋势。

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

## 目录结构(`Swin/`)

| 分组 | 内容 |
|---|---|
| `App/` | App 入口、根 `ContentView`(tab 门控 / 引导)、品牌样式 |
| `Camera/` | 采集会话、实时预览、视频 + 深度录制 |
| `Pose/` | `PoseService` 协议、YOLO(CoreML) + Vision 两套姿态后端、叠加层 |
| `Events/` | PoseTCN + 启发式事件检测器、实时挥杆追踪 |
| `Metrics/` | `SwingMetrics` / `SwingDynamics` 计算、`SwingReport` |
| `Coaching/` | 问题定义 + 检测器、评分器、session 生命周期/统计/报告 |
| `Feedback/` | 编排器、云端 LLM 服务、规则模板 |
| `Reference/` | 内置职业参考 `ProReference` + `SwingAligner` 配准 |
| `Ball/` | 击球后球的轨迹检测 |
| `Speech/` | TTS(实时语音指导) |
| `Analysis/` | `VideoAnalyzer` — 上传(离线)分析管线 |
| `Capture/` | **拍摄杆方向**:多摄/电影引擎(`CaptureController`)、判光自动拉亮(`LightingAdvisor`/`SubjectFocusController`)、动态保存(`RollingClipKeeper`)、存相册、实验台。详见交接文档 |
| `UI/` | 分析页、叠加层、录制/上传界面、session 历史 |

其它顶层目录:`Resources/`(内置职业叠加资产——姿态 JSON、剪影 PNG 序列、参考片段)、`Assets.xcassets/`(图标/配色)、`Swin.xcodeproj/`、`project.yml`。

## 模型

app 运行时加载 CoreML 模型。**build 必须的两个已包含在仓库 `Models/` 里**(共 ~6.5MB),clone 下来即可 build:

| 文件 | 作用 | 状态 |
|---|---|---|
| `Models/yolo11n-pose.mlpackage` | 逐帧人体姿态 | ✅ 仓库内(必须) |
| `Models/PoseTCN_v3_1.mlpackage` | 实时挥杆事件检测(滑动窗口) | ✅ 仓库内(必须) |
| `Models/PoseTCN_v3.mlpackage` | 整段挥杆事件检测 | 可选,单独分发 |
| `Models/GolfBallYOLO11n.mlpackage` | 球检测(轨迹分析) | 可选,单独分发 |

## 构建与运行

- **环境:** Xcode 16+,iOS **17.0+** 真机(需要摄像头 + CoreML;姿态在较新 A 系列芯片上最佳)。
- **密钥:** 复制 `Resources/Secrets.plist.example` → `Resources/Secrets.plist` 并填入 key(云端 LLM / TTS)。没有 key 时 app 退回本地规则模板——**诊断可完全离线工作**,只有定性总结和语音需要 key。
- **模型:** build 必须的两个 CoreML 模型已在仓库 `Models/` 内,无需额外操作;可选的整段事件 / 球检测模型若要启用再单独放入。
- 用 Xcode 打开 `Swin.xcodeproj`,选你的真机运行。(项目在 pbxproj 里用逐文件引用,build 不需要 XcodeGen 步骤;`project.yml` 仅作参考保留。)

## 设计原则

- **定性主导、定量支撑。** 给数字,但分三类:真实物理量 / 标准化指数 / 相对进步——不给伪精确的角度。2D 单视角本就低估真实转动,所以转动表盘强调**你与职业的差距**而非绝对度数。
- **两条非职业基线。** 问题判定对照"动作正确性边界";进步判定对照用户自己的历史——不拿巡回赛数据当标尺。
- **阈值即校准,不是代码。** 所有 trigger/severe 值集中在一个 `FaultThresholds` 结构体里,用来对照专家标注的样本集调参。
