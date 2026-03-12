//
//  PiPProgressManager.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import AVFoundation
import AVKit
import UIKit

/// Manages a Picture-in-Picture window that displays chat task progress.
/// PiP activates when the app resigns active during an active task,
/// and deactivates when the app returns to the foreground.
@MainActor
final class PiPProgressManager: NSObject {

    static let shared = PiPProgressManager()

    // MARK: - Settings

    private static let enabledKey = "pipProgressEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    // MARK: - Multi-Session State

    private struct PiPTaskEntry {
        let sessionID: String
        var projectName: String
        var projectSnapshot: UIImage?
        var statusText: String
        var startDate: Date
        var isFinished: Bool
        var finishedStatusText: String?
        var needsUserAction: Bool
    }

    private var taskEntries: [String: PiPTaskEntry] = [:]
    /// The session currently displayed in PiP.
    private var displayedSessionID: String?

    // MARK: - State

    private(set) var isActive = false
    private var hasActiveTask = false
    private var isPiPShowing = false
    private var isFinished = false
    private var needsUserAction = false

    /// The entry currently being rendered.
    private var displayedEntry: PiPTaskEntry?

    // MARK: - PiP Infrastructure

    private var pipController: AVPictureInPictureController?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipSourceView: UIView?
    private var refreshTimer: Timer?
    private var audioPlayer: AVAudioPlayer?

    private var projectName: String = ""
    private var projectSnapshot: UIImage?
    private var currentStatusText: String = ""
    private var currentElapsedText: String = ""
    private var taskStartDate: Date?
    private var finishedStatusText: String?
    // Portrait-oriented PiP (tall and narrow).
    private let pipSize = CGSize(width: 270, height: 480)
    private let refreshInterval: TimeInterval = 1.0

    private override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // MARK: - App Lifecycle

    @objc private func appWillResignActive() {
        guard isActive, isEnabled, hasActiveTask else { return }
        pipController?.startPictureInPicture()
    }

    @objc private func appDidBecomeActive() {
        guard isPiPShowing else { return }
        stopAudioPlayer()
        pipController?.stopPictureInPicture()

        // Detach old infrastructure so preparePiPController creates fresh ones.
        pipSourceView = nil
        pipController = nil
        displayLayer = nil
        isActive = false
        isPiPShowing = false

        // If the task is still running, recreate immediately.
        if hasActiveTask {
            preparePiPController()
        } else {
            isFinished = false
            finishedStatusText = nil
            projectSnapshot = nil
        }
    }

    // MARK: - Multi-Session Task Lifecycle

    func taskDidStart(sessionID: String, projectName: String, projectURL: URL) {
        guard isEnabled, AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }

        let snapshot = loadProjectSnapshot(from: projectURL)
        let entry = PiPTaskEntry(
            sessionID: sessionID,
            projectName: projectName,
            projectSnapshot: snapshot,
            statusText: String(localized: "pip.status.working"),
            startDate: Date(),
            isFinished: false,
            finishedStatusText: nil,
            needsUserAction: false
        )
        taskEntries[sessionID] = entry
        hasActiveTask = true

