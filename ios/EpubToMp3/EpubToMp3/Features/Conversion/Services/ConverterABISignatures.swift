import Foundation

typealias PlatformTtsCancelled = @convention(c) (UnsafeRawPointer?) -> Bool
typealias PlatformTtsCallback = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    PlatformTtsCancelled?, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, UInt32,
    UnsafeMutableRawPointer?
) -> Bool
typealias ConverterSetPlatformTts = @convention(c) (
    UnsafeMutableRawPointer?, PlatformTtsCallback?, UnsafeMutableRawPointer?
) -> Bool

typealias ConverterSessionOpen = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
typealias ConverterSessionMetadata = @convention(c) (UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
typealias ConverterSessionFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias ConverterChapterCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
typealias ConverterAudioChunkCallback = @convention(c) (
    Int, Int, UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?
) -> Bool
typealias ConverterJobControlCreate = @convention(c) () -> UnsafeMutableRawPointer?
typealias ConverterJobControlFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias ConverterJobControlCancel = @convention(c) (UnsafeRawPointer?) -> Void
typealias ConverterJobControlPrioritize = @convention(c) (UnsafeRawPointer?, Int) -> Bool
typealias ConverterJobControlWindow = @convention(c) (UnsafeRawPointer?, Int, Int) -> Void
typealias ConverterJobControlWindowContains = @convention(c) (UnsafeRawPointer?, Int) -> Bool
typealias ConverterJobControlJSON = @convention(c) (UnsafeRawPointer?, UnsafePointer<CChar>?) -> Bool
typealias ConverterJobControlGeneration = @convention(c) (UnsafeRawPointer?) -> UInt64
typealias ConverterSessionConvertJob = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32,
    ConverterChapterCallback?, ConverterChapterCallback?, UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?
typealias ConverterSessionConvertJobOptionsV1 = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32,
    ConverterChapterCallback?, ConverterChapterCallback?, UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?
typealias ConverterSessionConvertStreamingJob = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32,
    ConverterChapterCallback?, ConverterChapterCallback?, ConverterAudioChunkCallback?,
    UnsafeMutableRawPointer?, UnsafeRawPointer?
) -> UnsafeMutablePointer<CChar>?
typealias ConverterSessionConvertStreamingJobOptionsV1 = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32,
    ConverterChapterCallback?, ConverterChapterCallback?, ConverterAudioChunkCallback?,
    UnsafeMutableRawPointer?, UnsafeRawPointer?
) -> UnsafeMutablePointer<CChar>?
typealias ConverterSessionConvert = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, Int32, Int32
) -> UnsafeMutablePointer<CChar>?
typealias ConverterStringFree = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
typealias ConverterLastError = @convention(c) () -> UnsafeMutablePointer<CChar>?
typealias ConverterOptionsValidateV1 = @convention(c) (UnsafePointer<CChar>?) -> Bool
typealias ConverterTtsModels = @convention(c) () -> UnsafeMutablePointer<CChar>?
typealias ConverterTtsCatalogV3 = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?
typealias ConverterTtsCatalogProbeV3 = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?
typealias ConverterTtsDefaultEngine = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32) -> UnsafeMutablePointer<CChar>?
typealias ConverterTtsInstalledReadyEngine = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias ConverterTtsModelInstall = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias ConverterTtsModelRemove = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Bool
typealias ConverterTtsModelMetadata = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias ConverterTtsModelInstallManifest = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias ConverterTtsModelInstallCatalogManifest = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias ConverterModelInstallOperationCreate = @convention(c) (
    UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt64
) -> UnsafeMutableRawPointer?
typealias ConverterModelInstallOperationRecover = ConverterModelInstallOperationCreate
typealias ConverterModelInstallOperationJSON = @convention(c) (
    UnsafeRawPointer?
) -> UnsafeMutablePointer<CChar>?
typealias ConverterModelInstallOperationProgress = @convention(c) (
    UnsafeRawPointer?, Int, UInt64
) -> Bool
typealias ConverterModelInstallOperationAccept = @convention(c) (
    UnsafeRawPointer?, Int, UnsafePointer<CChar>?
) -> Bool
typealias ConverterModelInstallOperationPublish = @convention(c) (
    UnsafeRawPointer?
) -> UnsafeMutablePointer<CChar>?
typealias ConverterModelInstallOperationFail = @convention(c) (
    UnsafeRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Bool
typealias ConverterModelInstallOperationCancel = @convention(c) (UnsafeRawPointer?) -> Void
typealias ConverterModelInstallOperationFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
