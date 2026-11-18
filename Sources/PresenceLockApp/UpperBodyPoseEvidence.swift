import CoreGraphics
import CoreVideo
import PresenceLockCore
import Vision

enum UpperBodyPoseEvidence {
    static func evaluate(_ pixelBuffer: CVPixelBuffer) -> PoseShadowResult {
        let request = VNDetectHumanBodyPoseRequest()
        request.preferBackgroundProcessing = true
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
            guard let poses = request.results else { return .unavailable }
            var unreadablePose = false
            for pose in poses {
                guard let points = try? pose.recognizedPoints(.all), !points.isEmpty else {
                    unreadablePose = true
                    continue
                }
                if hasTorso(points) { return .torsoDetected }
            }
            return unreadablePose ? .unavailable : .noReliableTorso
        } catch {
            return .unavailable
        }
    }

    private static func hasTorso(_ points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        func location(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let point = points[joint], point.confidence >= 0.5,
                  (0...1).contains(point.location.x), (0...1).contains(point.location.y)
            else { return nil }
            return point.location
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        // An isolated joint or an inferred neck midway between two shoulders is insufficient.
        guard let left = location(.leftShoulder), let right = location(.rightShoulder) else { return false }
        let span = distance(left, right)
        guard span >= 0.06 else { return false }
        let center = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        for hip in [location(.leftHip), location(.rightHip)].compactMap({ $0 }) {
            if center.y - hip.y >= 0.3 * span && distance(center, hip) <= 3 * span { return true }
        }
        // At a desk the hips can be below the frame. Require a neck and a distinct upper arm.
        guard let neck = location(.neck), distance(center, neck) <= 0.5 * span else { return false }
        for (shoulder, elbow) in [(left, location(.leftElbow)), (right, location(.rightElbow))] {
            if let elbow, (0.25 * span...2 * span).contains(distance(shoulder, elbow)) { return true }
        }
        return false
    }
}
