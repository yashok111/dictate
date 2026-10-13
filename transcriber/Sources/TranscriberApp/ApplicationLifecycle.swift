import AppKit

@MainActor
final class TranscriberApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var library: LibraryController?
    private var finishing = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library else { return .terminateNow }
        guard !finishing else { return .terminateLater }
        finishing = true
        library.shutdown()
        Task {
            await library.models?.shutdown()
            // Keep the app alive until the worker has actually exited.
            for _ in 0..<30 {
                if library.active == nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            library.forceStopWorker()
            sender.reply(toApplicationShouldTerminate: true)
        }
        // URLSession resume-data callbacks must not prevent an ordinary quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak sender] in
            self?.library?.forceStopWorker()
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
