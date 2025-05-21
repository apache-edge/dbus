import DBusSwift
import NIO

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#endif

@available(macOS 14.0, *)
@main
struct App {
  static func main() async throws {
    do {
      // let uid = String(getuid())
      let uid = "0"
      try await DBusClient.withConnection(
        to: SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket"),
        auth: .external(userID: uid)
      ) { replies, send in
        try await send(
          DBusMessage.createMethodCall(
            destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            method: "Hello",
            serial: 1
          ))

        guard let helloReply = try await replies.next() else {
          print("No reply from Hello method call")
          return
        }

        guard case .methodReturn = helloReply.messageType else {
          print("Unexpected message type from Hello method call")
          return
        }

        print("Received reply from Hello method call \(helloReply)")

        print("DBus client connected as UID \(uid) with serial \(helloReply.serial)")

        // try await outbound.write(DBusMessage.createMethodCall(
        //     destination: "org.freedesktop.DBus",
        //     path: "/org/freedesktop/DBus",
        //     interface: "org.freedesktop.DBus",
        //     method: "ListNames",
        //     serial: 2
        // ))

        var serial: UInt32 = 2
        func nextSerial() -> UInt32 {
          defer { serial += 1 }
          return serial
        }

        func sendRequest(
          withSerial: (UInt32) throws -> DBusMessage
        ) async throws -> DBusMessage {
          print("Sending request with serial: \(serial)")
          let serial = nextSerial()
          let message = try withSerial(serial)
          print("Message: \(message)")
          try await send(message)
          print("Wrote message")
          while let reply = try await replies.next() {
            print("Received reply with serial: \(reply.replyTo ?? 0)")
            guard reply.replyTo == serial else {
              continue
            }
            print("Returning reply")
            return reply
          }

          print("No reply received")
          throw CancellationError()
        }

        // First, get all devices from NetworkManager
        let devicesReply = try await sendRequest { serial in
          NetworkManager.getDevices(serial: serial)
        }

        print("\nDevices reply: \(devicesReply)")

        // Extract device paths from the reply
        guard let bodyValue = devicesReply.body.first else {
          print("No body in GetDevices reply")
          return
        }

        var devicePaths: [String] = []
        switch bodyValue {
        case .array(let devices):
          devicePaths = devices.compactMap { device in
            if case .objectPath(let path) = device {
              return path
            } else if case .variant(let variant) = device,
              case .objectPath(let path) = variant.value
            {
              return path
            }
            return nil
          }
        case .variant(let variant):
          if case .array(let devices) = variant.value {
            devicePaths = devices.compactMap { device in
              if case .objectPath(let path) = device {
                return path
              } else if case .variant(let variant) = device,
                case .objectPath(let path) = variant.value
              {
                return path
              }
              return nil
            }
          }
        default:
          print("Unexpected arguments from GetDevices reply: \(bodyValue)")
          return
        }

        print("Found \(devicePaths.count) devices")

        // Find the Wi-Fi device by checking device type
        var wifiDevicePath: String? = nil
        for devicePath in devicePaths {
          let deviceTypeReply = try await sendRequest { serial in
            NetworkManager.getDeviceType(devicePath: devicePath, serial: serial)
          }

          guard let typeValue = deviceTypeReply.body.first else {
            print("No body in GetDeviceType reply for device \(devicePath)")
            continue
          }

          // Device type 2 is Wi-Fi (NM_DEVICE_TYPE_WIFI)
          var deviceType: UInt32 = 0
          switch typeValue {
          case .uint32(let type):
            deviceType = type
          case .variant(let variant):
            if case .uint32(let type) = variant.value {
              deviceType = type
            }
          default:
            print("Unexpected device type format: \(typeValue)")
            continue
          }

          print("Device \(devicePath) has type \(deviceType)")

          if deviceType == 2 {  // NM_DEVICE_TYPE_WIFI = 2
            wifiDevicePath = devicePath
            print("Found Wi-Fi device at \(devicePath)")
            break
          }
        }

        guard let wifiDevicePath = wifiDevicePath else {
          print("No Wi-Fi device found")
          return
        }

        // Now use the correct Wi-Fi device path
        let scanReply = try await sendRequest { serial in
          NetworkManager.scanAPs(devicePath: wifiDevicePath, serial: serial)
        }

        print("\nScan reply: \(scanReply)")

        guard let bodyValue = scanReply.body.first else {
          print("No body in Scan reply")
          return
        }

        print("\nScan reply body type: \(type(of: bodyValue))")
        print("\nScan reply body: \(bodyValue)")

        var accessPoints: [DBusValue] = []
        switch bodyValue {
        case .array(let aps):
          accessPoints = aps
        case .variant(let variant):
          if case .array(let aps) = variant.value {
            accessPoints = aps
          } else {
            print("Unexpected variant value in Scan reply: \(variant.value)")
            return
          }
        default:
          print("Unexpected arguments from Scan reply: \(bodyValue)")
          return
        }

        var hostnames = [(ssid: String, path: String)]()
        for ap in accessPoints {
          var apPath: String = ""

          switch ap {
          case .objectPath(let path):
            apPath = path
          case .variant(let variant):
            if case .objectPath(let path) = variant.value {
              apPath = path
            } else {
              print("Unexpected access point format: \(ap)")
              continue
            }
          default:
            print("Unexpected access point format: \(ap)")
            continue
          }

          let apObject = try await sendRequest { serial in
            NetworkManager.getSSID(apPath: apPath, serial: serial)
          }

          print("AP SSID response: \(apObject)")

          guard let bodyValue = apObject.body.first else {
            print("No body in GetSSID reply")
            continue
          }

          var ssidBytes: [DBusValue] = []

          switch bodyValue {
          case .variant(let variant):
            switch variant.value {
            case .array(let bytes):
              ssidBytes = bytes
            case .variant(let nestedVariant):
              if case .array(let bytes) = nestedVariant.value {
                ssidBytes = bytes
              } else {
                print("Unexpected nested variant value in GetSSID reply: \(nestedVariant.value)")
                continue
              }
            default:
              print("Unexpected variant value in GetSSID reply: \(variant.value)")
              continue
            }
          case .array(let bytes):
            ssidBytes = bytes
          default:
            print("Unexpected arguments from GetSSID reply: \(bodyValue)")
            continue
          }

          let ssid = ssidBytes.compactMap { value -> UInt8? in
            switch value {
            case .byte(let byte):
              return byte
            case .variant(let variant):
              if case .byte(let byte) = variant.value {
                return byte
              }
              return nil
            default:
              return nil
            }
          }

          if let ssid = String(bytes: ssid, encoding: .utf8) {
            hostnames.append((ssid, apPath))
          }
        }

        print(hostnames)

        if let (name, path) = hostnames.first(where: { $0.ssid == "Orlandos Wifi" }) {
          let reply = try await sendRequest { serial in
            NetworkManager.connect(
              networkDevicePath: wifiDevicePath,
              apPath: path,
              apName: name,
              password: "",
              serial: serial
            )
          }

          print(reply)
        }
      }
    } catch {
      print("DBus error: \(error)")
      exit(1)
    }
  }
}

