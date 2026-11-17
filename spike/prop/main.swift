// Phase 0 spike (throwaway): read / write / watch the LensBarSpike extension's
// custom device properties through the CoreMediaIO C API, the way the app will.
//
// Build: swiftc -O -o build/spike-prop spike/prop/main.swift
//   spike-prop get
//   spike-prop set "1920x1080@25:stream"      (mode: none | stream | device)
//   spike-prop watch                           listener blocks + 1 s polling side by side

import CoreMediaIO
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let deviceUID = "6A1B6C2E-8F0E-4B7A-9C55-2B1D3E4F5A60"

let tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
func log(_ s: String) { print("\(tsFormatter.string(from: Date())) \(s)") }

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

func addr(_ sel: UInt32) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: sel,
                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

let system = CMIOObjectID(kCMIOObjectSystemObject)
let selCount = fourCC("lbcc")
let selFormat = fourCC("lbfm")

func allowDAL() {
    var a = addr(UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices))
    var one: UInt32 = 1
    CMIOObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &one)
}

func devices() -> [CMIOObjectID] {
    var a = addr(UInt32(kCMIOHardwarePropertyDevices))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    CMIOObjectGetPropertyData(system, &a, 0, nil, size, &used, &out)
    return out
}

func getString(_ obj: CMIOObjectID, _ sel: UInt32) -> String? {
    var a = addr(sel)
    var cf: Unmanaged<CFString>?
    var used: UInt32 = 0
    let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let err = CMIOObjectGetPropertyData(obj, &a, 0, nil, size, &used, &cf)
    guard err == noErr else { return "<err \(err)>" }
    return cf?.takeRetainedValue() as String?
}

func setString(_ obj: CMIOObjectID, _ sel: UInt32, _ value: String) -> OSStatus {
    var a = addr(sel)
    var cf: CFString = value as CFString
    return CMIOObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<CFString>.size), &cf)
}

func findDevice() -> CMIOObjectID? {
    devices().first { getString($0, UInt32(kCMIODevicePropertyDeviceUID)) == deviceUID }
}

allowDAL()
// Device list is populated asynchronously on first use.
var dev: CMIOObjectID?
for _ in 0..<20 {
    dev = findDevice()
    if dev != nil { break }
    Thread.sleep(forTimeInterval: 0.1)
}
guard var device = dev else {
    log("LensBarSpike device not found")
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "get":
    log("device=\(device) lbcc=\(getString(device, selCount) ?? "nil") lbfm=\(getString(device, selFormat) ?? "nil")")
case "set":
    guard args.count > 1 else { log("usage: set WxH@fps:mode"); exit(2) }
    let st = setString(device, selFormat, args[1])
    log("set lbfm=\(args[1]) -> \(st)")
case "watch":
    let q = DispatchQueue(label: "listeners")
    var listened: Set<CMIOObjectID> = []
    func listen(_ d: CMIOObjectID) {
        guard !listened.contains(d) else { return }
        listened.insert(d)
        for (name, sel) in [("lbcc", selCount), ("lbfm", selFormat)] {
            var a = addr(sel)
            let st = CMIOObjectAddPropertyListenerBlock(d, &a, q) { _, _ in
                log("LISTENER \(name) on device \(d) -> \(getString(d, sel) ?? "nil")")
            }
            log("listener for \(name) on device \(d): \(st)")
        }
    }
    listen(device)
    var devAddr = addr(UInt32(kCMIOHardwarePropertyDevices))
    CMIOObjectAddPropertyListenerBlock(system, &devAddr, q) { _, _ in
        let d = findDevice()
        log("LISTENER device list changed; LensBarSpike = \(d.map { String($0) } ?? "absent")")
        if let d { listen(d) }
    }
    var last = ""
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        if let d = findDevice() { device = d }
        let now = "device=\(device) lbcc=\(getString(device, selCount) ?? "nil") lbfm=\(getString(device, selFormat) ?? "nil")"
        if now != last { log("POLL \(now)"); last = now }
    }
    RunLoop.main.run()
default:
    log("usage: spike-prop get | set WxH@fps:mode | watch")
    exit(2)
}
