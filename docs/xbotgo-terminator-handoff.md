# GoSwin × Xbotgo Terminator — 拍摄/剪辑/云台 交接文档

> 给接手这条线的同事。GoSwin 从「纯挥杆分析」扩成「分析 + 拍摄 + 剪辑」,配套一根自带电源、
> 带 pan 云台、可横竖屏的拍摄杆(代号 Xbotgo Terminator)。本文 = 要做什么 + 技术路径 +
> iOS 原生能用的接口目录 + 当前代码到哪了 + 真机验证状态。
> 分支:`Xbotgo-terminator`。最后更新:2026-06-29。

---

## 0. 一句话现状

- iPhone 端**单摄分析流照常工作**,已经把**判光 + 自动拉亮**接进真实「练习」流(见 §5)。
- 多摄/电影/动态保存/拍后剪辑 = **设计 + 端侧 PoC/实验台已就绪**,尚未并进主流程。
- 云台**还没有硬件**;BLE 控制契约已定,可用 ESP32 先验。
- 这一版唯一上云的还是 LLM 文字 + TTS,**视频从不出设备**——剪辑也坚决走端侧(见 §3)。

---

## 1. 要加的功能

| # | 功能 | 简述 |
|---|---|---|
| F1 | **光影识别 + 站位引导** | 判逆光/暗,告诉用户往哪挪;**检测到脸暗直接自动拉亮曝光** |
| F2 | **手势 / 语音交互** | 一个手势或一句话让云台转过来 / 触发回放 / "留这杆" |
| F3 | **多摄并发** | 广角拍全身挥杆 + 长焦拍特写,动态按需开第二颗(非全程) |
| F4 | **自动对焦 / 曝光** | 把对焦+测光钉在球员/人脸上,address 锁定防 pumping |
| F5 | **动态视频保存** | 滚动缓冲 + 选择性落盘(best-N / 代表问题 / 首尾 / 用户标记) |
| F6 | **拍后剪辑 / 集锦** | 拼好杆 + 穿插特写 + 按挥杆阶段曲线变速,全端侧 |
| F7 | **云台回放** | 用户手势/语音"看刚那杆" → 云台转过来 → 播 clip + 叠分析 |

---

## 2. 配套硬件契约(给硬件团队)

### 2.1 控制走 BLE,供电走触点 —— 二者解耦

**关键限制:iPhone 没有背面数据触点**(iPad 有 Smart Connector,iPhone 从来没有)。唯一数据出口是底部 USB-C/Lightning 口;App↔自定义配件有线通信 = External Accessory 框架 = **必须 MFi 认证**(重,创业期不上)。

| 通道 | 物理路径 | 苹果门槛 |
|---|---|---|
| 给手机供电 | pogopin/磁吸 → USB-C 口(优先有线,比 MagSafe 凉) | 无 |
| 风扇/电机供电 | 杆子自带电池直供 | 无(与 iPhone 无关) |
| **App ↔ 云台 控制** | **BLE(CoreBluetooth)** | **无(无需 MFi)** |

- 磁吸 = 对位+机械固定;pogopin/USB-C = 供电;**BLE = 控制**,三者解耦。
- 云台 MCU 由杆子电池供电 → "BLE 费电"顾虑消失。
- **散热**:风扇主动散热把热天花板抬一档,这是敢同时多摄 + 多模型的前提。

### 2.2 BLE GATT 草拟(待细化)

云台 MCU 做成标准 BLE peripheral,至少暴露:pan 角度写入(目标角度/速度)、当前角度 read+notify、横竖屏状态 read+notify、(可选)电量/温度/急停。
**拿一块 ESP32 当假云台即可先验 iPhone↔电机闭环,不用等正式杆子。**

---

## 3. 技术路径(关键决策)

### 3.1 录制 + 实时分析共存:不切流、不上 4K
- **一颗摄像头一个 format、多 output 并发**:同一条广角帧,既下采样喂 pose(YOLO 内部 192,**永远看全人**)、又喂录制。**不需要切流**;pose 成本与录制分辨率无关。
- **现在 1080p**(裸机 + 实时分析可持续);4K 的代价在 ISP+编码器+内存带宽,等散热/供电硬件再上。真要 4K 又想省 pose:录制用 `AVCaptureMovieFileOutput` 走 4K + data output 开 `deliversPreviewSizedOutputBuffers` 给小帧。

