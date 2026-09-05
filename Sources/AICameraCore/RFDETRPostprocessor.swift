import Foundation

public enum RFDETRPostprocessor {
    public static let maximumQueries = 1_000
    public static let maximumClasses = 256
    private struct Candidate {
        let score: Double
        let flatIndex: Int
        let query: Int
        let classID: Int
    }

    public static func detections(
        boxes: [Double],
        logits: [Double],
        queryCount: Int,
        classCount: Int,
        confidence: Double,
        selectionLimit: Int = 300,
        resultLimit: Int = AICameraContentLimits.detections
    ) -> [Detection] {
        guard (1...maximumQueries).contains(queryCount),
              (1...maximumClasses).contains(classCount),
              boxes.count >= queryCount * 4,
              logits.count >= queryCount * classCount,
              selectionLimit > 0,
              resultLimit > 0, confidence.isFinite else { return [] }

        let threshold = min(max(confidence, 0), 1)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(min(selectionLimit, queryCount * classCount))
        for flatIndex in 0..<(queryCount * classCount) {
            guard logits[flatIndex].isFinite else { continue }
            let logit = min(max(logits[flatIndex], -88), 88)
            let score = 1 / (1 + exp(-logit))
            guard score > threshold else { continue }
            candidates.append(Candidate(
                score: score,
                flatIndex: flatIndex,
                query: flatIndex / classCount,
                classID: flatIndex % classCount
            ))
        }
        candidates.sort {
            if $0.score == $1.score { return $0.flatIndex < $1.flatIndex }
            return $0.score > $1.score
        }

        var detections: [Detection] = []
        let resultLimit = min(resultLimit, AICameraContentLimits.detections)
        detections.reserveCapacity(min(resultLimit, selectionLimit))
        for candidate in candidates.prefix(selectionLimit) {
            guard candidate.score > threshold,
                  let label = cocoClassNames[candidate.classID] else { continue }
            let offset = candidate.query * 4
            guard boxes[offset..<(offset + 4)].allSatisfy(\.isFinite) else { continue }
            let centerX = boxes[offset]
            let centerY = boxes[offset + 1]
            let width = max(boxes[offset + 2], 0)
            let height = max(boxes[offset + 3], 0)
            let left = min(max(centerX - width / 2, 0), 1)
            let top = min(max(centerY - height / 2, 0), 1)
            let right = min(max(centerX + width / 2, 0), 1)
            let bottom = min(max(centerY + height / 2, 0), 1)
            detections.append(Detection(
                label: label,
                classID: candidate.classID,
                confidence: candidate.score,
                boundingBox: .init(
                    x: left,
                    y: top,
                    width: max(right - left, 0),
                    height: max(bottom - top, 0)
                )
            ))
            if detections.count == resultLimit { break }
        }
        return detections
    }

    // RF-DETR's pretrained COCO heads use sparse category IDs 1...90.
    public static let cocoClassNames: [Int: String] = [
        1: "person", 2: "bicycle", 3: "car", 4: "motorcycle", 5: "airplane",
        6: "bus", 7: "train", 8: "truck", 9: "boat", 10: "traffic light",
        11: "fire hydrant", 13: "stop sign", 14: "parking meter", 15: "bench",
        16: "bird", 17: "cat", 18: "dog", 19: "horse", 20: "sheep", 21: "cow",
        22: "elephant", 23: "bear", 24: "zebra", 25: "giraffe", 27: "backpack",
        28: "umbrella", 31: "handbag", 32: "tie", 33: "suitcase", 34: "frisbee",
        35: "skis", 36: "snowboard", 37: "sports ball", 38: "kite",
        39: "baseball bat", 40: "baseball glove", 41: "skateboard", 42: "surfboard",
        43: "tennis racket", 44: "bottle", 46: "wine glass", 47: "cup", 48: "fork",
        49: "knife", 50: "spoon", 51: "bowl", 52: "banana", 53: "apple",
        54: "sandwich", 55: "orange", 56: "broccoli", 57: "carrot", 58: "hot dog",
        59: "pizza", 60: "donut", 61: "cake", 62: "chair", 63: "couch",
        64: "potted plant", 65: "bed", 67: "dining table", 70: "toilet", 72: "tv",
        73: "laptop", 74: "mouse", 75: "remote", 76: "keyboard", 77: "cell phone",
        78: "microwave", 79: "oven", 80: "toaster", 81: "sink", 82: "refrigerator",
        84: "book", 85: "clock", 86: "vase", 87: "scissors", 88: "teddy bear",
        89: "hair drier", 90: "toothbrush",
    ]
}
