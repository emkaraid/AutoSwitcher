//
//  PauseManager.swift
//  AutoSwitcher
//
//  Temporary pause: "give me 30 minutes without corrections" without
//  flipping the persistent engineEnabled toggle. `.distantFuture` encodes
//  "paused until the app restarts" (nothing is persisted, so a relaunch
//  naturally resumes).
//

import Foundation
import Combine

final class PauseManager: ObservableObject {

    static let shared = PauseManager()

    @Published private(set) var pausedUntil: Date?

    private var resumeTimer: Timer?

    private init() {}

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > Date()
    }

    var isPausedUntilRestart: Bool {
        pausedUntil == .distantFuture
    }

    func pause(for interval: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(interval)
        Diag.log("engine paused for \(Int(interval))s")
        scheduleAutoResume()
    }

    func pauseUntilRestart() {
        pausedUntil = .distantFuture
        resumeTimer?.invalidate()
        Diag.log("engine paused until restart")
    }

    func resume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        pausedUntil = nil
        Diag.log("engine resumed by user")
    }

    private func scheduleAutoResume() {
        resumeTimer?.invalidate()
        guard let until = pausedUntil, until != .distantFuture else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            Diag.log("pause elapsed — auto-resuming")
            self?.pausedUntil = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }
}