### 3.2 多摄 vs 电影:互斥,且分析流别碰
- **Cinematic 与 MultiCam 在会话层互斥**(都吃满 ISP)。
- 分析**只需广角**;多摄/电影是**美学功能**,做成 opt-in 拍摄模式,**不并进常开的分析会话**(否则热翻倍 + 要把 `camera.session` 换成 MultiCamSession,牵动预览/录制/Archive)。

### 3.3 特写 = 长焦(光学) + pose 裁切跟踪(选部位)
- 长焦是**固定光轴**,只能拍"同向更紧的画面",**不会自己瞄脸**。拍脸/手腕 = 光学长焦给像素 + **软件按 pose 关键点裁切跟踪**(脸=0-4,手腕=9/10)。
- **覆盖必须实时保证**:角度不对、部位没进画,拍后救不回。所以"拍后裁"的**主力源是高分辨率广角(保底全覆盖)**,长焦是"有云台可靠对准时"的加分。
- **裁切/选部位 = 拍后剪辑做**(保全像素、非破坏、不抢实时热、可 look-ahead 平滑),不实时裁。

### 3.4 剪辑走端侧(坚决)
- 视频体积大,上云=练习场蜂窝网上传灾难 + 隐私(人脸/场地)+ 服务器 opex;且事件帧/pose/切片全在本地。
- 和 app 立身之本一致(README:全程端上,云端只用于可选 LLM 文字)。**视频从不出设备。**
- 剪辑本质是确定性合成:`AVMutableComposition` 拼 + `AVVideoComposition` 转场 + `scaleTimeRange` 按 8 事件帧变速 + `AVAssetExportSession` 导出,端上硬件加速。
- 云只作未来可选的"社交花哨模板"付费附加项,默认+核心永远端侧。

### 3.5 缓存/保存策略:运行工作集 → 结束定剪
- 矛盾:best/首尾/代表性问题**只有一节结束才知道**,视频却要实时录 → **运行中维护有界候选集 + 结束定剪**。
- 分层:
  - **数据层(永久)**:每杆 pose+annotated+score JSON(~100KB)。全节数据始终在,视频剪了也能复现分析。
  - **实时工作集(有界,~20-30 段封顶)**:最近 N 杆滚动窗(回放用)+ 运行 best-so-far top5 + 运行各主问题代表杆 + 开头前 N 杆 + 用户"留这杆"。
  - **结束定剪(永久,~8-12 段/节)**:best top-N(剪辑要多杆)+ 代表性问题 + 首/尾杆(进步对比)+ 用户标记;其余视频 prune,JSON 留。
  - **跨节上限**:只留最近 K 节视频 + 每节集锦成片;更老的只留 JSON + 缩略图。
- **云台回放**靠"最近 N 杆滚动窗"(建议 5-10 杆);不在窗里又没入 keep-set 的杆 → 只有 pose → 骨架回放降级可用。
- **复用现成**:`SessionAnalyzer.summarize` 已挑 best3/worst3/代表fault/上下半对比;`SwingArchive` 已选择性存 + 切每杆 mp4;`SwingScore` 给排序。补 first-N/last-N + 运行工作集 + 结束 prune 即可。

### 3.6 音频会话冲突(语音功能的坑)
- `CameraService` **故意不挂麦**(占麦打断用户音乐 + 拆麦可能死锁 AVCaptureSession);TTS 又占 playback 会话。
- **被动语音 = 长期占麦**,直接撞这两条。→ **MVP 先手势 / 语音只做主动**,被动语音等统一音频调度方案。
- 手势更省:举手过头等大动作直接用现有全身 pose 判,不必再开手部模型。

---

## 4. iOS 原生可用接口目录(已查证)

> 全部公开 API,无需额外 entitlement(相机/相册/麦权限已配或好配)。

### 4.1 多摄
- `AVCaptureMultiCamSession`(iOS 13+,A12/iPhone XS+)。`isMultiCamSupported`;`DiscoverySession.supportedMultiCamDeviceSets` 查可并发组合。
- **手动连接**:`addInputWithNoConnections`/`addOutputWithNoConnections` + `AVCaptureConnection(inputPorts:output:)`(自动连会把成本拉爆)。
- **成本**:`session.hardwareCost` 必须 < 1.0(ISP 硬上限);`systemPressureCost`。降分辨率/选 binned/`isMultiCamSupported` 的 format。
- **长焦只有 Pro 机型**(`.builtInTelephotoCamera`);非 Pro "2x" 是广角裁切。

