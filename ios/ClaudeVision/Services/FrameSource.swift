import Foundation
import AVFoundation

protocol FrameSource: AnyObject {
    var latestFrame: Data? { get }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}
