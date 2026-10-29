import AppKit
import SwiftUI

/// The paper every card is printed on.
///
/// Two card kinds exist — an annotation and an AI answer — and they used to
/// have two chromes: one flat, one accent-tinted. They are one system now: a
/// thin coloured rule, a soft shadow, and a stack of paper behind the card
/// that makes a grid of them read as a pile of cards rather than a wall of
/// boxes.
enum CardPaper {
    /// Six rules, chosen once per card by its identity. A colour drawn fresh
    /// on every redraw would flicker while scrolling, so it is a hash: it
    /// looks random, and it stays put.
    private static let rules: [(hue: Double, saturation: Double)] = [
        (0.02, 0.62),  // brick
        (0.10, 0.66),  // amber
        (0.33, 0.52),  // forest
        (0.50, 0.50),  // teal
        (0.62, 0.55),  // indigo
        (0.88, 0.45),  // rose
    ]

    static func rule(for identity: String, dark: Bool) -> Color {
        var hash: UInt64 = 5381
        for byte in identity.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let pick = rules[Int(hash % UInt64(rules.count))]
        return Color(
            hue: pick.hue, saturation: pick.saturation,
            brightness: dark ? 0.72 : 0.60)
    }

    static let corner: CGFloat = 10
}

private struct CardSurface: ViewModifier {
    let identity: String
    let selected: Bool
    /// How many sheets belong under this card: the cards behind it. A card
    /// with no siblings has none — a stack under a single card promises
    /// something that is not there.
    let sheets: Int
    @Environment(\.colorScheme) private var scheme

    private var rule: Color {
        CardPaper.rule(for: identity, dark: scheme == .dark)
            .opacity(scheme == .dark ? 0.85 : 0.7)
    }

    /// In dark appearance `controlBackgroundColor` and the page tone are the
    /// same colour, so a card would have only its edge. A fixed lifted
    /// surface: a dynamic `NSColor` resolves in the ambient appearance, which
    /// is how a "dark" card came out white.
    private var paper: Color {
        scheme == .dark
            ? Surface.paperDark
            : Color(nsColor: .textBackgroundColor)
    }

    private func sheet(
        _ shape: RoundedRectangle, inset: CGFloat, drop: CGFloat,
        shade: Double
    ) -> some View {
        shape
            .fill(paper)
            .overlay {
                shape.fill(
                    (scheme == .dark ? Color.white : Color.black)
                        .opacity(scheme == .dark ? shade * 0.7 : shade))
            }
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(scheme == .dark ? 0.18 : 0.13),
                    lineWidth: Metrics.borderLine)
            }
            .padding(.horizontal, inset)
            .offset(y: drop)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: CardPaper.corner, style: .continuous)
        content
            .background(shape.fill(paper))
            .background {
                // The sheets underneath: narrower than the card, stepped
                // down, and edged — without the edge they vanish into a
                // window the same colour as the paper.
                ZStack {
                    if sheets >= 2 {
                        sheet(shape, inset: 12, drop: 12, shade: 0.045)
                    }
                    if sheets >= 1 {
                        sheet(shape, inset: 6, drop: 6, shade: 0.075)
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    selected ? rule : rule.opacity(Opacity.o75),
                    lineWidth: selected ? 1.6 : 1)
            }
            // A card sits on the page, not in it: a soft contact shadow and a
            // tighter one under the top sheet.
            .shadow(
                color: .black.opacity(scheme == .dark ? 0.34 : 0.10),
                radius: 7, x: 0, y: 4)
            .shadow(
                color: .black.opacity(scheme == .dark ? 0.18 : 0.05),
                radius: 1.5, x: 0, y: 0.8)
    }
}

extension View {
    /// One card's paper: a coloured rule, a soft shadow, and as many sheets
    /// underneath as there are cards behind it.
    ///
    /// `identity` is stable per card, so its colour is too. `sheets` is 0 for
    /// a card on its own: a stack is a statement about what is behind the
    /// card, and a lone card has nothing there.
    func cardSurface(
        identity: String, selected: Bool = false, sheets: Int = 0
    ) -> some View {
        modifier(
            CardSurface(
                identity: identity, selected: selected,
                sheets: min(2, max(0, sheets))))
    }
}
