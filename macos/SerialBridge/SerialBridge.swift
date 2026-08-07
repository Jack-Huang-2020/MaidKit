//
// serial-bridge: unsandboxed LaunchAgent helper for MaidKit serial ports.
//
// The main app is sandboxed, so it cannot open /dev/cu.* device nodes
// directly. This helper lives inside the app bundle (Contents/Resources),
// is registered via SMAppService, runs unsandboxed, and bridges a serial
// device to the app over loopback TCP.
//
// Protocol (newline-delimited UTF-8 over TCP, 127.0.0.1 only):
//   C -> H: AUTH <token>\n
//   H -> C: OK\n                       | ERR <message>\n (then close)
//   C -> H: LIST\n                     (enumerate serial devices)
//   H -> C: LIST <json-array>\n        | ERR <message>\n (then close)
//   C -> H: OPEN <json>\n              | {"device": "...", "baudRate": 115200,
//                                        |  "dataBits": 8, "parity": "none",
//                                        |  "stopBits": 1, "flowControl": "none"}
//   H -> C: OK\n                       | ERR <message>\n (then close)
//   then raw duplex bytes until either side closes.
//
// Rendezvous: on startup the helper writes {"port": N, "token": "<uuid>"} to
// <home>/Library/Application Support/<bundle-id>/serial-bridge.json so the app
// can discover port + token. The app reads the same path via path_provider's
// getApplicationSupportDirectory(); the bundle id is passed as argv[1] by the
// app when it spawns this helper.
//
// The helper is deliberately not sandboxed and holds no credentials; it only
// opens devices the user asks for.

import Darwin
import Foundation

// MARK: - Rendezvous

let bundleId: String = {
  if CommandLine.arguments.count > 1, !CommandLine.arguments[1].isEmpty {
    return CommandLine.arguments[1]
  }
  return "dev.solsynth.maidKit"
}()

let appSupportDir = NSHomeDirectory() + "/Library/Application Support/\(bundleId)"
let rendezvousPath = appSupportDir + "/serial-bridge.json"

let token = UUID().uuidString

// MARK: - Termios

/// _IOW('T', 2, speed_t) from IOKit's ioss.h; not imported into Swift.
/// Set arbitrary baud rates on macOS (the standard constants stop at 230400).
private let kIOSSIOSPEED: UInt = 0x80045402

func applyBaudRate(fd: Int32, baudRate: Int) -> Bool {
  // macOS termios only defines constants up to B230400; arbitrary rates
  // (e.g. 460800, 921600) go through the IOSSIOSPEED ioctl instead.
  let standard: speed_t
  switch baudRate {
  case 9600: standard = speed_t(B9600)
  case 19200: standard = speed_t(B19200)
  case 38400: standard = speed_t(B38400)
  case 57600: standard = speed_t(B57600)
  case 115200: standard = speed_t(B115200)
  case 230400: standard = speed_t(B230400)
  default: standard = speed_t(B230400)
  }
  var t = termios()
  guard tcgetattr(fd, &t) == 0 else { return false }
  cfsetispeed(&t, standard)
  cfsetospeed(&t, standard)
  guard tcsetattr(fd, TCSANOW, &t) == 0 else { return false }
  var speed = speed_t(baudRate)
  return ioctl(fd, kIOSSIOSPEED, &speed) == 0
}

