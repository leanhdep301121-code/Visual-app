# GoSwin — 拍摄 / 剪辑 + 配套云台杆 设计

> 把 GoSwin 从「纯挥杆分析」扩成「分析 + 拍摄 + 剪辑」。配套一根**自带电源、带 pan 云台、可横竖屏**的拍摄杆。
> 本文记录:功能清单、每条的 iOS 可行性、和现有架构的接法、三大硬约束、硬件接口契约、推进顺序。
> 状态:**杆子尚未制造**——本文把工作分成「iPhone 端现在就能验」与「依赖硬件」两类,前者先行。
> 最后更新:2026-06-28。

---

## 0. 背景与原则

- 配套硬件:一根拍摄杆,带 **pan 云台**(可转向)、**自带电池**(给手机 + 风扇 + 电机供电)、**风扇主动散热**、横竖屏切换。
- **不加额外摄像头/追踪模块**:所有视频流仍来自 **iPhone 自己的镜头**;能多跑的模型也都跑在 iPhone 上。杆子只负责「转向 + 供电 + 散热」。
- 三个会决定成败的硬约束(贯穿所有功能):**热、音频会话、存储**。硬件方案(自带电+风扇)已基本拆掉「热」「功耗」两条,见 §3。

---

## 1. 功能清单

1. **光影识别 + 站位引导**:识别逆光/不良光影,告诉用户「往哪挪」避开。
2. **手势 / 语音交互**:一个手势或一句话,让云台转过来给用户看本杆回放/分析。
3. **多摄并发拍摄**:广角拍全身挥杆 + 长焦拍特写(手腕/杆头)。**动态策略**——不是全程多摄。
4. **自动对焦/曝光**:把对焦、测光钉在球员身上(复用 pose 关键点)。
5. **动态视频保存策略**:1 小时连录会爆存储,必须「滚动缓冲 + 选择性落盘」。多种输入(见 §2.5)。
6. **拍后剪辑 / 集锦**:练习场场景——把好杆拼起来,穿插特写,按挥杆阶段做曲线变速等效果。

---

## 2. 逐条可行性 + 接法

### 2.1 光影识别 + 站位引导  〔iPhone 端可验〕
- **iOS 让不让**:✅ 纯算法,无 API 限制。
- **判逆光**:每帧已有 pixel buffer + pose → 算「躯干 bbox 平均亮度 vs 全帧/天空区亮度」;球员欠曝 + 背景过曝 = 逆光。或读 `AVCaptureDevice.exposureTargetOffset`。
- **判光从哪来**:① 画面内找过曝亮斑(太阳/反光)质心,相对球员在左/右;② 更鲁棒:`CoreLocation`(经纬度+时间)算**太阳方位/高度角** + `CoreMotion`/`CLHeading` 拿手机朝向 → 推「太阳在球员背后偏右,整套转 ~90°」。
- **输出**:「往左挪两步避开逆光」/「把杆转到另一侧」。有云台时可**自动转到更优角度**再提示站位。
- **接法**:新增 `Lighting/LightingAdvisor`,消费现有 pose + pixel buffer;真机前可拿 `sim_camera.mp4` 验逻辑。

### 2.2 手势 / 语音交互  〔iPhone 端可验(手势完整可验;语音受音频会话限制)〕
- **手势**:✅ `VNDetectHumanHandPoseRequest`(iOS 14+,端上,21 点)。**更省**:举手过头这类大动作直接用现有全身 pose 判,不必再开手部模型(省热预算);精细手势(数字/OK)才上 hand pose。
- **语音**:✅ `SFSpeechRecognizer`,可 `requiresOnDeviceRecognition = true` 纯端上。主动(按一下说)成本低;被动(常听唤醒词)需常驻麦 + 轻量 KWS。
- ⚠️ **和现有设计冲突**:`CameraService` 故意**不挂麦**(注释:占麦会打断用户音乐、拆麦输入可能让 AVCaptureSession 死锁),且 TTS 占着 playback 会话。**被动语音 = 长期占麦**,直接撞这两条。
  - 决策:**MVP 先做手势**(零音频风险,复用 pose);**语音只做主动**或等统一音频会话调度方案。

