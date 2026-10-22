import AppKit
import SceneKit

let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let iconDestination = URL(fileURLWithPath: CommandLine.arguments[2])

struct Hammer {
  let image: NSBitmapImageRep
  let face: NSPoint
  let length: CGFloat

  init(yaw: Float, textured: Bool) {
    let image = Self.render(yaw: yaw, textured: textured)
    let opaqueRows = (0..<image.pixelsHigh).filter { y in
      (0..<image.pixelsWide).contains { image.colorAt(x: $0, y: y)!.alphaComponent > 0.3 }
    }
    let top = opaqueRows.first!
    let bottom = opaqueRows.last!
    let headColumns = stride(from: bottom - (bottom - top) / 4, through: bottom, by: 2).flatMap {
      y in (0..<image.pixelsWide).filter { image.colorAt(x: $0, y: y)!.alphaComponent > 0.3 }
    }
    self.image = image
    face = NSPoint(
      x: CGFloat(headColumns.min()! + headColumns.max()!) / 2,
      y: CGFloat(image.pixelsHigh - bottom))
    length = CGFloat(bottom - top)
  }

  func draw(face target: NSPoint, length: CGFloat) {
    let scale = length / self.length
    image.draw(
      in: NSRect(
        x: target.x - face.x * scale, y: target.y - face.y * scale,
        width: CGFloat(image.pixelsWide) * scale, height: CGFloat(image.pixelsHigh) * scale),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
  }

  private static func render(yaw: Float, textured: Bool) -> NSBitmapImageRep {
    let model = SCNNode()
    let scanned = try! SCNScene(url: resources.appendingPathComponent("Sledgehammer.obj"))
    for child in scanned.rootNode.childNodes { model.addChildNode(child) }
    let material = SCNMaterial()
    if textured {
      material.lightingModel = .physicallyBased
      let texture = { (name: String) in resources.appendingPathComponent("Sledgehammer\(name)") }
      material.diffuse.contents = texture("Color.jpg")
      material.normal.contents = texture("Normal.png")
      material.roughness.contents = texture("Roughness.jpg")
      material.metalness.contents = texture("Metalness.jpg")
    } else {
      material.lightingModel = .constant
      material.diffuse.contents = NSColor.black
    }
    model.enumerateHierarchy { node, _ in node.geometry?.materials = [material] }
    let (low, high) = model.boundingBox
    model.position = SCNVector3(
      (low.x + high.x) / -2, (low.y + high.y) / -2, (low.z + high.z) / -2)
    let pose = SCNNode()
    pose.simdOrientation =
      simd_quatf(angle: -1.85, axis: [0, 0, 1]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
    pose.addChildNode(model)

    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    scene.rootNode.addChildNode(pose)
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera?.usesOrthographicProjection = true
    camera.camera?.orthographicScale = 5.6
    camera.simdPosition = [0, 0, 30]
    scene.rootNode.addChildNode(camera)
    if textured {
      scene.lightingEnvironment.contents = resources.appendingPathComponent("Studio.hdr")
      scene.lightingEnvironment.intensity = 1.4
      let key = SCNNode()
      key.light = SCNLight()
      key.light?.type = .directional
      key.light?.intensity = 900
      key.simdPosition = [-6, 8, 10]
      key.simdLook(at: [0, 0, 0])
      scene.rootNode.addChildNode(key)
    }

    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene
    renderer.pointOfView = camera
    let snapshot = renderer.snapshot(
      atTime: 0, with: CGSize(width: 2048, height: 2048), antialiasingMode: .multisampling4X)
    return NSBitmapImageRep(data: snapshot.tiffRepresentation!)!
  }
}

struct Noise {
  private var state: UInt64

  init(_ seed: UInt64) { state = seed }

  mutating func next() -> CGFloat {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
  }
}

func canvas(_ size: Int, _ draw: () -> Void) -> NSBitmapImageRep {
  let image = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
  draw()
  NSGraphicsContext.restoreGraphicsState()
  return image
}

func save(_ image: NSBitmapImageRep, to url: URL) {
  try! image.representation(using: .png, properties: [:])!.write(to: url)
}

func withShadow(alpha: CGFloat, offset: NSSize, blur: CGFloat, _ draw: () -> Void) {
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(white: 0, alpha: alpha)
  shadow.shadowOffset = offset
  shadow.shadowBlurRadius = blur
  shadow.set()
  draw()
  NSGraphicsContext.restoreGraphicsState()
}

func ember(_ alpha: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: 0x89 / 255, green: 0x57 / 255, blue: 0xE5 / 255, alpha: alpha)
}

func cracks(from impact: NSPoint, color: NSColor, width: CGFloat) {
  var noise = Noise(11)
  let rays = 11
  let reach: CGFloat = 400
  let paths = (0..<rays).map { ray in
    let angle =
      .pi * (0.95 + CGFloat(ray) / CGFloat(rays - 1) * 1.1) + (noise.next() - 0.5) * 0.2
    let length = reach * (0.6 + noise.next() * 0.5)
    return (1...6).map { step in
      let distance = length * CGFloat(step) / 6
      let wobble = (noise.next() - 0.5) * 0.35
      return NSPoint(
        x: impact.x + cos(angle + wobble) * distance,
        y: impact.y + sin(angle + wobble) * distance * 0.42)
    }
  }
  color.setStroke()
  for points in paths {
    let path = NSBezierPath()
    path.lineWidth = width * 1.4
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: impact)
    for point in points { path.line(to: point) }
    path.stroke()
  }
  for ring in [1, 3] {
    let path = NSBezierPath()
    path.lineWidth = width * 0.8
    for ray in 0..<(rays - 1) where noise.next() > 0.3 {
      path.move(to: paths[ray][ring])
      path.line(to: paths[ray + 1][ring])
    }
    path.stroke()
  }
}

