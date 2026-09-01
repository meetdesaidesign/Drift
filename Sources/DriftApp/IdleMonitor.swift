import AppKit
import CoreGraphics

/// Polls how long the Mac has been idle, for the optional full-screen-on-idle behaviour.
///
/// Uses `CGEventSource.secondsSinceLastEventType`, which needs no Accessibility
/// permission and no event tap — Drift never observes *what* you type, only how long ago
/// you last did anything.
@MainActor
final class IdleMonitor {

    private var poller: Task<Void, Never>?
    private static let pollInterval: TimeInterval = 2

    /// Called once each time the Mac crosses from active into idle.
    var onIdle: (() -> Void)?
    /// Called once each time activity resumes after having been idle.
    var onActive: (() -> Void)?

    private var wasIdle = false

    static func systemIdleSeconds() -> TimeInterval {
        // kCGAnyInputEventType — any keyboard, mouse or trackpad event.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    func start(threshold: TimeInterval) {
        stop()
        wasIdle = false
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(IdleMonitor.pollInterval))
                if Task.isCancelled { return }
                guard let self else { return }
                let idle = IdleMonitor.systemIdleSeconds()
                if idle >= threshold, !self.wasIdle {
                    self.wasIdle = true
                    self.onIdle?()
                } else if idle < threshold, self.wasIdle {
                    self.wasIdle = false
                    self.onActive?()
                }
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    deinit { poller?.cancel() }
}
