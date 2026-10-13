// Appended to TranscriberApp.swift by test-layout.sh so private views remain private.
@main struct LayoutRegressionApp: App {
    @StateObject private var library = LibraryController(
        libraryRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-layout-\(UUID().uuidString)"), resources: nil)

    var body: some Scene {
        WindowGroup("Transcriber · layout regression") {
            LibraryView(library: library)
                .frame(minWidth: 900, minHeight: 620)
                .task { await checkLayout() }
        }.defaultSize(width: 900, height: 620)
    }

    @MainActor private func checkLayout() async {
        // Wait for native split view creation; initial SwiftUI geometry can be correct
        // even when AppKit subsequently expands the split view outside the window.
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }),
              let root = window.contentView else { fatalError("Missing test window") }
        var record = Recording(title: "Проверка интерфейса", sourceName: "source.wav")
        let states: [RecordingState] = [.waitingForMemory, .failed, .interrupted, .processing, .queued]
        var checks = 0
        for size in [NSSize(width: 900, height: 620), NSSize(width: 1080, height: 760)] {
            window.setContentSize(size)
            for state in states {
                record.state = state
                library.recordings = [record]
                library.selected = record.id
                try? await Task.sleep(nanoseconds: 750_000_000)
                root.layoutSubtreeIfNeeded()
                var splits: [NSSplitView] = []
                func collect(_ view: NSView) {
                    if let split = view as? NSSplitView { splits.append(split) }
                    view.subviews.forEach(collect)
                }
                collect(root)
                guard !splits.isEmpty else { fatalError("Missing native split view") }
                for split in splits {
                    let rect = split.convert(split.bounds, to: root)
                    guard root.bounds.insetBy(dx: -1, dy: -1).contains(rect) else {
                        fatalError("\(state): split \(rect) escapes window \(root.bounds)")
                    }
                }
                checks += 1
                print("PASS layout \(state) at \(size)")
            }
        }
        print("Layout regression: \(checks) checks passed")
        await checkNativeSearchHighlights()
        await checkModelsLayout()
        await checkMeetingContextLayout()
        NSApp.terminate(nil)
    }

    @MainActor private func checkMeetingContextLayout() async {
        for oversized in [false, true] {
            let request = MeetingContextRequest(urls: [URL(fileURLWithPath: "/tmp/Планирование релиза.wav")],
                context: oversized ? String(repeating: "я", count: 301) : "Обсуждение релиза. Анна Смирнова, Алексей. TestFlight, onboarding, API.")
            let host = NSHostingView(rootView: MeetingContextView(request: request, confirm: { _ in })
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host; window.orderFront(nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
            host.layoutSubtreeIfNeeded()
            guard host.fittingSize.width <= 561, host.fittingSize.height <= 550 else { fatalError("Context sheet escapes minimum window") }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/layout/context-\(oversized).png"))
            }
            print("PASS meeting context layout oversized=\(oversized)")
            window.close()
        }
    }

    @MainActor private func checkModelsLayout() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let catalog = try ModelCatalog.load(from: URL(fileURLWithPath: "Resources/models.json"))
            let controller = try ModelsController(root: root, catalog: catalog)
            await controller.prepare()
            controller.error = "Недостаточно свободного места для загрузки выбранной модели. Освободите место на диске и повторите попытку."
            let host = NSHostingView(rootView: ModelsView(controller: controller, firstRun: true)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 580, height: 550),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host; window.orderFront(nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
            host.layoutSubtreeIfNeeded()
            guard host.fittingSize.width <= 581, host.fittingSize.height <= 550 else { fatalError("Models sheet escapes minimum window") }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/layout/models.png"))
            }
            print("PASS models first-run layout with long error")
            window.close(); await controller.shutdown()
        } catch { fatalError("Models layout: \(error)") }
    }

    @MainActor private func checkNativeSearchHighlights() async {
        let text = "Проверка, в том числе повторная проверка длинной строки."
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for query in ["числе", "числе повторная проверка", "", "отсутствует"] {
                let content = SearchHighlightedText(text: text, query: query)
                    .font(.system(size: 20)).lineSpacing(5).textSelection(.enabled)
                    .frame(width: 230, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20).background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                window.contentView = host
                window.orderFront(nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    fatalError("Missing native text snapshot")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: "build/layout/search-native-\(dark).png"))
                var yellowPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                           color.redComponent > 0.85, color.greenComponent > 0.65,
                           color.blueComponent < 0.65,
                           color.greenComponent - color.blueComponent > 0.2 { yellowPixels += 1 }
                    }
                }
                let expectsHighlight = !TranscriptSearch.ranges(of: query, in: text).isEmpty
                guard expectsHighlight ? yellowPixels > 100 : yellowPixels == 0 else {
                    fatalError("Native selectable text: query=\(query), dark=\(dark), yellowPixels=\(yellowPixels)")
                }
                print("PASS native search dark=\(dark), query=\(query)")
            }
        }
    }
}
