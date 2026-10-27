import SwiftUI

/// Native iOS 26 Liquid Glass, with a translucent material fallback for iOS 17–25.
/// Glass is reserved for navigation, cards and controls; album covers stay unobstructed.
struct VinylGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 22

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.13), lineWidth: 0.7))
        }
    }
}

extension View {
    func vinylGlassSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(VinylGlassSurface(cornerRadius: cornerRadius))
    }
}

struct VinylGlassButtonModifier: ViewModifier {
    var prominent = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                // TabView has a white tint. Without an explicit button tint,
                // .glassProminent inherits it and creates a white-on-white pill.
                content
                    .buttonStyle(.glassProminent)
                    .tint(Color(red: 0.25, green: 0.27, blue: 0.33))
                    .foregroundStyle(.white)
            } else {
                content
                    .buttonStyle(.glass)
                    .foregroundStyle(.white)
            }
        } else {
            if prominent {
                content
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.25, green: 0.27, blue: 0.33))
                    .foregroundStyle(.white)
            } else {
                content
                    .buttonStyle(.bordered)
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Low-saturation ambient background that samples the current album's palette.
/// Keeping it outside the glass controls gives the system material something to refract.
struct VinylBackdrop: View {
    var accent: RGBColor = CoverPalette.fallback

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.045, green: 0.049, blue: 0.065)
                Ellipse()
                    .fill(accent.swiftUIColor.opacity(0.95))
                    .frame(width: geometry.size.width * 1.25, height: 340)
                    .blur(radius: 100)
                    .offset(x: geometry.size.width * 0.3, y: -geometry.size.height * 0.26)
                Ellipse()
                    .fill(Color(red: 0.19, green: 0.27, blue: 0.35).opacity(0.35))
                    .frame(width: 380, height: 380)
                    .blur(radius: 110)
                    .offset(x: -geometry.size.width * 0.36, y: geometry.size.height * 0.3)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