/// Helper for NetworkManager D-Bus API
public struct NetworkManager {
  /// Get all network devices from NetworkManager
  /// - Parameter serial: The D-Bus serial number to use
  /// - Returns: A DBusMessage for the GetDevices method
  public static func getDevices(serial: UInt32) -> DBusMessage {
    return DBusMessage.createMethodCall(
      destination: "org.freedesktop.NetworkManager",
      path: "/org/freedesktop/NetworkManager",
      interface: "org.freedesktop.NetworkManager",
      method: "GetDevices",
      serial: serial
    )
  }

  /// Get the type of a network device
  /// - Parameters:
  ///   - devicePath: The object path of the device
  ///   - serial: The D-Bus serial number to use
  /// - Returns: A DBusMessage for the Get method to get device type
  public static func getDeviceType(devicePath: String, serial: UInt32) -> DBusMessage {
    return DBusMessage.createMethodCall(
      destination: "org.freedesktop.NetworkManager",
      path: devicePath,
      interface: "org.freedesktop.DBus.Properties",
      method: "Get",
      serial: serial,
      body: [
        .string("org.freedesktop.NetworkManager.Device"),
        .string("DeviceType"),
      ]
    )
  }

  /// Create a D-Bus message to request a Wi-Fi scan on a given device
  /// - Parameters:
  ///   - devicePath: The object path of the wireless device (e.g. "/org/freedesktop/NetworkManager/Devices/0")
  ///   - serial: The D-Bus serial number to use
  /// - Returns: A DBusMessage for the Scan method
  public static func scanAPs(devicePath: String, serial: UInt32) -> DBusMessage {
    return DBusMessage.createMethodCall(
      destination: "org.freedesktop.NetworkManager",
      path: devicePath,
      interface: "org.freedesktop.NetworkManager.Device.Wireless",
      method: "GetAllAccessPoints",
      serial: serial
    )
  }

  public static func getSSID(apPath: String, serial: UInt32) -> DBusMessage {
    return DBusMessage.createMethodCall(
      destination: "org.freedesktop.NetworkManager",
      path: apPath,
      interface: "org.freedesktop.DBus.Properties",
      method: "Get",
      serial: serial,
      body: [
        DBusValue.string("org.freedesktop.NetworkManager.AccessPoint"), DBusValue.string("Ssid"),
      ]
    )
  }

  public static func connect(
    networkDevicePath: String,
    apPath: String,
    apName: String,
    password: String,
    serial: UInt32
  ) -> DBusMessage {
    return DBusMessage.createMethodCall(
      destination: "org.freedesktop.NetworkManager",
      path: apPath,
      interface: "org.freedesktop.NetworkManager",
      method: "AddAndActivateConnection",
      serial: serial,
      body: [
        .array([
          .dictionary([
            .string("connection"): .array([
              .dictionary([
                .string("id"): .string(apName)
              ]),
              .dictionary([
                .string("type"): .string("802-11-wireless")
              ]),
              .dictionary([
                .string("uuid"): .string(UUID().uuidString)
              ]),
              .dictionary([
                .string("autoconnect"): .boolean(true)
              ]),
            ])
          ]),
          .dictionary([
            .string("802-11-wireless"): .array([
              .dictionary([
                .string("ssid"): .array(apName.utf8.map { DBusValue.byte($0) })
              ]),
              .dictionary([
                .string("mode"): .string("infrastructure")
              ]),
            ])
          ]),
          .dictionary([
            .string("802-11-wireless-security"): .array([
              .dictionary([
                .string("key-mgmt"): .string("wpa-psk")
              ]),
              .dictionary([
                .string("psk"): .string(password)
              ]),
            ])
          ]),
          .dictionary([
            .string("ipv4"): .array([
              .dictionary([
                .string("method"): .string("auto")
              ])
            ])
          ]),
          .dictionary([
            .string("ipv6"): .array([
              .dictionary([
                .string("method"): .string("auto")
              ])
            ])
          ]),
        ]),
        .objectPath(networkDevicePath),
        .objectPath(apPath),
      ]
    )
  }
}
