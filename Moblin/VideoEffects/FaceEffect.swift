import AVFoundation
import MetalPetal
import UIKit
import Vision

struct FaceEffectSettings {
    var crop = true
    var showBlur = true
    var showColors = true
    var showMoblin = true
    var showFaceLandmarks = true
    var contrast: Float = 1.0
    var brightness: Float = 0.0
    var saturation: Float = 1.0
    var showBeauty = true
    var shapeRadius: Float = 0.5
    var shapeScale: Float = 0.5
    var shapeOffset: Float = 0.5
    var smoothAmount: Float = 0.65
    var smoothRadius: Float = 20.0
}

private let cropScaleDownFactor = 0.8

final class FaceEffect: VideoEffect {
    var safeSettings = Atomic<FaceEffectSettings>(.init())
    private var settings = FaceEffectSettings()
    let moblinImage: CIImage?
    private var findFace = false
    private var onFindFaceChanged: ((Bool) -> Void)?
    private var shapeScaleFactor: Float = 0.0
    private var lastFaceDetections: [VNFaceObservation] = []
    private var framesPerFade: Float = 30

    init(fps: Float) {
        framesPerFade = 15 * (fps / 30)
        if let image = UIImage(named: "AppIconNoBackground"), let image = image.cgImage {
            moblinImage = CIImage(cgImage: image)
        } else {
            moblinImage = nil
        }
        super.init()
    }

    convenience init(fps: Float, onFindFaceChanged: @escaping (Bool) -> Void) {
        self.init(fps: fps)
        self.onFindFaceChanged = onFindFaceChanged
    }

    override func getName() -> String {
        return "face filter"
    }

    override func needsFaceDetections() -> Bool {
        return true
    }

    private func isBeautyEnabled() -> Bool {
        return settings.showBeauty && (settings.shapeScale > 0 || settings.smoothAmount > 0)
    }

    private func findFaceNeeded() -> Bool {
        return settings.showBeauty && settings.shapeScale > 0
    }

    private func updateFindFace(_ faceDetections: [VNFaceObservation]?) {
        if findFace {
            if findFaceNeeded() {
                if let faceDetections, !faceDetections.isEmpty {
                    findFace = false
                    onFindFaceChanged?(findFace)
                }
            } else {
                findFace = false
                onFindFaceChanged?(findFace)
            }
        } else {
            if findFaceNeeded() {
                if let faceDetections, faceDetections.isEmpty {
                    findFace = true
                    onFindFaceChanged?(findFace)
                }
            }
        }
    }

    private func createFacesMaskImage(imageExtent: CGRect, detections: [VNFaceObservation]) -> CIImage? {
        var facesMask = CIImage.empty().cropped(to: imageExtent)
        for detection in detections {
            let faceBoundingBox = CGRect(x: detection.boundingBox.minX * imageExtent.width,
                                         y: detection.boundingBox.minY * imageExtent.height,
                                         width: detection.boundingBox.width * imageExtent.width,
                                         height: detection.boundingBox.height * imageExtent.height)
            let faceCenter = CGPoint(x: faceBoundingBox.maxX - (faceBoundingBox.width / 2),
                                     y: faceBoundingBox.maxY - (faceBoundingBox.height / 2))
            let faceMask = CIFilter.radialGradient()
            faceMask.center = faceCenter
            faceMask.radius0 = Float(faceBoundingBox.height / 2)
            faceMask.radius1 = Float(faceBoundingBox.height)
            faceMask.color0 = CIColor.white
            faceMask.color1 = CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
            guard let faceMask = faceMask.outputImage?.cropped(to: faceBoundingBox.insetBy(
                dx: -faceBoundingBox.width / 2,
                dy: -faceBoundingBox.height / 2
            )) else {
                continue
            }
            facesMask = faceMask.composited(over: facesMask)
        }
        return facesMask
    }

