import Foundation

extension CloudTunnelCoordinator {
    /// The production coordinator. The Network Extension packet tunnel is not
    /// part of this build, so the backend is always unavailable and the
    /// controller is inert: no start is ever admitted and NetworkExtension
    /// preferences are never loaded.
    @MainActor
    public static func inert(consumers: any CloudTunnelConsumerSource) -> CloudTunnelCoordinator {
        CloudTunnelCoordinator(
            backend: .unavailable(.extensionNotBundled),
            controller: CloudTunnelInertController(),
            enroller: VMTunnelEnroller(manager: VMTunnelManager()),
            consumers: consumers,
            admission: .constant { .cloudMachinesOff }
        )
    }

    /// The controller for `backend`. NetworkExtension is used only when the
    /// build can run it, and it is built at launch only when this Mac already
    /// saved a VPN configuration, so a tunnel a previous app instance left
    /// running is still adopted or stopped. On every other Mac the real
    /// controller waits behind ``CloudTunnelDeferredController`` for the first
    /// admitted start: a user who never opted in never loads NetworkExtension
    /// preferences.
    @MainActor
    public static func liveController(
        for backend: CloudTunnelBackend,
        activation: CloudActivationPolicy,
        makeNetworkExtensionController: @escaping @MainActor (String) -> any CloudTunnelControlling
    ) -> any CloudTunnelControlling {
        switch backend {
        case .networkExtension(let extensionBundleIdentifier):
            if activation.allowsLaunchTimeTunnelAdoption {
                return makeNetworkExtensionController(extensionBundleIdentifier)
            }
            return CloudTunnelDeferredController {
                makeNetworkExtensionController(extensionBundleIdentifier)
            }
        case .unavailable:
            return CloudTunnelInertController()
        }
    }
}
