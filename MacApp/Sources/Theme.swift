import SwiftUI

// MARK: – Shared design tokens matching the HTML UI (#141420 / #6C8EF5 palette).
// Used by both the Preferences window and the menu-bar dropdown so the whole
// app shares one visual language.

extension Color {
    static let vlBackground  = Color(red: 0.08, green: 0.08, blue: 0.12)  // #141420
    static let vlSurface     = Color(red: 0.12, green: 0.12, blue: 0.18)  // #1e1e2e
    static let vlSurface2    = Color(red: 0.15, green: 0.15, blue: 0.22)  // #252538
    static let vlBorder      = Color.white.opacity(0.1)
    static let vlAccent      = Color(red: 0.42, green: 0.56, blue: 0.96)  // #6C8EF5
    static let vlLabel       = Color(red: 0.91, green: 0.91, blue: 0.94)  // #e8e8f0
    static let vlSecondary   = Color(red: 0.53, green: 0.53, blue: 0.66)  // #8888a8
    static let vlDim         = Color(red: 0.27, green: 0.27, blue: 0.35)  // #44445a
    static let vlGreen       = Color(red: 0.36, green: 0.78, blue: 0.59)  // #5cc896
    static let vlOrange      = Color(red: 0.95, green: 0.61, blue: 0.07)  // #f29b12
    static let vlRed         = Color(red: 0.96, green: 0.42, blue: 0.42)  // #f56c6c
}
