public struct QEMUArguments: Sendable {
    public let memory: String
    public let cpuCount: Int
    public let maxCPUCount: Int
    public let kernelPath: String
    public let initrdPath: String
    public let diskPath: String
    public let networkBackend: String

    public init(
        memory: String,
        cpuCount: Int,
        maxCPUCount: Int,
        kernelPath: String,
        initrdPath: String,
        diskPath: String,
        networkBackend: String
    ) {
        self.memory = memory
        self.cpuCount = cpuCount
        self.maxCPUCount = maxCPUCount
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.diskPath = diskPath
        self.networkBackend = networkBackend
    }

    public var values: [String] {
        [
            "-m", memory,
            "-device", "virtio-net-pci,id=net1,netdev=net0",
            "-netdev", networkBackend,
            "-cpu", "Haswell-v4,-pcid,-tsc-deadline,-invpcid,-spec-ctrl",
            "-smp", "cpus=\(cpuCount),maxcpus=\(maxCPUCount),sockets=1,cores=\(maxCPUCount),threads=1",
            "-device", "virtio-blk-pci,id=disk1,drive=drive1,num-queues=\(maxCPUCount)",
            "-drive", "media=disk,id=drive1,if=none,file=\(diskPath),discard=unmap,detect-zeroes=unmap",
            "-kernel", kernelPath,
            "-initrd", initrdPath,
        ]
    }
}
