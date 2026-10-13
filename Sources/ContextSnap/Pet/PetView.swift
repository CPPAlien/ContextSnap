import SwiftUI

/// What the pet is doing right now.
enum PetMood {
    /// Nudging the user to get up.
    case nudge
    /// Standing by while the user stretches, counting the break down.
    case resting
    /// Welcoming the user back before it fades out.
    case happy
}

@MainActor
final class PetModel: ObservableObject {
    @Published var mood: PetMood = .nudge
    @Published var headline = ""
    @Published var detail = ""
    /// Seconds left in the break; only read while `mood == .resting`.
    @Published var remaining = 0

    var onRest: () -> Void = {}
    var onSnooze: () -> Void = {}
    var onBackToWork: () -> Void = {}
    var onDismiss: () -> Void = {}
}

private let petAccent = Color(red: 0.55, green: 0.36, blue: 0.96)

// MARK: - Panel

struct PetPanelView: View {
    @ObservedObject var model: PetModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            bubble
            PetView(mood: model.mood)
                .frame(width: 132, height: 116)
            controls
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.10)))
                .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: model.onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .padding(8)
            .opacity(hovering ? 1 : 0)
            .help("Hide until the next reminder")
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .padding(10)  // room for the shadow inside the borderless panel
    }

    private var bubble: some View {
        VStack(spacing: 2) {
            Text(model.headline)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .frame(maxWidth: 230)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var controls: some View {
        switch model.mood {
        case .nudge:
            HStack(spacing: 8) {
                Button("Stretch now", action: model.onRest)
                    .buttonStyle(PetButtonStyle(filled: true))
                Button("5 more min", action: model.onSnooze)
                    .buttonStyle(PetButtonStyle(filled: false))
            }
        case .resting:
            Button("Back to work", action: model.onBackToWork)
                .buttonStyle(PetButtonStyle(filled: false))
        case .happy:
            Color.clear.frame(height: 1)
        }
    }
}

private struct PetButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(filled ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(filled ? petAccent : Color.primary.opacity(0.08))
            )
            .overlay(Capsule().stroke(Color.primary.opacity(filled ? 0 : 0.12)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - The pet itself

/// A small cat drawn entirely in shapes — no image assets, same approach as
/// the status-bar icon. Everything animates off one clock so the bob, the
/// tail sway and the blink stay in step.
struct PetView: View {
    let mood: PetMood

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            cat(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    private func cat(at t: Double) -> some View {
        // Resting: a slow, deep stretch. Otherwise a light idle bob.
        let stretching = mood == .resting
        let pulse = sin(t * (stretching ? 1.4 : 2.2))
        let bob = pulse * (stretching ? 5 : 3)
        let tailSway = sin(t * 2.8) * 16
        let armLift = stretching ? 152.0 + pulse * 16 : 8.0
        let eyesShut = mood != .nudge || isBlinking(at: t)

        return ZStack {
            // Tail, behind the body.
            Capsule()
                .fill(petAccent.opacity(0.85))
                .frame(width: 9, height: 40)
                .rotationEffect(.degrees(24 + tailSway), anchor: .bottom)
                .offset(x: 41, y: 8)

            // Feet.
            HStack(spacing: 16) {
                Ellipse().frame(width: 24, height: 12)
                Ellipse().frame(width: 24, height: 12)
            }
            .foregroundStyle(petAccent.opacity(0.9))
            .offset(y: 45)

            ZStack {
                // Ears.
                HStack(spacing: 30) {
                    Ear().frame(width: 22, height: 19).rotationEffect(.degrees(-10))
                    Ear().frame(width: 22, height: 19).rotationEffect(.degrees(10))
                }
                .foregroundStyle(petAccent)
                .offset(y: -40)

                // Body.
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(LinearGradient(
                        colors: [petAccent.opacity(0.95), petAccent.opacity(0.72)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: 86, height: 78)
                    .overlay(
                        Ellipse()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 44, height: 32)
                            .offset(y: 20)
                    )

                // Arms — raised overhead during the stretch.
                Capsule().fill(petAccent.opacity(0.95)).frame(width: 11, height: 30)
                    .rotationEffect(.degrees(-armLift), anchor: .top)
                    .offset(x: -45, y: -8)
                Capsule().fill(petAccent.opacity(0.95)).frame(width: 11, height: 30)
                    .rotationEffect(.degrees(armLift), anchor: .top)
                    .offset(x: 45, y: -8)

                // Face.
                HStack(spacing: 22) {
                    Eye(shut: eyesShut)
                    Eye(shut: eyesShut)
                }
                .offset(y: -14)

                HStack(spacing: 44) {
                    Ellipse().frame(width: 13, height: 8)
                    Ellipse().frame(width: 13, height: 8)
                }
                .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.62).opacity(0.65))
                .offset(y: -3)

                Mouth()
                    .stroke(Color.black.opacity(0.62), style: .init(lineWidth: 2, lineCap: .round))
                    .frame(width: 18, height: 7)
                    .offset(y: -1)
            }
            .offset(y: bob)
        }
    }

    /// One quick blink roughly every four seconds.
    private func isBlinking(at t: Double) -> Bool {
        t.truncatingRemainder(dividingBy: 4.1) < 0.16
    }
}

private struct Ear: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Open eyes are dark ovals; shut eyes are the happy "^ ^" arc.
private struct Eye: View {
    let shut: Bool

    var body: some View {
        ZStack {
            if shut {
                Arc()
                    .stroke(Color.black.opacity(0.75), style: .init(lineWidth: 2.4, lineCap: .round))
                    .frame(width: 13, height: 7)
            } else {
                Capsule()
                    .fill(Color.black.opacity(0.78))
                    .frame(width: 9, height: 12)
                    .overlay(
                        Circle().fill(.white.opacity(0.9))
                            .frame(width: 3, height: 3)
                            .offset(x: -1.5, y: -3)
                    )
            }
        }
        .frame(width: 13, height: 12)
    }
}

private struct Arc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                       control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return p
    }
}

private struct Mouth: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                       control: CGPoint(x: rect.width * 0.25, y: rect.maxY * 1.5))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.width * 0.75, y: rect.maxY * 1.5))
        return p
    }
}