func configureSerial(fd: Int32, baudRate: Int, dataBits: Int, parity: String, stopBits: Int, flowControl: String) -> Bool {
  var t = termios()
  guard tcgetattr(fd, &t) == 0 else { return false }
  cfmakeraw(&t)

  t.c_cflag &= ~tcflag_t(CSIZE)
  switch dataBits {
  case 5: t.c_cflag |= tcflag_t(CS5)
  case 6: t.c_cflag |= tcflag_t(CS6)
  case 7: t.c_cflag |= tcflag_t(CS7)
  default: t.c_cflag |= tcflag_t(CS8)
  }

  t.c_cflag &= ~tcflag_t(PARENB)
  t.c_cflag &= ~tcflag_t(PARODD)
  if parity == "even" {
    t.c_cflag |= tcflag_t(PARENB)
  } else if parity == "odd" {
    t.c_cflag |= tcflag_t(PARENB | PARODD)
  }

  t.c_cflag &= ~tcflag_t(CSTOPB)
  if stopBits == 2 {
    t.c_cflag |= tcflag_t(CSTOPB)
  }

  t.c_cflag &= ~tcflag_t(CRTSCTS)
  t.c_iflag &= ~tcflag_t(IXON)
  t.c_iflag &= ~tcflag_t(IXOFF)
  if flowControl == "hardware" {
    t.c_cflag |= tcflag_t(CRTSCTS)
  } else if flowControl == "software" {
    t.c_iflag |= tcflag_t(IXON | IXOFF)
  }

  t.c_cflag |= tcflag_t(CLOCAL | CREAD)
  return tcsetattr(fd, TCSANOW, &t) == 0
}

// MARK: - Socket helpers

func setNonBlocking(_ fd: Int32) {
  let flags = fcntl(fd, F_GETFL)
  if flags >= 0 {
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
  }
}

func sendLine(_ fd: Int32, _ text: String) {
  let data = Array((text + "\n").utf8)
  var written = 0
  while written < data.count {
    let n = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
      write(fd, raw.baseAddress!.advanced(by: written), data.count - written)
    }
    if n < 0 {
      if errno == EAGAIN {
        usleep(1000)
        continue
      }
      return
    }
    written += n
  }
}

/// Reads one newline-terminated line. Returns nil on timeout (10s) or EOF.
func readLine(_ fd: Int32) -> String? {
  var buffer: [UInt8] = []
  var byte: UInt8 = 0
  let deadline = Date().addingTimeInterval(10)
  while buffer.count < 4096 {
    if Date() > deadline { return nil }
    var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let p = poll(&fds, 1, 200)
    if p < 0 {
      if errno == EINTR { continue }
      return nil
    }
    if p == 0 { continue }
    if fds.revents & Int16(POLLIN) == 0 {
      if fds.revents & Int16(POLLHUP | POLLERR) != 0 { return nil }
      continue
    }
    let n = read(fd, &byte, 1)
    if n <= 0 {
      if n < 0 && errno == EAGAIN { continue }
      return nil
    }
    if byte == 0x0A { return String(decoding: buffer, as: UTF8.self) }
    buffer.append(byte)
  }
  return nil
}

// MARK: - Device enumeration

/// Call-out serial devices on macOS: /dev/cu.* entries (the variant that does
/// not block on carrier detect, which is what serial consoles use).
func listSerialDevices() -> [String] {
  let fm = FileManager.default
  guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else {
    return []
  }
  return entries
    .filter { $0.hasPrefix("cu.") }
    .map { "/dev/" + $0 }
    .sorted()
}

// MARK: - Connection handling

