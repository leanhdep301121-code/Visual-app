import AVFoundation
import CoreMedia

final class VideoRecorder: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    /// Optional — only added when the caller indicates audio buffers will
    /// arrive. With audio-less capture, leaving this nil keeps the mp4
    /// from waiting for non-existent audio.
    private let audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.swin.recorder", qos: .userInitiated)
    private var sessionStarted = false
    let outputURL: URL

    /// `overrideTransform` lets callers bypass the landscape→portrait rotation.
    /// On a real device the camera delivers landscape sensor frames that need
    /// ±90° to show upright; the SIMULATOR's virtual camera feeds frames that
    /// are ALREADY portrait, so it passes `.identity` to avoid a sideways clip.
    init(outputURL: URL, sensorSize: CGSize, isFrontCamera: Bool = false,
         includeAudio: Bool = false, overrideTransform: CGAffineTransform? = nil) throws {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // We tried fragmented mp4 (`movieFragmentInterval = 1s`) to allow
        // mid-session clip exports, but AVF's behaviour exporting from a
        // still-being-written fragmented file was unreliable: the first
        // clip exported correctly, subsequent clips came back with wrong
        // time range / cropped frames. Easier to live with the memory
        // peak at session end than to debug iOS export internals.

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(sensorSize.width),
            AVVideoHeightKey: Int(sensorSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        // Buffers are appended in sensor (landscape) orientation; this display
        // transform tells players how to show them upright in portrait. The
        // back sensor needs +90°, the front sensor −90° — the fixed +90° for
        // both is why front-camera recordings came out flipped (test-report
        // item 3). Direction needs DEVICE verification — the simulator has
        // no camera.
        videoInput.transform = overrideTransform
            ?? CGAffineTransform(rotationAngle: isFrontCamera ? -.pi / 2 : .pi / 2)

        if writer.canAdd(videoInput) { writer.add(videoInput) }

        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) { writer.add(aInput) }
            audioInput = aInput
        } else {
            audioInput = nil
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.writer.startWriting()
        }
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            if writer.status == .writing, !sessionStarted {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            guard writer.status == .writing, sessionStarted, videoInput.isReadyForMoreMediaData else { return }
            videoInput.append(buffer)
        }
    }

    func appendAudio(_ buffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let audioInput else { return }
            guard writer.status == .writing, sessionStarted, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(buffer)
        }
    }

    func finish() async -> URL {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(returning: URL(fileURLWithPath: "/dev/null"))
                    return
                }
                guard writer.status == .writing else {
                    cont.resume(returning: outputURL)
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [outputURL] in
                    cont.resume(returning: outputURL)
                }
            }
        }
    }
}