    private func adjustColorControls(image: CIImage?) -> CIImage? {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = settings.brightness
        filter.contrast = settings.contrast
        filter.saturation = settings.saturation
        return filter.outputImage
    }

    private func adjustColors(image: CIImage?) -> CIImage? {
        return adjustColorControls(image: image)
    }

    private func applyBlur(image: CIImage?) -> CIImage? {
        guard let image else {
            return image
        }
        return image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: image.extent.width / 50.0)
            .cropped(to: image.extent)
    }

    private func applyFacesMask(backgroundImage: CIImage?, image: CIImage?,
                                detections: [VNFaceObservation]?) -> CIImage?
    {
        guard let image, let detections else {
            return image
        }
        let faceBlender = CIFilter.blendWithMask()
        faceBlender.inputImage = image
        faceBlender.backgroundImage = backgroundImage
        faceBlender.maskImage = createFacesMaskImage(imageExtent: image.extent, detections: detections)
        return faceBlender.outputImage
    }

    private func addMoblin(image: CIImage?, detections: [VNFaceObservation]?) -> CIImage? {
        guard let image, let detections, let moblinImage else {
            return image
        }
        var outputImage = image
        for detection in detections {
            guard let innerLips = detection.landmarks?.innerLips else {
                continue
            }
            let points = innerLips.pointsInImage(imageSize: image.extent.size)
            guard let firstPoint = points.first else {
                continue
            }
            var minX = firstPoint.x
            var maxX = firstPoint.x
            var minY = firstPoint.y
            var maxY = firstPoint.y
            for point in points {
                minX = min(point.x, minX)
                maxX = max(point.x, maxX)
                minY = min(point.y, minY)
                maxY = max(point.y, maxY)
            }
            let diffX = maxX - minX
            let diffY = maxY - minY
            if diffY <= diffX {
                continue
            }
            let moblinImage = moblinImage
                .transformed(by: CGAffineTransform(
                    scaleX: diffX / moblinImage.extent.width,
                    y: diffX / moblinImage.extent.width
                ))
            let offsetY = minY + (diffY - moblinImage.extent.height) / 2
            outputImage = moblinImage
                .transformed(by: CGAffineTransform(translationX: minX, y: offsetY))
                .composited(over: outputImage)
        }
        return outputImage.cropped(to: image.extent)
    }

    private func createMesh(landmark: VNFaceLandmarkRegion2D?, image: CIImage?) -> [CIVector] {
        guard let landmark, let image else {
            return []
        }
        var mesh: [CIVector] = []
        let points = landmark.pointsInImage(imageSize: image.extent.size)
        switch landmark.pointsClassification {
        case .closedPath:
            for i in 0 ..< landmark.pointCount {
                let j = (i + 1) % landmark.pointCount
                mesh.append(CIVector(x: points[i].x,
                                     y: points[i].y,
                                     z: points[j].x,
                                     w: points[j].y))
            }
        case .openPath:
            for i in 0 ..< landmark.pointCount - 1 {
                mesh.append(CIVector(x: points[i].x,
                                     y: points[i].y,
                                     z: points[i + 1].x,
                                     w: points[i + 1].y))
            }
        case .disconnected:
            for i in 0 ..< landmark.pointCount - 1 {
                mesh.append(CIVector(x: points[i].x,
                                     y: points[i].y,
                                     z: points[i + 1].x,
                                     w: points[i + 1].y))
            }
        }
        return mesh
    }

    private func addBeauty(image: CIImage?, detections: [VNFaceObservation]?) -> CIImage? {
        guard let image, let detections else {
            return image
        }
        var outputImage: CIImage? = image
        for detection in detections {
            if let medianLine = detection.landmarks?.medianLine {
                let points = medianLine.pointsInImage(imageSize: image.extent.size)
                guard let firstPoint = points.first, let lastPoint = points.last else {
                    continue
                }
                let maxY = firstPoint.y
                let minY = lastPoint.y
                let centerX = lastPoint.x
                let filter = CIFilter.bumpDistortion()
                filter.inputImage = outputImage
                filter.center = CGPoint(
                    x: centerX,
                    y: minY + CGFloat(Float(maxY - minY) * (settings.shapeOffset * 0.15 + 0.35))
                )
                filter.radius = Float(maxY - minY) * (0.75 + settings.shapeRadius * 0.15)
                filter.scale = -(settings.shapeScale * 0.15)
                outputImage = filter.outputImage
            }
        }
        return outputImage?.cropped(to: image.extent)
    }

    private func addFaceLandmarks(image: CIImage?, detections: [VNFaceObservation]?) -> CIImage? {
        guard let image, let detections else {
            return image
        }
        var mesh: [CIVector] = []
        for detection in detections {
            guard let landmarks = detection.landmarks else {
                continue
            }
            mesh += createMesh(landmark: landmarks.faceContour, image: image)
            mesh += createMesh(landmark: landmarks.outerLips, image: image)
            mesh += createMesh(landmark: landmarks.innerLips, image: image)
            mesh += createMesh(landmark: landmarks.leftEye, image: image)
            mesh += createMesh(landmark: landmarks.rightEye, image: image)
            mesh += createMesh(landmark: landmarks.nose, image: image)
            mesh += createMesh(landmark: landmarks.medianLine, image: image)
            mesh += createMesh(landmark: landmarks.leftEyebrow, image: image)
            mesh += createMesh(landmark: landmarks.rightEyebrow, image: image)
        }
        let filter = CIFilter.meshGenerator()
        filter.color = .green
        filter.width = 3
        filter.mesh = mesh
        guard let outputImage = filter.outputImage else {
            return image
        }
        return outputImage.composited(over: image).cropped(to: image.extent)
    }

    private func loadSettings() {
        settings = safeSettings.value
    }

    override func execute(_ image: CIImage, _ faceDetections: [VNFaceObservation]?) -> CIImage {
        loadSettings()
        updateFindFace(faceDetections)
        updateScaleFactors(faceDetections)
        guard let faceDetections else {
            return image
        }
        var outputImage: CIImage? = image
        if settings.showColors {
            outputImage = adjustColors(image: outputImage)
        }
        if settings.showBlur {
            outputImage = applyBlur(image: outputImage)
        }
        if outputImage != image {
            outputImage = applyFacesMask(
                backgroundImage: image,
                image: outputImage,
                detections: faceDetections
            )
        }
        if settings.showMoblin {
            outputImage = addMoblin(image: outputImage, detections: faceDetections)
        }
        if settings.showBeauty {
            outputImage = addBeauty(image: outputImage, detections: faceDetections)
        }
        if settings.showFaceLandmarks {
            outputImage = addFaceLandmarks(image: outputImage, detections: faceDetections)
        }
        if settings.crop {
            let width = image.extent.width
            let height = image.extent.height
            let scaleUpFactor = 1 / cropScaleDownFactor
            let smallWidth = width * cropScaleDownFactor
            let smallHeight = height * cropScaleDownFactor
            let smallOffsetX = (width - smallWidth) / 2
            let smallOffsetY = (height - smallHeight) / 2
            outputImage = outputImage?
                .cropped(to: CGRect(x: smallOffsetX, y: smallOffsetY, width: smallWidth, height: smallHeight))
                .transformed(by: CGAffineTransform(translationX: -smallOffsetX, y: -smallOffsetY))
                .transformed(by: CGAffineTransform(scaleX: scaleUpFactor, y: scaleUpFactor))
                .cropped(to: image.extent)
        }
        lastFaceDetections = faceDetections
        return outputImage ?? image
    }

    private func addBeautyMetalPetal(_ image: MTIImage?, _ detections: [VNFaceObservation]?) -> MTIImage? {
        var image = image
        if settings.smoothAmount > 0 {
            image = addBeautySmoothMetalPetal(image)
        }
        if settings.shapeScale > 0 {
            image = addBeautyShapeMetalPetal(image, detections)
        }
        return image
    }

    private func addBeautySmoothMetalPetal(_ image: MTIImage?) -> MTIImage? {
        let filter = MTIHighPassSkinSmoothingFilter()
        filter.amount = settings.smoothAmount
        filter.radius = settings.smoothRadius
        filter.inputImage = image
        return filter.outputImage
    }

    private func addBeautyShapeMetalPetal(_ image: MTIImage?,
                                          _ detections: [VNFaceObservation]?) -> MTIImage?
    {
        guard let image, var detections else {
            return nil
        }
        if detections.isEmpty {
            detections = lastFaceDetections
        }
        var outputImage: MTIImage? = image
        for detection in detections {
            if let medianLine = detection.landmarks?.medianLine {
                let points = medianLine.pointsInImage(imageSize: image.extent.size)
                guard let firstPoint = points.first, let lastPoint = points.last else {
                    continue
                }
                let maxY = Float(firstPoint.y)
                let minY = Float(lastPoint.y)
                let centerX = Float(lastPoint.x)
                let filter = MTIBulgeDistortionFilter()
                let y = Float(image.size.height) -
                    (minY + (maxY - minY) * (settings.shapeOffset * 0.15 + 0.35))
                filter.inputImage = outputImage
                filter.center = .init(x: centerX, y: y)
                filter.radius = (maxY - minY) * (0.6 + settings.shapeRadius * 0.15)
                filter.scale = shapeScale()
                outputImage = filter.outputImage
            }
        }
        return outputImage
    }

    private func shapeScale() -> Float {
        return -(settings.shapeScale * 0.075) * shapeScaleFactor
    }

    private func increaseShapeScaleFactor() {
        shapeScaleFactor = min(shapeScaleFactor + (1.0 / framesPerFade), 1)
        if shapeScaleFactor != 1 {
            logger.info("\(shapeScaleFactor)")
        }
    }

    private func decreaseShapeScaleFactor() {
        shapeScaleFactor = max(shapeScaleFactor - (1.0 / framesPerFade), 0)
        if shapeScaleFactor != 0 {
            logger.info("\(shapeScaleFactor)")
        }
    }

    private func updateScaleFactors(_ detections: [VNFaceObservation]?) {
        if detections?.isEmpty ?? true {
            decreaseShapeScaleFactor()
        } else {
            increaseShapeScaleFactor()
        }
    }

    override func executeMetalPetal(_ image: MTIImage?, _ faceDetections: [VNFaceObservation]?) -> MTIImage? {
        updateFindFace(faceDetections)
        updateScaleFactors(faceDetections)
        var outputImage = image
        guard let image else {
            return nil
        }
        if settings.showBeauty {
            outputImage = addBeautyMetalPetal(outputImage, faceDetections)
        }
        if settings.crop {
            let width = image.extent.width
            let height = image.extent.height
            let smallWidth = width * cropScaleDownFactor
            let smallHeight = height * cropScaleDownFactor
            let smallOffsetX = (width - smallWidth) / 2
            let smallOffsetY = (height - smallHeight) / 2
            outputImage = outputImage?
                .cropped(to: CGRect(
                    x: smallOffsetX,
                    y: smallOffsetY,
                    width: smallWidth,
                    height: smallHeight
                ))?
                .resized(to: image.size)
        }
        if let faceDetections, !faceDetections.isEmpty {
            lastFaceDetections = faceDetections
        }
        return outputImage
    }

    override func supportsMetalPetal() -> Bool {
        // Do not load again for this frame as settings may not change from calling this function to
        // executing.
        loadSettings()
        return isBeautyEnabled() || settings.crop
    }

    override func removed() {
        findFace = false
        onFindFaceChanged?(findFace)
    }
}