### 2.3 多摄并发  〔需真机验〕
- **iOS 让不让**:✅ `AVCaptureMultiCamSession`(iOS 13+,A12/iPhone XS 起)。广角+长焦不冲突。
  - 注:深度路径(`DepthCaptureService`)不能 multicam,因为 LiDAR+RGB 共用同一颗广角;**广角+长焦特写可以**。
- **硬约束**:`hardwareCost` / `systemPressureCost` 必须 ≤ 1.0;多摄强制降分辨率/帧率(不能两路都 1080p60)。
- **动态策略**:平时单广角;检测到 address/即将挥杆时开特写路,Finish 后关。本质是**分配热预算**(见 §3)。
- **接法**:把单 `AVCaptureVideoDataOutput` 改造成 `AVCaptureMultiCamSession`,每路一 output;pose 只跑主路(广角),特写路只录不推理。

### 2.4 自动对焦 / 曝光  〔需真机验〕
- **iOS 让不让**:✅ 全公开 API,无额外 entitlement。`exposurePointOfInterest`/`focusPointOfInterest`(+ `is*Supported`)、`setExposureTargetBias`(±~8 EV)、HDR video(`isVideoHDREnabled`)、`autoFocusRangeRestriction = .far`、`isSmoothAutoFocusEnabled`。人脸驱动 AE/AF(iOS 15.4+)默认就开。
- **用 pose 驱动而非人脸**:高尔夫 DTL 是侧脸、address 头低,人脸检测常失败;**用关键点(头/肩中点)驱动 POI** 更稳,face-on/DTL 都成立。
- ⚠️ **曝光 pumping 对模型有害**:continuous AE 帧亮度逐帧跳 → YOLO/PoseTCN 不稳 + 录像忽明忽暗。**绑定 `LiveSwingTracker` 状态机**:address 站定后在球员身上测好光 → 切 `.locked` 锁死;Finish 后切回 continuous 重测。
- **坐标系坑**:POI 用 device(sensor)坐标(固定 landscape、原点左上、0–1),**不是预览坐标也不是 pose 的各向异性归一化坐标**,需按 video orientation 手动换算。
- **锁的位置**:`lockForConfiguration` 走 `sessionQueue`,别在 `captureOutput`(videoQueue)里频繁调;POI 更新节流 ~0.3–0.5s。

### 2.5 动态视频保存策略  〔iPhone 端可验〕
- **存储数学**:现 `VideoRecorder` = 1080p30 H.264 @ 12 Mbps ≈ **90 MB/分 = 5.4 GB/时**;多摄特写翻倍。连续保存不可能。
- **地基已有**:60s **分块录制** + 隐藏的 `SwingScore.total` + `SwingArchive`(已只存 clean/problem 视频)。
- **滚动缓冲**:持续录进 ring buffer;Finish 后回看刚才几秒,够格才切片落盘,否则丢。
- **保留决策的多输入**:

  | 输入 | 类型 | 信号 |
  |---|---|---|
  | 手势/语音「存这条」 | 用户**主动** | 立即标记保留 |
  | 对杆满意(点头/竖拇指/语气) | 用户**被动** | 软信号,提分 |
  | `SwingScore.total` 高 | 系统自动(当前未暴露) | 无用户反馈时的兜底:留高分杆 |

### 2.6 拍后剪辑 / 集锦  〔iPhone 端可验〕
- **iOS 让不让**:✅ 全端上。`AVMutableComposition`(拼好杆)+ `AVVideoComposition`(转场/叠加)+ `scaleTimeRange`(变速)+ `AVAssetExportSession`(导出)。
- **最契合点**:已有每杆 **8 个挥杆事件帧** → 直接「**按挥杆阶段曲线变速**」(上杆常速、下杆到击球慢放、收杆恢复),穿插特写。数据驱动剪辑是差异化。

---

## 3. 三大硬约束 & 硬件如何拆解

1. **热 🔥**(最致命):多摄 + YOLO + PoseTCN + 手势模型 + 长时录制,手机还暴晒。
   - **硬件解法:风扇主动散热**,把整个热天花板抬高一档 → 多摄+多模型从「频繁降级」变「偶尔降级」。
   - **软件解法**:把 `ThermalBadge`/`PowerBench` 升级成**热预算调度器**——热了就降级(关特写路、降推理帧率、停集锦预渲染)。
