import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SceneKit
import ScreenCaptureKit

private enum CaptureMode: String {
    case systemAudio = "System Audio"
    case microphone = "Microphone"
    case simulated = "Simulated"
}

private enum BackgroundMode: String {
    case full = "Full"
    case overlay = "Overlay"
}

private struct Ripple {
    var position: CGPoint
    var age: CGFloat = 0
    var lifespan: CGFloat = 1.2
}

private struct Star {
    var position: CGPoint
    var velocity: CGVector
    var size: CGFloat
    var brightness: CGFloat
    var depth: CGFloat
    var twinkleOffset: CGFloat
    var hueOffset: CGFloat
}

private final class VisualizerView: NSView {
    private var displayTimer: Timer?
    private var phase: CGFloat = 0
    private var audioLevel: CGFloat = 0
    private var energy: CGFloat = 0
    private var smoothedAudio: CGFloat = 0
    private var beatPulse: CGFloat = 0
    private var colorShift: CGFloat = 0
    private var backgroundOpacity: CGFloat = 1
    private var ripples: [Ripple] = []
    private var stars: [Star] = []
    private var starFieldSize: CGSize = .zero
    private var waveformHistory: [CGFloat] = Array(repeating: 0.06, count: 220)
    private var modelView: SCNView?
    private var rotatingModelNode: SCNNode?
    private var modelJumpOffset: CGFloat = 0
    private var modelJumpVelocity: CGFloat = 0
    private var modelDepthPhase: CGFloat = 0
    private var tickerScroll: CGFloat = 0
    private let modelBaseY: CGFloat = 0.56
    private let modelBaseZ: CGFloat = -1.18
    private let modelDepthDrift: CGFloat = 0.18
    private let glyphTickerFont = NSFont.monospacedSystemFont(ofSize: 42, weight: .bold)
    private let glyphTickerLineHeight: CGFloat = 47
    private let glyphTickerAdvance: CGFloat = 25.0
    private let greekTickerAlphabet: [Character] = Array("ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ")
    private lazy var greekTickerLoopLines: [String] = makeGreekTickerLoopLines(count: 140, length: 96)
    private let creditFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let clockFont: NSFont = {
        let size: CGFloat = 72
        let preferredFonts = [
            "DBLCDTempBlack",
            "Digital-7 Mono",
            "DS-Digital",
            "Eurostile-Bold",
            "Menlo-Bold"
        ]
        for name in preferredFonts {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .black)
    }()
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        setupModelView()
        startRenderingLoop()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        layoutModelView()
    }

    func setAudioLevel(_ level: CGFloat) {
        audioLevel = max(0, min(1, level))

        let previousSmoothed = smoothedAudio
        smoothedAudio = (smoothedAudio * 0.82) + (audioLevel * 0.18)
        let transient = max(0, audioLevel - previousSmoothed)
        let trigger = max(0, transient - 0.035) * 8.0
        beatPulse = max(beatPulse * 0.84, min(1, trigger))

        energy = max(smoothedAudio, max(beatPulse * 0.95, energy * 0.90))
    }

    func registerClick(at point: CGPoint) {
        ripples.append(Ripple(position: point))
        energy = min(1, energy + 0.35)
    }

    func setBackgroundOpacity(_ opacity: CGFloat) {
        backgroundOpacity = max(0, min(1, opacity))
        needsDisplay = true
    }

    private func setupModelView() {
        let scnView = SCNView(frame: .zero)
        scnView.wantsLayer = true
        scnView.layer?.backgroundColor = NSColor.clear.cgColor
        scnView.backgroundColor = .clear
        scnView.antialiasingMode = .multisampling4X
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        scnView.rendersContinuously = true
        scnView.isPlaying = true

        let scene = SCNScene()
        configureCameraAndLights(for: scene)
        if let modelNode = loadVaporwaveModelNode() {
            rotatingModelNode = modelNode
            scene.rootNode.addChildNode(modelNode)
            applyModelAnimation(to: modelNode)
        } else {
            NSLog("Could not load marble_youth.glb; model view will be empty.")
        }

        scnView.scene = scene
        addSubview(scnView)
        modelView = scnView
        layoutModelView()
    }

    private func layoutModelView() {
        guard let modelView else {
            return
        }

        let rect = bounds
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let width = rect.width * 0.37
        let height = rect.height
        let x = rect.maxX - width - (rect.width * 0.02)
        let y = rect.minY
        modelView.frame = CGRect(x: x, y: y, width: width, height: height)
        updateModelWaveformOcclusionMask()
    }

    private func updateModelWaveformOcclusionMask() {
        guard let modelView, let layer = modelView.layer else { return }
        let mask = CAGradientLayer()
        mask.frame = modelView.bounds
        mask.startPoint = CGPoint(x: 0.5, y: 0.0)
        mask.endPoint = CGPoint(x: 0.5, y: 1.0)
        mask.colors = [
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.15).cgColor,
            NSColor.clear.cgColor
        ]
        mask.locations = [0.0, 0.74, 0.88, 1.0]
        layer.mask = mask
    }

    private func configureCameraAndLights(for scene: SCNScene) {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 40
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 200
        cameraNode.position = SCNVector3(0, 0.15, 7.2)
        scene.rootNode.addChildNode(cameraNode)

        let ambientLightNode = SCNNode()
        ambientLightNode.light = SCNLight()
        ambientLightNode.light?.type = .ambient
        ambientLightNode.light?.color = NSColor(calibratedRed: 0.35, green: 0.24, blue: 0.55, alpha: 1)
        scene.rootNode.addChildNode(ambientLightNode)

        let cyanKeyLight = SCNNode()
        cyanKeyLight.light = SCNLight()
        cyanKeyLight.light?.type = .omni
        cyanKeyLight.light?.color = NSColor(calibratedRed: 0.18, green: 0.95, blue: 1.0, alpha: 1)
        cyanKeyLight.position = SCNVector3(3.8, 2.4, 5.8)
        scene.rootNode.addChildNode(cyanKeyLight)

        let pinkFillLight = SCNNode()
        pinkFillLight.light = SCNLight()
        pinkFillLight.light?.type = .omni
        pinkFillLight.light?.color = NSColor(calibratedRed: 1.0, green: 0.28, blue: 0.78, alpha: 1)
        pinkFillLight.position = SCNVector3(-4.2, 1.7, 4.6)
        scene.rootNode.addChildNode(pinkFillLight)
    }

    private func loadVaporwaveModelNode() -> SCNNode? {
        let preferredModelFiles = [
            "marble_youth.usda",
            "marble_youth.usdz",
            "marble_youth.usdc",
            "marble_youth.usd",
            "marble_youth.dae",
            "marble_youth.obj",
            "marble_youth.glb",
            "marble_youth.gltf"
        ]

        guard let modelURL = locateModelAsset(preferredNames: preferredModelFiles) else {
            return nil
        }

        guard let modelScene = loadModelScene(from: modelURL) else {
            NSLog("Model found at \(modelURL.path), but SceneKit could not parse it.")
            return nil
        }
        NSLog("Loaded vaporwave model from \(modelURL.path)")

        let container = SCNNode()
        if modelScene.rootNode.childNodes.isEmpty, modelScene.rootNode.geometry != nil {
            container.addChildNode(modelScene.rootNode.clone())
        } else {
            for child in modelScene.rootNode.childNodes {
                container.addChildNode(child)
            }
        }

        let (minBox, maxBox) = container.boundingBox
        let size = SCNVector3(maxBox.x - minBox.x, maxBox.y - minBox.y, maxBox.z - minBox.z)
        let maxDimension = max(size.x, max(size.y, size.z))
        if maxDimension > 0 {
            let targetSize: CGFloat = 4.35
            let scale = targetSize / maxDimension
            container.scale = SCNVector3(scale, scale, scale)
            let centerX = (minBox.x + maxBox.x) * 0.5
            let centerY = (minBox.y + maxBox.y) * 0.5
            let centerZ = (minBox.z + maxBox.z) * 0.5
            container.pivot = SCNMatrix4MakeTranslation(centerX, centerY, centerZ)
        }

        container.position = SCNVector3(0, modelBaseY, modelBaseZ)
        return container
    }

    private func loadModelScene(from url: URL) -> SCNScene? {
        if let sceneSource = SCNSceneSource(url: url, options: nil),
           let sceneFromSource = sceneSource.scene(options: nil) {
            return sceneFromSource
        }
        return nil
    }

    private func locateModelAsset(preferredNames fileNames: [String]) -> URL? {
        let fileManager = FileManager.default
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        var executableDirectory: URL?
        if let executablePath = CommandLine.arguments.first {
            executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        }

        var attemptedPaths: [String] = []

        for fileName in fileNames {
            let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            let ext = URL(fileURLWithPath: fileName).pathExtension
            var candidatesForFile: [URL] = []

            #if SWIFT_PACKAGE
            if let moduleURL = Bundle.module.url(forResource: baseName, withExtension: ext.isEmpty ? nil : ext) {
                candidatesForFile.append(moduleURL)
            }
            #endif

            if let bundledURL = Bundle.main.url(forResource: baseName, withExtension: ext.isEmpty ? nil : ext) {
                candidatesForFile.append(bundledURL)
            }

            candidatesForFile.append(workingDirectory.appendingPathComponent(fileName))
            candidatesForFile.append(workingDirectory.appendingPathComponent("Sources/MusicalWallpaper/Resources/\(fileName)"))

            if let executableDirectory {
                candidatesForFile.append(executableDirectory.appendingPathComponent(fileName))
                candidatesForFile.append(executableDirectory.deletingLastPathComponent().appendingPathComponent(fileName))
                candidatesForFile.append(executableDirectory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(fileName))
            }

            for candidate in candidatesForFile {
                attemptedPaths.append(candidate.path)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        NSLog("Model asset not found. Tried: \(attemptedPaths.joined(separator: ", "))")
        return nil
    }

    private func applyModelAnimation(to node: SCNNode) {
        let slowSpin = SCNAction.repeatForever(
            SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 58)
        )
        node.runAction(slowSpin, forKey: "slow-spin")
    }

    private func startRenderingLoop() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(displayTimer!, forMode: .common)
    }

    private func tick() {
        configureStarFieldIfNeeded()

        phase += 0.035 + (audioLevel * 0.16) + (beatPulse * 0.09)
        tickerScroll += 0.09
        let scrollCycle = CGFloat(max(1, greekTickerLoopLines.count)) * glyphTickerLineHeight
        let cycleWrap = max(1, scrollCycle * 1_000)
        if tickerScroll > cycleWrap {
            tickerScroll -= cycleWrap
        }
        colorShift += 0.0010 + (audioLevel * 0.0005)
        if colorShift > 1 {
            colorShift -= 1
        }
        energy *= 0.972
        beatPulse *= 0.90

        let waveformSample = min(1, max(0.02, (audioLevel * 0.74) + (energy * 0.22) + (beatPulse * 0.55)))
        waveformHistory.append(waveformSample)
        if waveformHistory.count > 260 {
            waveformHistory.removeFirst(waveformHistory.count - 260)
        }

        for index in ripples.indices {
            ripples[index].age += 1.0 / 60.0
        }
        ripples.removeAll { $0.age > $0.lifespan }

        updateStars()
        updateModelMotion()

        needsDisplay = true
    }

    private func updateModelMotion() {
        guard let rotatingModelNode else {
            return
        }

        // Add a subtle beat bounce when the track gets punchy.
        let jumpTrigger = max(0, beatPulse - 0.20)
        if jumpTrigger > 0 {
            modelJumpVelocity += jumpTrigger * 0.070
        }

        modelJumpVelocity -= 0.006
        modelJumpVelocity *= 0.89
        modelJumpOffset += modelJumpVelocity
        modelJumpOffset = min(modelJumpOffset, 0.28)

        if modelJumpOffset < 0 {
            modelJumpOffset = 0
            modelJumpVelocity = 0
        }

        let hover = sin(phase * 0.50) * 0.05
        rotatingModelNode.position.y = modelBaseY + hover + modelJumpOffset

        modelDepthPhase += 0.010
        let depthBreath = sin(modelDepthPhase) * modelDepthDrift
        rotatingModelNode.position.z = modelBaseZ + depthBreath
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        drawBackground(in: context)
        drawStarfield(in: context)
        drawVaporwaveGrid(in: context)
        drawCenterPulse(in: context)
        drawWireframeGlobes(in: context)
        drawBottomWaveform(in: context)
        drawSystemClock(in: context)
        drawLeftGlyphTicker(in: context)
        drawRipples(in: context)
        drawSubtleCredit(in: context)
    }

    private func configureStarFieldIfNeeded() {
        let currentSize = bounds.size
        guard currentSize.width > 0, currentSize.height > 0 else {
            return
        }

        let sizeChanged = abs(currentSize.width - starFieldSize.width) > 1 || abs(currentSize.height - starFieldSize.height) > 1
        guard stars.isEmpty || sizeChanged else {
            return
        }

        starFieldSize = currentSize
        let area = currentSize.width * currentSize.height
        let starCount = max(95, min(210, Int(area / 18_000)))
        stars = (0..<starCount).map { _ in
            makeStar(in: bounds, nearCenter: false)
        }
    }

    private func makeStar(in rect: CGRect, nearCenter: Bool) -> Star {
        let center = CGPoint(x: rect.midX, y: rect.midY + (rect.height * 0.03))
        let angle = CGFloat.random(in: 0..<(2 * .pi))
        let spread: CGFloat = nearCenter
            ? CGFloat.random(in: 8...(min(rect.width, rect.height) * 0.22))
            : CGFloat.random(in: 0...(max(rect.width, rect.height) * 0.5))

        let depth = CGFloat.random(in: 0.45...1.0)
        let direction = angle + CGFloat.random(in: -0.25...0.25)
        let speed = CGFloat.random(in: 35...120) * (0.45 + (depth * 1.25))

        return Star(
            position: CGPoint(
                x: center.x + (cos(angle) * spread),
                y: center.y + (sin(angle) * spread)
            ),
            velocity: CGVector(
                dx: cos(direction) * speed,
                dy: sin(direction) * speed
            ),
            size: CGFloat.random(in: 0.8...2.2),
            brightness: CGFloat.random(in: 0.5...1.0),
            depth: depth,
            twinkleOffset: CGFloat.random(in: 0..<(2 * .pi)),
            hueOffset: CGFloat.random(in: 0..<1)
        )
    }

    private func updateStars() {
        guard !stars.isEmpty else {
            return
        }

        let rect = bounds
        let center = CGPoint(x: rect.midX, y: rect.midY + (rect.height * 0.03))
        let zoomMultiplier = 1.0 + (audioLevel * 2.3) + (beatPulse * 5.6)
        let beatPush = 3 + (beatPulse * 34)
        let dt: CGFloat = 1.0 / 60.0
        let margin = max(rect.width, rect.height) * 0.18

        for index in stars.indices {
            var star = stars[index]
            let drift = sin((phase * 0.9) + star.twinkleOffset) * (6 + (star.depth * 13))

            star.position.x += (star.velocity.dx * zoomMultiplier * dt) + (cos(star.twinkleOffset + phase) * drift * dt)
            star.position.y += (star.velocity.dy * zoomMultiplier * dt) + (sin(star.twinkleOffset + phase * 1.2) * drift * dt)

            let outwardX = star.position.x - center.x
            let outwardY = star.position.y - center.y
            let outwardLength = max(1, hypot(outwardX, outwardY))
            star.position.x += (outwardX / outwardLength) * beatPush * dt
            star.position.y += (outwardY / outwardLength) * beatPush * dt

            if star.position.x < rect.minX - margin ||
                star.position.x > rect.maxX + margin ||
                star.position.y < rect.minY - margin ||
                star.position.y > rect.maxY + margin {
                star = makeStar(in: rect, nearCenter: true)
            }
            stars[index] = star
        }
    }

    private func neonColor(
        offset: CGFloat,
        saturation: CGFloat = 0.90,
        brightness: CGFloat = 1.0,
        alpha: CGFloat = 1.0
    ) -> NSColor {
        var hue = colorShift + offset + (beatPulse * 0.03)
        hue = hue.truncatingRemainder(dividingBy: 1)
        if hue < 0 {
            hue += 1
        }
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }

    private func drawBackground(in context: CGContext) {
        let rect = bounds
        let top = neonColor(
            offset: 0.66,
            saturation: 0.70,
            brightness: 0.16 + (energy * 0.12),
            alpha: backgroundOpacity
        )
        let middle = neonColor(
            offset: 0.86,
            saturation: 0.76,
            brightness: 0.11 + (audioLevel * 0.08),
            alpha: backgroundOpacity
        )
        let bottom = neonColor(
            offset: 0.48,
            saturation: 0.78,
            brightness: 0.05 + (beatPulse * 0.04),
            alpha: backgroundOpacity
        )

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [top.cgColor, middle.cgColor, bottom.cgColor] as CFArray,
            locations: [0, 0.54, 1]
        ) else {
            context.setFillColor(bottom.cgColor)
            context.fill(rect)
            return
        }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: []
        )

        context.setBlendMode(.screen)
        let glowRadius = max(rect.width, rect.height) * (0.45 + (beatPulse * 0.12))
        context.setFillColor(
            neonColor(
                offset: 0.76,
                saturation: 0.88,
                brightness: 1.0,
                alpha: (0.05 + (energy * 0.08) + (beatPulse * 0.06)) * backgroundOpacity
            ).cgColor
        )
        context.fillEllipse(in: CGRect(
            x: rect.midX - glowRadius / 2,
            y: rect.midY - glowRadius / 2,
            width: glowRadius,
            height: glowRadius
        ))

        let upperGlowRadius = max(rect.width, rect.height) * 0.28
        context.setFillColor(
            neonColor(
                offset: 0.22,
                saturation: 0.85,
                brightness: 1.0,
                alpha: (0.05 + (beatPulse * 0.08)) * backgroundOpacity
            ).cgColor
        )
        context.fillEllipse(in: CGRect(
            x: rect.midX - upperGlowRadius / 2,
            y: rect.minY + (rect.height * 0.62) - upperGlowRadius / 2,
            width: upperGlowRadius,
            height: upperGlowRadius
        ))

        let sideGlowRadius = max(rect.width, rect.height) * 0.22
        context.setFillColor(
            neonColor(
                offset: 0.02,
                saturation: 0.86,
                brightness: 1.0,
                alpha: (0.05 + (audioLevel * 0.07)) * backgroundOpacity
            ).cgColor
        )
        context.fillEllipse(in: CGRect(
            x: rect.midX + (rect.width * 0.22) - sideGlowRadius / 2,
            y: rect.minY + (rect.height * 0.56) - sideGlowRadius / 2,
            width: sideGlowRadius,
            height: sideGlowRadius
        ))

        let sunCenter = CGPoint(x: rect.midX, y: rect.minY + (rect.height * 0.72))
        let sunRadius = min(rect.width, rect.height) * 0.13
        let sunRect = CGRect(
            x: sunCenter.x - sunRadius,
            y: sunCenter.y - sunRadius,
            width: sunRadius * 2,
            height: sunRadius * 2
        )

        context.setFillColor(
            neonColor(
                offset: 0.04,
                saturation: 0.84,
                brightness: 1.0,
                alpha: (0.22 + (energy * 0.14) + (beatPulse * 0.18)) * backgroundOpacity
            ).cgColor
        )
        context.fillEllipse(in: sunRect)

        context.saveGState()
        context.addEllipse(in: sunRect)
        context.clip()
        context.setStrokeColor(
            neonColor(
                offset: 0.62,
                saturation: 0.60,
                brightness: 0.34,
                alpha: 0.58 * backgroundOpacity
            ).cgColor
        )
        context.setLineWidth(2.2)
        for i in 0..<6 {
            let y = sunRect.minY + (CGFloat(i) * sunRect.height / 8.0)
            context.move(to: CGPoint(x: sunRect.minX, y: y))
            context.addLine(to: CGPoint(x: sunRect.maxX, y: y))
            context.strokePath()
        }
        context.restoreGState()
        context.setBlendMode(.normal)
    }

    private func drawStarfield(in context: CGContext) {
        guard !stars.isEmpty else {
            return
        }

        let pulse = 0.55 + (audioLevel * 0.70) + (beatPulse * 1.30)

        context.saveGState()
        context.setBlendMode(.screen)

        for star in stars {
            let velocityMagnitude = max(1, hypot(star.velocity.dx, star.velocity.dy))
            let direction = CGPoint(x: star.velocity.dx / velocityMagnitude, y: star.velocity.dy / velocityMagnitude)
            let twinkle = 0.56 + (0.44 * sin((phase * (2.6 + star.depth)) + star.twinkleOffset))
            let glowIntensity = (0.55 + pulse) * twinkle * star.depth

            let coreSize = star.size * (0.88 + (glowIntensity * 0.45))
            let trailLength = 3 + (star.depth * 12) + (audioLevel * 10) + (beatPulse * 28)
            let trailStart = CGPoint(
                x: star.position.x - (direction.x * trailLength),
                y: star.position.y - (direction.y * trailLength)
            )

            let starAlpha = min(1, (0.22 + (star.brightness * 0.54) + (beatPulse * 0.24)) * twinkle)
            let starColor = neonColor(
                offset: 0.10 + star.hueOffset,
                saturation: 0.54 + (star.depth * 0.32),
                brightness: 1.0,
                alpha: starAlpha
            )

            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: (4 + (star.size * 4)) + (audioLevel * 9) + (beatPulse * 22),
                color: starColor.withAlphaComponent(min(1, starAlpha * 0.92)).cgColor
            )
            context.setStrokeColor(starColor.cgColor)
            context.setLineWidth(max(0.7, star.size * (0.8 + (glowIntensity * 0.3))))
            context.move(to: trailStart)
            context.addLine(to: star.position)
            context.strokePath()
            context.restoreGState()

            context.setFillColor(starColor.cgColor)
            context.fillEllipse(in: CGRect(
                x: star.position.x - (coreSize * 0.5),
                y: star.position.y - (coreSize * 0.5),
                width: coreSize,
                height: coreSize
            ))
        }

        context.restoreGState()
    }

    private func drawVaporwaveGrid(in context: CGContext) {
        let rect = bounds
        let horizonY = rect.minY + (rect.height * 0.32)
        let warpStrength = 5 + (audioLevel * 18) + (beatPulse * 36)

        context.saveGState()
        context.setBlendMode(.screen)

        let rowCount = 12
        let rowSegments = 34
        for i in 0..<rowCount {
            let t = CGFloat(i) / CGFloat(rowCount - 1)
            let eased = pow(t, 1.75)
            let baseY = horizonY - eased * (horizonY - rect.minY)
            let alpha = (0.05 + ((1 - t) * 0.18) + (beatPulse * 0.11)) * backgroundOpacity
            let rowPath = CGMutablePath()

            for segment in 0...rowSegments {
                let xT = CGFloat(segment) / CGFloat(rowSegments)
                let x = rect.minX + (rect.width * xT)
                let waveA = sin((xT * 9.5) + (phase * 1.35) + (t * 5.0))
                let waveB = cos((xT * 17.0) - (phase * 0.84) + (t * 4.4))
                let yWarp = ((waveA * 0.64) + (waveB * 0.36)) * warpStrength * (1 - t)
                let point = CGPoint(x: x, y: baseY + yWarp)

                if segment == 0 {
                    rowPath.move(to: point)
                } else {
                    rowPath.addLine(to: point)
                }
            }

            context.addPath(rowPath)
            context.setStrokeColor(
                neonColor(
                    offset: 0.18 + (t * 0.34),
                    saturation: 0.90,
                    brightness: 1.0,
                    alpha: alpha
                ).cgColor
            )
            context.setLineWidth(1.0 + ((1 - t) * 0.22))
            context.strokePath()
        }

        let columns = 18
        let columnSegments = 24
        for index in 0...columns {
            let t = CGFloat(index) / CGFloat(columns)
            let baseX = rect.minX + (rect.width * t)
            let columnPath = CGMutablePath()

            for segment in 0...columnSegments {
                let s = CGFloat(segment) / CGFloat(columnSegments)
                let y = rect.minY + (horizonY - rect.minY) * s
                let perspectiveScale = 1 - (s * 0.88)
                let projectedX = rect.midX + ((baseX - rect.midX) * perspectiveScale)
                let xWarp = sin((phase * 1.9) + (s * 10.0) + (t * 7.2)) * warpStrength * 0.62 * (1 - s)
                let yWarp = cos((phase * 1.24) + (t * 8.0) + (s * 4.6)) * warpStrength * 0.14 * (1 - s)
                let point = CGPoint(x: projectedX + xWarp, y: y + yWarp)

                if segment == 0 {
                    columnPath.move(to: point)
                } else {
                    columnPath.addLine(to: point)
                }
            }

            context.addPath(columnPath)
            context.setStrokeColor(
                neonColor(
                    offset: 0.88 - (t * 0.22),
                    saturation: 0.88,
                    brightness: 1.0,
                    alpha: (0.06 + (abs(t - 0.5) * 0.10) + (beatPulse * 0.12)) * backgroundOpacity
                ).cgColor
            )
            context.setLineWidth(1.0)
            context.strokePath()
        }

        context.restoreGState()
    }

    private func makeGreekTickerLine(seed: Int, length: Int) -> String {
        guard length > 0 else { return "" }
        var value = UInt64(truncatingIfNeeded: seed)
        var result = ""
        result.reserveCapacity(length)

        while result.count < length {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            let wordLength = 2 + Int(value % 8)
            for _ in 0..<wordLength where result.count < length {
                value = value &* 6364136223846793005 &+ 1442695040888963407
                let letterIndex = Int(value % UInt64(greekTickerAlphabet.count))
                result.append(greekTickerAlphabet[letterIndex])
            }

            value = value &* 6364136223846793005 &+ 1442695040888963407
            let spacingRoll = Int(value % 100)
            let spaceCount: Int
            switch spacingRoll {
            case 0..<62:
                spaceCount = 1
            case 62..<84:
                spaceCount = 2
            case 84..<95:
                spaceCount = 3
            default:
                spaceCount = 4
            }
            for _ in 0..<spaceCount where result.count < length {
                result.append(" ")
            }
        }
        return result
    }

    private func makeGreekTickerLoopLines(count: Int, length: Int) -> [String] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            makeGreekTickerLine(seed: (index * 977) + 0x9E37, length: length)
        }
    }

    private func drawLeftGlyphTicker(in context: CGContext) {
        let rect = bounds
        let panelWidth = rect.width * 0.24
        let panelHeight = rect.height * 0.62
        let panelX = rect.minX + (rect.width * 0.035)
        let panelY = rect.minY + (rect.height * 0.07)
        let panelRect = CGRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        let innerRect = panelRect.insetBy(dx: 14, dy: 14)

        context.saveGState()
        context.setBlendMode(.screen)

        context.setFillColor(
            neonColor(
                offset: 0.67,
                saturation: 0.44,
                brightness: 0.18,
                alpha: 0.26 * backgroundOpacity
            ).cgColor
        )
        context.fill(panelRect)

        context.setStrokeColor(
            neonColor(
                offset: 0.31,
                saturation: 0.88,
                brightness: 1.0,
                alpha: 0.82 * backgroundOpacity
            ).cgColor
        )
        context.setLineWidth(1.8)
        context.stroke(panelRect)

        context.setStrokeColor(
            neonColor(
                offset: 0.86,
                saturation: 0.80,
                brightness: 1.0,
                alpha: 0.40 * backgroundOpacity
            ).cgColor
        )
        context.setLineWidth(0.8)
        context.stroke(panelRect.insetBy(dx: 4, dy: 4))

        let lineHeight = glyphTickerLineHeight
        let contentHeight = CGFloat(max(1, greekTickerLoopLines.count)) * lineHeight
        let scroll = tickerScroll.truncatingRemainder(dividingBy: max(1, contentHeight))
        let firstLine = Int(scroll / lineHeight)
        let intraLineOffset = scroll.truncatingRemainder(dividingBy: lineHeight)
        let baseY = innerRect.maxY - intraLineOffset
        let rowCount = Int(ceil(innerRect.height / lineHeight)) + 4

        context.addRect(innerRect)
        context.clip()

        for row in 0..<rowCount {
            let y = baseY - (CGFloat(row) * lineHeight)
            if y < innerRect.minY - lineHeight {
                break
            }
            if y > innerRect.maxY + lineHeight {
                continue
            }

            let lineIndex = (firstLine + row) % max(1, greekTickerLoopLines.count)
            let text = greekTickerLoopLines[lineIndex]
            let lineColor = neonColor(
                offset: 0.29 + (CGFloat(row % 3) * 0.03),
                saturation: 0.56,
                brightness: 1.0,
                alpha: 1.0
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: glyphTickerFont,
                .foregroundColor: lineColor
            ]
            (text as NSString).draw(at: CGPoint(x: innerRect.minX + 2, y: y), withAttributes: attrs)

            let characters = Array(text)
            let timeBucket = Int(tickerScroll * 0.30)
            var glowState = UInt64(truncatingIfNeeded: (lineIndex &* 73_856_093) ^ (timeBucket &* 19_349_663) ^ (row &* 83_492_791))
            glowState = glowState &* 6364136223846793005 &+ 1442695040888963407
            let glowCount = 2 + Int(glowState % 5)

            for glowIndex in 0..<glowCount {
                glowState = glowState &* 6364136223846793005 &+ 1442695040888963407
                let charIndex = Int(glowState % UInt64(max(1, characters.count)))
                guard charIndex < characters.count else { continue }
                let char = characters[charIndex]
                guard char != " " else { continue }

                let glowColor = neonColor(
                    offset: 0.08 + (CGFloat(glowIndex) * 0.05),
                    saturation: 0.12,
                    brightness: 1.0,
                    alpha: 1.0
                )
                let glowAttrs: [NSAttributedString.Key: Any] = [
                    .font: glyphTickerFont,
                    .foregroundColor: glowColor
                ]
                let glowX = innerRect.minX + 2 + (CGFloat(charIndex) * glyphTickerAdvance)

                context.saveGState()
                context.setShadow(offset: .zero, blur: 16, color: glowColor.cgColor)
                (String(char) as NSString).draw(at: CGPoint(x: glowX, y: y), withAttributes: glowAttrs)
                let coreAttrs: [NSAttributedString.Key: Any] = [
                    .font: glyphTickerFont,
                    .foregroundColor: NSColor.white
                ]
                (String(char) as NSString).draw(at: CGPoint(x: glowX, y: y), withAttributes: coreAttrs)
                context.restoreGState()
            }
        }

        context.restoreGState()
    }

    private func drawCenterPulse(in context: CGContext) {
        let rect = bounds
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let minRadius = min(rect.width, rect.height) * 0.09
        let baseRadius = minRadius * (1.0 + (energy * 0.70) + (beatPulse * 1.55))

        let fillColor = neonColor(
            offset: 0.04,
            saturation: 0.80,
            brightness: 1.0,
            alpha: 0.18 + (energy * 0.09) + (beatPulse * 0.22)
        )
        context.setFillColor(fillColor.cgColor)
        context.fillEllipse(in: CGRect(
            x: center.x - baseRadius,
            y: center.y - baseRadius,
            width: baseRadius * 2,
            height: baseRadius * 2
        ))

        context.setStrokeColor(
            neonColor(
                offset: 0.30,
                saturation: 0.90,
                brightness: 1.0,
                alpha: 0.38 + (energy * 0.16) + (beatPulse * 0.28)
            ).cgColor
        )
        context.setLineWidth(1.8 + (audioLevel * 2.4) + (beatPulse * 3.0))
        context.strokeEllipse(in: CGRect(
            x: center.x - (baseRadius * 1.2),
            y: center.y - (baseRadius * 1.2),
            width: baseRadius * 2.4,
            height: baseRadius * 2.4
        ))

        if beatPulse > 0.08 {
            context.setStrokeColor(
                neonColor(
                    offset: 0.90,
                    saturation: 0.82,
                    brightness: 1.0,
                    alpha: min(0.86, beatPulse + 0.12)
                ).cgColor
            )
            context.setLineWidth(2.0 + (beatPulse * 6.0))
            context.strokeEllipse(in: CGRect(
                x: center.x - (baseRadius * 1.55),
                y: center.y - (baseRadius * 1.55),
                width: baseRadius * 3.1,
                height: baseRadius * 3.1
            ))
        }
    }

    private func drawWireframeGlobes(in context: CGContext) {
        let rect = bounds
        let baseCenter = CGPoint(x: rect.midX, y: rect.midY + (rect.height * 0.03))
        let minDimension = min(rect.width, rect.height)

        let globeConfigs: [(radius: CGFloat, offsetX: CGFloat, offsetY: CGFloat, hue: CGFloat, alpha: CGFloat, speed: CGFloat, tilt: CGFloat)] = [
            (
                radius: minDimension * (0.18 + (beatPulse * 0.03)),
                offsetX: 0,
                offsetY: 0,
                hue: 0.34,
                alpha: 0.90,
                speed: 0.68,
                tilt: 0.32
            ),
            (
                radius: minDimension * (0.13 + (audioLevel * 0.02)),
                offsetX: (minDimension * 0.11) * sin(phase * 0.52),
                offsetY: minDimension * 0.02,
                hue: 0.90,
                alpha: 0.74,
                speed: -0.94,
                tilt: -0.28
            )
        ]

        for (index, config) in globeConfigs.enumerated() {
            let center = CGPoint(
                x: baseCenter.x + config.offsetX,
                y: baseCenter.y + config.offsetY
            )
            let rotationY = (phase * (1 + config.speed)) + (beatPulse * 2.2)
            let rotationX = config.tilt + (sin(phase * 0.40 + CGFloat(index)) * 0.18) + (audioLevel * 0.10)
            let perspective = config.radius * 4.0
            let latitudeCount = 6
            let longitudeCount = 11
            let sampleCount = 46

            func project(latitude: CGFloat, longitude: CGFloat) -> (point: CGPoint, depth: CGFloat) {
                let rawX = config.radius * cos(latitude) * cos(longitude)
                let rawY = config.radius * sin(latitude)
                let rawZ = config.radius * cos(latitude) * sin(longitude)

                let x1 = (rawX * cos(rotationY)) + (rawZ * sin(rotationY))
                let z1 = (-rawX * sin(rotationY)) + (rawZ * cos(rotationY))
                let y2 = (rawY * cos(rotationX)) - (z1 * sin(rotationX))
                let z2 = (rawY * sin(rotationX)) + (z1 * cos(rotationX))

                let scale = perspective / max(1, perspective - z2)
                let point = CGPoint(x: center.x + (x1 * scale), y: center.y + (y2 * scale))
                let depth = max(0, min(1, (z2 / config.radius + 1) * 0.5))
                return (point, depth)
            }

            func strokeCurve(pointProvider: (CGFloat) -> (point: CGPoint, depth: CGFloat)) {
                var previous = pointProvider(0)
                for step in 1...sampleCount {
                    let t = CGFloat(step) / CGFloat(sampleCount)
                    let current = pointProvider(t)
                    let depth = max(0, min(1, (previous.depth + current.depth) * 0.5))
                    let alpha = (0.05 + (depth * 0.58)) * config.alpha
                    let width = 0.55 + (depth * 1.4) + (beatPulse * 0.45)
                    context.setStrokeColor(
                        neonColor(
                            offset: config.hue + (depth * 0.18),
                            saturation: 0.90,
                            brightness: 1.0,
                            alpha: alpha
                        ).cgColor
                    )
                    context.setLineWidth(width)
                    context.move(to: previous.point)
                    context.addLine(to: current.point)
                    context.strokePath()
                    previous = current
                }
            }

            for latitudeIndex in 0..<latitudeCount {
                let latitudeT = CGFloat(latitudeIndex + 1) / CGFloat(latitudeCount + 1)
                let latitude = (latitudeT - 0.5) * .pi
                strokeCurve { t in
                    let longitude = (t * 2 * .pi) - .pi
                    return project(latitude: latitude, longitude: longitude)
                }
            }

            strokeCurve { t in
                let longitude = (t * 2 * .pi) - .pi
                return project(latitude: 0, longitude: longitude)
            }

            for longitudeIndex in 0..<longitudeCount {
                let longitude = ((CGFloat(longitudeIndex) / CGFloat(longitudeCount)) * 2 * .pi) - .pi
                strokeCurve { t in
                    let latitude = (t * .pi) - (.pi / 2)
                    return project(latitude: latitude, longitude: longitude)
                }
            }

            context.setStrokeColor(
                neonColor(
                    offset: config.hue + 0.26,
                    saturation: 0.80,
                    brightness: 1.0,
                    alpha: 0.34 * config.alpha
                ).cgColor
            )
            context.setLineWidth(1.0 + (beatPulse * 0.65))
            context.strokeEllipse(in: CGRect(
                x: center.x - config.radius,
                y: center.y - config.radius,
                width: config.radius * 2,
                height: config.radius * 2
            ))
        }
    }

    private func drawBottomWaveform(in context: CGContext) {
        let rect = bounds
        guard waveformHistory.count > 1 else { return }

        let baseline = rect.minY + (rect.height * 0.11)
        let amplitude = rect.height * (0.024 + (audioLevel * 0.06) + (beatPulse * 0.16))

        var points: [CGPoint] = []
        points.reserveCapacity(waveformHistory.count)
        for (index, sample) in waveformHistory.enumerated() {
            let t = CGFloat(index) / CGFloat(waveformHistory.count - 1)
            let x = rect.minX + (rect.width * t)
            let envelope = 0.42 + (0.58 * sin(.pi * t))
            let modulation = sin((phase * 2.2) + (t * 14.0)) * (0.08 + (audioLevel * 0.10))
            let y = baseline + (((sample * 0.82) + modulation) * amplitude * envelope)
            points.append(CGPoint(x: x, y: y))
        }

        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: rect.minX, y: rect.minY))
        fillPath.addLine(to: CGPoint(x: rect.minX, y: baseline))
        for point in points {
            fillPath.addLine(to: point)
        }
        fillPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        fillPath.closeSubpath()

        context.setFillColor(
            neonColor(
                offset: 0.26,
                saturation: 0.85,
                brightness: 1.0,
                alpha: 0.08 + (audioLevel * 0.11) + (beatPulse * 0.15)
            ).cgColor
        )
        context.addPath(fillPath)
        context.fillPath()
        drawWaveformBodySweep(in: context, maskPath: fillPath, rect: rect, baseline: baseline)

        let linePath = CGMutablePath()
        if let firstPoint = points.first {
            linePath.move(to: firstPoint)
        }
        for point in points.dropFirst() {
            linePath.addLine(to: point)
        }

        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: 12 + (audioLevel * 10) + (beatPulse * 26),
            color: neonColor(offset: 0.96, saturation: 0.88, brightness: 1.0, alpha: 0.80).cgColor
        )
        context.addPath(linePath)
        context.setStrokeColor(neonColor(offset: 0.92, saturation: 0.84, brightness: 1.0, alpha: 0.92).cgColor)
        context.setLineWidth(2.0 + (audioLevel * 1.8) + (beatPulse * 4.4))
        context.strokePath()
        context.restoreGState()

        context.addPath(linePath)
        context.setStrokeColor(neonColor(offset: 0.36, saturation: 0.90, brightness: 1.0, alpha: 0.98).cgColor)
        context.setLineWidth(1.2 + (audioLevel * 1.1) + (beatPulse * 1.8))
        context.strokePath()
    }

    private func drawWaveformBodySweep(in context: CGContext, maskPath: CGPath, rect: CGRect, baseline: CGFloat) {
        let bandWidth = rect.width * (0.12 + (beatPulse * 0.08))
        let travel = rect.width + (bandWidth * 2)
        let leadX = (rect.minX - bandWidth) + (phase * 180).truncatingRemainder(dividingBy: travel)
        let reverseX = (rect.maxX + bandWidth) - (phase * 130).truncatingRemainder(dividingBy: travel)
        let bodyHeight = max(1, baseline - rect.minY + (rect.height * 0.04))

        context.saveGState()
        context.addPath(maskPath)
        context.clip()
        context.setBlendMode(.screen)

        context.setFillColor(
            neonColor(
                offset: 0.29,
                saturation: 0.70,
                brightness: 1.0,
                alpha: (0.06 + (audioLevel * 0.06) + (beatPulse * 0.10)) * backgroundOpacity
            ).cgColor
        )
        context.fill(CGRect(x: leadX, y: rect.minY, width: bandWidth, height: bodyHeight))

        context.setFillColor(
            neonColor(
                offset: 0.42,
                saturation: 0.64,
                brightness: 1.0,
                alpha: (0.04 + (audioLevel * 0.05) + (beatPulse * 0.08)) * backgroundOpacity
            ).cgColor
        )
        context.fill(CGRect(x: reverseX - (bandWidth * 0.7), y: rect.minY, width: bandWidth * 0.7, height: bodyHeight))

        context.restoreGState()
    }

    private func drawSystemClock(in context: CGContext) {
        let rect = bounds
        let text = clockFormatter.string(from: Date())
        let characters = Array(text)
        guard !characters.isEmpty else { return }

        let tracking: CGFloat = 3.0
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: clockFont]
        var widths: [CGFloat] = []
        widths.reserveCapacity(characters.count)
        var totalWidth: CGFloat = 0
        for char in characters {
            let width = (String(char) as NSString).size(withAttributes: baseAttrs).width
            widths.append(width)
            totalWidth += width
        }
        totalWidth += tracking * CGFloat(max(0, characters.count - 1))

        let textHeight = clockFont.capHeight + 20
        let center = CGPoint(
            x: rect.minX + (rect.width * 0.27),
            y: rect.minY + (rect.height * 0.89)
        )
        var x = center.x - (totalWidth * 0.5)
        let y = center.y - (textHeight * 0.5)
        let hueDrift = (phase * 0.0035).truncatingRemainder(dividingBy: 1)

        for (index, char) in characters.enumerated() {
            let hueOffset = 0.06 + hueDrift + (CGFloat(index) * 0.12)
            let glowColor = neonColor(
                offset: hueOffset,
                saturation: 0.42,
                brightness: 1.0,
                alpha: 1.0
            )
            let charText = String(char)

            // Pseudo-3D extrusion: draw stacked offset layers behind each glyph.
            let depthSteps = 8
            for step in stride(from: depthSteps, through: 1, by: -1) {
                let t = CGFloat(step) / CGFloat(depthSteps)
                let depthColor = neonColor(
                    offset: hueOffset + 0.08,
                    saturation: 0.78,
                    brightness: 0.16 + ((1 - t) * 0.18),
                    alpha: 1.0
                )
                let depthAttrs: [NSAttributedString.Key: Any] = [
                    .font: clockFont,
                    .foregroundColor: depthColor
                ]
                let depthPoint = CGPoint(
                    x: x + (CGFloat(step) * 1.6),
                    y: y - (CGFloat(step) * 1.1)
                )
                (charText as NSString).draw(at: depthPoint, withAttributes: depthAttrs)
            }

            context.saveGState()
            context.setBlendMode(.screen)
            let glowAttrs: [NSAttributedString.Key: Any] = [
                .font: clockFont,
                .foregroundColor: glowColor
            ]
            context.setShadow(
                offset: .zero,
                blur: 30 + (beatPulse * 26),
                color: glowColor.cgColor
            )
            (charText as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: glowAttrs)
            context.restoreGState()

            let coreAttrs: [NSAttributedString.Key: Any] = [
                .font: clockFont,
                .foregroundColor: NSColor.white
            ]
            context.saveGState()
            context.setShadow(offset: .zero, blur: 9 + (beatPulse * 6), color: glowColor.cgColor)
            (charText as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: coreAttrs)
            context.restoreGState()

            x += widths[index] + tracking
        }
    }

    private func drawSubtleCredit(in context: CGContext) {
        let rect = bounds
        let text = "zachbohl.com"
        let alpha = (0.08 + (backgroundOpacity * 0.06))
        let color = neonColor(offset: 0.13, saturation: 0.34, brightness: 0.92, alpha: alpha)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: creditFont,
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = CGPoint(
            x: rect.maxX - size.width - 14,
            y: rect.minY + 10
        )

        context.saveGState()
        context.setBlendMode(.screen)
        context.setShadow(offset: .zero, blur: 4, color: color.withAlphaComponent(alpha).cgColor)
        (text as NSString).draw(at: origin, withAttributes: attrs)
        context.restoreGState()
    }

    private func drawRipples(in context: CGContext) {
        for ripple in ripples {
            let progress = ripple.age / ripple.lifespan
            let radius = 20 + (progress * 280)
            let alpha = (1.0 - progress) * 0.95
            let stroke = neonColor(
                offset: 0.90 + (progress * 0.2),
                saturation: 0.86,
                brightness: 1.0,
                alpha: alpha
            )

            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(2.2 + ((1 - progress) * 1.6))
            context.strokeEllipse(in: CGRect(
                x: ripple.position.x - radius,
                y: ripple.position.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }
}

private final class WallpaperController {
    private var windows: [NSWindow: VisualizerView] = [:]
    private var backgroundMode: BackgroundMode = .full

    func start() {
        rebuildWindows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenConfigurationChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleActiveSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleScreenConfigurationChange() {
        rebuildWindows()
    }

    @objc private func handleActiveSpaceChange() {
        reorderBehindDesktopIcons()
    }

    func setAudioLevel(_ level: CGFloat) {
        for view in windows.values {
            view.setAudioLevel(level)
        }
    }

    func registerGlobalClick(at point: CGPoint) {
        for (window, view) in windows where window.frame.contains(point) {
            let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
            view.registerClick(at: local)
        }
    }

    func setBackgroundMode(_ mode: BackgroundMode) {
        backgroundMode = mode
        applyBackgroundModeToWindows()
    }

    private func rebuildWindows() {
        for window in windows.keys {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()

        // This level keeps the wallpaper window above the static desktop image layer.
        let wallpaperLevel = Int(CGWindowLevelForKey(.desktopWindow))

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.level = NSWindow.Level(rawValue: wallpaperLevel)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.hasShadow = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.hidesOnDeactivate = false
            window.setFrame(screen.frame, display: true)

            let view = VisualizerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.orderBack(nil)

            windows[window] = view
        }

        applyBackgroundModeToWindows()
        reorderBehindDesktopIcons()
    }

    private func applyBackgroundModeToWindows() {
        let isOverlay = backgroundMode == .overlay
        let backgroundOpacity: CGFloat = isOverlay ? 0.42 : 1.0

        for (window, view) in windows {
            window.isOpaque = !isOverlay
            window.backgroundColor = isOverlay ? .clear : .black
            view.setBackgroundOpacity(backgroundOpacity)
        }
    }

    private func reorderBehindDesktopIcons() {
        for window in windows.keys {
            window.orderBack(nil)
        }
    }
}

private final class ClickMonitor {
    var onClick: ((CGPoint) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.onClick?(NSEvent.mouseLocation)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.onClick?(NSEvent.mouseLocation)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}

private final class MicrophoneAudioMonitor {
    var onLevel: ((CGFloat) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var smoothing: Float = 0

    func start() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let level = self.calculateLevel(from: buffer)
            DispatchQueue.main.async {
                self.onLevel?(CGFloat(level))
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return 0
        }

        let sampleCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let firstChannel = channels[0]

        var sum: Float = 0
        for index in 0..<sampleCount {
            let sample = firstChannel[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(sampleCount))
        let compensated = min(1, rms * max(4, Float(channelCount) * 2.5))

        smoothing = (smoothing * 0.82) + (compensated * 0.18)
        return smoothing
    }
}

private enum AudioMonitorError: Error {
    case noDisplay
}

private final class SystemAudioMonitor: NSObject, SCStreamOutput, SCStreamDelegate {
    var onLevel: ((CGFloat) -> Void)?

    private let queue = DispatchQueue(label: "wallpaper.system.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var smoothing: Float = 0

    func start() async throws {
        stop()

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareableContent.displays.first else {
            throw AudioMonitorError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 2
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        guard let stream else {
            return
        }

        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Keep last known level when stream drops; app-level monitor handles retries.
        NSLog("System audio stream stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              let level = calculateRMS(sampleBuffer: sampleBuffer) else {
            return
        }

        let compensated = min(1, level * 8.5)
        smoothing = (smoothing * 0.80) + (compensated * 0.20)
        let output = CGFloat(smoothing)

        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(output)
        }
    }

    private func calculateRMS(sampleBuffer: CMSampleBuffer) -> Float? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = streamBasicDescription.pointee
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let bytesPerSample = max(Int(asbd.mBitsPerChannel / 8), 1)
        let bytesPerFrame = max(Int(asbd.mBytesPerFrame), bytesPerSample * channels)

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr,
              let dataPointer,
              length >= bytesPerFrame else {
            return nil
        }

        let frameCount = length / bytesPerFrame
        guard frameCount > 0 else {
            return nil
        }

        if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 {
            let samplePointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            var sum: Float = 0
            var index = 0
            for _ in 0..<frameCount {
                let sample = samplePointer[index]
                sum += sample * sample
                index += channels
            }
            return sqrt(sum / Float(frameCount))
        }

        if asbd.mBitsPerChannel == 16 {
            let samplePointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
            var sum: Float = 0
            var index = 0
            for _ in 0..<frameCount {
                let sample = Float(samplePointer[index]) / Float(Int16.max)
                sum += sample * sample
                index += channels
            }
            return sqrt(sum / Float(frameCount))
        }

        if asbd.mBitsPerChannel == 32 {
            let samplePointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int32.self)
            var sum: Float = 0
            var index = 0
            for _ in 0..<frameCount {
                let sample = Float(samplePointer[index]) / Float(Int32.max)
                sum += sample * sample
                index += channels
            }
            return sqrt(sum / Float(frameCount))
        }

        return nil
    }
}

private final class AudioReactiveController {
    var onLevel: ((CGFloat) -> Void)?
    var onModeChange: ((CaptureMode) -> Void)?

    private let systemAudioMonitor = SystemAudioMonitor()
    private let microphoneMonitor = MicrophoneAudioMonitor()
    private var simulationTimer: Timer?

    init() {
        systemAudioMonitor.onLevel = { [weak self] level in
            self?.onLevel?(level)
        }

        microphoneMonitor.onLevel = { [weak self] level in
            self?.onLevel?(level)
        }
    }

    func start() {
        Task { @MainActor in
            await startPreferredCapture()
        }
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        systemAudioMonitor.stop()
        microphoneMonitor.stop()
    }

    @MainActor
    private func startPreferredCapture() async {
        do {
            try await systemAudioMonitor.start()
            onModeChange?(.systemAudio)
            return
        } catch {
            NSLog("System audio capture unavailable: \(error.localizedDescription)")
        }

        do {
            try microphoneMonitor.start()
            onModeChange?(.microphone)
            return
        } catch {
            NSLog("Microphone capture unavailable: \(error.localizedDescription)")
        }

        startSimulationFallback()
        onModeChange?(.simulated)
    }

    private func startSimulationFallback() {
        var t: CGFloat = 0
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            t += 0.028
            let level = (sin(t) * 0.5 + 0.5) * 0.35
            self?.onLevel?(level)
        }
        if let simulationTimer {
            RunLoop.main.add(simulationTimer, forMode: .common)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let wallpaperController = WallpaperController()
    private let clickMonitor = ClickMonitor()
    private let audioController = AudioReactiveController()

    private var statusItem: NSStatusItem?
    private var backgroundMode: BackgroundMode = .full
    private let modeMenuItem = NSMenuItem(title: "Audio Mode: Starting…", action: nil, keyEquivalent: "")
    private let backgroundModeMenuItem = NSMenuItem(title: "Background: Full", action: nil, keyEquivalent: "")
    private let overlayToggleMenuItem = NSMenuItem(title: "Enable Desktop Overlay", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        wallpaperController.start()
        wallpaperController.setBackgroundMode(backgroundMode)

        clickMonitor.onClick = { [weak self] point in
            self?.wallpaperController.registerGlobalClick(at: point)
        }
        clickMonitor.start()

        audioController.onLevel = { [weak self] level in
            self?.wallpaperController.setAudioLevel(level)
        }
        audioController.onModeChange = { [weak self] mode in
            self?.modeMenuItem.title = "Audio Mode: \(mode.rawValue)"
        }
        audioController.start()

        setupStatusMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clickMonitor.stop()
        audioController.stop()
    }

    private func setupStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "♪"

        let menu = NSMenu()
        modeMenuItem.isEnabled = false
        backgroundModeMenuItem.isEnabled = false
        menu.addItem(modeMenuItem)
        menu.addItem(backgroundModeMenuItem)

        overlayToggleMenuItem.action = #selector(toggleBackgroundMode)
        overlayToggleMenuItem.target = self
        overlayToggleMenuItem.keyEquivalent = "o"
        menu.addItem(overlayToggleMenuItem)

        menu.addItem(.separator())

        let restartItem = NSMenuItem(title: "Restart Audio Capture", action: #selector(restartAudioCapture), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        updateBackgroundMenuItems()
    }

    @objc private func restartAudioCapture() {
        audioController.restart()
    }

    @objc private func toggleBackgroundMode() {
        backgroundMode = backgroundMode == .full ? .overlay : .full
        wallpaperController.setBackgroundMode(backgroundMode)
        updateBackgroundMenuItems()
    }

    private func updateBackgroundMenuItems() {
        backgroundModeMenuItem.title = "Background: \(backgroundMode.rawValue)"
        overlayToggleMenuItem.title = backgroundMode == .overlay ? "Disable Desktop Overlay" : "Enable Desktop Overlay"
        overlayToggleMenuItem.state = backgroundMode == .overlay ? .on : .off
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
