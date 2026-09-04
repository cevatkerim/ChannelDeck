import AVFoundation
import AVKit
import AppKit
import SwiftUI

/// Native macOS AirPlay route picker bound to the application's shared player.
@MainActor
public struct AirPlayRoutePicker: NSViewRepresentable {
    public let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.player = player
        routePicker.isRoutePickerButtonBordered = false
        routePicker.setRoutePickerButtonColor(.labelColor, for: .normal)
        routePicker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        routePicker.toolTip = "Choose an AirPlay device"
        routePicker.setAccessibilityLabel("AirPlay")
        routePicker.setAccessibilityHelp("Choose a device for video or audio playback")
        return routePicker
    }

    public func updateNSView(_ routePicker: AVRoutePickerView, context: Context) {
        if routePicker.player !== player {
            routePicker.player = player
        }
    }

    public static func dismantleNSView(_ routePicker: AVRoutePickerView, coordinator: Void) {
        // SwiftUI can transiently rebuild toolbar items while playback state
        // changes. Clearing the association here can tear down the active
        // AirPlay route even though the shared AVPlayer remains alive. The
        // released route picker drops its reference without explicit cleanup;
        // PlayerController exclusively owns playback and route lifetime.
    }
}
