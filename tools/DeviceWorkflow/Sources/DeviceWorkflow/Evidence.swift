import Foundation
import CoreFoundation

public enum Evidence {
    public static let appID = "com.pietrocode.epubtomp3"
    public static let benchmarkTest = "DeviceConversionBenchmarkTests/testOptInDeviceConversionBenchmark"

    public static func find(_ value: Any, key: String) -> Any? {
        if let dictionary = value as? [String: Any] {
            if let result = dictionary[key] { return result }
            for child in dictionary.values { if let result = find(child, key: key) { return result } }
        } else if let array = value as? [Any] {
            for child in array { if let result = find(child, key: key) { return result } }
        }
        return nil
    }

    public static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(Int32.max) else { return nil }
        return number.intValue
    }

    public static func verifySummary(_ summary: [String: Any], benchmark: Bool) throws {
        guard summary["result"] as? String == "Passed",
              integer(summary["failedTests"]) == 0,
              let passed = integer(summary["passedTests"]), passed > 0,
              let skipped = integer(summary["skippedTests"]) else {
            throw WorkflowError("XCTest did not verify an executed passing test; inspect testWall.log and xcresult.")
        }
        guard !benchmark || (passed == 1 && skipped == 0) else {
            throw WorkflowError("Benchmark requires exactly one executed test and zero skips.")
        }
    }

    public static func configure(_ original: [String: Any], products: URL, spec: [String: Any]) throws -> [String: Any] {
        func expand(_ item: Any) -> Any {
            if let string = item as? String { return string.replacingOccurrences(of: "__TESTROOT__", with: products.path) }
            if let list = item as? [Any] { return list.map(expand) }
            if let dict = item as? [String: Any] { return dict.mapValues(expand) }
            return item
        }
        guard var result = expand(original) as? [String: Any],
              let metadata = result["__xctestrun_metadata__"] as? [String: Any],
              (metadata["FormatVersion"] as? NSNumber)?.intValue == 2,
              let configurations = result["TestConfigurations"] as? [[String: Any]] else {
            throw WorkflowError("Expected a version-2 xctestrun.")
        }
        for var configuration in configurations {
            guard let targets = configuration["TestTargets"] as? [[String: Any]],
                  var target = targets.first(where: { $0["BlueprintName"] as? String == "EpubToMp3Tests" }) else { continue }
            target["OnlyTestIdentifiers"] = [benchmarkTest]
            target.removeValue(forKey: "SkipTestIdentifiers")
            var environment = target["EnvironmentVariables"] as? [String: Any] ?? [:]
            environment["EPUB2MP3_DEVICE_BENCHMARK_SPEC"] = String(decoding: try JSONSerialization.data(withJSONObject: spec), as: UTF8.self)
            target["EnvironmentVariables"] = environment
            target["InProcessParallelizationEnabled"] = false
            target["TestTimeoutsEnabled"] = true
            target["UserAttachmentLifetime"] = "keepAlways"
            configuration["TestTargets"] = [target]
            configuration["IsEnabled"] = true
            result["TestConfigurations"] = [configuration]
            return result
        }
        throw WorkflowError("No EpubToMp3Tests target in xctestrun.")
    }

    public static func verifyHost(_ app: URL, identity: String) throws {
        guard identity.contains("Authority=Apple Development:") || identity.contains("Authority=Apple Distribution:") else {
            throw WorkflowError("Test host requires Apple Development/Distribution signing; ad-hoc is insufficient.")
        }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
        guard plist?["CFBundleIdentifier"] as? String == appID,
              plist?["CFBundleExecutable"] as? String == "EpubToMp3",
              FileManager.default.isReadableFile(atPath: app.appendingPathComponent("embedded.mobileprovision").path) else {
            throw WorkflowError("Unexpected test host bundle ID/executable or missing provisioning profile.")
        }
    }

    public static func verifyProfile(_ data: Data, udid: String, now: Date = Date()) throws {
        guard let profile = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let expiration = profile["ExpirationDate"] as? Date, expiration > now,
              let entitlements = profile["Entitlements"] as? [String: Any],
              let identifier = entitlements["application-identifier"] as? String,
              let teams = profile["TeamIdentifier"] as? [String],
              teams.contains(where: { identifier == $0 + "." + appID }) else {
            throw WorkflowError("Provisioning profile is expired or does not authorize the app bundle ID/team.")
        }
        guard profile["ProvisionsAllDevices"] as? Bool == true || (profile["ProvisionedDevices"] as? [String] ?? []).contains(udid) else {
            throw WorkflowError("Provisioning profile does not authorize the requested hardware UDID.")
        }
    }

    public static func verifyNative(_ native: [String: Any], runID: String, cases: [BenchmarkCase]) throws -> [String: Double] {
        guard integer(native["schemaVersion"]) == 1, native["runID"] as? String == runID,
              native["status"] as? String == "passed",
              let actual = native["cases"] as? [[String: Any]], actual.count == cases.count else {
            throw WorkflowError("Native evidence does not match the completed benchmark. \(failure(native))")
        }
        var synthesis = 0.0
        var verification = 0.0
        for (request, item) in zip(cases, actual) {
            guard item["bookPath"] as? String == request.bookPath,
                  (item["chapterStart"] as? NSNumber)?.intValue == request.start,
                  (item["chapterEnd"] as? NSNumber)?.intValue == request.end,
                  let count = integer(item["chaptersRequested"]), count > 0,
                  integer(item["chaptersCompleted"]) == count,
                  request.start == -1 || count == request.end - request.start + 1,
                  let cache = item["cacheReuse"] as? [String: Any], cache["audio"] as? Bool == false,
                  cache["parsedText"] as? String == "not_measured",
                  let characters = integer(item["characters"]), characters > 0,
                  let duration = item["audioDurationSeconds"] as? Double, duration.isFinite, duration > 0,
                  let s = item["synthesisSeconds"] as? Double, s.isFinite, s > 0,
                  let v = item["verificationSeconds"] as? Double, v.isFinite, v >= 0,
                  item["error"] == nil || item["error"] is NSNull else {
                throw WorkflowError("Native scope/count/cache/audio evidence differs from requested synthesis.")
            }
            synthesis += s
            verification += v
        }
        return ["synthesisSeconds": synthesis, "verificationSeconds": verification]
    }

    public static func failure(_ native: [String: Any]) -> String {
        let errors = ([native["error"] as? String].compactMap { $0 } + (native["errors"] as? [String] ?? [])).joined(separator: "\n")
        if errors.contains("os error 2") || errors.contains("OS error 2") {
            return "Native Rust conversion failed (ffprobe/ffmpeg OS error 2 baseline). \(errors)"
        }
        return errors
    }

    public static func attachment(_ directory: URL, runID: String) -> [String: Any]? {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let url as URL in files where url.pathExtension == "json" {
            if let data = try? DurableJSON.read(url), integer(data["schemaVersion"]) == 1, data["runID"] as? String == runID { return data }
        }
        return nil
    }
}
