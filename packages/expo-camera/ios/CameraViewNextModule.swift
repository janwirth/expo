// Copyright 2022-present 650 Industries. All rights reserved.

import AVFoundation
import ExpoModulesCore
import VisionKit

let cameraNextEvents = ["onCameraReady", "onMountError", "onPictureSaved", "onBarcodeScanned", "onResponsiveOrientationChanged"]

struct ScannerContext {
  var controller: Any?
  var delegate: Any?
}

public final class CameraViewNextModule: Module, ScannerResultHandler {
  private var scannerContext: ScannerContext?

  public func definition() -> ModuleDefinition {
    Name("ExpoCameraNext")

    Events("onModernBarcodeScanned")

    OnCreate {
      let permissionsManager = self.appContext?.permissions
      EXPermissionsMethodsDelegate.register(
        [
          CameraPermissionRequester(),
          CameraOnlyPermissionRequester(),
          CameraMicrophonePermissionRequester()
        ],
        withPermissionsManager: permissionsManager
      )
    }

    Property("isModernBarcodeScannerAvailable") { () -> Bool in
      if #available(iOS 16.0, *) {
        return true
      }
      return false
    }

    // swiftlint:disable:next closure_body_length
    View(CameraViewNext.self) {
      Events(cameraNextEvents)

      Prop("facing") { (view, type: CameraTypeNext?) in
        if let type, view.presetCamera != type.toPosition() {
          view.presetCamera = type.toPosition()
        }
      }

      Prop("flashMode") { (view, flashMode: CameraFlashModeNext?) in
        if let flashMode, view.flashMode != flashMode {
          view.flashMode = flashMode
        }
      }

      Prop("enableTorch") { (view, enabled: Bool?) in
        view.torchEnabled = enabled ?? false
      }

      Prop("pictureSize") { (view, pictureSize: PictureSize?) in
        if let pictureSize, view.pictureSize != pictureSize {
          view.pictureSize = pictureSize
        }
      }

      Prop("zoom") { (view, zoom: Double?) in
        if let zoom, fabs(view.zoom - zoom) > Double.ulpOfOne {
          view.zoom = zoom
        }
      }

      Prop("mode") { (view, mode: CameraModeNext?) in
        if let mode, view.mode != mode {
          view.mode = mode
        }
      }

      Prop("barcodeScannerEnabled") { (view, scanBarcodes: Bool?) in
        if let scanBarcodes, view.isScanningBarcodes != scanBarcodes {
          view.isScanningBarcodes = scanBarcodes
        }
      }

      Prop("barcodeScannerSettings") { (view, settings: BarcodeSettings?) in
        if let settings {
          view.setBarcodeScannerSettings(settings: settings)
        }
      }

      Prop("mute") { (view, muted: Bool?) in
        if let muted, view.isMuted != muted {
          view.isMuted = muted
        }
      }

      Prop("videoQuality") { (view, quality: VideoQuality?) in
        if let quality, view.videoQuality != quality {
          view.videoQuality = quality
        }
      }

      Prop("responsiveOrientationWhenOrientationLocked") { (view, responsiveOrientation: Bool?) in
        if let responsiveOrientation, view.responsiveWhenOrientationLocked != responsiveOrientation {
          view.responsiveWhenOrientationLocked = responsiveOrientation
        }
      }

      AsyncFunction("getAvailablePictureSizes") { (_: String?) in
        return PictureSize.allCases.map {
          $0.rawValue
        }
      }

      AsyncFunction("takePicture") { (view, options: TakePictureOptionsNext, promise: Promise) in
        #if targetEnvironment(simulator)
        try takePictureForSimulator(self.appContext, view, options, promise)
        #else // simulator
        view.takePicture(options: options, promise: promise)
        #endif // not simulator
      }.runOnQueue(.main)

      AsyncFunction("record") { (view, options: CameraRecordingOptionsNext, promise: Promise) in
        #if targetEnvironment(simulator)
        throw Exceptions.SimulatorNotSupported()
        #else
        view.record(options: options, promise: promise)
        #endif
      }.runOnQueue(.main)

      AsyncFunction("stopRecording") { view in
        #if targetEnvironment(simulator)
        throw Exceptions.SimulatorNotSupported()
        #else
        view.stopRecording()
        #endif
      }.runOnQueue(.main)
    }

