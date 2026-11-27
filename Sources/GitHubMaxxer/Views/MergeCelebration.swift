import AVFoundation
import SwiftUI
import os

enum Slam {
  static let settle = 0.35
  static let impact = 0.55
  static let hold = 0.09
  static let release = impact + hold
  static let shatter = release + 0.36
  static let reveal = Landing.celebration
  static let impactHeight = 0.55

  static func seed(_ slam: Date?) -> Int {
    slam.map { Int($0.timeIntervalSince1970 * 1000) % 9973 } ?? 0
  }
}

struct Choreography<Content: View>: View {
  let start: Date?
  let duration: Double
  @ViewBuilder let content: (Double) -> Content
  @State private var isSettled = false

  private var origin: Date { start ?? .distantPast }

  var body: some View {
    TimelineView(.animation(paused: isSettled)) { context in
      content(isSettled ? duration : min(context.date.timeIntervalSince(origin), duration))
    }
    .task(id: start) {
      isSettled = false
      let remaining = origin.addingTimeInterval(duration).timeIntervalSinceNow
      try? await Task.sleep(for: .seconds(max(0, remaining)))
      isSettled = true
    }
  }
}

struct HammerSlam: View {
  let landing: Landing?

  var body: some View {
    HammerShatter(landing: landing).overlay { HammerSwing(landing: landing, overscan: 1) }
  }
}

struct HammerSwing: View {
  let landing: Landing?
  let overscan: Double