### 4.2 Cinematic Video(虚化 + 追焦,iOS 26+ / iPhone 13+)
- `AVCaptureDeviceInput.isCinematicVideoCaptureEnabled`;`format.isCinematicVideoCaptureSupported`(后置 DualWide / 前置 TrueDepth,1080p或4K,**30fps only**)。
- 虚化是**计算合成**(双摄视差+PDAF+神经网络深度→神经引擎分割主体+合成模糊);主体清晰(pose 仍可跑),**细球杆可能被糊**。
- `simulatedAperture` / `format.min/max/defaultSimulatedAperture` 调虚化(f 值,越小越虚)。
- 追焦:`metadataOutput.requiredMetadataObjectTypesForCinematicVideoCapture`(face/person/salient,带 objectID)→ `setCinematicVideoTrackingFocus(detectedObjectID:focusMode:)`,`CinematicVideoFocusMode` = none/strong/weak。
- 内置场景监控:`cinematicVideoCaptureSceneMonitoringStatuses` 含 `.notEnoughLight`。
- **与 MultiCam 互斥**。

### 4.3 曝光 / 对焦
- `exposurePointOfInterest`/`focusPointOfInterest`(+ `is*Supported`)、`exposureMode`(continuous/locked/custom)、`focusMode`。
- `setExposureTargetBias(_:)`(±~8EV,`min/maxExposureTargetBias`)—— **全局加亮,无需点位映射**(我们自动拉亮用的就是这条)。
- `exposureTargetOffset`(只读,判欠/过曝)、`AVCaptureDeviceSubjectAreaDidChange`(主体移动重测)。
- `autoFocusRangeRestriction = .far`(远处球员防拉风)、`isSmoothAutoFocusEnabled`(视频平滑对焦)。
- 人脸驱动 AE/AF(iOS 15.4+):`isFaceDrivenAutoExposureEnabled` / `automaticallyAdjustsFaceDrivenAuto*`。注:高尔夫侧脸/低头,人脸检测不稳,**用 pose 关键点比人脸框稳**。
- 电子变焦:`videoZoomFactor`(裁+放大);`videoZoomFactorUpscaleThreshold`(无损上限,4K 裁 1080 有余量)。

### 4.4 手势 / 语音
- `VNDetectHumanHandPoseRequest`(iOS 14+,端上,21 手部点)。大动作可直接用现有全身 pose。
- `SFSpeechRecognizer`,`requiresOnDeviceRecognition = true` 纯端上;**实测 zh-Hans + en-US 都支持 on-device**。

### 4.5 剪辑 / 合成(全端侧)
- `AVMutableComposition`(拼接)、`AVMutableVideoComposition`(转场/叠加)、`CMTimeMapping`/`scaleTimeRange`(变速)、`AVAssetExportSession`(导出)。
- `AVAssetReader`/`AVAssetWriter`(逐帧处理/裁切)。

### 4.6 云台控制 / 周边
- `CoreBluetooth`(BLE central,自定义 GATT 驱动云台 MCU)。
- `CoreLocation`(经纬度/时间→太阳方位)+ `CoreMotion`/`CLHeading`(手机朝向)→ 站位引导方向。
- `PHPhotoLibrary` / `PHAssetCreationRequest`(存相册,add-only 授权)。
- `VNDetectTrajectoriesRequest`(球轨迹,已在用)。
- `ProcessInfo.thermalState`(热预算调度)。

---

## 5. 代码现状(`Swin/Capture/` + 诊断探针)

### 5.1 已落地的文件

