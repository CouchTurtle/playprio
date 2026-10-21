import Foundation
import os

/// Decides which target a media key goes to, following the priority list.
///
/// Play/Pause:
///   1. Something in the list playing → pause it. Else other sound PlayPrio can pause
///      (an app, a browser tab, a Quick Look preview via macOS) → pause that instead of
///      playing over it.
///   2. Otherwise resume what PlayPrio paused last (if it's still there), else the first
///      paused source that may auto-resume (music players), else an idle one.
///   3. Nothing open → open the first closed music source (YouTube Music).
/// Next/Previous go to the playing source that can skip, else the best open one.
///
/// Not thread-safe: call it from one queue only (the queue passed to `init`).
final class Router {
    typealias Snapshot = [(target: MediaTarget, status: SourceStatus)]

    private static let log = Logger(subsystem: "local.PlayPrio", category: "Router")
    /// A press that waited longer than this behind a slow script is dropped: acting on it
    /// late (or twice) is worse than doing nothing.
    private static let staleAfter: TimeInterval = 1.5

    /// Set when a target couldn't be queried or controlled.
    private(set) var problem: ScriptError?
    /// Human-readable summary of the last action.
    private(set) var lastAction: String?

    private let queue: DispatchQueue
    /// Sound outside the list; it must be paused too, not played over.
    let otherAudio = OtherAudio()
    private var lastPaused: (id: String, at: Date)?
    /// Bumped by every press, so a pending "play once loaded" gives way to newer intent.
    private var generation = 0

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    // MARK: Media keys