        // If no session is being displayed, display this one
        if displayedSessionID == nil {
            displaySession(entry)
        }
    }

    func updateStatus(_ text: String, sessionID: String) {
        taskEntries[sessionID]?.statusText = text
        taskEntries[sessionID]?.needsUserAction = false
        if displayedSessionID == sessionID {
            currentStatusText = text
            needsUserAction = false
            if isActive { pushFrame() }
        }
    }

    func setNeedsUserAction(sessionID: String) {
        taskEntries[sessionID]?.needsUserAction = true
        if displayedSessionID == sessionID {
            needsUserAction = true
            if isActive { pushFrame() }
        }
    }

    func clearNeedsUserAction(sessionID: String) {
        taskEntries[sessionID]?.needsUserAction = false
        if displayedSessionID == sessionID {
            needsUserAction = false
            if isActive { pushFrame() }
        }
    }

    func taskDidComplete(sessionID: String) {
        taskEntries.removeValue(forKey: sessionID)
        if taskEntries.isEmpty { hasActiveTask = false }
        if displayedSessionID == sessionID {
            displayedSessionID = nil
            if let nextEntry = taskEntries.values.first(where: { !$0.isFinished }) {
                displaySession(nextEntry)
            } else {
                taskDidComplete()
            }
        }
    }

    func taskDidFail(sessionID: String, message: String? = nil) {
        taskEntries.removeValue(forKey: sessionID)
        if taskEntries.isEmpty { hasActiveTask = false }
        if displayedSessionID == sessionID {
            displayedSessionID = nil
            if let nextEntry = taskEntries.values.first(where: { !$0.isFinished }) {
                displaySession(nextEntry)
            } else {
                taskDidFail(message)
            }
        }
    }

    func taskDidCancel(sessionID: String) {
        taskEntries.removeValue(forKey: sessionID)
        if taskEntries.isEmpty { hasActiveTask = false }
        if displayedSessionID == sessionID {
            displayedSessionID = nil
            if let nextEntry = taskEntries.values.first(where: { !$0.isFinished }) {
                displaySession(nextEntry)
            } else {
                taskDidCancel()
            }
        }
    }

    private func displaySession(_ entry: PiPTaskEntry) {
        displayedSessionID = entry.sessionID
        displayedEntry = entry
        projectName = entry.projectName
        projectSnapshot = entry.projectSnapshot
        currentStatusText = entry.statusText
        taskStartDate = entry.startDate
        needsUserAction = entry.needsUserAction
        isFinished = entry.isFinished
        finishedStatusText = entry.finishedStatusText
        currentElapsedText = formattedElapsed(Date().timeIntervalSince(entry.startDate))

        if !isActive {
            preparePiPController()
        } else {
            pushFrame()
        }
    }

    // MARK: - Legacy Task Lifecycle (single-session)

    func taskDidStart(projectName: String, projectURL: URL) {
        guard isEnabled, AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }

        // Clean up any previous finished state.
        if isActive {
            tearDown()
        }

        self.projectName = projectName
        // Load static preview as initial fallback; live snapshots replace it.
        self.projectSnapshot = loadProjectSnapshot(from: projectURL)
        hasActiveTask = true
        isFinished = false
        finishedStatusText = nil
        taskStartDate = Date()
        currentStatusText = String(localized: "pip.status.working")
        currentElapsedText = formattedElapsed(0)

        preparePiPController()
    }

    func updateStatus(_ text: String) {
        guard hasActiveTask else { return }
        currentStatusText = text
        needsUserAction = false
        if isActive {
            pushFrame()
        }
    }

    /// Call when the task is waiting for user confirmation (e.g. tool authorization).
    func setNeedsUserAction() {
        guard hasActiveTask else { return }
        needsUserAction = true
        if isActive {
            pushFrame()
        }
    }

    /// Call when the task completes successfully.
    func taskDidComplete() {
        hasActiveTask = false
        guard isActive else { return }
        if isPiPShowing {
            isFinished = true
            finishedStatusText = String(localized: "pip.status.completed")
            stopAudioPlayer()
            stopRefreshTimer()
            freezeElapsedTime()
            pushFrame()
            playChime()
        } else {
            tearDown()
        }
    }

    /// Call when the task fails with an error.
    func taskDidFail(_ message: String? = nil) {
        hasActiveTask = false
        guard isActive else { return }
        if isPiPShowing {
            isFinished = true
            finishedStatusText = message ?? String(localized: "pip.status.failed")
            stopAudioPlayer()
            stopRefreshTimer()
            freezeElapsedTime()
            pushFrame()
            playChime()
        } else {
            tearDown()
        }
    }

    /// Call when the task is cancelled.
    func taskDidCancel() {
        let wasActive = isActive
        hasActiveTask = false
        isFinished = true
        finishedStatusText = String(localized: "pip.status.cancelled")
        if wasActive {
            stopAudioPlayer()
            stopRefreshTimer()
            freezeElapsedTime()
            pushFrame()
            playChime()
        } else {
            taskStartDate = nil
            tearDown()
        }
    }

    private func freezeElapsedTime() {
        if let start = taskStartDate {
            currentElapsedText = formattedElapsed(Date().timeIntervalSince(start))
        }
        taskStartDate = nil
    }

    // MARK: - PiP Setup

    private func preparePiPController() {
        guard pipController == nil else { return }

        configureAudioSession()

        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(origin: .zero, size: pipSize)
        layer.videoGravity = .resizeAspect

        // The source view must be fully opaque and on-screen for iOS to
        // pick up valid PiP content. We insert it at index 0 so the app's
        // real UI sits on top and hides it from the user.
        let sourceView = UIView(frame: CGRect(origin: .zero, size: pipSize))
        sourceView.isUserInteractionEnabled = false
        sourceView.layer.addSublayer(layer)

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let window = windowScene.windows.first else {
            return
        }
        window.insertSubview(sourceView, at: 0)

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        controller.setValue(2, forKey: "controlsStyle")

        self.displayLayer = layer
        self.pipSourceView = sourceView
        self.pipController = controller
        self.isActive = true

        pushFrame()
        startRefreshTimer()
    }

    private func tearDown() {
        stopRefreshTimer()
        stopAudioPlayer()

        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }

        isActive = false
        isPiPShowing = false
        isFinished = false
        hasActiveTask = false
        finishedStatusText = nil
        projectSnapshot = nil
        displayLayer?.flushAndRemoveImage()
        pipSourceView?.removeFromSuperview()
        pipSourceView = nil
        displayLayer = nil
        pipController = nil
    }

    // MARK: - Audio

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func startAudioPlayer() {
        guard audioPlayer == nil, !isFinished,
              let url = Bundle.main.url(forResource: "keyboard-typing", withExtension: "mp3") else {
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.15
            player.play()
            audioPlayer = player
        } catch {}
    }

    private func stopAudioPlayer() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func playChime() {
        guard let url = Bundle.main.url(forResource: "complete", withExtension: "wav") else {
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.4
            player.play()
            // Keep a reference so it doesn't get deallocated mid-playback.
            audioPlayer = player
        } catch {}
    }

    // MARK: - Frame Rendering

    private func pushFrame() {
        guard let layer = displayLayer else { return }
        guard let pixelBuffer = renderPixelBuffer() else { return }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: refreshInterval, preferredTimescale: 600),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let format = formatDescription else { return }

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard let buffer = sampleBuffer else { return }

        // Flush any stale image so the layer is ready to display new content.
        layer.flush()
        layer.enqueue(buffer)
    }

    /// Renders the status UI directly into a CVPixelBuffer (BGRA format).
    /// This avoids UIImage/CGImage intermediary conversion that can cause
    /// format mismatches with AVSampleBufferDisplayLayer.
    private func renderPixelBuffer() -> CVPixelBuffer? {
        let scale = UIScreen.main.scale
        let width = Int(pipSize.width * scale)
        let height = Int(pipSize.height * scale)

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let data = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // CGContext has origin at bottom-left; flip for UIKit drawing.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)

        UIGraphicsPushContext(ctx)
        drawStatusContent()
        UIGraphicsPopContext()

        return buffer
    }

    /// Draws the PiP status content using UIKit into the current graphics context.
    /// Layout: text info on top, project screenshot "phone preview" on bottom.
    private func drawStatusContent() {
        // Background
        UIColor.black.setFill()
        UIRectFill(CGRect(origin: .zero, size: pipSize))

        let padding: CGFloat = 16
        let contentWidth = pipSize.width - padding * 2
        var y: CGFloat = 20

        // Project name
        let nameFont = UIFont.systemFont(ofSize: 16, weight: .bold)
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: UIColor.white,
        ]
        let nameRect = CGRect(x: padding, y: y, width: contentWidth, height: 22)
        (projectName as NSString).draw(
            with: nameRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: nameAttributes,
            context: nil
        )
        y += 28

        // Elapsed time
        let elapsedFont = UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        let elapsedColor: UIColor = isFinished ? UIColor(white: 1, alpha: 0.5) : UIColor(white: 1, alpha: 0.9)
        let elapsedAttributes: [NSAttributedString.Key: Any] = [
            .font: elapsedFont,
            .foregroundColor: elapsedColor,
        ]
        let elapsedRect = CGRect(x: padding, y: y, width: contentWidth, height: 34)
        (currentElapsedText as NSString).draw(
            with: elapsedRect,
            options: [.usesLineFragmentOrigin],
            attributes: elapsedAttributes,
            context: nil
        )
        y += 38

        // Finished banner
        if let finishedText = finishedStatusText {
            let bannerColor: UIColor = finishedText == String(localized: "pip.status.completed")
                ? UIColor.systemGreen.withAlphaComponent(0.85)
                : UIColor.systemRed.withAlphaComponent(0.85)
            let bannerRect = CGRect(x: padding, y: y, width: contentWidth, height: 30)
            bannerColor.setFill()
            UIBezierPath(roundedRect: bannerRect, cornerRadius: 6).fill()

            let bannerFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let bannerAttributes: [NSAttributedString.Key: Any] = [
                .font: bannerFont,
                .foregroundColor: UIColor.white,
            ]
            let bannerTextSize = (finishedText as NSString).size(withAttributes: bannerAttributes)
            let bannerTextX = padding + (contentWidth - bannerTextSize.width) / 2
            let bannerTextY = y + (30 - bannerTextSize.height) / 2
            (finishedText as NSString).draw(
                at: CGPoint(x: bannerTextX, y: bannerTextY),
                withAttributes: bannerAttributes
            )
            y += 36
        }

        // User action needed banner
        if needsUserAction {
            let actionText = String(localized: "pip.status.needs_action")
            let actionBannerRect = CGRect(x: padding, y: y, width: contentWidth, height: 30)
            UIColor.systemOrange.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: actionBannerRect, cornerRadius: 6).fill()

            let actionFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let actionAttributes: [NSAttributedString.Key: Any] = [
                .font: actionFont,
                .foregroundColor: UIColor.white,
            ]
            let actionTextSize = (actionText as NSString).size(withAttributes: actionAttributes)
            let actionTextX = padding + (contentWidth - actionTextSize.width) / 2
            let actionTextY = y + (30 - actionTextSize.height) / 2
            (actionText as NSString).draw(
                at: CGPoint(x: actionTextX, y: actionTextY),
                withAttributes: actionAttributes
            )
            y += 36
        }

        // Status text (1-2 lines)
        let statusFont = UIFont.systemFont(ofSize: 13, weight: .regular)
        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: UIColor(white: 1, alpha: 0.7),
        ]
        let statusHeight: CGFloat = 36
        let statusRect = CGRect(x: padding, y: y, width: contentWidth, height: statusHeight)
        let statusString = NSAttributedString(string: currentStatusText, attributes: statusAttributes)
        statusString.draw(with: statusRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        y += statusHeight + 8

        // --- Project screenshot "phone preview" in the bottom area ---
        drawPhonePreview(topY: y, padding: padding)
    }

    /// Draws the project screenshot in the bottom portion of the PiP,
    /// showing the top 2/3 of the snapshot with rounded top corners,
    /// like a phone screen peeking up from the bottom edge.
    private func drawPhonePreview(topY: CGFloat, padding: CGFloat) {
        guard let snapshot = projectSnapshot else { return }

        let phoneMargin: CGFloat = 40
        let phoneWidth = pipSize.width - phoneMargin * 2
        let phoneHeight = phoneWidth * 3 / 2 // 3:2 aspect ratio
        guard phoneWidth > 0, phoneHeight > 0 else { return }

        // Bottom-aligned: phone bottom edge = PiP bottom edge
        let phoneY = pipSize.height - phoneHeight
        let phoneRect = CGRect(x: phoneMargin, y: phoneY, width: phoneWidth, height: phoneHeight)
        let cornerRadius: CGFloat = 24

        // Rounded rect with only top corners rounded
        let path = UIBezierPath(
            roundedRect: phoneRect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
        )

        // Scale full image width to fit phoneWidth, draw bottom-aligned
        let imgSize = snapshot.size
        let imgScale = phoneWidth / imgSize.width
        let scaledFullHeight = imgSize.height * imgScale

        UIGraphicsGetCurrentContext()?.saveGState()
        path.addClip()

        // Position image so its top edge aligns with phone top edge
        let drawY = phoneY
        let drawRect = CGRect(x: phoneMargin, y: drawY, width: phoneWidth, height: scaledFullHeight)
        snapshot.draw(in: drawRect)

        UIGraphicsGetCurrentContext()?.restoreGState()

        // Thin border for the phone outline
        let borderPath = UIBezierPath(
            roundedRect: phoneRect.insetBy(dx: 0.5, dy: 0.5),
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
        )
        UIColor(white: 1, alpha: 0.15).setStroke()
        borderPath.lineWidth = 1
        borderPath.stroke()
    }

    private func loadProjectSnapshot(from projectURL: URL) -> UIImage? {
        let previewURL = projectURL.appendingPathComponent("preview.jpg")
        guard let data = try? Data(contentsOf: previewURL) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Timer

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func timerTick() {
        guard let start = taskStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        currentElapsedText = formattedElapsed(elapsed)
        pushFrame()
    }

    private func formattedElapsed(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPProgressManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.isPiPShowing = true
            self?.startAudioPlayer()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPiPShowing = false
            self.stopAudioPlayer()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in
            // Hide the source view so the restore animation doesn't show a black rectangle.
            self?.pipSourceView?.isHidden = true
            completionHandler(true)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPProgressManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
