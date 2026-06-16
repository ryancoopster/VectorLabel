import SwiftUI

// MARK: – Shared design tokens for the menu-bar dropdown and Preferences window.
// Colors resolve from AppSettings.shared.appearance ("dark" | "light") so the
// whole app themes together. Views that read these must observe AppSettings so
// their bodies re-evaluate when the appearance flips.

private func vl(_ dark: Color, _ light: Color) -> Color {
    AppSettings.shared.appearance == "light" ? light : dark
}

extension Color {
    static var vlBackground: Color { vl(Color(red: 0.08, green: 0.08, blue: 0.12),   // #141420
                                         Color(red: 0.93, green: 0.94, blue: 0.96)) } // #eef0f4
    static var vlSurface: Color    { vl(Color(red: 0.12, green: 0.12, blue: 0.18),   // #1e1e2e
                                         Color(red: 1.00, green: 1.00, blue: 1.00)) } // #ffffff
    static var vlSurface2: Color   { vl(Color(red: 0.15, green: 0.15, blue: 0.22),   // #252538
                                         Color(red: 0.92, green: 0.93, blue: 0.95)) } // #ebeef2
    static var vlBorder: Color     { vl(Color.white.opacity(0.10),
                                         Color.black.opacity(0.12)) }
    static var vlAccent: Color     { vl(Color(red: 0.42, green: 0.56, blue: 0.96),   // #6C8EF5
                                         Color(red: 0.29, green: 0.42, blue: 0.83)) } // #4a6cd4
    static var vlLabel: Color      { vl(Color(red: 0.91, green: 0.91, blue: 0.94),   // #e8e8f0
                                         Color(red: 0.11, green: 0.11, blue: 0.14)) } // #1b1c24
    static var vlSecondary: Color  { vl(Color(red: 0.53, green: 0.53, blue: 0.66),   // #8888a8
                                         Color(red: 0.36, green: 0.38, blue: 0.44)) } // #5d6070
    static var vlDim: Color        { vl(Color(red: 0.27, green: 0.27, blue: 0.35),   // #44445a
                                         Color(red: 0.58, green: 0.60, blue: 0.66)) } // #9499a8
    static var vlGreen: Color      { vl(Color(red: 0.36, green: 0.78, blue: 0.59),   // #5cc896
                                         Color(red: 0.12, green: 0.62, blue: 0.39)) } // #1f9d63
    static var vlOrange: Color     { vl(Color(red: 0.95, green: 0.61, blue: 0.07),   // #f29b12
                                         Color(red: 0.71, green: 0.47, blue: 0.04)) } // #b5790a
    static var vlRed: Color        { vl(Color(red: 0.96, green: 0.42, blue: 0.42),   // #f56c6c
                                         Color(red: 0.84, green: 0.23, blue: 0.23)) } // #d63b3b
}