func handleConnection(client: Int32, token: String) {
  defer { close(client) }
  setNonBlocking(client)

  // AUTH
  guard let authLine = readLine(client) else {
    sendLine(client, "ERR auth timeout")
    return
  }
  let parts = authLine.split(separator: " ", maxSplits: 1)
  guard parts.count == 2, parts[0] == "AUTH", String(parts[1]) == token else {
    sendLine(client, "ERR invalid token")
    return
  }
  sendLine(client, "OK")

  // Command: LIST enumerates devices and ends the connection; OPEN starts a
  // byte tunnel for one device.
  guard let commandLine = readLine(client) else {
    sendLine(client, "ERR command timeout")
    return
  }
  let commandParts = commandLine.split(separator: " ", maxSplits: 1)
  guard let command = commandParts.first else {
    sendLine(client, "ERR expected OPEN or LIST")
    return
  }
  if command == "LIST" {
    let devices = listSerialDevices()
    if let data = try? JSONSerialization.data(withJSONObject: devices, options: .withoutEscapingSlashes),
       let json = String(data: data, encoding: .utf8) {
      sendLine(client, "LIST \(json)")
    } else {
      sendLine(client, "ERR cannot enumerate devices")
    }
    return
  }
  guard command == "OPEN", commandParts.count == 2 else {
    sendLine(client, "ERR expected OPEN or LIST")
    return
  }
  let openParts = commandParts
  guard
    let jsonData = String(openParts[1]).data(using: .utf8),
    let json = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
    let device = json["device"] as? String,
    !device.isEmpty
  else {
    sendLine(client, "ERR invalid serial config")
    return
  }

  let baudRate = (json["baudRate"] as? NSNumber)?.intValue ?? 115200
  let dataBits = (json["dataBits"] as? NSNumber)?.intValue ?? 8
  let parity = json["parity"] as? String ?? "none"
  let stopBits = (json["stopBits"] as? NSNumber)?.intValue ?? 1
  let flowControl = json["flowControl"] as? String ?? "none"

  // Open with O_NONBLOCK so a wedged carrier-detect port cannot hang us.
  let serialFD = open(device, O_RDWR | O_NOCTTY | O_NONBLOCK)
  guard serialFD >= 0 else {
    sendLine(client, "ERR cannot open \(device): \(String(cString: strerror(errno)))")
    return
  }
  defer { close(serialFD) }

  guard configureSerial(fd: serialFD, baudRate: baudRate, dataBits: dataBits, parity: parity, stopBits: stopBits, flowControl: flowControl) else {
    sendLine(client, "ERR cannot configure \(device)")
    return
  }
  sendLine(client, "OK")
  relay(socket: client, serial: serialFD)
}

/// Bidirectional byte pump between the socket and the serial device.
func relay(socket: Int32, serial: Int32) {
  let bufSize = 4096
  var buf = [UInt8](repeating: 0, count: bufSize)
  while true {
    var fds = [
      pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
      pollfd(fd: serial, events: Int16(POLLIN), revents: 0),
    ]
    let n = poll(&fds, 2, -1)
    if n < 0 {
      if errno == EINTR { continue }
      return
    }
    for i in 0..<2 {
      let revents = fds[i].revents
      if revents & Int16(POLLIN) != 0 {
        let src = fds[i].fd
        let dst = i == 0 ? serial : socket
        let r = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
          read(src, raw.baseAddress!, bufSize)
        }
        if r <= 0 { return }  // EOF or error on either side ends the session
        var written = 0
        while written < r {
          let w = buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            write(dst, raw.baseAddress!.advanced(by: written), r - written)
          }
          if w < 0 {
            if errno == EAGAIN {
              usleep(1000)
              continue
            }
            return
          }
          written += w
        }
      }
      if revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
        return
      }
    }
  }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)

let listenFD = socket(AF_INET, SOCK_STREAM, 0)
guard listenFD >= 0 else {
  exit(1)
}
defer { close(listenFD) }

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = 0  // ephemeral
addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
  ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
    bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
  }
}
guard ok else {
  exit(1)
}
guard listen(listenFD, 16) == 0 else {
  exit(1)
}

var len = socklen_t(MemoryLayout<sockaddr_in>.size)
var boundAddr = sockaddr_in()
withUnsafeMutablePointer(to: &boundAddr) { ptr in
  ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
    _ = getsockname(listenFD, sockPtr, &len)
  }
}
let port = UInt16(bigEndian: boundAddr.sin_port)

// Publish the rendezvous file. The app polls this path under its
// Application Support directory.
do {
  try FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
  let payload = "{\"port\":\(port),\"token\":\"\(token)\"}"
  try payload.write(toFile: rendezvousPath, atomically: true, encoding: .utf8)
} catch {
  exit(1)
}

while true {
  let client = accept(listenFD, nil, nil)
  if client < 0 {
    if errno == EINTR { continue }
    break
  }
  Thread.detachNewThread {
    handleConnection(client: client, token: token)
  }
}
