import SwiftUI

/// Every square part in one window, to try by hand: hovers, popovers and the
/// shortcut recorder answer as they do in the app. Each part's file also
/// previews its states one by one.
@main
struct DesignSystemGallery: App {
    var body: some Scene {
        Window("design system", id: "gallery") {
            #if DEBUG
            SquareGallery()
            #endif
        }
        .defaultSize(width: 1320, height: 900)
    }
}
