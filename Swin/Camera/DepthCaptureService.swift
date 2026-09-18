import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

/// Single-source synchronized RGB + depth capture.
///
/// Source is selectable via `preferredSource`:
///   - `.lidar`    — `.builtInLiDARDepthCamera` (iPhone/iPad Pro). Absolute
///                   metric depth, high quality. Preferred for golf.
///   - `.dualCam`  — `.builtInDualWideCamera` / Dual / Triple. Disparity
///                   from baseline; Apple flags this relative+low for
///                   typical scenes. Kept for comparison only.
///   - `.auto`     — prefer LiDAR, fall back to dual-cam.
///
/// `AVCaptureMultiCamSession` was tried earlier but Apple does not allow
/// both `.builtInLiDARDepthCamera` and `.builtInDualWideCamera` in one
/// session (both need the wide camera as their underlying physical input).
/// To compare LiDAR vs dual-cam depth, record one swing with each source.
///
/// Storage layout per session:
///
///   Documents/DepthCaptures/{yyyy-MM-dd_HHmmss}/
///     meta.json           — depth_source ("lidar" | "dualCam"), dims, fps
///     intrinsics.json     — fx/fy/cx/cy + lens distortion
///     frame_metas.json    — per-frame PTS, depth accuracy/quality flags
///     rgb/000000.jpg      — 1080p JPEG q=0.85
///     depth/000000.bin    — Float32 little-endian, row-major, meters,
///                            NaN where invalid
@Observable
final class DepthCaptureService: NSObject, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case configuring
        case denied
        case ready
        case recording
        case finishing
        case done
        case error(String)
    }

    enum DepthSource: String {
        case lidar
        case dualCam
        case auto
    }

    var preferredSource: DepthSource = .auto
    private(set) var activeSource: DepthSource? = nil

    private(set) var state: State = .idle
    private(set) var currentSessionDir: URL?
    private(set) var frameCount: Int = 0

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "swin.depth.session", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "swin.depth.capture", qos: .userInitiated)
    private let writeQueue   = DispatchQueue(label: "swin.depth.write",   qos: .utility)

    private let videoOut = AVCaptureVideoDataOutput()
    private let depthOut = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var videoInput: AVCaptureDeviceInput?
    private weak var device: AVCaptureDevice?

    private let writeLock = NSLock()
    private var isWriting: Bool = false
    private var writtenIntrinsics: Bool = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private struct FrameMeta: Encodable {
        let idx: Int
        let pts_sec: Double
        let depth_pts_sec: Double
        let depth_accuracy: String
        let depth_quality: String
    }
    private var frameMetas: [FrameMeta] = []

    fileprivate static var didLogFirstSync: Bool = false
    private var syncFireCount: Int = 0
    private var syncWithDepthCount: Int = 0

    private var sessionID: String = ""
    private var startedAt: String = ""

    // MARK: - lifecycle

    func bootstrap() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .video)
            guard ok else { await MainActor.run { self.state = .denied }; return }
        default:
            await MainActor.run { self.state = .denied }; return
        }
        configure()
    }

    func teardown() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func resumePreview() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// Switch source and reconfigure. No-op while recording.
    func setSource(_ src: DepthSource) {
        guard preferredSource != src else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.writeLock.lock()
            let recording = self.isWriting
            self.writeLock.unlock()
            if recording { return }
            self.preferredSource = src
            self.session.stopRunning()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.synchronizer = nil
            self.videoInput = nil
            self.device = nil
            self.activeSource = nil
            self.session.commitConfiguration()
            self.configure()
        }
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.publish(.configuring)
            self.session.beginConfiguration()

            func pickLiDAR() -> AVCaptureDevice? {
                AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
            }
            func pickDualCam() -> AVCaptureDevice? {
                AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            }

            let chosen: (AVCaptureDevice, DepthSource)? = {
                switch self.preferredSource {
                case .lidar:
                    return pickLiDAR().map { ($0, .lidar) }
                case .dualCam:
                    return pickDualCam().map { ($0, .dualCam) }
                case .auto:
                    if let d = pickLiDAR() { return (d, .lidar) }
                    if let d = pickDualCam() { return (d, .dualCam) }
                    return nil
                }
            }()
            guard let (device, source) = chosen else {
                self.session.commitConfiguration()
                let need: String = {
                    switch self.preferredSource {
                    case .lidar:   return "LiDAR (iPhone/iPad Pro)"
                    case .dualCam: return "dual/triple back camera"
                    case .auto:    return "LiDAR or dual/triple back camera"
                    }
                }()
                self.publish(.error("device has no \(need)"))
                return
            }
            self.device = device
            self.activeSource = source

            guard let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                self.publish(.error("can't add camera input"))
                return
            }
            self.session.addInput(input)
            self.videoInput = input

            self.videoOut.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            self.videoOut.alwaysDiscardsLateVideoFrames = false
            if self.session.canAddOutput(self.videoOut) {
                self.session.addOutput(self.videoOut)
            }

            if self.session.canAddOutput(self.depthOut) {
                self.session.addOutput(self.depthOut)
            }
            self.depthOut.isFilteringEnabled = false

            self.applyBestFormatWithDepth(on: device)

            if let dc = self.depthOut.connection(with: .depthData) {
                dc.isEnabled = true
                if #available(iOS 17.0, *) {
                    if dc.isVideoRotationAngleSupported(90) { dc.videoRotationAngle = 90 }
                } else {
                    dc.videoOrientation = .portrait
                }
            }
            if let vc = self.videoOut.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if vc.isVideoRotationAngleSupported(90) { vc.videoRotationAngle = 90 }
                } else {
                    vc.videoOrientation = .portrait
                }
            }

            let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [self.videoOut, self.depthOut])
            sync.setDelegate(self, queue: self.captureQueue)
            self.synchronizer = sync

            let vfmtDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let dfmtDims: CMVideoDimensions? = device.activeDepthDataFormat.map {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            }
            dbg(tag: "depth", "source=\(source.rawValue) device=\(device.localizedName), "
                + "video=\(vfmtDims.width)×\(vfmtDims.height), "
                + "depth=\(dfmtDims.map { "\($0.width)×\($0.height)" } ?? "nil"), "
                + "depthConn.enabled=\(self.depthOut.connection(with: .depthData)?.isEnabled ?? false)")

            self.session.commitConfiguration()
            self.session.startRunning()
            dbg(tag: "depth", "session running=\(self.session.isRunning)")
            self.publish(.ready)
        }
    }

    private func applyBestFormatWithDepth(on device: AVCaptureDevice) {
        let candidates = device.formats.filter { fmt in
            !fmt.supportedDepthDataFormats.isEmpty
        }
        guard !candidates.isEmpty else {
            publish(.error("device has no video format that supports depth output"))
            return
        }
        let preferred = candidates.first(where: { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            return dims.width == 1920 && dims.height == 1080
        }) ?? candidates.first!

        let depthFormats = preferred.supportedDepthDataFormats
        let depthFmt = depthFormats.max(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        })

        do {
            try device.lockForConfiguration()
            device.activeFormat = preferred
            if let depthFmt {
                device.activeDepthDataFormat = depthFmt
            }
            if let fr = preferred.videoSupportedFrameRateRanges.first {
                let fps = min(fr.maxFrameRate, 30)
                let dur = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            }
            device.unlockForConfiguration()
        } catch {
            publish(.error("format setup failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - recording control

    func startRecording() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeLock.lock()
            if self.isWriting { self.writeLock.unlock(); return }
            do {
                let id = Self.makeSessionID()
                let dir = try Self.makeSessionDir(id: id)
                self.sessionID = id
                self.startedAt = ISO8601DateFormatter().string(from: Date())
                self.currentSessionDir = dir
                self.frameCount = 0
                self.writtenIntrinsics = false
                self.isWriting = true
                self.frameMetas.removeAll(keepingCapacity: true)
                DepthCaptureService.didLogFirstSync = false
                self.writeLock.unlock()
                dbg(tag: "depth", "REC start → \(dir.lastPathComponent)")
                DispatchQueue.main.async { self.state = .recording }
            } catch {
                self.writeLock.unlock()
                DispatchQueue.main.async {
                    self.state = .error("create dir: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopRecording() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeLock.lock()
            guard self.isWriting, let dir = self.currentSessionDir else {
                self.writeLock.unlock()
                return
            }
            self.isWriting = false
            let frames = self.frameCount
            let metasCopy = self.frameMetas
            self.writeLock.unlock()
            self.writeMeta(into: dir, frameCount: frames)
            self.writeFrameMetas(metasCopy, into: dir)
            dbg(tag: "depth", "REC stop → \(frames) frames in \(dir.lastPathComponent)")
            DispatchQueue.main.async {
                self.state = .done
            }
        }
    }

    private func writeFrameMetas(_ metas: [FrameMeta], into dir: URL) {
        let url = dir.appendingPathComponent("frame_metas.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(metas) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - file naming

    private static func makeSessionID() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }

    private static func makeSessionDir(id: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs
            .appendingPathComponent("DepthCaptures", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("rgb"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("depth"),
                                                withIntermediateDirectories: true)
        return dir
    }

    private func publish(_ s: State) {
        DispatchQueue.main.async { self.state = s }
    }
}

// MARK: - AVCaptureDataOutputSynchronizerDelegate

extension DepthCaptureService: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        let videoData = synchronizedDataCollection
            .synchronizedData(for: videoOut) as? AVCaptureSynchronizedSampleBufferData
        let depthData = synchronizedDataCollection
            .synchronizedData(for: depthOut) as? AVCaptureSynchronizedDepthData

        syncFireCount += 1
        if depthData != nil { syncWithDepthCount += 1 }
        if !DepthCaptureService.didLogFirstSync {
            DepthCaptureService.didLogFirstSync = true
            dbg(tag: "depth", "first sync: video=\(videoData != nil), depth=\(depthData != nil), "
                + "videoDropped=\(videoData?.sampleBufferWasDropped ?? false), "
                + "depthDropped=\(depthData?.depthDataWasDropped ?? false)")
        } else if syncFireCount % 30 == 0 {
            dbg(tag: "depth", "fires=\(syncFireCount) withDepth=\(syncWithDepthCount) written=\(frameCount)")
        }

        guard let videoData, let depthData else { return }
        if videoData.sampleBufferWasDropped || depthData.depthDataWasDropped { return }

        writeLock.lock()
        guard isWriting, let dir = currentSessionDir else {
            writeLock.unlock(); return
        }
        let idx = frameCount
        frameCount += 1
        let needIntrinsics = !writtenIntrinsics
        writtenIntrinsics = true

        let vidPts = CMTimeGetSeconds(
            CMSampleBufferGetPresentationTimeStamp(videoData.sampleBuffer))
        let depPts = CMTimeGetSeconds(depthData.timestamp)
        let accuracy: String
        switch depthData.depthData.depthDataAccuracy {
        case .absolute: accuracy = "absolute"
        case .relative: accuracy = "relative"
        @unknown default: accuracy = "unknown"
        }
        let quality: String
        switch depthData.depthData.depthDataQuality {
        case .high: quality = "high"
        case .low: quality = "low"
        @unknown default: quality = "unknown"
        }
        frameMetas.append(FrameMeta(
            idx: idx,
            pts_sec: vidPts,
            depth_pts_sec: depPts,
            depth_accuracy: accuracy,
            depth_quality: quality
        ))
        writeLock.unlock()

        let sampleBuffer = videoData.sampleBuffer
        let rawDepth = depthData.depthData

        writeQueue.async { [weak self] in
            guard let self else { return }
            self.persistFrame(
                sampleBuffer: sampleBuffer,
                depth: rawDepth,
                index: idx,
                into: dir,
                writeIntrinsics: needIntrinsics
            )
        }
    }

    private func persistFrame(sampleBuffer: CMSampleBuffer,
                              depth rawDepth: AVDepthData,
                              index: Int,
                              into dir: URL,
                              writeIntrinsics: Bool) {
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let ci = CIImage(cvPixelBuffer: pb)
            let rgbURL = dir.appendingPathComponent("rgb")
                .appendingPathComponent(String(format: "%06d.jpg", index))
            writeJPEG(ciImage: ci, to: rgbURL, quality: 0.85)
        }

        let depthMeters: AVDepthData
        if rawDepth.depthDataType == kCVPixelFormatType_DepthFloat32 {
            depthMeters = rawDepth
        } else {
            depthMeters = rawDepth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        let depthURL = dir.appendingPathComponent("depth")
            .appendingPathComponent(String(format: "%06d.bin", index))
        writeDepthRaw(depthMeters.depthDataMap, to: depthURL)

        if writeIntrinsics, let calib = depthMeters.cameraCalibrationData {
            writeIntrinsicsJSON(calib, depthMap: depthMeters.depthDataMap, into: dir)
        }
    }

    private func writeJPEG(ciImage: CIImage, to url: URL, quality: CGFloat) {
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func writeDepthRaw(_ pixelBuffer: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = w * MemoryLayout<Float32>.size
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        var packed = Data(capacity: rowBytes * h)
        for row in 0..<h {
            let rowPtr = base.advanced(by: row * bytesPerRow)
            packed.append(Data(bytesNoCopy: rowPtr, count: rowBytes, deallocator: .none))
        }
        try? packed.write(to: url, options: .atomic)
    }

    private func writeIntrinsicsJSON(_ calib: AVCameraCalibrationData,
                                     depthMap: CVPixelBuffer,
                                     into dir: URL) {
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        let m = calib.intrinsicMatrix
        let ref = calib.intrinsicMatrixReferenceDimensions
        // AVFoundation's `intrinsicMatrix` is reported in the SENSOR's native
        // landscape orientation. The depth buffer here has been rotated to
        // portrait via `videoRotationAngle = 90`. We detect orientation
        // mismatch by aspect ratio and rotate the intrinsics accordingly:
        // a 90° rotation swaps the fx↔fy and cx↔cy axes, plus shifts cy
        // because the new y-axis runs along the OLD width.
        let bufLandscape = dw > dh
        let refLandscape = ref.width > ref.height
        let rotated = bufLandscape != refLandscape

        let fx_l = Double(m.columns.0.x)
        let fy_l = Double(m.columns.1.y)
        let cx_l = Double(m.columns.2.x)
        let cy_l = Double(m.columns.2.y)
        let refW = Double(ref.width)
        let refH = Double(ref.height)

        let fx, fy, cx, cy: Double
        if rotated {
            // After 90° CCW rotation: new_x = old_y, new_y = (refW − 1) − old_x
            // → fx_new = fy_old, fy_new = fx_old (in landscape pixels)
            // → cx_new = cy_old, cy_new = refW − cx_old
            // Then scale to depth-buffer resolution.
            let sx = Double(dw) / refH    // new width maps to old height
            let sy = Double(dh) / refW    // new height maps to old width
            fx = fy_l * sx
            fy = fx_l * sy
            cx = cy_l * sx
            cy = (refW - cx_l) * sy
        } else {
            let sx = Double(dw) / refW
            let sy = Double(dh) / refH
            fx = fx_l * sx
            fy = fy_l * sy
            cx = cx_l * sx
            cy = cy_l * sy
        }

        var obj: [String: Any] = [
            "rgb_intrinsics_reference": [
                "width": Double(ref.width),
                "height": Double(ref.height),
                "fx": fx_l, "fy": fy_l, "cx": cx_l, "cy": cy_l,
            ],
            "depth_intrinsics": [
                "width": dw,
                "height": dh,
                "fx": fx, "fy": fy, "cx": cx, "cy": cy,
                "rotated_from_landscape": rotated,
            ],
            "pixel_size_mm": Double(calib.pixelSize),
        ]
        if let lut = calib.lensDistortionLookupTable {
            obj["lens_distortion_lookup_count"] = lut.count / MemoryLayout<Float>.size
        }
        if let center = calib.lensDistortionCenter as CGPoint? {
            obj["lens_distortion_center"] = ["x": Double(center.x), "y": Double(center.y)]
        }
        let url = dir.appendingPathComponent("intrinsics.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func writeMeta(into dir: URL, frameCount: Int) {
        var meta: [String: Any] = [
            "session_id": sessionID,
            "started_at": startedAt,
            "ended_at": ISO8601DateFormatter().string(from: Date()),
            "depth_source": activeSource?.rawValue ?? "unknown",
            "frame_count": frameCount,
            "depth_format": "float32_meters_row_major_little_endian",
            "rgb_format": "jpeg_q0.85",
        ]
        if let activeFormat = device?.activeFormat {
            let d = CMVideoFormatDescriptionGetDimensions(activeFormat.formatDescription)
            meta["rgb_video_dims"] = ["width": Int(d.width), "height": Int(d.height)]
            if let fr = activeFormat.videoSupportedFrameRateRanges.first {
                meta["max_fps"] = fr.maxFrameRate
            }
        }
        if let activeDepth = device?.activeDepthDataFormat {
            let d = CMVideoFormatDescriptionGetDimensions(activeDepth.formatDescription)
            meta["depth_dims"] = ["width": Int(d.width), "height": Int(d.height)]
        }
        let url = dir.appendingPathComponent("meta.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
