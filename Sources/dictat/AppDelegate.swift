import AppKit
import Combine

/// Ties everything together: a menu-bar icon, a global hotkey, and the
/// record → transcribe → paste pipeline. Everything runs locally on-device.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var hotkey: Hotkey?
    private var hotkeyCancellable: AnyCancellable?
    private var uiState: UIState = .loadingModel
    private var lastTranscript = ""

    // Live input meter shown while recording (see MARK: - Level meter).
    private var meterTimer: Timer?
    private var meterHistory: [Float] = []
    private var silentTicks = 0
    private weak var statusMenuItem: NSMenuItem?

    private enum UIState {
        case loadingModel
        case ready
        case recording
        case transcribing
        case error(String)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        render(.loadingModel)

        // Ask for Accessibility up front (needed to paste at the cursor).
        TextInjector.ensureAccessibility(prompt: true)

        // Register the global hotkey and keep it in sync with the user's chosen shortcut.
        // sink() fires immediately with the current value, so this also does the initial bind.
        let hotkey = Hotkey()
        hotkey.onPress = { [weak self] in self?.toggle() }
        self.hotkey = hotkey
        hotkeyCancellable = HotkeyStore.shared.$shortcut.sink { [weak self] shortcut in
            hotkey.apply(shortcut)
            self?.refreshMenu()
        }

        // Load the local model (downloads once, then cached + offline).
        Task {
            await transcriber.loadIfNeeded()
            let state = await transcriber.state
            await MainActor.run {
                switch state {
                case .ready: self.render(.ready)
                case let .failed(message): self.render(.error(message))
                default: break
                }
            }
        }
    }

    // MARK: - Pipeline

    private func toggle() {
        if recorder.isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        Task {
            guard await transcriber.state == .ready else { return }
            do {
                try recorder.start()
                render(.recording)
            } catch {
                render(.error(error.localizedDescription))
            }
        }
    }

    private func stopAndTranscribe() {
        let samples = recorder.stop()
        render(.transcribing)
        Task {
            do {
                let text = try await transcriber.transcribe(samples)
                await MainActor.run {
                    if !text.isEmpty {
                        self.lastTranscript = text
                        TextInjector.insert(text)   // clipboard + auto-paste at cursor
                    }
                    self.render(.ready)
                }
            } catch {
                await MainActor.run { self.render(.error(error.localizedDescription)) }
            }
        }
    }

    // MARK: - Menu bar

    /// Re-render the menu using the last known state (e.g. after the shortcut changes).
    private func refreshMenu() { render(uiState) }

    private func render(_ state: UIState) {
        uiState = state
        let button = statusItem.button
        let shortcut = HotkeyStore.shared.shortcut.display
        let menu = NSMenu()
        menu.autoenablesItems = false   // we manage enabled state ourselves

        // The mascot is the menu-bar icon; state is shown as a short word beside it.
        button?.image = Mascot.menuBar
        button?.imagePosition = .imageLeading

        // Only the recording state animates; everything else is a static word.
        if case .recording = state {} else { stopMeter() }

        switch state {
        case .loadingModel:
            setTitle(" loading…")
            menu.addItem(disabled("Downloading / loading model…"))
        case .ready:
            setTitle("")
            menu.addItem(disabled("Ready — \(shortcut) to dictate"))
        case .recording:
            startMeter()   // draws the title itself, and keeps redrawing it
            let item = disabled(recordingStatusText)
            statusMenuItem = item
            menu.addItem(item)
        case .transcribing:
            setTitle(" transcribing…")
            menu.addItem(disabled("Transcribing…"))
        case let .error(message):
            setTitle(" error")
            menu.addItem(disabled("Error: \(message)"))
        }

        // Pasting at the cursor needs Accessibility. Surface it clearly if it's missing,
        // since CGEvent paste fails silently without it (clipboard copy still works).
        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            let warn = NSMenuItem(
                title: "⚠️ Enable Accessibility to paste…",
                action: #selector(openAccessibilitySettings), keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let toggleItem = NSMenuItem(
            title: recorder.isRecording ? "Stop Dictation" : "Start Dictation",
            action: #selector(menuToggle), keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let copyPreviousItem = NSMenuItem(
            title: "Copy previous", action: #selector(copyPrevious), keyEquivalent: ""
        )
        copyPreviousItem.target = self
        copyPreviousItem.isEnabled = !lastTranscript.isEmpty
        menu.addItem(copyPreviousItem)

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit dictat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Level meter

    // A scrolling bar-graph of recent mic levels, drawn with block characters beside
    // the mascot. A dead input (AirPods gone, lid shut, wrong device selected) shows a
    // flat line instead of a moving waveform, so it's obvious before you stop talking.
    private static let meterBarCount = 8
    private static let meterInterval = 0.08
    private static let meterBlocks = Array("▁▂▃▄▅▆▇█")
    /// Peaks below this are treated as digital silence (a muted device delivers exact zeros).
    private static let silenceThreshold: Float = 0.002
    /// How long the input must stay silent before we call it out in words.
    private static let silenceGrace = 1.5

    private var meterIsSilent: Bool {
        Double(silentTicks) * Self.meterInterval >= Self.silenceGrace
    }

    private var recordingStatusText: String {
        meterIsSilent
            ? "No audio reaching the mic — check your input device"
            : "Recording — \(HotkeyStore.shared.shortcut.display) to stop"
    }

    private func startMeter() {
        guard meterTimer == nil else { return }
        meterHistory = Array(repeating: 0, count: Self.meterBarCount)
        silentTicks = 0
        drawMeter()
        // .common so the meter keeps animating while the menu is open.
        let timer = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            self?.tickMeter()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func tickMeter() {
        guard recorder.isRecording else { stopMeter(); return }
        let level = recorder.level
        let wasSilent = meterIsSilent
        silentTicks = level < Self.silenceThreshold ? silentTicks + 1 : 0
        meterHistory.removeFirst()
        meterHistory.append(level)
        drawMeter()
        // Keep the menu's wording in sync when audio drops out or comes back. Edit the
        // existing item rather than re-rendering, which would close an open menu.
        if meterIsSilent != wasSilent { statusMenuItem?.title = recordingStatusText }
    }

    private func drawMeter() {
        let bars = String(meterHistory.map { Self.meterBlocks[Self.barIndex(for: $0)] })
        let silent = meterIsSilent
        setTitle(" " + bars + (silent ? " no audio" : ""),
                 color: silent ? .systemRed : nil)
    }

    /// Map a linear peak amplitude onto a bar height, on a dB scale so quiet speech
    /// still visibly moves. -55 dB and below is the flat bar; -5 dB and up is full.
    private static func barIndex(for level: Float) -> Int {
        guard level >= silenceThreshold else { return 0 }
        let db = 20 * log10(level)
        let fraction = (Double(db) + 55) / 50
        return min(meterBlocks.count - 1, max(0, Int((fraction * Double(meterBlocks.count - 1)).rounded())))
    }

    /// Titles use a monospaced font so the bars keep a fixed width and don't jitter.
    private func setTitle(_ title: String, color: NSColor? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        ]
        if let color { attributes[.foregroundColor] = color }
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func menuToggle() { toggle() }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func copyPrevious() {
        TextInjector.copyToClipboard(lastTranscript)
    }

    @objc private func openAccessibilitySettings() {
        // Re-trigger the system prompt, then open the Accessibility pane directly.
        TextInjector.ensureAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
