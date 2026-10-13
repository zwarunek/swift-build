//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import Foundation

extension ProcessInfo {
    /// The number of processors this process can actually run on.
    ///
    /// On Linux, `activeProcessorCount` only reads cgroup v1 quota files and otherwise returns every online
    /// processor of the host. In a container on a large host (cgroup v2, a CPU affinity mask, a CPU quota) that can
    /// be many times the processors the build may use. This also takes the affinity mask and the cgroup v1 or v2
    /// CPU quota into account. Elsewhere it is `activeProcessorCount`.
    public var usableProcessorCount: Int {
        #if os(Linux)
        return Self.usableProcessorCount(
            online: activeProcessorCount,
            affinityList: Self.firstLine(ofFile: "/proc/self/status", withPrefix: "Cpus_allowed_list:"),
            procSelfCgroup: try? String(contentsOfFile: "/proc/self/cgroup", encoding: .utf8),
            readCgroupFile: { try? String(contentsOfFile: $0, encoding: .utf8) })
        #else
        return activeProcessorCount
        #endif
    }

    /// Combines the online processor count with the affinity list and cgroup CPU quota of a Linux process.
    ///
    /// - Parameters:
    ///   - online: the online processor count.
    ///   - affinityList: the `Cpus_allowed_list` value from `/proc/self/status`, for example `1-25,52-77`.
    ///   - procSelfCgroup: the contents of `/proc/self/cgroup`.
    ///   - readCgroupFile: reads a file below `/sys/fs/cgroup`.
    package static func usableProcessorCount(online: Int, affinityList: String?, procSelfCgroup: String?, readCgroupFile: (String) -> String?) -> Int {
        var count = max(online, 1)
        if let affinity = affinityList.flatMap(processorCount(cpuList:)) {
            count = min(count, affinity)
        }
        if let quota = cgroupCPUQuota(procSelfCgroup: procSelfCgroup, readCgroupFile: readCgroupFile) {
            count = min(count, quota)
        }
        return max(count, 1)
    }

    /// Counts the processors in a Linux CPU list such as `0-3,8,10-11`.
    package static func processorCount(cpuList: String) -> Int? {
        var count = 0
        for range in cpuList.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",") {
            let bounds = range.split(separator: "-", maxSplits: 1).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch bounds.count {
            case 1:
                guard bounds[0] != nil else { return nil }
                count += 1
            case 2:
                guard let first = bounds[0], let last = bounds[1], last >= first else { return nil }
                count += last - first + 1
            default:
                return nil
            }
        }
        return count > 0 ? count : nil
    }

    /// Converts a cgroup v2 `cpu.max` value (`<quota> <period>` or `max <period>`) to a processor count, rounding up.
    package static func processorCount(cgroupCPUMax: String) -> Int? {
        let fields = cgroupCPUMax.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count >= 2, let quota = Int(fields[0]), let period = Int(fields[1]) else { return nil }
        return processorCount(quota: quota, period: period)
    }

    /// Converts a CFS quota and period (cgroup v1 `cpu.cfs_quota_us` and `cpu.cfs_period_us`) to a processor count.
    package static func processorCount(quota: Int, period: Int) -> Int? {
        guard quota > 0, period > 0 else { return nil }
        return max((quota + period - 1) / period, 1)
    }

    /// The smallest CPU quota on the process's cgroup v2 path (each ancestor can limit it), or the cgroup v1 quota.
    package static func cgroupCPUQuota(procSelfCgroup: String?, readCgroupFile: (String) -> String?) -> Int? {
        let lines = procSelfCgroup?.split(separator: "\n") ?? []
        if let unified = lines.first(where: { $0.hasPrefix("0::") }) {
            var path = String(unified.dropFirst(3))
            var result: Int?
            while true {
                let dir = path == "/" || path.isEmpty ? "/sys/fs/cgroup" : "/sys/fs/cgroup" + path
                if let count = readCgroupFile(dir + "/cpu.max").flatMap(processorCount(cgroupCPUMax:)) {
                    result = min(result ?? count, count)
                }
                guard let slash = path.lastIndex(of: "/"), path != "/" else { break }
                path = slash == path.startIndex ? "/" : String(path[..<slash])
            }
            if result != nil {
                return result
            }
        }
        if let quota = readCgroupFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us").flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
           let period = readCgroupFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us").flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            return processorCount(quota: quota, period: period)
        }
        return nil
    }

    private static func firstLine(ofFile path: String, withPrefix prefix: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }
}