func appIcon(_ hammer: Hammer) -> NSBitmapImageRep {
  let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
  let squircle = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
  let impact = NSPoint(x: 512, y: 340)
  return canvas(1024) {
    withShadow(alpha: 0.35, offset: NSSize(width: 0, height: -12), blur: 28) {
      NSColor.black.setFill()
      squircle.fill()
    }
    NSColor(srgbRed: 0x24 / 255, green: 0x27 / 255, blue: 0x5E / 255, alpha: 1).setFill()
    squircle.fill()
    squircle.addClip()

    var noise = Noise(41)
    for y in stride(from: plate.minY, to: plate.maxY, by: 3) {
      NSColor(white: noise.next() > 0.5 ? 1 : 0, alpha: 0.0175 + noise.next() * 0.021).setFill()
      NSRect(x: plate.minX, y: y, width: plate.width, height: 1.5).fill()
    }

    NSGraphicsContext.saveGraphicsState()
    NSAffineTransform(transform: AffineTransform(translationByX: 0, byY: -3)).concat()
    cracks(from: impact, color: NSColor(white: 1, alpha: 0.14), width: 7)
    NSGraphicsContext.restoreGraphicsState()
    cracks(
      from: impact,
      color: NSColor(srgbRed: 0x07 / 255, green: 0x08 / 255, blue: 0x1A / 255, alpha: 1),
      width: 7)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: NSRect(x: impact.x - 200, y: impact.y - 90, width: 400, height: 180))
      .addClip()
    cracks(from: impact, color: ember(0.85), width: 3.5)
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: ember(0.45), ending: ember(0))!
      .draw(fromCenter: impact, radius: 0, toCenter: impact, radius: 70, options: [])

    noise = Noise(23)
    ember().setStroke()
    for _ in 0..<7 {
      let angle = .pi * (0.12 + noise.next() * 0.76)
      let distance = 150 + noise.next() * 40
      let length = 14 + noise.next() * 24
      let start = NSPoint(
        x: impact.x + cos(angle) * distance * 1.3, y: impact.y + sin(angle) * distance * 0.4)
      let spark = NSBezierPath()
      spark.lineWidth = 4 + noise.next() * 2
      spark.lineCapStyle = .round
      spark.move(to: start)
      spark.line(
        to: NSPoint(x: start.x + cos(angle) * length * 1.3, y: start.y + sin(angle) * length * 0.6))
      spark.stroke()
    }

    withShadow(alpha: 0.5, offset: NSSize(width: 10, height: -14), blur: 22) {
      hammer.draw(face: impact, length: 1900)
    }
  }
}

func mark(_ hammer: Hammer, points: CGFloat) -> NSBitmapImageRep {
  canvas(Int(18 * points)) {
    NSAffineTransform(transform: AffineTransform(scale: points / 2)).concat()
    let face = NSPoint(x: 18, y: 9)
    hammer.draw(face: face, length: 100)
    let ground = NSBezierPath()
    ground.lineWidth = 2.4
    ground.lineCapStyle = .round
    ground.move(to: NSPoint(x: 2, y: face.y - 3))
    ground.line(to: NSPoint(x: 34, y: face.y - 3))
    NSColor.black.setStroke()
    ground.stroke()
  }
}

func portrait(_ hammer: Hammer) -> NSBitmapImageRep {
  canvas(256) {
    withShadow(alpha: 0.3, offset: NSSize(width: 4, height: -8), blur: 10) {
      hammer.draw(face: NSPoint(x: 128, y: 36), length: 700)
    }
  }
}

let textured = Hammer(yaw: 1.4, textured: true)
save(appIcon(textured), to: iconDestination)
save(portrait(textured), to: resources.appendingPathComponent("Hammer.png"))
save(
  mark(Hammer(yaw: 1.57, textured: false), points: 8),
  to: resources.appendingPathComponent("Mark.png"))