2. **功耗**:1 小时连录会耗光电。
   - **硬件解法:杆子自带电池给手机供电**。iOS 对长期外部供电+满载无意见,App 不被打断。
   - 注:充电本身发热,风扇要同时压 SoC + 充电两份热;**有线(走 USB-C 口)比 MagSafe 无线充更凉更快**,优先有线供电。
3. **音频会话**:录音 + TTS + 语音识别三方抢一个 `AVAudioSession`,叠加「故意不占麦」的决定。
   - 解法:避开被动语音,或做统一音频调度(独立硬骨头)。

---

## 4. 硬件接口契约(给硬件团队)

### 4.1 控制连通性:**走 BLE,不走触点**
- **关键限制**:**iPhone 没有背面数据触点**(iPad 有 Smart Connector,iPhone 从来没有)。唯一数据出口是底部 USB-C/Lightning 口。
- 因此:
  - **pogopin / 磁吸阵列(背面)→ 只能传电,传不了数据。**
  - App↔自定义配件有线双向通信 = **External Accessory 框架 = 必须 MFi 认证**(配件需苹果认证协处理器)。创业期不建议。
- **结论 — 供电与控制解耦**:

  | 通道 | 物理路径 | 是否需苹果门槛 |
  |---|---|---|
  | 给手机供电 | pogopin/磁吸 → USB-C 口(优先有线) | 否 |
  | 风扇/电机供电 | 杆子电池直供 | 否(与 iPhone 无关) |
  | **App ↔ 云台 控制** | **BLE(CoreBluetooth)** | **否(无需 MFi)** |

  - 磁吸(MagSafe 式)= 对位 + 机械固定;pogopin/USB-C = 供电;**BLE = 控制**,三者解耦,硬件迭代互不影响。
  - 云台 MCU 由杆子电池供电 → **「BLE 费电」顾虑消失**。
  - MFi(一根 USB-C 同时供电+控制)留作后续优化,别让它卡 MVP。

### 4.2 BLE GATT 草拟(待细化)
云台 MCU 做成标准 BLE peripheral,至少暴露:
- **pan 角度写入**(目标角度/速度)
- **当前角度** read + notify
- **横竖屏状态** read + notify
- (可选)电量、温度、急停

> 拿一块 ESP32 当假云台即可先验 iPhone↔电机闭环,**不用等正式杆子**。

---

## 5. 推进顺序(先软件、先低风险,不等硬件)

| # | 任务 | 依赖硬件? | 现在可验? |
|---|---|---|---|
| 1 | **能力探针**(CapabilityProbe):真机一次性报告多摄/手势/语音/曝光/热的可用性 | 否 | ✅ 真机跑 |
| 2 | **光影识别 + 站位引导** | 否 | ✅(可拿 sim 视频验逻辑) |
| 3 | **手势触发**(复用现有 pose,零音频风险) | 否 | ✅ |
| 4 | **滚动缓冲 + 分数/手势保存** | 否 | ✅(改现有 chunk + SwingScore) |
| 5 | **多摄可行性 PoC**(`AVCaptureMultiCamSession`,量 hardwareCost/热) | 否(用 iPhone 自身镜头) | ✅ 真机 |
| 6 | **集锦剪辑**(端上 AVFoundation,用事件帧变速) | 否 | ✅ |
| 7 | **BLE 电机闭环 PoC**(ESP32 当假云台) | 否(假硬件) | ⏳ 需 ESP32 |
| 8 | 自动曝光/对焦(POI + address 锁定) | 否 | ✅ 真机 |
| 9 | 语音 / 统一音频会话调度 | 否 | ⏳ 待方案 |

**两个最大未知数**:多摄热成本(#5)、iPhone↔电机闭环(#7)——都不依赖正式杆子就能 derisk。

---

## 6. 现在已落地

- `Swin/Diagnostics/CapabilityProbe.swift` — 真机一次性能力探针(见 §5 #1)。env `CAPPROBE=1` 启动时跑,把多摄支持/可用镜头/手势/端上语音/曝光对焦能力/热状态打到 Xcode 控制台。模拟器能编过但多数相机项返回默认值——**以真机输出为准**。
