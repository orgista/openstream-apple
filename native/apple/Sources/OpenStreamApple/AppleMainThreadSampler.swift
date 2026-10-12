#if DEBUG && (os(macOS) || targetEnvironment(simulator)) && arch(arm64)
import Darwin
import Foundation
import MachO

/// Review builds only (N47): a 1 ms main-thread stack sampler, so a title
/// page's open can be profiled without attaching a profiler or debugger.
///
/// `-OpenStreamMainThreadSamples </abs/path.txt>`: each title-page push
/// (`AppleTitlePageOpenProbe`) samples the main thread for 700 ms and
/// appends `S <ms> <frame ids leaf first>` lines and a `Y <id> <symbol>`
/// table. App frames are written as `MAIN+0x<offset>` for `atos`.
///
/// While the main thread is suspended nothing here allocates (it may hold
/// the malloc lock): stacks go into a buffer allocated beforehand.
enum AppleMainThreadSampler {
    nonisolated(unsafe) private static var mainThread: thread_act_t = 0
    nonisolated(unsafe) private static var mainStack: (bottom: UInt, top: UInt) = (0, 0)
    private static let maxFrames = 96
    private static let maxSamples = 900

    static var outputPath: String? {
        UserDefaults.standard.string(forKey: "OpenStreamMainThreadSamples")
    }

    /// Call once on the main thread.
    static func captureMainThread() {
        guard mainThread == 0 else { return }
        mainThread = mach_thread_self()
        let main = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(main))
        mainStack = (top - UInt(pthread_get_stacksize_np(main)), top)
    }

    static func sample(label: String, duration: TimeInterval = 0.7) {
        guard let path = outputPath, mainThread != 0 else { return }
        let thread = Thread {
            run(label: label, duration: duration, path: path)
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func run(label: String, duration: TimeInterval, path: String) {
        let (stackBottom, stackTop) = mainStack
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: maxSamples * (maxFrames + 2))
        defer { buffer.deallocate() }
        let mask: UInt = (1 << 47) - 1
        var count = 0
        let start = CFAbsoluteTimeGetCurrent()
        while count < maxSamples {
            let now = CFAbsoluteTimeGetCurrent()
            if now - start > duration { break }
            let row = buffer + count * (maxFrames + 2)
            var state = arm_thread_state64_t()
            var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            guard thread_suspend(mainThread) == KERN_SUCCESS else { break }
            let got = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                    thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
                }
            }
            var frames = 0
            if got == KERN_SUCCESS {
                row[2] = UInt(state.__pc) & mask
                row[3] = UInt(state.__lr) & mask
                frames = 2
                var fp = UInt(state.__fp)
                while frames < maxFrames, fp >= stackBottom, fp + 16 <= stackTop, fp & 7 == 0 {
                    let pointer = UnsafePointer<UInt>(bitPattern: fp)!
                    let next = pointer[0]
                    let ret = pointer[1] & mask
                    if ret == 0 { break }
                    row[2 + frames] = ret
                    frames += 1
                    if next <= fp { break }
                    fp = next
                }
            }
            thread_resume(mainThread)
            row[0] = UInt(((now - start) * 1000).rounded())
            row[1] = UInt(frames)
            count += 1
            usleep(1000)
        }
        write(label: label, buffer: buffer, count: count, path: path)
    }

    private static func write(label: String, buffer: UnsafeMutablePointer<UInt>, count: Int, path: String) {
        let mainHeader = UInt(bitPattern: _dyld_get_image_header(0))
        var mainEnd = mainHeader
        if let header = _dyld_get_image_header(0) {
            var size: UInt = 0
            _ = getsegmentdata(UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self), "__TEXT", &size)
            mainEnd = mainHeader + size
        }
        var ids: [UInt: Int] = [:]
        var names: [String] = []
        var lines = ["# \(label) \(count) samples"]
        for index in 0..<count {
            let row = buffer + index * (maxFrames + 2)
            var parts: [String] = []
            for frame in 0..<Int(row[1]) {
                let address = row[2 + frame]
                let id: Int
                if let known = ids[address] {
                    id = known
                } else {
                    id = names.count
                    ids[address] = id
                    names.append(symbol(address, mainStart: mainHeader, mainEnd: mainEnd))
                }
                parts.append(String(id))
            }
            lines.append("S \(row[0]) \(parts.joined(separator: ","))")
        }
        for (id, name) in names.enumerated() { lines.append("Y \(id) \(name)") }
        let text = lines.joined(separator: "\n") + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
        print("[OpenStream] sampler \(label) wrote \(count) samples")
        fflush(stdout)
    }

    private static func symbol(_ address: UInt, mainStart: UInt, mainEnd: UInt) -> String {
        if address >= mainStart, address < mainEnd {
            return "MAIN+0x" + String(address - mainStart, radix: 16)
        }
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return "?0x" + String(address, radix: 16) }
        let image = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
        let name = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image)`\(name)"
    }
}
#endif
