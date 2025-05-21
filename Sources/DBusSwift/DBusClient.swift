import Logging
import NIO
import NIOCore
import NIOExtras

@available(macOS 10.15, iOS 13, *)
public struct DBusClient: Sendable {
  private let group: EventLoopGroup
  private let asyncChannel: NIOAsyncChannel<DBusMessage, DBusMessage>

  public struct Replies {
    fileprivate var iterator: NIOAsyncChannelInboundStream<DBusMessage>.AsyncIterator

    public mutating func next() async throws -> DBusMessage? {
      try await iterator.next()
    }
  }

  public struct Send {
    fileprivate let writer: NIOAsyncChannelOutboundWriter<DBusMessage>

    public func send(_ message: DBusMessage) async throws {
      try await writer.write(message)
    }

    public func callAsFunction(_ message: DBusMessage) async throws {
      try await send(message)
    }
  }

  public static func withConnection<R: Sendable>(
    to address: SocketAddress,
    auth: AuthType,
    _ handler: @Sendable @escaping (inout Replies, Send) async throws -> R
  ) async throws -> R {
    let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .channelInitializer { channel in
        do {
          try DBusClient.addToPipeline(channel.pipeline, auth: auth)
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
    let asyncChannel = try await bootstrap.connect(to: address)
      .flatMapThrowing {
        try NIOAsyncChannel(
          wrappingChannelSynchronously: $0,
          configuration: .init(
            inboundType: DBusMessage.self,
            outboundType: DBusMessage.self
          )
        )
      }.get()

    return try await asyncChannel.executeThenClose { inbound, outbound in
      var replies = Replies(
        iterator: inbound.makeAsyncIterator()
      )
      let send = Send(writer: outbound)
      return try await handler(&replies, send)
    }
  }

  static func addToPipeline(_ pipeline: ChannelPipeline, auth: AuthType) throws {
    let handlers: [any ChannelHandler] = [
      ByteToMessageHandler(LineBasedFrameDecoder()),
      DBusAuthenticationHandler(auth: auth),
      ByteToMessageHandler(DBusMessageDecoder()),
      MessageToByteHandler(DBusMessageEncoder()),
    ]
    try pipeline.syncOperations.addHandlers(handlers)
  }
}

internal enum DBusClientError: Error {
  case notConnected
}
