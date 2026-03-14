//
//  MediaSessionManager.swift
//  Doufu
//

import AVFoundation
import WebRTC

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Manages native camera/microphone capture and streams media to the WKWebView
/// via a loopback WebRTC PeerConnection.
///
/// Each `ProjectWorkspaceViewController` owns its own instance — this is **not** a singleton.
/// Camera and microphone are independent capabilities that share a single PeerConnection
/// when both are active.
@MainActor
final class MediaSessionManager: NSObject {

    weak var bridge: DoufuBridge?

    // MARK: - WebRTC Factory (shared across all instances)

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        // Use manual audio mode so that WebRTC does NOT automatically configure
        // AVAudioSession. This prevents video-only sessions from failing when
        // the system microphone permission is denied.
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        audioSession.useManualAudio = true
        audioSession.isAudioEnabled = false
        audioSession.unlockForConfiguration()
        // Prefer H264 High Profile for better quality at same bitrate.
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        videoEncoderFactory.preferredCodec = RTCVideoCodecInfo(name: kRTCH264CodecName, parameters: [
            "profile-level-id": kRTCMaxSupportedH264ProfileLevelConstrainedHigh,
        ])
        return RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )
    }()

    // MARK: - State

    private var peerConnection: RTCPeerConnection?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var videoSender: RTCRtpSender?
    private var audioSender: RTCRtpSender?

    private(set) var isCameraActive = false
    private(set) var isMicActive = false
    private var currentFacing: AVCaptureDevice.Position = .front
    private var capturedWidth = 1920
    private var capturedHeight = 1440
    private var capturedFPS = 30

    // MARK: - Pending Completions

    /// Called when SDP answer is received and connection established.
    /// The JS side resolves its promise via `ontrack`; native just needs to know
    /// that the pipeline is running so `executeCapability` can return success.
    private var pendingCameraCompletion: ((Result<Void, DoufuBridgeCapabilityError>) -> Void)?
    private var pendingMicCompletion: ((Result<Void, DoufuBridgeCapabilityError>) -> Void)?

    // MARK: - Public API

    func startCamera(
        facing: String,
        options: [String: Any] = [:],
        completion: @escaping (Result<Void, DoufuBridgeCapabilityError>) -> Void
    ) {
        let position: AVCaptureDevice.Position = (facing == "environment") ? .back : .front

        // If camera is already active with same facing, signal JS to reuse existing stream
        if isCameraActive && position == currentFacing {
            completion(.success(()))
            return
        }

        // If camera is active but facing changed, switch camera via replaceTrack
        if isCameraActive && position != currentFacing {
            switchCamera(to: position, options: options)
            completion(.success(()))
            return
        }

        // Check for available camera device
        guard findCameraDevice(position: position) != nil else {
            completion(.failure(DoufuBridgeCapabilityError(
                message: "No camera device available.",
                name: "NotSupportedError"
            )))
            return
        }

        isCameraActive = true
        currentFacing = position
        pendingCameraCompletion = completion

        let width = options["width"] as? Int ?? 1920
        let height = options["height"] as? Int ?? 1440
        let fps = options["fps"] as? Int ?? 30
        capturedWidth = width
        capturedHeight = height
        capturedFPS = fps

        addVideoTrack(position: position, width: width, height: height, fps: fps)
        renegotiate()
    }

    func stopCamera() {
        guard isCameraActive else { return }
        isCameraActive = false

        videoCapturer?.stopCapture()
        videoCapturer = nil
        videoSource = nil

        if let sender = videoSender {
            peerConnection?.removeTrack(sender)
            videoSender = nil
        }
        localVideoTrack = nil

        if isMicActive {
            renegotiate()
        } else {
            teardown()
        }
    }

    func startMicrophone(
        completion: @escaping (Result<Void, DoufuBridgeCapabilityError>) -> Void
    ) {
        // If mic is already active, signal JS to reuse existing stream
        if isMicActive {
            completion(.success(()))
            return
        }

        isMicActive = true
        pendingMicCompletion = completion

        configureAudioSession()
        addAudioTrack()
        renegotiate()
    }

    func stopMicrophone() {
        guard isMicActive else { return }
        isMicActive = false

        if let sender = audioSender {
            peerConnection?.removeTrack(sender)
            audioSender = nil
        }
        localAudioTrack = nil

        restoreAudioSession()

        if isCameraActive {
            renegotiate()
        } else {
            teardown()
        }
    }

    // MARK: - Camera Controls

    /// Focus at a normalized point (0–1, 0–1). Origin is top-left of the video frame.
    func focus(x: Double, y: Double) -> Result<Void, DoufuBridgeCapabilityError> {
        guard isCameraActive, let device = currentCaptureDevice() else {
            return .failure(DoufuBridgeCapabilityError(message: "Camera is not active.", name: "InvalidStateError"))
        }
        let point = CGPoint(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1))
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
            return .success(())
        } catch {
            return .failure(DoufuBridgeCapabilityError(message: error.localizedDescription, name: "NotReadableError"))
        }
    }

    /// Adjusts exposure compensation. `bias` is in EV units (typically -3.0 to +3.0).
    func setExposure(bias: Float) -> Result<Void, DoufuBridgeCapabilityError> {
        guard isCameraActive, let device = currentCaptureDevice() else {
            return .failure(DoufuBridgeCapabilityError(message: "Camera is not active.", name: "InvalidStateError"))
        }
        let clampedBias = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
            return .success(())
        } catch {
            return .failure(DoufuBridgeCapabilityError(message: error.localizedDescription, name: "NotReadableError"))
        }
    }

    /// Sets torch (flashlight) mode: "on" or "off". Acts as continuous fill light.
    func setTorch(mode: String) -> Result<Void, DoufuBridgeCapabilityError> {
        guard isCameraActive, let device = currentCaptureDevice() else {
            return .failure(DoufuBridgeCapabilityError(message: "Camera is not active.", name: "InvalidStateError"))
        }
        guard device.hasTorch else {
            return .failure(DoufuBridgeCapabilityError(message: "Torch is not available on this device.", name: "NotSupportedError"))
        }
        let torchMode: AVCaptureDevice.TorchMode = (mode == "on") ? .on : .off
        do {
            try device.lockForConfiguration()
            device.torchMode = torchMode
            device.unlockForConfiguration()
            return .success(())
        } catch {
            return .failure(DoufuBridgeCapabilityError(message: error.localizedDescription, name: "NotReadableError"))
        }
    }

    /// Sets zoom factor (1.0 = no zoom). Clamped to device's supported range.
    func setZoom(factor: Double) -> Result<Void, DoufuBridgeCapabilityError> {
        guard isCameraActive, let device = currentCaptureDevice() else {
            return .failure(DoufuBridgeCapabilityError(message: "Camera is not active.", name: "InvalidStateError"))
        }
        let clamped = CGFloat(factor.clamped(to: 1.0...Double(device.activeFormat.videoMaxZoomFactor)))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            return .success(())
        } catch {
            return .failure(DoufuBridgeCapabilityError(message: error.localizedDescription, name: "NotReadableError"))
        }
    }

    /// Mirrors the video track horizontally. Front camera is mirrored by default in most apps.
    func setMirrored(_ mirrored: Bool) -> Result<Void, DoufuBridgeCapabilityError> {
        guard isCameraActive, let source = videoSource else {
            return .failure(DoufuBridgeCapabilityError(message: "Camera is not active.", name: "InvalidStateError"))
        }
        // RTCVideoSource has an `adaptOutputFormat` but no direct mirror.
        // Mirror is achieved by setting the capturer's transform. For RTCCameraVideoCapturer,
        // we apply the mirror via the video source's frame adapter.
        // Note: Actual mirroring in GoogleWebRTC is typically handled via RTCVideoFrame rotation/mirror.
        // For now, we return not-supported — mirroring should be done in CSS (transform: scaleX(-1)).
        return .failure(DoufuBridgeCapabilityError(
            message: "Use CSS transform: scaleX(-1) on the video element to mirror.",
            name: "NotSupportedError"
        ))
    }

    private func currentCaptureDevice() -> AVCaptureDevice? {
        return findCameraDevice(position: currentFacing)
    }

    func stopAll() {
        let wasActive = isCameraActive || isMicActive

        videoCapturer?.stopCapture()
        videoCapturer = nil
        videoSource = nil
        localVideoTrack = nil
        localAudioTrack = nil
        videoSender = nil
        audioSender = nil
        isCameraActive = false
        isMicActive = false

        failPendingCompletions(message: "Media session stopped.", name: "AbortError")

        if wasActive {
            restoreAudioSession()
        }

        teardown()
    }

    // MARK: - Signaling (from JS via DoufuBridge)

    func handleMediaSignal(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }

        switch type {
        case "answer":
            guard let sdp = payload["sdp"] as? String else { return }
            handleAnswer(sdp: sdp)
        case "ice":
            guard let candidateDict = payload["candidate"] as? [String: Any],
                  let sdpMid = candidateDict["sdpMid"] as? String,
                  let candidate = candidateDict["candidate"] as? String else { return }
            // JS numbers arrive as NSNumber → Int; convert to Int32 for WebRTC API
            let sdpMLineIndex: Int32
            if let idx = candidateDict["sdpMLineIndex"] as? Int {
                sdpMLineIndex = Int32(idx)
            } else if let idx = candidateDict["sdpMLineIndex"] as? Int32 {
                sdpMLineIndex = idx
            } else {
                return
            }
            let iceCandidate = RTCIceCandidate(
                sdp: candidate,
                sdpMLineIndex: sdpMLineIndex,
                sdpMid: sdpMid
            )
            peerConnection?.add(iceCandidate)
        default:
            break
        }
    }

    // MARK: - Private: Track Management

    private func addVideoTrack(position: AVCaptureDevice.Position, width: Int, height: Int, fps: Int) {
        let source = Self.factory.videoSource()
        self.videoSource = source

        let capturer = RTCCameraVideoCapturer(delegate: source)
        self.videoCapturer = capturer

        let track = Self.factory.videoTrack(with: source, trackId: "doufu-video-0")
        track.isEnabled = true
        self.localVideoTrack = track

        guard ensurePeerConnection(), let pc = peerConnection else { return }
        guard let sender = pc.add(track, streamIds: ["doufu-video-stream"]) else { return }
        self.videoSender = sender

        // Boost encoding quality for loopback (no network, bandwidth is unlimited).
        configureVideoSender(sender, width: width, height: height, fps: fps)

        startCapture(capturer: capturer, position: position, width: width, height: height, fps: fps)
    }

    private func addAudioTrack() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let source = Self.factory.audioSource(with: constraints)
        let track = Self.factory.audioTrack(with: source, trackId: "doufu-audio-0")
        track.isEnabled = true
        self.localAudioTrack = track

        guard ensurePeerConnection(), let pc = peerConnection else { return }
        guard let sender = pc.add(track, streamIds: ["doufu-audio-stream"]) else { return }
        self.audioSender = sender
    }

    private func switchCamera(to position: AVCaptureDevice.Position, options: [String: Any] = [:]) {
        currentFacing = position

        guard videoCapturer != nil else { return }

        videoCapturer?.stopCapture()

        // Update resolution if new options provided
        if let w = options["width"] as? Int { capturedWidth = w }
        if let h = options["height"] as? Int { capturedHeight = h }
        if let f = options["fps"] as? Int { capturedFPS = f }

        // Create new source and track for the switched camera
        let newSource = Self.factory.videoSource()
        let newCapturer = RTCCameraVideoCapturer(delegate: newSource)
        let newTrack = Self.factory.videoTrack(with: newSource, trackId: "doufu-video-0")
        newTrack.isEnabled = true

        self.videoSource = newSource
        self.videoCapturer = newCapturer
        self.localVideoTrack = newTrack

        // Replace track on the existing sender (no renegotiation needed)
        videoSender?.track = newTrack

        startCapture(capturer: newCapturer, position: position, width: capturedWidth, height: capturedHeight, fps: capturedFPS)
    }

    private func startCapture(capturer: RTCCameraVideoCapturer, position: AVCaptureDevice.Position, width: Int, height: Int, fps: Int) {
        guard let device = findCameraDevice(position: position) else { return }

        // Find the best matching format
        let targetWidth = Int32(width)
        let targetHeight = Int32(height)
        var bestFormat: AVCaptureDevice.Format?
        var bestDiff = Int32.max

        for format in RTCCameraVideoCapturer.supportedFormats(for: device) {
            let desc = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(desc.width - targetWidth) + abs(desc.height - targetHeight)
            if diff < bestDiff {
                bestDiff = diff
                bestFormat = format
            }
        }

        guard let format = bestFormat else { return }

        // Find best matching FPS
        var bestFPS = fps
        var foundFPS = false
        for range in format.videoSupportedFrameRateRanges {
            if Int(range.minFrameRate) <= fps && fps <= Int(range.maxFrameRate) {
                foundFPS = true
                break
            }
        }
        if !foundFPS, let range = format.videoSupportedFrameRateRanges.first {
            bestFPS = min(fps, Int(range.maxFrameRate))
        }

        capturer.startCapture(with: device, format: format, fps: bestFPS)
    }

    private func findCameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devices = RTCCameraVideoCapturer.captureDevices()
        return devices.first { $0.position == position } ?? devices.first
    }

    /// Configures the video sender for high quality loopback streaming.
    private func configureVideoSender(_ sender: RTCRtpSender, width: Int, height: Int, fps: Int) {
        let params = sender.parameters
        for encoding in params.encodings {
            // High bitrate — loopback has no network constraint.
            // ~12 Mbps for 1080p, scales proportionally.
            let pixels = width * height
            let baseBitrate = Double(pixels) / (1920.0 * 1080.0) * 12_000_000.0
            encoding.maxBitrateBps = NSNumber(value: Int(baseBitrate))
            encoding.maxFramerate = NSNumber(value: fps)
        }
        // Under load, drop frames instead of reducing resolution.
        // degradationPreference: 1 = maintain-resolution, 2 = maintain-framerate, 3 = balanced
        params.degradationPreference = NSNumber(value: 1)
        sender.parameters = params
    }

    // MARK: - Private: PeerConnection

    @discardableResult
    private func ensurePeerConnection() -> Bool {
        guard peerConnection == nil else { return true }

        let config = RTCConfiguration()
        config.iceServers = [] // Loopback — no external STUN/TURN needed
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        guard let pc = Self.factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: nil
        ) else {
            failPendingCompletions(message: "Failed to create PeerConnection.", name: "NotSupportedError")
            return false
        }
        // Set delegate after creation (delegate is nonisolated but we route back to MainActor)
        pc.delegate = self
        self.peerConnection = pc
        return true
    }

    private func renegotiate() {
        guard let pc = peerConnection else { return }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "false",
                "OfferToReceiveAudio": "false"
            ],
            optionalConstraints: nil
        )

        pc.offer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor [weak self] in
                guard let self, let sdp else {
                    self?.failPendingCompletions(
                        message: error?.localizedDescription ?? "Failed to create offer.",
                        name: "NotSupportedError"
                    )
                    return
                }
                self.peerConnection?.setLocalDescription(sdp) { error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let error {
                            self.failPendingCompletions(
                                message: error.localizedDescription,
                                name: "NotSupportedError"
                            )
                            return
                        }
                        // Send offer to JS
                        self.bridge?.sendMediaSignal(
                            type: "offer",
                            sdp: sdp.sdp
                        )
                        // Complete pending callbacks — the native pipeline is running.
                        // JS will resolve its own promise via `ontrack`.
                        self.succeedPendingCompletions()
                    }
                }
            }
        }
    }

    private func handleAnswer(sdp: String) {
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        peerConnection?.setRemoteDescription(answer) { error in
            if let error {
                print("[MediaSessionManager] Failed to set remote description: \(error.localizedDescription)")
            }
        }
    }

    private func teardown() {
        if let pc = peerConnection {
            pc.delegate = nil
            pc.close()
            peerConnection = nil
        }
        // Notify JS to tear down its PeerConnection
        bridge?.sendMediaSignal(type: "teardown")
    }

    // MARK: - Private: Completions

    private func succeedPendingCompletions() {
        if let c = pendingCameraCompletion {
            pendingCameraCompletion = nil
            c(.success(()))
        }
        if let c = pendingMicCompletion {
            pendingMicCompletion = nil
            c(.success(()))
        }
    }

    private func failPendingCompletions(message: String, name: String) {
        let error = DoufuBridgeCapabilityError(message: message, name: name)
        if let c = pendingCameraCompletion {
            pendingCameraCompletion = nil
            c(.failure(error))
        }
        if let c = pendingMicCompletion {
            pendingMicCompletion = nil
            c(.failure(error))
        }
    }

    // MARK: - Private: Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("[MediaSessionManager] Failed to configure audio session: \(error)")
        }
        // Tell WebRTC it's OK to use audio now
        let rtcAudio = RTCAudioSession.sharedInstance()
        rtcAudio.lockForConfiguration()
        rtcAudio.isAudioEnabled = true
        rtcAudio.unlockForConfiguration()
    }

    private func restoreAudioSession() {
        guard !isMicActive else { return }
        // Tell WebRTC to stop using audio
        let rtcAudio = RTCAudioSession.sharedInstance()
        rtcAudio.lockForConfiguration()
        rtcAudio.isAudioEnabled = false
        rtcAudio.unlockForConfiguration()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
        } catch {
            print("[MediaSessionManager] Failed to restore audio session: \(error)")
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension MediaSessionManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed {
            Task { @MainActor [weak self] in
                self?.failPendingCompletions(message: "ICE connection failed.", name: "NotSupportedError")
                self?.stopAll()
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            self?.bridge?.sendMediaSignal(
                type: "ice",
                candidate: [
                    "candidate": candidate.sdp,
                    "sdpMid": candidate.sdpMid ?? "",
                    "sdpMLineIndex": candidate.sdpMLineIndex
                ]
            )
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
