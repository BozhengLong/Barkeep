//
//  LayoutBarStyle.swift
//  Ice
//

import SwiftUI

extension View {
    /// Returns a view that is drawn in the style of a layout bar.
    ///
    /// - Note: The view this modifier is applied to must be transparent, or the style
    ///   will be drawn incorrectly.
    @ViewBuilder
    func layoutBarStyle(appState: AppState, averageColorInfo: MenuBarAverageColorInfo?) -> some View {
        background {
            // Opaque base so the bar is never see-through, and dark so that the
            // (typically light) menu-bar icons stay visible even when color sampling
            // returns nil on macOS 26. When a sampled/average color is available it
            // is drawn opaquely on top of this base, hiding it.
            ZStack {
                Color(white: 0.13)
                if appState.isActiveSpaceFullscreen {
                    Color.black
                } else if let averageColorInfo {
                    switch averageColorInfo.source {
                    case .menuBarWindow:
                        Color(cgColor: averageColorInfo.color)
                            .overlay(
                                Material.bar
                                    .opacity(0.2)
                                    .blendMode(.softLight)
                            )
                    case .desktopWallpaper:
                        Color(cgColor: averageColorInfo.color)
                            .overlay(
                                Material.bar
                                    .opacity(0.5)
                                    .blendMode(.softLight)
                            )
                    }
                } else {
                    Color.defaultLayoutBar
                }
            }
        }
        .overlay {
            if !appState.isActiveSpaceFullscreen {
                switch appState.appearanceManager.configuration.current.tintKind {
                case .none:
                    EmptyView()
                case .solid:
                    Color(cgColor: appState.appearanceManager.configuration.current.tintColor)
                        .opacity(0.2)
                        .allowsHitTesting(false)
                case .gradient:
                    appState.appearanceManager.configuration.current.tintGradient
                        .opacity(0.2)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
