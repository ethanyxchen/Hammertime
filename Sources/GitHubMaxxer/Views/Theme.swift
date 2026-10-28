import AppKit
import SwiftUI

enum Palette {
  static let background = dynamic(light: 0xE2E3E0, dark: 0x111311)
  static let panel = dynamic(light: 0xF1F2EF, dark: 0x1A1C1A)
  static let sidebar = dynamic(light: 0xDCDED9, dark: 0x141614)
  static let ink = dynamic(light: 0x141714, dark: 0xEBEEE9)
  static let secondary = dynamic(light: 0x5C615B, dark: 0x8C928A)
  static let rule = dynamic(light: 0xC1C5BE, dark: 0x2E322E)
  static let empty = dynamic(light: 0xD2D5CF, dark: 0x292D29)
  static let reached = dynamic(light: 0x6E9150, dark: 0x9BB87A)
  static let over = dynamic(light: 0x435E30, dark: 0xC4DCA2)
  static let merged = dynamic(light: 0x8250DF, dark: 0xA371F7)

  static func heat(_ count: Int) -> Color {
    switch count {
    case 0: empty
    case 1: reached.opacity(0.4)
    case 2: reached.opacity(0.7)
    case 3: reached
    default: over
    }
  }

  static func colour(_ colour: WorkspaceColour?) -> Color {
    switch colour {
    case nil: ink
    case .terracotta: dynamic(light: 0xB8613A, dark: 0xE08A60)
    case .ochre: dynamic(light: 0xB88A1F, dark: 0xE0B44A)
    case .plum: dynamic(light: 0x84507A, dark: 0xC188B5)
    case .slate: dynamic(light: 0x587089, dark: 0x8FA8C2)
    case .rosewood: dynamic(light: 0xA85A62, dark: 0xD88A92)
    case .umber: dynamic(light: 0x7A6650, dark: 0xC2A88A)
    }
  }

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
      })
  }
}

extension NSColor {
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

extension Font {
  static func readout(_ size: CGFloat) -> Font {
    .system(size: size, weight: .medium, design: .monospaced)
  }
}

struct Eyebrow: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 10.5, weight: .medium, design: .monospaced))
      .tracking(1.2)
      .foregroundStyle(Palette.secondary)
  }
}

struct PageTitle: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct Rule: View {
  var vertical = false

  var body: some View {
    Palette.rule.frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
  }
}

struct Lamp: View {
  let isOn: Bool

  var body: some View {
    Circle()
      .fill(isOn ? Palette.reached : Palette.empty)
      .frame(width: 7, height: 7)
      .shadow(color: isOn ? Palette.reached : .clear, radius: 3)
  }
}

struct MeterShare: Identifiable {
  let id: AnyHashable
  let title: String
  let count: Int
  let target: Int
  let color: Color
}

struct SegmentMeter: View {
  let count: Int
  let target: Int
  let isReached: Bool
  var pace: Int?
  var tint = Palette.ink
  var shares: [MeterShare] = []
  var height: CGFloat = 18

  private var scale: Int { max(target, count) }
  private var segments: Int { max(1, min(scale, 60)) }
  private var perSegment: Double { Double(scale) / Double(segments) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      bar
      if shares.count > 1 { legend }
    }
    .accessibilityHidden(true)
  }

  private var bar: some View {
    HStack(spacing: segments > 30 ? 2 : 3) {
      ForEach(0..<segments, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1).fill(color(end: Double(index + 1) * perSegment))
      }
    }
    .frame(height: height)
    .overlay {
      if let pace, scale > 0 {
        GeometryReader { geometry in
          Triangle().fill(Palette.ink)
            .frame(width: 8, height: 5)
            .position(
              x: geometry.size.width * Double(pace) / Double(scale), y: geometry.size.height + 6)
        }
      }
    }
  }

  private var legend: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .leading)],
      alignment: .leading, spacing: 6
    ) {
      ForEach(shares) { share in
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 1).fill(share.color).frame(width: 8, height: 8)
          Text("\(share.title) \(share.count)/\(share.target)").lineLimit(1)
        }
        .help("\(share.title): \(share.count) of \(share.target)")
      }
    }
    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.secondary)
  }

  func color(end: Double) -> Color {
    guard Double(count) >= end - 0.001 else { return Palette.empty }
    if !shares.isEmpty && !isReached { return shareColor(at: end - perSegment / 2) }
    if end > Double(target) + 0.001 { return Palette.over }
    return isReached ? Palette.reached : tint
  }

  private func shareColor(at position: Double) -> Color {
    var end = 0.0
    for share in shares {
      end += Double(share.count)
      if position < end { return share.color }
    }
    return Palette.empty
  }
}

private struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.closeSubpath()
    }
  }
}

struct ProminentButtonStyle: PrimitiveButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ProminentButton(configuration: configuration)
  }
}

extension PrimitiveButtonStyle where Self == ProminentButtonStyle {
  static var prominent: Self { .init() }
}

private struct ProminentButton: View {
  let configuration: PrimitiveButtonStyleConfiguration
  @State private var isHovering = false

  var body: some View {
    Button(configuration)
      .buttonStyle(.borderedProminent)
      .tint(Color.accentColor.mix(with: .black, by: isHovering ? 0.18 : 0))
      .onHover { isHovering = $0 }
  }
}
