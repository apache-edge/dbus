import Logging
import NIO
import NIOCore
import NIOExtras

/// Authentication types supported for DBus connections
/// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms
public struct AuthType: Sendable {
  internal enum Backing: Sendable {
    /// Anonymous authentication (no credentials)
    /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms-anonymous
    case anonymous

    /// External authentication using provided user ID
    /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms-external
    case external(userID: String)
  }

  let backing: Backing

  /// Anonymous authentication (no credentials)
  /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms-anonymous
  public static let anonymous = AuthType(backing: .anonymous)

  /// External authentication using provided user ID
  /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms-external
  public static func external(userID: String) -> AuthType {
    AuthType(backing: .external(userID: userID))
  }
}

/// Handles the DBus authentication protocol
/// This channel handler implements the client-side of the DBus authentication protocol
/// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-protocol
internal final class DBusAuthenticationHandler: ChannelDuplexHandler, @unchecked Sendable {
  internal typealias InboundIn = ByteBuffer
  internal typealias InboundOut = ByteBuffer
  internal typealias OutboundIn = ByteBuffer
  internal typealias OutboundOut = ByteBuffer

  /// States of the DBus authentication protocol
  /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-protocol
  internal enum State {
    /// Waiting for NUL byte reply from server (initial state)
    case waitingForNullReply
    /// Authentication sent, waiting for OK response
    case waitingForOK
    /// Successfully authenticated, normal message passing can begin
    case authenticated
    /// Authentication failed
    case failed
  }

  private var state: State = .waitingForNullReply
  private var buffer = ByteBufferAllocator().buffer(capacity: 128)
  private let auth: AuthType
  private var writeBuffer = [ByteBuffer]()

  internal init(auth: AuthType) {
    self.auth = auth
  }

  internal func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buf = self.unwrapInboundIn(data)
    buffer.writeBuffer(&buf)
    processBuffer(context: context)
  }

  private func processBuffer(context: ChannelHandlerContext) {
    defer { buffer.discardReadBytes() }
    while buffer.readableBytes > 0 {
      switch state {
      case .waitingForNullReply:
        // Wait for server's NUL byte reply (optional, but some servers send it)
        if let byte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self), byte == 0 {
          buffer.moveReaderIndex(forwardBy: 1)
        }

        state = .waitingForOK
      case .waitingForOK:
        guard var line = buffer.readString(length: buffer.readableBytes) else { return }
        if line.starts(with: "OK ") {
          line = String(line.dropFirst(3))

          let begin = "BEGIN\r\n"
          let out = context.channel.allocator.buffer(string: begin)
          context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)

          do {
            let handler = try context.pipeline.syncOperations.handler(
              type: ByteToMessageHandler<LineBasedFrameDecoder>.self)
            _ = context.pipeline.syncOperations.removeHandler(handler)

            // Directly process buffers after handler removal
            for buffer in self.writeBuffer {
              context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
            }
            self.writeBuffer.removeAll(keepingCapacity: true)
            self.state = .authenticated
            context.fireChannelActive()
            context.fireChannelWritabilityChanged()
          } catch {
            context.fireErrorCaught(error)
          }
        } else if line.starts(with: "REJECTED ") {
          context.fireErrorCaught(DBusAuthenticationError.invalidAuthCommand)
          // let mechanisms = line.split(separator: " ")
          //     .dropFirst()

          return
        } else {
          state = .failed
          context.fireErrorCaught(DBusAuthenticationError.invalidAuthCommand)
          return
        }
      case .authenticated:
        if buffer.readableBytes > 0 {
          let pass = buffer.readSlice(length: buffer.readableBytes)!
          buffer.discardReadBytes()
          context.fireChannelRead(self.wrapInboundOut(pass))
        }
      case .failed:
        // Drop all data
        buffer.clear()
        context.close(promise: nil)
      }
    }
  }

  internal func write(
    context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?
  ) {
    if state == .authenticated, writeBuffer.isEmpty {
      context.writeAndFlush(data, promise: promise)
    } else {
      writeBuffer.append(self.unwrapOutboundIn(data))
    }
  }

  internal func channelWritabilityChanged(context: ChannelHandlerContext) {
    if state == .authenticated {
      context.fireChannelWritabilityChanged()
    }
  }

  /// Initiates the DBus authentication process when the channel becomes active
  /// Sends the initial NUL byte followed by the AUTH command
  /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-command
  internal func channelActive(context: ChannelHandlerContext) {
    // Send initial NUL byte and AUTH command
    var buf = context.channel.allocator.buffer(capacity: 64)
    buf.writeInteger(UInt8(0))
    // Use EXTERNAL with empty UID (for root) or hex-encoded UID for current user
    // For now, send EXTERNAL with empty (\r\n at end)
    let auth: String

    switch self.auth.backing {
    case .anonymous:
      auth = "AUTH ANONYMOUS\r\n"
    case .external(let userID):
      let hex = userID.utf8.map { byte in
        let hexString = String(byte, radix: 16)
        return hexString.count == 1 ? "0\(hexString)" : hexString
      }.joined()
      auth = "AUTH EXTERNAL \(hex)\r\n"
    }
    buf.writeString(auth)
    context.writeAndFlush(self.wrapOutboundOut(buf), promise: nil)
  }
}

/// Errors that can occur during the DBus authentication process
/// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-protocol
enum DBusAuthenticationError: Error {
  /// The initial NUL byte was invalid or missing
  case invalidInitialNull
  /// Received an invalid AUTH command response
  case invalidAuthCommand
  /// The BEGIN command failed
  case invalidBegin
}

/// Events that can be triggered during the DBus authentication process
enum DBusAuthenticationEvent {
  /// Authentication was successful
  case authenticated
}