    AsyncFunction("launchScanner") { (options: VisionScannerOptions?) in
      if #available(iOS 16.0, *) {
        try await MainActor.run {
          let delegate = VisionScannerDelegate(handler: self)
          scannerContext = ScannerContext(delegate: delegate)
          launchScanner(with: options)
        }
      }
    }

    AsyncFunction("dismissScanner") {
      if #available(iOS 16.0, *) {
        await MainActor.run {
          dismissScanner()
        }
      }
    }

    AsyncFunction("getCameraPermissionsAsync") { (promise: Promise) in
      EXPermissionsMethodsDelegate.getPermissionWithPermissionsManager(
        self.appContext?.permissions,
        withRequester: CameraOnlyPermissionRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("requestCameraPermissionsAsync") { (promise: Promise) in
      EXPermissionsMethodsDelegate.askForPermission(
        withPermissionsManager: self.appContext?.permissions,
        withRequester: CameraOnlyPermissionRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("getMicrophonePermissionsAsync") { (promise: Promise) in
      EXPermissionsMethodsDelegate.getPermissionWithPermissionsManager(
        self.appContext?.permissions,
        withRequester: CameraMicrophonePermissionRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("requestMicrophonePermissionsAsync") { (promise: Promise) in
      EXPermissionsMethodsDelegate.askForPermission(
        withPermissionsManager: self.appContext?.permissions,
        withRequester: CameraMicrophonePermissionRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("getAvailableVideoCodecsAsync") { () -> [String] in
      return getAvailableVideoCodecs()
    }
  }

  @available(iOS 16.0, *)
  @MainActor
  private func launchScanner(with options: VisionScannerOptions?) {
    let symbologies = options?.toSymbology() ?? [.qr]
    let controller = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: symbologies)],
      isPinchToZoomEnabled: options?.isPinchToZoomEnabled ?? true,
      isGuidanceEnabled: options?.isGuidanceEnabled ?? true,
      isHighlightingEnabled: options?.isHighlightingEnabled ?? false
    )

    scannerContext?.controller = controller
    if let delegate = scannerContext?.delegate as? VisionScannerDelegate {
      controller.delegate = delegate
    }

    appContext?.utilities?.currentViewController()?.present(controller, animated: true) {
      try? controller.startScanning()
    }
  }

  @available(iOS 16.0, *)
  @MainActor
  private func dismissScanner() {
    guard let controller = scannerContext?.controller as? DataScannerViewController else {
      return
    }
    controller.stopScanning()
    controller.dismiss(animated: true)
  }

  func onItemScanned(result: [String: Any]) {
    sendEvent("onModernBarcodeScanned", result)
  }

  private func getAvailableVideoCodecs() -> [String] {
    let session = AVCaptureSession()

    session.beginConfiguration()

    guard let captureDevice = ExpoCameraUtils.device(
      with: AVMediaType.video,
      preferring: AVCaptureDevice.Position.front) else {
      return []
    }
    guard let deviceInput = try? AVCaptureDeviceInput(device: captureDevice) else {
      return []
    }
    if session.canAddInput(deviceInput) {
      session.addInput(deviceInput)
    }

    session.commitConfiguration()

    let movieFileOutput = AVCaptureMovieFileOutput()

    if session.canAddOutput(movieFileOutput) {
      session.addOutput(movieFileOutput)
    }
    return movieFileOutput.availableVideoCodecTypes.map { $0.rawValue }
  }
}

private func takePictureForSimulator(
  _ appContext: AppContext?,
  _ view: CameraView,
  _ options: TakePictureOptionsNext,
  _ promise: Promise
) throws {
  if options.fastMode {
    promise.resolve()
  }
  let result = try generatePictureForSimulator(appContext: appContext, options: options)

  if options.fastMode {
    view.onPictureSaved([
      "data": result,
      "id": options.id
    ])
  } else {
    promise.resolve(result)
  }
}

private func generatePictureForSimulator(
  appContext: AppContext?,
  options: TakePictureOptionsNext
) throws -> [String: Any?] {
  let path = FileSystemUtilities.generatePathInCache(
    appContext,
    in: "Camera",
    extension: ".jpg"
  )

  let generatedPhoto = ExpoCameraUtilsNext.generatePhoto(of: CGSize(width: 200, height: 200))
  guard let photoData = generatedPhoto.jpegData(compressionQuality: options.quality) else {
    throw CameraInvalidPhotoData()
  }

  return [
    "uri": ExpoCameraUtils.write(data: photoData, to: path),
    "width": generatedPhoto.size.width,
    "height": generatedPhoto.size.height,
    "base64": options.base64 ? photoData.base64EncodedString() : nil
  ]
}
