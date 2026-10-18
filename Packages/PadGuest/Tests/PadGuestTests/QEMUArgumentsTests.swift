import PadGuest
import Testing

@Test func qemuArgumentsMatchIPadLauncherOptionOrder() {
    let arguments = QEMUArguments(
        memory: "1G",
        cpuCount: 2,
        maxCPUCount: 4,
        kernelPath: "/guest/bzImage",
        initrdPath: "/guest/initrd.img",
        diskPath: "/guest/root.img",
        networkBackend: "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp:127.0.0.1:10022-:22"
    )

    #expect(
        arguments.values == [
            "-M", "pc",
            "-m", "1G",
            "-device", "virtio-net-pci,id=net1,netdev=net0",
            "-netdev", "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp:127.0.0.1:10022-:22",
            "-device", "virtio-rng-pci",
            "-append", "tcti_disk=file console=ttyS0",
            "-cpu", "Haswell-v4,-pcid,-tsc-deadline,-invpcid,-spec-ctrl",
            "-smp", "cpus=2,maxcpus=4,sockets=1,cores=4,threads=1",
            "-device", "virtio-blk-pci,id=disk1,drive=drive1,num-queues=4",
            "-drive", "media=disk,id=drive1,if=none,format=raw,file=/guest/root.img,discard=unmap,detect-zeroes=unmap",
            "-kernel", "/guest/bzImage",
            "-initrd", "/guest/initrd.img",
        ])
}
