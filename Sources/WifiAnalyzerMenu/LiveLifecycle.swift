/// Startup results are accepted only for the current generation. Sleep and pause invalidate in-flight discovery.
struct LiveLifecycle {
    private(set) var enabled = true
    private(set) var sleeping = false
    private(set) var quitting = false
    private(set) var generation = 0
    var shouldRun: Bool { enabled && !sleeping && !quitting }
    mutating func pause() { enabled = false; generation += 1 }
    mutating func resume() { enabled = true; generation += 1 }
    mutating func sleep() { sleeping = true; generation += 1 }
    mutating func wake() { sleeping = false; generation += 1 }
    mutating func quit() { quitting = true; enabled = false; generation += 1 }
}
