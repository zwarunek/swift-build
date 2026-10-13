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

import Foundation
import Testing
import SWBUtil

@Suite fileprivate struct ProcessorCountTests {
    @Test func cpuLists() {
        #expect(ProcessInfo.processorCount(cpuList: "0") == 1)
        #expect(ProcessInfo.processorCount(cpuList: "0-7") == 8)
        #expect(ProcessInfo.processorCount(cpuList: "40-43,104-107\n") == 8)
        #expect(ProcessInfo.processorCount(cpuList: "1-25,52-77") == 51)
        #expect(ProcessInfo.processorCount(cpuList: "0,2,4-5") == 4)
        #expect(ProcessInfo.processorCount(cpuList: "") == nil)
        #expect(ProcessInfo.processorCount(cpuList: "3-1") == nil)
        #expect(ProcessInfo.processorCount(cpuList: "a-b") == nil)
    }

    @Test func cgroupV2CPUMax() {
        #expect(ProcessInfo.processorCount(cgroupCPUMax: "3200000 100000\n") == 32)
        #expect(ProcessInfo.processorCount(cgroupCPUMax: "150000 100000") == 2)
        #expect(ProcessInfo.processorCount(cgroupCPUMax: "50000 100000") == 1)
        #expect(ProcessInfo.processorCount(cgroupCPUMax: "max 100000") == nil)
        #expect(ProcessInfo.processorCount(cgroupCPUMax: "") == nil)
    }

    @Test func cgroupV2Hierarchy() {
        let files = [
            "/sys/fs/cgroup/kubepods/pod1/cpu.max": "max 100000",
            "/sys/fs/cgroup/kubepods/cpu.max": "400000 100000",
        ]
        let quota = ProcessInfo.cgroupCPUQuota(procSelfCgroup: "0::/kubepods/pod1\n", readCgroupFile: { files[$0] })
        #expect(quota == 4)
        let namespaced = ProcessInfo.cgroupCPUQuota(procSelfCgroup: "0::/\n", readCgroupFile: { $0 == "/sys/fs/cgroup/cpu.max" ? "800000 100000" : nil })
        #expect(namespaced == 8)
        #expect(ProcessInfo.cgroupCPUQuota(procSelfCgroup: "0::/\n", readCgroupFile: { _ in nil }) == nil)
    }

    @Test func cgroupV1() {
        let files = [
            "/sys/fs/cgroup/cpu/cpu.cfs_quota_us": "600000\n",
            "/sys/fs/cgroup/cpu/cpu.cfs_period_us": "100000\n",
        ]
        #expect(ProcessInfo.cgroupCPUQuota(procSelfCgroup: "4:cpu,cpuacct:/docker/abc\n", readCgroupFile: { files[$0] }) == 6)
        #expect(ProcessInfo.cgroupCPUQuota(procSelfCgroup: nil, readCgroupFile: { $0.hasSuffix("quota_us") ? "-1" : "100000" }) == nil)
    }

    @Test func smallestLimitWins() {
        let quota32 = { (path: String) -> String? in path == "/sys/fs/cgroup/cpu.max" ? "3200000 100000" : nil }
        // Affinity narrower than the quota (a pod pinned to 8 processors with a 32-processor quota).
        #expect(ProcessInfo.usableProcessorCount(online: 128, affinityList: "40-43,104-107", procSelfCgroup: "0::/", readCgroupFile: quota32) == 8)
        // Quota narrower than the affinity.
        #expect(ProcessInfo.usableProcessorCount(online: 104, affinityList: "1-25,52-77", procSelfCgroup: "0::/", readCgroupFile: quota32) == 32)
        // Nothing known beyond the online count.
        #expect(ProcessInfo.usableProcessorCount(online: 16, affinityList: nil, procSelfCgroup: nil, readCgroupFile: { _ in nil }) == 16)
        #expect(ProcessInfo.usableProcessorCount(online: 0, affinityList: nil, procSelfCgroup: nil, readCgroupFile: { _ in nil }) == 1)
    }

    @Test func currentProcess() {
        let count = ProcessInfo.processInfo.usableProcessorCount
        #expect(count >= 1)
        #expect(count <= ProcessInfo.processInfo.activeProcessorCount)
    }
}
