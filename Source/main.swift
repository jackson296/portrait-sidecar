import Cocoa
import ScreenCaptureKit
import CoreImage
import MetalKit

final class OutputWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
final class FrameView: MTKView, MTKViewDelegate {
    private let frameLock = NSLock()
    private var newest: CVPixelBuffer?
    private var generation = 0
    private var renderedGeneration = -1
    private let gpuQueue: MTLCommandQueue
    private let ci: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let inFlight = DispatchSemaphore(value: 2)
    var clockwise = true { didSet { renderedGeneration = -1 } }
    var metrics: ((String) -> Void)?
    private var lastMetric = CACurrentMediaTime()
    private var draws = 0
    init() {
        let gpu = MTLCreateSystemDefaultDevice()!
        gpuQueue = gpu.makeCommandQueue()!
        ci = CIContext(mtlDevice: gpu, options: [.cacheIntermediates: false])
        super.init(frame: .zero, device: gpu)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        colorspace = colorSpace
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = true
        autoResizeDrawable = false
        delegate = self
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
            metalLayer.displaySyncEnabled = true
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    func submit(_ buffer: CVPixelBuffer) {
        frameLock.lock(); newest = buffer; generation += 1; frameLock.unlock()
    }
    func clear() {
        isPaused = true
        frameLock.lock(); newest = nil; generation += 1; frameLock.unlock()
        renderedGeneration = -1
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { renderedGeneration = -1 }
    func draw(in view: MTKView) {
        frameLock.lock(); let buffer = newest; let current = generation; frameLock.unlock()
        guard let buffer, current != renderedGeneration else { return }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let command = gpuQueue.makeCommandBuffer() else { inFlight.signal(); return }
        let input = CIImage(cvPixelBuffer: buffer)
        let rotated = input.oriented(clockwise ? .right : .left)
        let origin = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let image = origin.transformed(by: CGAffineTransform(scaleX: size.width / origin.extent.width, y: size.height / origin.extent.height))
        ci.render(image, to: drawable.texture, commandBuffer: command, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        command.present(drawable)
        command.addCompletedHandler { [inFlight, buffer] _ in _ = buffer; inFlight.signal() }
        command.commit()
        renderedGeneration = current; draws += 1
        let now = CACurrentMediaTime()
        if now - lastMetric > 2 {
            let fps = Double(draws) / (now - lastMetric)
            metrics?("Capture \(CVPixelBufferGetWidth(buffer)) × \(CVPixelBufferGetHeight(buffer)) → GPU \(Int(size.width)) × \(Int(size.height)); \(Int(fps)) updated fps")
            lastMetric = now; draws = 0
        }
    }
}
final class App: NSObject, NSApplicationDelegate, SCStreamOutput, SCStreamDelegate {
    var window: NSWindow!
    let targets = NSPopUpButton(frame: .zero, pullsDown: false)
    let status = NSTextField(wrappingLabelWithString: "Connect your iPad with Sidecar, then choose it below.")
    let resolutions = NSPopUpButton(frame: .zero, pullsDown: false)
    let scaling = NSPopUpButton(frame: .zero, pullsDown: false)
    let detail = NSTextField(wrappingLabelWithString: "Retina keeps text sharp while workspace size controls how much fits.")
    var presets: [WorkspacePreset] = []
    var applyingMode = false
    var sessionGeneration = 0
    var virtual: CGVirtualDisplay?
    var stream: SCStream?
    var output: NSWindow?
    let view = FrameView()
    var targetID: CGDirectDisplayID = 0
    var screens: [NSScreen] = []
    var starting = false
    var originalTargetOrigin: CGPoint?
    var pointerGuard: Timer?
    var appearanceItems: [NSMenuItem] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); submenu.addItem(withTitle: "Quit Portrait Sidecar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu
        let appearanceItem = NSMenuItem(title: "Appearance",action:nil,keyEquivalent:"")
        let appearanceMenu = NSMenu(title:"Appearance")
        for (index,name) in ["Follow System","Light","Dark"].enumerated() {
            let choice = NSMenuItem(title:name,action:#selector(changeAppearance(_:)),keyEquivalent:"")
            choice.tag = index; choice.target = self; appearanceMenu.addItem(choice); appearanceItems.append(choice)
        }
        appearanceItem.submenu = appearanceMenu; menu.addItem(appearanceItem); NSApp.mainMenu = menu
        applyAppearance(UserDefaults.standard.integer(forKey:"appearanceChoice"))
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 570,height: 620), styleMask: [.titled,.closable,.miniaturizable,.fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Portrait Sidecar"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        let background = NSVisualEffectView()
        background.material = .windowBackground; background.blendingMode = .behindWindow; background.state = .active
        window.contentView = background
        let title = NSTextField(labelWithString: "Portrait Sidecar")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "A taller workspace. A clearer view.")
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle]); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 5
        let symbol = NSImageView()
        symbol.image = NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "png") ?? URL(fileURLWithPath: "/nonexistent")) ?? NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "Portrait Sidecar")
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([symbol.widthAnchor.constraint(equalToConstant: 64), symbol.heightAnchor.constraint(equalToConstant: 64)])
        let header = NSStackView(views: [symbol, heading]); header.spacing = 16
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 11)
        targets.target = self; targets.action = #selector(targetChanged)
        resolutions.target = self; resolutions.action = #selector(modeChanged)
        scaling.addItems(withTitles: ["Retina · 2× (recommended)", "Standard · 1×"])
        scaling.target = self; scaling.action = #selector(modeChanged)
        scaling.selectItem(at: UserDefaults.standard.integer(forKey: "scalingChoice"))
        func row(_ label: String, _ control: NSView) -> NSStackView {
            let text = NSTextField(labelWithString: label); text.font = .systemFont(ofSize: 13, weight: .medium)
            text.translatesAutoresizingMaskIntoConstraints = false; text.widthAnchor.constraint(equalToConstant: 92).isActive = true
            control.translatesAutoresizingMaskIntoConstraints = false
            let result = NSStackView(views: [text,control]); result.spacing = 12
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
            return result
        }
        let form = NSStackView(views: [row("Display", targets), row("Workspace", resolutions), row("Rendering", scaling), detail])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 15
        let card: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(); glass.cornerRadius = 18; glass.style = .regular
            let content = NSView(); glass.contentView = content; card = glass
            content.addSubview(form); form.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([form.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant:20),form.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant:-20),form.topAnchor.constraint(equalTo: content.topAnchor,constant:20),form.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant:-20)])
        } else {
            let effect = NSVisualEffectView(); effect.material = .contentBackground; effect.state = .active; effect.wantsLayer = true; effect.layer?.cornerRadius = 18
            effect.addSubview(form); form.translatesAutoresizingMaskIntoConstraints = false; card = effect
            NSLayoutConstraint.activate([form.leadingAnchor.constraint(equalTo: effect.leadingAnchor,constant:20),form.trailingAnchor.constraint(equalTo: effect.trailingAnchor,constant:-20),form.topAnchor.constraint(equalTo: effect.topAnchor,constant:20),form.bottomAnchor.constraint(equalTo: effect.bottomAnchor,constant:-20)])
        }
        let controls = NSStackView()
        for (name, action) in [("Start", #selector(start)), ("Flip", #selector(flip)), ("Stop", #selector(stop)), ("Refresh", #selector(refresh))] {
            let button = NSButton(title: name, target: self, action: action); button.bezelStyle = .rounded
            if name == "Start" { button.keyEquivalent = "\r" }
            controls.addArrangedSubview(button)
        }
        let note = NSTextField(wrappingLabelWithString: "Stand your iPad upright. Move windows past the right edge of your main display. Choose a workspace size at any time; Flip reverses the image.")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [header,card,controls,status,note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: background.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo: background.trailingAnchor,constant:-28),stack.topAnchor.constraint(equalTo: background.topAnchor,constant:48),card.widthAnchor.constraint(equalTo: stack.widthAnchor),status.widthAnchor.constraint(equalTo: stack.widthAnchor),note.widthAnchor.constraint(equalTo: stack.widthAnchor),stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor,constant:-24)])
        view.metrics = { [weak self] text in
            DispatchQueue.main.async { guard self?.stream != nil else { return }; self?.status.stringValue = "Running · " + text }
        }
        refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func applyAppearance(_ choice: Int) {
        NSApp.appearance = choice == 0 ? nil : NSAppearance(named: choice == 1 ? .aqua : .darkAqua)
        for item in appearanceItems { item.state = item.tag == choice ? .on : .off }
    }
    @objc func changeAppearance(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag,forKey:"appearanceChoice"); applyAppearance(sender.tag)
    }
    func id(_ s: NSScreen) -> CGDirectDisplayID { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value }
    @objc func refresh() {
        guard stream == nil, !starting else { return }
        screens = NSScreen.screens.filter { id($0) != virtual?.displayID }
        targets.removeAllItems(); targets.addItems(withTitles: screens.map { $0.localizedName })
        if let i = screens.firstIndex(where: { ["ipad", "sidecar", "airplay"].contains(where: $0.localizedName.lowercased().contains) }) { targets.selectItem(at: i) }
        targetChanged()
    }
    @objc func targetChanged() {
        guard screens.indices.contains(targets.indexOfSelectedItem) else { return }
        let target = screens[targets.indexOfSelectedItem]
        guard let native = CGDisplayCopyDisplayMode(id(target)) else { return }
        let nativeW = min(native.pixelWidth, native.pixelHeight)
        let nativeH = max(native.pixelWidth, native.pixelHeight)
        presets = WorkspaceOptions.presets(nativeWidth:nativeW,nativeHeight:nativeH)
        resolutions.removeAllItems(); resolutions.addItems(withTitles: presets.map(\.title))
        let saved = UserDefaults.standard.object(forKey: "workspaceChoice") as? Int ?? 1
        resolutions.selectItem(at: min(max(0,saved),presets.count-1)); updateModeDetail()
    }
    func updateModeDetail() {
        guard presets.indices.contains(resolutions.indexOfSelectedItem) else { return }
        let p = presets[resolutions.indexOfSelectedItem]; let scale = scaling.indexOfSelectedItem == 0 ? 2 : 1
        detail.stringValue = "\(p.width) × \(p.height) workspace · \(p.width*scale) × \(p.height*scale) rendered pixels."
    }
    @objc func modeChanged() {
        updateModeDetail()
        UserDefaults.standard.set(resolutions.indexOfSelectedItem,forKey:"workspaceChoice")
        UserDefaults.standard.set(scaling.indexOfSelectedItem,forKey:"scalingChoice")
        guard stream != nil, !applyingMode else { return }
        Task { @MainActor in await applySelectedMode() }
    }
    @MainActor func applySelectedMode() async {
        guard let virtual, let capture = stream, presets.indices.contains(resolutions.indexOfSelectedItem) else { return }
        let token = sessionGeneration
        let p = presets[resolutions.indexOfSelectedItem]; let scale = scaling.indexOfSelectedItem == 0 ? 2 : 1
        applyingMode = true; resolutions.isEnabled = false; scaling.isEnabled = false
        defer { applyingMode = false; resolutions.isEnabled = true; scaling.isEnabled = true }
        let modes = CGDisplayCopyAllDisplayModes(virtual.displayID,[kCGDisplayShowDuplicateLowResolutionModes:true] as CFDictionary) as? [CGDisplayMode] ?? []
        guard let mode = modes.first(where: { $0.width == p.width && $0.height == p.height && $0.pixelWidth == p.width*scale && $0.pixelHeight == p.height*scale }) else { status.stringValue = "That mode is unavailable on this Mac. Try another size."; return }
        guard CGDisplaySetDisplayMode(virtual.displayID,mode,nil) == .success else { status.stringValue = "macOS could not switch that mode."; return }
        let config = captureConfiguration(width: mode.pixelWidth,height: mode.pixelHeight)
        do {
            try await capture.updateConfiguration(config)
            guard sessionGeneration == token else { return }
            arrangeDisplays(sourceWidth: p.width,sourceHeight: p.height)
            positionOutput(); status.stringValue = "Workspace updated. " + detail.stringValue
        } catch { if sessionGeneration == token { status.stringValue = "Could not update capture: " + error.localizedDescription } }
    }
    func captureConfiguration(width: Int,height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration(); config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value:1,timescale:60); config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true; config.capturesAudio = false
        return config
    }
    func arrangeDisplays(sourceWidth: Int,sourceHeight: Int) {
        guard let virtual else { return }
        let main = CGDisplayBounds(CGMainDisplayID()); var layout: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&layout) == .success, let layout {
            CGConfigureDisplayOrigin(layout,virtual.displayID,Int32(main.maxX),Int32(main.minY))
            CGConfigureDisplayOrigin(layout,targetID,Int32(main.maxX)+Int32(sourceWidth),Int32(main.minY)+Int32(sourceHeight)-1)
            CGCompleteDisplayConfiguration(layout,.forAppOnly)
        }
    }
    @objc func start() {
        guard !starting, stream == nil else { return }
        guard screens.indices.contains(targets.indexOfSelectedItem) else { status.stringValue = "No target display found."; return }
        let target = screens[targets.indexOfSelectedItem]
        guard CGDisplayIsBuiltin(id(target)) == 0 else { status.stringValue = "Choose your iPad, not the built-in display."; return }
        guard CGPreflightScreenCaptureAccess() else {
            status.stringValue = "Screen Recording permission is needed. Allow PortraitSidecar in Privacy & Security, then reopen this app."
            CGRequestScreenCaptureAccess(); return
        }
        guard !presets.isEmpty else { return }
        sessionGeneration += 1; let token = sessionGeneration
        starting = true; targets.isEnabled = false; resolutions.isEnabled = false; scaling.isEnabled = false
        targetID = id(target); status.stringValue = "Creating portrait workspace…"
        let selected = presets[resolutions.indexOfSelectedItem]
        let factor = scaling.indexOfSelectedItem == 0 ? 2 : 1
        let w = selected.width * factor; let h = selected.height * factor
        let desc = CGVirtualDisplayDescriptor(); desc.name = "Portrait Workspace"; desc.queue = .main
        desc.maxPixelsWide = UInt32(presets.map { $0.width * 2 }.max()!); desc.maxPixelsHigh = UInt32(presets.map { $0.height * 2 }.max()!)
        desc.sizeInMillimeters = CGSize(width:160,height:160 * Double(selected.height) / Double(selected.width)); desc.vendorID = 0x5053; desc.productID = 2; desc.serialNum = 1024
        virtual = CGVirtualDisplay(descriptor:desc)
        let settings = CGVirtualDisplaySettings(); settings.hiDPI = 1
        var seen = Set<String>()
        settings.modes = presets.flatMap { p in [CGVirtualDisplayMode(width:UInt(p.width*2),height:UInt(p.height*2),refreshRate:60),CGVirtualDisplayMode(width:UInt(p.width),height:UInt(p.height),refreshRate:60)] }.filter { seen.insert("\($0.width)x\($0.height)").inserted }
        guard let v = virtual, v.apply(settings) else { fail("macOS could not create the virtual display."); return }
        Task { @MainActor in
            do {
                guard token == sessionGeneration else { return }
                var selectedMode: CGDisplayMode?
                // Select a mode using both logical and backing dimensions.
                for _ in 0..<15 {
                    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
                    let modes = CGDisplayCopyAllDisplayModes(v.displayID, options) as? [CGDisplayMode] ?? []
                    if let retina = modes.first(where: { $0.width == selected.width && $0.height == selected.height && $0.pixelWidth == w && $0.pixelHeight == h }) {
                        selectedMode = retina
                        guard CGDisplaySetDisplayMode(v.displayID, retina, nil) == .success else { fail("Could not enable Retina mode."); return }
                        break
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard token == sessionGeneration else { return }
                guard selectedMode != nil else { fail("The requested rendering mode is unavailable. Try another workspace size."); return }
                var captureDisplay: SCDisplay?
                for _ in 0..<15 {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    captureDisplay = content.displays.first { $0.displayID == v.displayID }
                    if captureDisplay != nil { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                guard let display = captureDisplay else { fail("The virtual workspace did not become available."); return }
                guard token == sessionGeneration else { return }
                self.originalTargetOrigin = CGDisplayBounds(self.targetID).origin
                arrangeDisplays(sourceWidth:selected.width,sourceHeight:selected.height)
                let config = captureConfiguration(width:w,height:h)
                let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
                try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "portrait.frames"))
                stream = capture
                let panel = OutputWindow(contentRect: target.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.title = "Portrait Sidecar Output"; panel.isReleasedWhenClosed = false; panel.level = .screenSaver; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.ignoresMouseEvents = true; panel.contentView = view; panel.setFrame(NSScreen.screens.first(where: { self.id($0) == self.targetID })?.frame ?? target.frame, display: true); panel.orderFrontRegardless(); output = panel
                positionOutput()
                pointerGuard?.invalidate()
                pointerGuard = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(redirectTargetPointer), userInfo: nil, repeats: true)
                RunLoop.main.add(pointerGuard!, forMode: .common)
                view.isPaused = false; try await capture.startCapture()
                guard token == sessionGeneration else { return }
                starting = false; resolutions.isEnabled = true; scaling.isEnabled = true
                status.stringValue = "Running. Move windows and your pointer to the right of your main screen onto ‘Portrait Workspace’. Flip if the image is upside down."
            } catch { if token == sessionGeneration { fail(error.localizedDescription) } }
        }
    }
    func fail(_ message: String) { stop(); status.stringValue = message }
    @objc func flip() { view.clockwise.toggle() }
    @objc func stop() {
        sessionGeneration += 1
        targets.isEnabled = true; resolutions.isEnabled = true; scaling.isEnabled = true
        pointerGuard?.invalidate(); pointerGuard = nil
        let old = stream; stream = nil; starting = false
        view.clear(); output?.orderOut(nil); output = nil
        if let old { Task { try? await old.stopCapture() } }
        if let origin = originalTargetOrigin {
            var layout: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&layout) == .success, let layout {
                CGConfigureDisplayOrigin(layout, targetID, Int32(origin.x), Int32(origin.y))
                CGCompleteDisplayConfiguration(layout, .forAppOnly)
            }
            originalTargetOrigin = nil
        }
        virtual = nil; status.stringValue = "Stopped. The portrait workspace has been removed."
    }
    // Only the virtual workspace accepts input. The physical Sidecar desktop is a video target.
    // If the pointer enters that target, move it to the corresponding source coordinate.
    @objc func redirectTargetPointer() {
        guard stream != nil, let virtual, let event = CGEvent(source: nil) else { return }
        let target = CGDisplayBounds(targetID)
        let source = CGDisplayBounds(virtual.displayID)
        let point = event.location
        guard target.contains(point), target.width > 0, target.height > 0 else { return }
        let u = min(1, max(0, (point.x - target.minX) / target.width))
        let v = min(1, max(0, (point.y - target.minY) / target.height))
        let x = view.clockwise ? v : 1 - v
        let y = view.clockwise ? 1 - u : u
        let destination = CGPoint(x: source.minX + x * (source.width - 1), y: source.minY + y * (source.height - 1))
        CGWarpMouseCursorPosition(destination)
    }
    func positionOutput() {
        guard let output, let target = NSScreen.screens.first(where: { id($0) == targetID }) else { return }
        output.setFrame(target.frame, display: true)
        view.frame = CGRect(origin: .zero, size: target.frame.size)
        // The drawable must use physical pixels even if the window was created on a 1x screen.
        if let mode = CGDisplayCopyDisplayMode(targetID) {
            view.drawableSize = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        output.orderFrontRegardless()
    }
    @objc func screenChanged() {
        DispatchQueue.main.async { self.positionOutput() }
        if stream != nil && !NSScreen.screens.contains(where: { id($0) == targetID }) { fail("iPad disconnected. Reconnect Sidecar, refresh, and start again.") }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { DispatchQueue.main.async { guard self.stream === stream else { return }; self.fail(error.localizedDescription) } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        view.submit(buffer)
    }
    func applicationWillTerminate(_ notification: Notification) { stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = App(); app.delegate = delegate
app.setActivationPolicy(.regular); app.run()
