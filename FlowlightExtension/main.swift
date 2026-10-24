#if !APP_STORE
import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
    IPCServer.shared.startListener()
}

dispatchMain()
#endif
