import AVKit
@testable import BugScreenSDK
import SwiftUI
import ViewInspector
import XCTest

@MainActor
final class AttachmentPreviewVideoTests: XCTestCase {
    func testHostedVideoExposesPlaybackControlsWithoutAutoplay() async throws {
        let model = try await mixedAttachments()
        defer { model.cleanupVideos() }
        let host = UIHostingController(rootView: AttachmentPreview(viewModel: model, startIndex: 1, onClose: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let controller = try XCTUnwrap(playerController(in: host), "Playback needs a contained AVPlayerViewController")
        XCTAssertEqual(controller.player?.rate, 0, "Preview must not autoplay")
        let preview = try host.rootView.inspect().find(NativeVideoPreview.self)
        XCTAssertNoThrow(try preview.find(ViewType.Slider.self), "Seek must be available without revealing hidden AVKit chrome")
        XCTAssertNoThrow(try preview.find(ViewType.Button.self, where: {
            try $0.accessibilityLabel().string() == SDKStrings.videoPlay
        }), "Play must be available on opening the paused preview")
    }

    func testLeavingVideoBackgroundingAndClosingPausePlayback() async throws {
        let state = VideoPreviewTestState()
        let host = UIHostingController(rootView: VideoPreviewTestHost(state: state, url: fixture()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        let controller = try XCTUnwrap(playerController(in: host))
        let player = try XCTUnwrap(controller.player)
        try await waitUntil { player.currentItem?.status == .readyToPlay }

        player.playImmediately(atRate: 1)
        state.active = false
        try await waitUntil { player.rate == 0 }
        state.active = true
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(player.rate, 0, "Returning to a video must not resume playback automatically")

        player.playImmediately(atRate: 1)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try await waitUntil { player.rate == 0 }

        player.playImmediately(atRate: 1)
        window.rootViewController = nil
        try await waitUntil { player.rate == 0 }
    }

    func testPlaybackCanPlayPauseSeekAndReplayAfterEnd() async throws {
        let playback = VideoPreviewPlayback(url: fixture())
        try await waitUntil { playback.duration > 0 }
        XCTAssertEqual(playback.player.rate, 0)
        playback.togglePlayback()
        try await waitUntil { playback.isPlaying && playback.player.rate > 0 }
        playback.togglePlayback()
        try await waitUntil { !playback.isPlaying && playback.player.rate == 0 }

        playback.position = playback.duration / 2
        playback.seek()
        try await waitUntil { abs(playback.player.currentTime().seconds - playback.duration / 2) < 0.05 }
        XCTAssertEqual(playback.player.rate, 0, "Seeking a paused video must keep it paused")

        playback.position = playback.duration
        playback.seek()
        try await waitUntil { abs(playback.player.currentTime().seconds - playback.duration) < 0.05 }
        playback.togglePlayback()
        try await waitUntil { playback.player.rate > 0 && playback.player.currentTime().seconds < playback.duration / 2 }
        playback.player.pause()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 40 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Playback did not reach the expected state within two seconds")
    }

    private func playerController(in controller: UIViewController) -> AVPlayerViewController? {
        if let player = controller as? AVPlayerViewController { return player }
        return controller.children.lazy.compactMap { self.playerController(in: $0) }.first
    }

    func testVideoPageKeepsPlayerWhenAdjacentScreenshotIsSelected() async throws {
        let model = try await mixedAttachments()
        defer { model.cleanupVideos() }
        let preview = AttachmentPreview(viewModel: model, startIndex: 0, onClose: {})
        let pages = try preview.inspect().find(ViewType.TabView.self).forEach(0)

        XCTAssertNoThrow(try pages.vStack(1).find(NativeVideoPreview.self),
                         "The incoming page must already be a player while swiping, rather than switching from a poster on release")
    }

    func testMarkupActionBelongsToScreenshotPageRatherThanChangingPagerHeight() async throws {
        let model = try await mixedAttachments()
        defer { model.cleanupVideos() }
        let preview = AttachmentPreview(viewModel: model, startIndex: 0, onClose: {})

        XCTAssertNoThrow(try preview.inspect().find(ViewType.TabView.self).forEach(0).vStack(0).find(button: SDKStrings.markupOpen),
                         "Markup must be within the screenshot page so selecting a video cannot resize the entire pager")
    }

    func testThumbnailSymbolsUseSame18PointContentBox() throws {
        for isVideo in [false, true] {
            let image = UIImage()
            let video = isVideo ? PreparedVideo(file: fixture(), poster: image, durationSeconds: 1) : nil
            let thumb = AttachmentThumb(image: image, attachmentNumber: 1, enabled: true, video: video, onOpen: {})
            let symbol = try thumb.inspect().find(ViewType.Image.self, where: {
                try $0.actualImage().name() == (isVideo ? "play" : "pencil")
            })
            XCTAssertEqual(try symbol.fixedWidth(), 18)
            XCTAssertEqual(try symbol.fixedHeight(), 18)
        }
    }

    private func fixture() -> URL {
        Bundle.module.url(forResource: "valid.mp4", withExtension: nil, subdirectory: "Fixtures")!
    }

    private func mixedAttachments() async throws -> BugReportViewModel {
        let model = BugReportViewModel(onDismiss: {}, submitter: PreviewVideoSubmitter(),
                                       videoAttachmentLimits: VideoAttachmentLimits(maxSizeBytes: 10_000_000, maxDurationSeconds: 60))
        let source = try VideoPreparation.copySelection(fixture())
        await model.addPickedAttachments([.image(UIImage()), .video(source)])
        XCTAssertEqual(model.screenshots.count, 2)
        return model
    }
}

@MainActor
private final class VideoPreviewTestState: ObservableObject {
    @Published var active = true
}

private struct VideoPreviewTestHost: View {
    @ObservedObject var state: VideoPreviewTestState
    let url: URL

    var body: some View {
        NativeVideoPreview(url: url, isActive: state.active)
    }
}

@MainActor
private final class PreviewVideoSubmitter: VideoReportSubmitting {
    func submitBugReport(description _: String, screenshots _: [PreparedScreenshot], type _: String?,
                         severity _: String?) async throws -> ReportReceipt
    {
        ReportReceipt(partialFailures: [])
    }

    func submitVideoBugReport(description _: String, screenshots _: [PreparedScreenshot], videos _: [PreparedVideo],
                              visualOrder _: [ReportMediaOrder], type _: String?, severity _: String?) async throws -> ReportReceipt
    {
        ReportReceipt(partialFailures: [])
    }
}