  var body: some View {
    Choreography(start: landing?.slam, duration: Swing.timeline.duration) { time in
      if time > Swing.entrance, time < Swing.timeline.duration {
        let swing = Swing.timeline.value(time: time)
        Sledgehammer(swing: swing, overscan: overscan).opacity(swing.opacity)
      }
    }
    .task(id: landing?.slam) {
      guard let date = landing?.slam else { return }
      Soundtrack.shared.play(elapsed: -date.timeIntervalSinceNow)
    }
    .task { _ = SledgehammerRig.shared }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct HammerShatter: View {
  let landing: Landing?
  @State private var page: (date: Date, layers: PageLayers)?

  var body: some View {
    Choreography(start: landing?.slam, duration: Shatter.duration) { time in
      Shatter(
        time: time, seed: Slam.seed(landing?.slam),
        layers: page.flatMap { $0.date == landing?.slam ? $0.layers : nil })
    }
    .background {
      PageCapture(date: landing?.slam) { date, layers in page = (date, layers) }
    }
    .task(id: landing?.slam) {
      guard let date = landing?.slam else { return }
      do {
        try await Task.sleep(for: .seconds(max(0, Shatter.duration + date.timeIntervalSinceNow)))
      } catch { return }
      page = nil
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct ScreenCracks: View {
  static let duration = Shatter.duration
  let slam: Date

  var body: some View {
    Choreography(start: slam, duration: Self.duration) { time in
      Canvas { context, size in
        guard time >= Slam.release, time < Self.duration else { return }
        let web = Web(size: size, seed: Slam.seed(slam))
        context.opacity = Shatter.opacity(at: time)
        context.translateBy(x: 0, y: size.height * Shatter.shake.value(time: time))
        web.cracks(in: context, extent: web.extent(at: time))
        web.flash(in: context, size: size, time: time)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

@MainActor
final class Soundtrack {
  static let shared = Soundtrack()
  static let mutedKey = "slamSoundMuted"
  private let cues = [
    (Slam.impact, Soundtrack.player("Impact")), (Slam.shatter, Soundtrack.player("Shatter")),
  ]

  func play(elapsed: Double) {
    guard elapsed < Slam.impact, !UserDefaults.standard.bool(forKey: Self.mutedKey) else { return }
    Logger.merges.log("Playing slam sound")
    for (time, player) in cues {
      guard let player else { continue }
      player.stop()
      player.currentTime = 0
      player.play(atTime: player.deviceCurrentTime + time - elapsed)
    }
  }

  private static func player(_ name: String) -> AVAudioPlayer? {
    let player = Bundle.main.url(forResource: name, withExtension: "caf").flatMap {
      try? AVAudioPlayer(contentsOf: $0)
    }
    player?.prepareToPlay()
    return player
  }
}

private struct PageCapture: NSViewRepresentable {
  let date: Date?
  let capture: (Date, PageLayers) -> Void

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    guard let date, date != context.coordinator.slam?.date else { return }
    context.coordinator.slam?.task.cancel()
    let task = Task {
      try? await Task.sleep(for: .seconds(max(0, Slam.settle + date.timeIntervalSinceNow)))
      for _ in 0..<10 {
        guard !Task.isCancelled else { return }
        if let page = Self.snapshot(view) {
          let layers = await Task.detached(priority: .userInitiated) { PageLayers(page) }.value
          guard let layers else { return }
          capture(date, layers)
          await Self.hideChrome(above: view, during: date)
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    context.coordinator.slam = (date, task)
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.slam?.task.cancel()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  private static func snapshot(_ view: NSView) -> CGImage? {
    guard let window = view.window?.contentView?.superview else { return nil }
    let frame = view.convert(view.bounds, to: window)
    guard let bitmap = window.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
    let pockets = scrollPockets(in: window).filter { !$0.isHidden }
    for pocket in pockets { pocket.isHidden = true }
    window.cacheDisplay(in: frame, to: bitmap)
    for pocket in pockets { pocket.isHidden = false }
    return bitmap.cgImage
  }

  private static func scrollPockets(in view: NSView) -> [NSView] {
    view.subviews.flatMap {
      String(describing: type(of: $0)) == "NSScrollPocket" ? [$0] : scrollPockets(in: $0)
    }
  }

  private static func hideChrome(above view: NSView, during slam: Date) async {
    guard let content = view.window?.contentView, let window = content.superview else { return }
    let chrome = window.subviews.drop { $0 !== content }.dropFirst()
    func fade(to alpha: Double, over duration: Double) async {
      await NSAnimationContext.runAnimationGroup { animation in
        animation.duration = duration
        for view in chrome { view.animator().alphaValue = alpha }
      }
    }
    do {
      try await Task.sleep(for: .seconds(max(0, Slam.impact + slam.timeIntervalSinceNow)))
      await fade(to: 0, over: 0)
      try await Task.sleep(for: .seconds(max(0, Slam.reveal + slam.timeIntervalSinceNow)))
      await fade(to: 1, over: Shatter.fade)
    } catch {
      await fade(to: 1, over: 0)
    }
  }

  final class Coordinator {
    var slam: (date: Date, task: Task<Void, Never>)?
  }
}

private struct Shatter: View {
  static let fade = 0.35
  static let duration = Slam.reveal + fade
  @MainActor static let shake = KeyframeTimeline(initialValue: 0.0) {
    KeyframeTrack {
      LinearKeyframe(0, duration: Slam.release)
      LinearKeyframe(0.035, duration: 0.03)
      CubicKeyframe(-0.0225, duration: 0.06)
      CubicKeyframe(0.01375, duration: 0.07)
      CubicKeyframe(-0.0075, duration: 0.07)
      CubicKeyframe(0.00375, duration: 0.08)
      CubicKeyframe(0, duration: 0.1)
    }
  }
  let time: Double
  let seed: Int
  let layers: PageLayers?

  var body: some View {
    Canvas { context, size in
      let bounds = CGRect(origin: .zero, size: size)
      let web = Web(size: size, seed: seed)
      guard let layers, time >= Slam.impact, time < Self.duration else { return }
      context.translateBy(x: 0, y: size.height * Self.shake.value(time: time))
      var backdrop = context
      backdrop.opacity = Self.opacity(at: time)
      backdrop.draw(context.resolve(Image(decorative: layers.backdrop, scale: 1)), in: bounds)
      web.shards(
        in: &context, time: time - Slam.shatter, extent: web.extent(at: time),
        content: context.resolve(Image(decorative: layers.content, scale: 1)), bounds: bounds)
      web.flash(in: context, size: size, time: time)
    }
  }

  static func opacity(at time: Double) -> Double {
    1 - min(max((time - Slam.reveal) / fade, 0), 1)
  }
}

private struct Web {
  static let rings = [0.01, 0.022, 0.04, 0.065, 0.1, 0.15, 0.22, 0.31, 0.43, 0.58, 0.78, 1.15]
  private static let growth = 0.18
  let center: CGPoint
  let reach: Double
  let seed: Int

  init(size: CGSize, seed: Int) {
    center = CGPoint(x: size.width / 2, y: size.height * Slam.impactHeight)
    reach = hypot(max(center.x, size.width - center.x), max(center.y, size.height - center.y))
    self.seed = seed
  }

  private var spokes: Int { 12 + Int(random(0, 9) * 6) }

  func extent(at time: Double) -> Double {
    let growth = min(max((time - Slam.release) / Self.growth, 0), 1)
    return reach * Self.rings.last! * (1 - pow(1 - growth, 3))
  }

  func flash(in context: GraphicsContext, size: CGSize, time: Double) {
    let fade = 1 - max(time - Slam.release, 0) / 0.25
    guard fade > 0, fade <= 1 else { return }
    let radius = min(size.width, size.height) * 0.18
    context.fill(
      Path(
        ellipseIn: CGRect(
          x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
      with: .radialGradient(
        Gradient(colors: [.white.opacity(fade), .clear]), center: center, startRadius: 0,
        endRadius: radius))
  }

  func cracks(in context: GraphicsContext, extent: Double) {
    for ring in Self.rings.indices {
      for spoke in 0..<spokes where extent >= distance(vertex(spoke, ring)) {
        crack(outline(spoke, ring), in: context)
      }
    }
  }

  private func crack(_ outline: Path, in context: GraphicsContext) {
    context.stroke(outline, with: .color(.black.opacity(0.3)), lineWidth: 2.2)
    context.stroke(outline, with: .color(.white.opacity(0.85)), lineWidth: 1)
  }

  func shards(
    in context: inout GraphicsContext, time: Double, extent: Double,
    content: GraphicsContext.ResolvedImage, bounds: CGRect
  ) {
    let pieces = (0..<Self.rings.count).reversed().flatMap { ring in
      (0..<spokes).compactMap { spoke in
        let outline = outline(spoke, ring)
        return pose(spoke, ring, frame: outline.boundingRect, time: time, extent: extent).map {
          (outline, $0)
        }
      }
    }
    if time > 0 {
      context.drawLayer { shadows in
        shadows.addFilter(.blur(radius: 4 + 14 * min(time, 1)))
        for (outline, pose) in pieces where pose.lift > 0 {
          var shadow = shadows
          shadow.translateBy(x: pose.lift * 10, y: pose.lift * 26)
          pose.apply(to: &shadow, around: outline.boundingRect)
          shadow.fill(outline, with: .color(.black.opacity(0.2 * pose.opacity)))
        }
      }
    }
    for (outline, pose) in pieces {
      var piece = context
      pose.apply(to: &piece, around: outline.boundingRect)
      if pose.lift > 0 {
        var edge = piece
        edge.clip(to: outline, options: .inverse)
        edge.translateBy(x: pose.thickness * 0.5, y: pose.thickness)
        edge.fill(outline, with: .color(Color(red: 0.55, green: 0.68, blue: 0.64).opacity(0.85)))
      }
      piece.drawLayer { face in
        face.clip(to: outline)
        face.draw(content, in: bounds)
        let frame = outline.boundingRect
        let sweep = (sin(pose.tumble * 2 + Double(frame.minX)) + 1) / 2
        face.fill(
          outline,
          with: .linearGradient(
            Gradient(stops: [
              .init(color: .white.opacity(0.06 * pose.shine), location: 0),
              .init(color: .white.opacity(0.4 * pose.shine), location: sweep),
              .init(color: .white.opacity(0.04 * pose.shine), location: 1),
            ]),
            startPoint: CGPoint(x: frame.minX, y: frame.minY),
            endPoint: CGPoint(x: frame.maxX, y: frame.maxY)))
      }
      if pose.cracked { crack(outline, in: piece) }
    }
  }

  private func outline(_ spoke: Int, _ ring: Int) -> Path {
    var outline = Path()
    outline.addLines([
      vertex(spoke, ring - 1), kink(spoke, ring), vertex(spoke, ring),
      vertex(spoke + 1, ring), kink(spoke + 1, ring), vertex(spoke + 1, ring - 1),
    ])
    outline.closeSubpath()
    return outline
  }

  private func pose(_ spoke: Int, _ ring: Int, frame: CGRect, time: Double, extent: Double)
    -> Pose?
  {
    let away = CGVector(dx: frame.midX - center.x, dy: frame.midY - center.y)
    let distance = max(hypot(away.dx, away.dy), 1)
    let cracked = extent >= self.distance(vertex(spoke, ring)) ? 1.0 : 0
    let delay =
      0.22 * Double(ring) / Double(Self.rings.count) + 0.08 * random(spoke * 5 + ring, 15)
    let flight = max(time - delay, 0)
    guard flight < Pose.life else { return nil }
    let push =
      cracked * (2 + 4 * random(spoke * 11 + ring, 19))
      + reach * (0.1 + 0.9 * exp(-distance / (0.18 * reach))) * flight
    return Pose(
      offset: CGVector(
        dx: away.dx / distance * push,
        dy: away.dy / distance * push + reach * 1.3 * flight * flight),
      spin: (random(spoke * 3 + ring, 16) - 0.5) * (0.04 * cracked + 5 * flight),
      tumble: (random(spoke * 7 + ring, 20) - 0.5) * 9 * flight,
      lift: flight,
      opacity: min((Pose.life - flight) / 0.25, 1),
      cracked: cracked > 0 || flight > 0)
  }
  private func random(_ index: Int, _ salt: Int) -> Double { noise(index + seed, salt) }

  private func vertex(_ spoke: Int, _ ring: Int) -> CGPoint {
    guard ring >= 0 else { return center }
    let spoke = spoke % spokes
    let angle =
      2 * .pi * (Double(spoke) + 0.6 * (random(spoke, 10) - 0.5)) / Double(spokes)
      + (random(spoke * 17 + ring, 12) - 0.5) * 0.12
    let radius = Self.rings[ring] * reach * (0.8 + 0.4 * random(spoke * 31 + ring, 11))
    return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
  }

  private func kink(_ spoke: Int, _ ring: Int) -> CGPoint {
    let start = vertex(spoke, ring - 1)
    let end = vertex(spoke, ring)
    let offset = (random((spoke % spokes) * 13 + ring, 17) - 0.5) * 0.35
    return CGPoint(
      x: (start.x + end.x) / 2 - (end.y - start.y) * offset,
      y: (start.y + end.y) / 2 + (end.x - start.x) * offset)
  }

  private func distance(_ point: CGPoint) -> Double {
    hypot(point.x - center.x, point.y - center.y)
  }
}

private struct Pose {
  static let life = 1.15
  let offset: CGVector
  let spin: Double
  let tumble: Double
  let lift: Double
  let opacity: Double
  let cracked: Bool

  var thickness: Double { 2 + 7 * abs(sin(tumble)) }
  var shine: Double { min(lift * 4, 1) }

  func apply(to context: inout GraphicsContext, around frame: CGRect) {
    let scale = 1 + 0.9 * lift
    context.opacity = opacity
    context.translateBy(x: frame.midX + offset.dx, y: frame.midY + offset.dy)
    context.rotate(by: .radians(spin))
    context.scaleBy(x: scale * max(abs(cos(tumble)), 0.15), y: scale)
    context.translateBy(x: -frame.midX, y: -frame.midY)
  }
}

struct MergedStamp: View {
  let landing: Landing

  var body: some View {
    Choreography(start: landing.reveal, duration: StampScene.duration) { time in
      StampScene(time: time)
    }
  }
}

private struct StampScene: View {
  private static let sweepStart = 0.5
  private static let sweepDuration = 0.45
  private static let sparkleLife = 0.8
  static let duration = sweepStart + sweepDuration + sparkleLife
  let time: Double

  var body: some View {
    let time = time - Self.sweepStart
    HStack(spacing: 6) {
      Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
      Text("Merged").textCase(.uppercase).tracking(1.8)
    }
    .font(.system(size: 12, weight: .heavy, design: .monospaced))
    .foregroundStyle(Palette.merged)
    .padding(.horizontal, 10)
    .frame(maxHeight: .infinity)
    .overlay { CropBrackets().stroke(Palette.merged, lineWidth: 1.5).padding(0.75) }
    .mask {
      Rectangle().scaleEffect(x: min(max(time / Self.sweepDuration, 0), 1), anchor: .leading)
    }
    .overlay {
      Canvas { context, size in sparkles(in: &context, size: size, time: time) }
        .padding(-16)
    }
  }

  private func sparkles(in context: inout GraphicsContext, size: CGSize, time: Double) {
    let count = 16
    for sparkle in 0..<count {
      let spawn = Double(sparkle) / Double(count)
      let age = (time - spawn * Self.sweepDuration) / Self.sparkleLife
      guard age >= 0, age < 1 else { continue }
      let drift = 1 - pow(1 - age, 2)
      let x = 16 + spawn * (size.width - 32) + (noise(sparkle, 6) - 0.5) * 16 * drift
      let y =
        size.height / 2 + (noise(sparkle, 7) - 0.5) * 10 + (8 + 14 * noise(sparkle, 8)) * drift
      let radius = (2 + 2.5 * noise(sparkle, 9)) * (1 - age)
      context.fill(
        Sparkle().path(
          in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
        with: .color(Palette.merged.opacity(1 - age)))
    }
  }
}

private struct CropBrackets: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      let length = 6.0
      for (corner, dx, dy) in [
        (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
        (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
        (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
        (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
      ] {
        path.move(to: CGPoint(x: corner.x + length * dx, y: corner.y))
        path.addLine(to: corner)
        path.addLine(to: CGPoint(x: corner.x, y: corner.y + length * dy))
      }
    }
  }
}

private struct Sparkle: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      let center = CGPoint(x: rect.midX, y: rect.midY)
      let pinch = rect.width * 0.12
      path.move(to: CGPoint(x: center.x, y: rect.minY))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: center.y), control: center.offsetBy(pinch, -pinch))
      path.addQuadCurve(
        to: CGPoint(x: center.x, y: rect.maxY), control: center.offsetBy(pinch, pinch))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX, y: center.y), control: center.offsetBy(-pinch, pinch))
      path.addQuadCurve(
        to: CGPoint(x: center.x, y: rect.minY), control: center.offsetBy(-pinch, -pinch))
    }
  }
}

func noise(_ index: Int, _ salt: Int) -> Double {
  let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
  return value - floor(value)
}

extension CGPoint {
  fileprivate func offsetBy(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
    CGPoint(x: x + dx, y: y + dy)
  }
}