| 文件 | 行 | 作用 | 状态 |
|---|---|---|---|
| `Capture/CaptureMode.swift` | 73 | 模式枚举(analysis/multiAngle/cinematic)+ `CaptureCapabilities.detect()` 真机门控 | ✅ |
| `Capture/CaptureController.swift` | 315 | 模式引擎:按模式建会话(单/多摄),广角喂 pose+光影+录制,长焦录+画中画预览 | ✅ 实验台用,**未并主流程** |
| `Capture/LightingAdvisor.swift` | 176 | 判光(只看人脸,竖屏空间直接采样,无映射)+ 反差逆光判定 + 驱动自动拉亮 | ✅ **已并入 CameraService** |
| `Capture/SubjectFocusController.swift` | 142 | pose 驱动对焦/测光 POI + address 锁定 + **autoBrighten 全局曝光收敛** | ✅ autoBrighten 已用;**POI 点测光未启用(映射待验)** |
| `Capture/CinematicController.swift` | 74 | iOS26 cinematic:选格式/enable/`simulatedAperture`/metadata 追焦锁球员 | ✅ 实验台用 |
| `Capture/RollingClipKeeper.swift` | 135 | 滚动分块 + keepRecent 留存(多摄两路各一个) | ✅ 实验台用,**主流程改用工作集策略(见 §3.5)** |
| `Capture/PhotoSaver.swift` | 24 | 留存片段写进系统相册(add-only) | ✅ |
| `Capture/CaptureLabView.swift` | 157 | `CAPTURELAB=1` 或「我的→拍摄实验台」入口:预览/模式切换/光影框+读数/虚化滑杆/录制/⭐存相册 | ✅ DEBUG |
| `Diagnostics/CapabilityProbe.swift` | 199 | `CAPPROBE=1` 真机能力报告:多摄/镜头/曝光对焦/cinematic+光圈/手势/端上语音/热 | ✅ |
| `Diagnostics/MultiCamProbe.swift` | 186 | `MULTICAM=1` 真机多摄 PoC:广角+长焦双流,量 hardwareCost/双流 fps/热 | ✅ |

### 5.2 已并入主分析流(`CameraService` + `RecordView`)
- `CameraService.lighting`(LightingAdvisor)挂在广角帧上(`captureOutput`,节流~3Hz),`lighting.onResult` → `subjectFocus.autoBrighten` **全局拉亮**。对焦器随相机切换重建。
- **只接了全局曝光补偿(无映射,已认可);未接 exposurePointOfInterest 点测光**(点位映射待真机验)。
- `RecordView`:光线确有问题(自动拉亮救不回的极端逆光)才弹橙色提示条。

### 5.3 还没做
- 缓存重构(§3.5 RetentionConfig + 运行工作集 + 结束定剪)—— **下一步,剪辑+回放的地基**。
- 手势/语音"留这杆" + 接现有 Archive。
- 多摄/电影并进 opt-in 拍摄模式(现仅实验台)。
- 拍后 `CloseupReframer`(端侧,读存好的 pose 裁部位)+ 集锦合成。
- 站位/构图引导(FramingAdvisor)+ 太阳方位。
- 云台 BLE(等 ESP32/硬件)。
- 4K + `deliversPreviewSizedOutputBuffers` 解耦(等散热硬件)。
- 工程加新源文件需 `xcodegen generate`(逐文件引用);**Xcode 开着工程时别 regenerate,会卡死**。

---

## 6. 真机验证状态(iPhone 16 Pro Max,iOS 26.3)

- ✅ 全新 clone build 通过(模拟器 + 真机签名)。
- ✅ 自动拉亮:逆光黑脸 → 自动提亮,人脸判光框稳贴脸(竖屏采样修复后)。
- ✅ 端上语音 zh/en、手势路径、Cinematic 能力、多摄 hardwareCost(640×480 时 0.857)— 探针实测。
- ⏳ 待真机验:**POI 点测光/对焦的点位映射方向**(同 VideoRecorder 朝向注记)、多摄 1080p 准确 hardwareCost/热、Cinematic 实拍对细球杆的影响。

---

## 7. 怎么测

- App →「我的」→「拍摄实验台 (debug)」:模式切换、广角+长焦画中画、光影框+读数、虚化滑杆、⏺录制、⭐存相册(进系统相册)。
- 真机能力报告:`CAPPROBE=1`;多摄 PoC:`MULTICAM=1`(Xcode scheme env 或 devicectl `--environment-variables`)。
- 正常分析流自带判光+自动拉亮:「练习 → 开始训练」对着逆光位,脸自动提亮、极端时弹提示。
- 留存片段在系统相册(多摄两路都有);备用:`UIFileSharingEnabled` 已开,Documents 在「文件」App 可见。

---

## 8. 相关仓库

| 仓库 | 作用 |
|---|---|
| `Swi-app` | iOS app(本仓库),分支 `Xbotgo-terminator` |
| `Swi-furnace` | PC/研究/训练分析器(3D 在这) |
| `Swi-backend` | LLM 密钥代理(FastAPI+Fly)——**只代理文字/TTS,不碰视频** |
| `Swi-ModelGarage` | 模型权重 |
