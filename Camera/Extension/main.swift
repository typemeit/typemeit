import CoreMediaIO
import Foundation

let provider = CameraProvider(clientQueue: nil)
CMIOExtensionProvider.startService(provider: provider.provider)
CFRunLoopRun()