    func handle(_ key: MediaKey, pressedAt: Date = Date()) {
        generation += 1
        guard Date().timeIntervalSince(pressedAt) < Self.staleAfter else {
            lastAction = "dropped a late \(key.rawValue)"
            return
        }
        let started = Date()
        let snapshot = takeSnapshot()
        let action: String
        switch key {
        case .playPause: action = playPause(snapshot)
        case .next: action = skip(snapshot, forward: true)
        case .previous: action = skip(snapshot, forward: false)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        lastAction = "\(action) · \(ms) ms"
        Self.log.info("\(key.rawValue, privacy: .public): \(action, privacy: .public) in \(ms) ms")
    }

    /// Status of every active target, in priority order. A target that errors is left out
    /// (and reported via `problem`) instead of blocking the others.
    func takeSnapshot() -> Snapshot {
        var result: Snapshot = []
        var firstProblem: ScriptError?
        for target in Settings.activeTargets {
            do {
                result.append((target, try target.status()))
            } catch {
                firstProblem = firstProblem ?? (error as? ScriptError ?? .failed("\(error)"))
                Self.log.error("\(target.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        problem = firstProblem
        return result
    }

    /// The list source Play/Pause would control right now (the panel's large card).
    func keyTargetID(_ snapshot: Snapshot) -> String? {
        if let playing = snapshot.first(where: { $0.status.state == .playing }) { return playing.target.id }
        return (resumeCandidate(snapshot) ?? launchCandidate(snapshot))?.id
    }

    private func playPause(_ snapshot: Snapshot) -> String {
        let playing = snapshot.filter { $0.status.state == .playing }.map(\.target)
        if !playing.isEmpty {
            for target in playing { attempt { try target.pause() } }
            lastPaused = (playing[0].id, Date())
            return "⏸ " + playing.map(\.displayName).joined(separator: ", ")
        }
        // Only scanned when the list is quiet: it can take a moment (browser tabs).
        let others = otherAudio.scan(discovery: .now).filter { $0.status.state == .playing && $0.keyPausesIt }
        let controlled = others.compactMap(\.target)
        if !controlled.isEmpty {
            for target in controlled { attempt { try target.pause() } }
            return "⏸ " + controlled.map(\.displayName).joined(separator: ", ")
        }
        // Only something PlayPrio can't control is playing (e.g. a Finder preview): let
        // macOS pause it, it's the system's newest Now Playing app.
        if let other = others.first(where: \.viaSystem) {
            otherAudio.toggleViaSystem(pid: other.pid, wasPlaying: true)
            return "⏸ \(other.app.localizedName ?? "app") (via macOS)"
        }
        if let target = resumeCandidate(snapshot) {
            attempt { try target.play() }
            return "▶︎ " + target.displayName
        }
        if let target = launchCandidate(snapshot), target.launch() {
            playWhenLoaded(target)
            return "opening " + target.displayName
        }
        return "nothing to play"
    }

    private func resumeCandidate(_ snapshot: Snapshot) -> MediaTarget? {
        let recentlyPaused = lastPaused.flatMap { last in
            Date().timeIntervalSince(last.at) < 3 * 3600
                ? snapshot.first { $0.target.id == last.id && $0.status.state == .paused }?.target : nil
        }
        let resumable = snapshot.filter { $0.target.autoResume }
        return recentlyPaused
            ?? resumable.first(where: { $0.status.state == .paused })?.target
            ?? resumable.first(where: { $0.status.state == .idle })?.target
    }

    /// The first closed music source, when "Play opens YouTube Music" is on. Never a
    /// pause-only app, and never anything while a source errored (it may well be open).
    private func launchCandidate(_ snapshot: Snapshot) -> MediaTarget? {
        guard problem == nil, Settings.launchIfAbsent else { return nil }
        return snapshot.first { $0.status.state == .absent && $0.target.canLaunch && $0.target.autoResume }?.target
    }

    private func skip(_ snapshot: Snapshot, forward: Bool) -> String {
        let open = snapshot.filter { $0.status.state != .absent && $0.target.canSkip }
        guard let best = open.min(by: { $0.status.state.rank < $1.status.state.rank }) else { return "nothing to skip" }
        attempt { forward ? try best.target.next() : try best.target.previous() }
        return (forward ? "⏭ " : "⏮ ") + best.target.displayName
    }

    // MARK: Headphones gone

    /// Pauses everything playing that PlayPrio controls, in the list or not, and never starts
    /// anything. macOS sometimes pauses on its own when AirPods leave, so only pauses that
    /// leave paused media paused are used: no "Play/Pause" menu items, nothing via macOS.
    func pauseAllPlaying() {
        generation += 1 // a pending "play once loaded" mustn't start it again
        let listed = pauseUnlessToggle(takeSnapshot().filter { $0.status.state == .playing }.map(\.target))
        if let first = listed.first { lastPaused = (first.id, Date()) } // Play resumes it later
        // Scanned after the list is paused: finding browser tabs can take a moment.
        let others = pauseUnlessToggle(otherAudio.scan(discovery: .now)
            .filter { $0.status.state == .playing }.compactMap(\.target))
        let paused = (listed + others).map(\.displayName)
        lastAction = paused.isEmpty ? "headphones gone, nothing to pause"
            : "⏸ \(paused.joined(separator: ", ")) (headphones gone)"
        Self.log.info("\(self.lastAction ?? "", privacy: .public)")
    }

    private func pauseUnlessToggle(_ targets: [MediaTarget]) -> [MediaTarget] {
        let safe = targets.filter { !$0.pauseIsToggle }
        for target in safe { attempt { try target.pause() } }
        return safe
    }

    // MARK: Panel buttons (one specific target)

    /// A source in the list, any app, or a media tab found by `otherAudio`.
    func target(id: String) -> MediaTarget? {
        Targets.target(id: id) ?? otherAudio.target(id: id)
    }

    func toggle(_ target: MediaTarget) {
        generation += 1
        problem = nil
        attempt {
            switch try target.status().state {
            case .playing:
                try target.pause()
                lastPaused = (target.id, Date())
                lastAction = "⏸ " + target.displayName
            case .paused, .idle:
                try target.play()
                lastAction = "▶︎ " + target.displayName
            case .absent:
                if target.launch() {
                    playWhenLoaded(target)
                    lastAction = "opening " + target.displayName
                }
            }
        }
    }

    func skip(_ target: MediaTarget, forward: Bool) {
        problem = nil
        attempt {
            _ = try target.status() // picks the tab to act on
            forward ? try target.next() : try target.previous()
        }
        lastAction = (forward ? "⏭ " : "⏮ ") + target.displayName
    }

    func focus(_ target: MediaTarget) {
        problem = nil
        attempt { try target.focus() }
    }

    // MARK: Helpers

    /// After launching, press play once something is loaded. A fresh YouTube Music has an
    /// empty queue (state idle); then there's nothing to play and polling just times out.
    private func playWhenLoaded(_ target: MediaTarget) {
        let started = generation
        let deadline = Date().addingTimeInterval(20)
        func poll() {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.generation == started else { return }
                let state = (try? target.status().state) ?? .absent
                if state == .paused { self.attempt { try target.play() } }
                if state == .paused || state == .playing || Date() > deadline { return }
                poll()
            }
        }
        poll()
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch {
            problem = error as? ScriptError ?? .failed("\(error)")
            Self.log.error("\(String(describing: error), privacy: .public)")
        }
    }
}
