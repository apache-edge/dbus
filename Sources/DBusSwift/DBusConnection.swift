import CDBus
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An error that can occur when working with DBus connections
public enum DBusConnectionError: Error, CustomStringConvertible {
    /// Indicates that a D-Bus connection could not be established
    ///
    /// - Parameter reason: A string describing why the connection failed
    case connectionFailed(String)
    
    /// Indicates that a D-Bus message operation failed
    ///
    /// - Parameter reason: A string describing why the message operation failed
    case messageFailed(String)
    
    /// Indicates that a D-Bus reply was invalid or could not be processed
    ///
    /// - Parameter reason: A string describing why the reply was invalid
    case invalidReply(String)
    
    /// Indicates that the requested D-Bus functionality is not supported
    case notSupported
    
    public var description: String {
        switch self {
        case .connectionFailed(let reason):
            return "D-Bus connection failed: \(reason)"
        case .messageFailed(let reason):
            return "D-Bus message failed: \(reason)"
        case .invalidReply(let reason):
            return "Invalid D-Bus reply: \(reason)"
        case .notSupported:
            return "This operation is not supported"
        }
    }
}

/// Represents a connection to a D-Bus bus
public final class DBusConnection: @unchecked Sendable {
    private var connection: OpaquePointer?
    private var busType: DBusBusType
    
    /// Initializes a new connection to a D-Bus bus
    /// - Parameter busType: The type of bus to connect to
    /// - Throws: DBusConnectionError if the connection fails
    public init(busType: DBusBusType = .session) throws {
        self.busType = busType
        
        // Create a C DBusError
        var cError = CDBus.DBusError()
        dbus_error_init(&cError)
        
        // Connect to the bus using the enum's raw value directly
        connection = _dbus_bus_get(busType.rawValue, &cError)
        
        // Check for errors
        if dbus_error_is_set(&cError) != 0 {
            let errorMessage = String(cString: cError.message)
            dbus_error_free(&cError)
            throw DBusConnectionError.connectionFailed(errorMessage)
        }
        
        if connection == nil {
            throw DBusConnectionError.connectionFailed("Failed to connect to D-Bus")
        }
    }
    
    deinit {
        if let connection = connection {
            dbus_connection_unref(connection)
        }
    }
    
    /// Returns the underlying D-Bus connection pointer
    /// - Returns: The D-Bus connection pointer
    public func getConnection() -> OpaquePointer? {
        return connection
    }
    
    /// Flushes the connection, sending any pending outgoing messages
    public func flush() {
        if let connection = connection {
            dbus_connection_flush(connection)
        }
    }
    
    /// Sends a message on the bus and optionally waits for a reply
    /// - Parameters:
    ///   - message: The message to send
    ///   - timeoutMS: Timeout in milliseconds, -1 for default, 0 for no timeout
    /// - Returns: The reply message if one was requested
    /// - Throws: DBusConnectionError if sending the message fails
    public func send(message: DBusMessage, timeoutMS: Int32 = -1) throws -> DBusMessage? {
        guard let connection = connection else {
            throw DBusConnectionError.connectionFailed("No active connection")
        }
        
        guard let messagePtr = message.getMessage() else {
            throw DBusConnectionError.messageFailed("Invalid message")
        }
        
        // If this is a method call with a reply expected
        if message.getMessageType() == .methodCall && 
           dbus_message_get_no_reply(messagePtr) == 0 {
            var cError = CDBus.DBusError()
            dbus_error_init(&cError)
            
            let replyPtr = dbus_connection_send_with_reply_and_block(connection, messagePtr, timeoutMS, &cError)
            
            if dbus_error_is_set(&cError) != 0 {
                let errorMessage = String(cString: cError.message)
                dbus_error_free(&cError)
                throw DBusConnectionError.messageFailed(errorMessage)
            }
            
            if let replyPtr = replyPtr {
                return DBusMessage(message: replyPtr, freeOnDeinit: true)
            } else {
                throw DBusConnectionError.invalidReply("No reply received")
            }
        } else {
            // Just send without waiting for reply
            var serial: DBusUInt32 = 0
            if dbus_connection_send(connection, messagePtr, &serial) == 0 {
                throw DBusConnectionError.messageFailed("Failed to send message")
            }
            
            return nil
        }
    }
    
    /// Adds a match rule to match messages received on the bus
    /// - Parameter rule: The match rule
    /// - Throws: DBusConnectionError if adding the match rule fails
    public func addMatch(rule: String) throws {
        guard let connection = connection else {
            throw DBusConnectionError.connectionFailed("No active connection")
        }
        
        var cError = CDBus.DBusError()
        dbus_error_init(&cError)
        
        rule.withCString { cRule in
            dbus_bus_add_match(connection, cRule, &cError)
        }
        
        if dbus_error_is_set(&cError) != 0 {
            let errorMessage = String(cString: cError.message)
            dbus_error_free(&cError)
            throw DBusConnectionError.connectionFailed(errorMessage)
        }
    }
    
    /// Removes a match rule
    /// - Parameter rule: The match rule to remove
    /// - Throws: DBusConnectionError if removing the match rule fails
    public func removeMatch(rule: String) throws {
        guard let connection = connection else {
            throw DBusConnectionError.connectionFailed("No active connection")
        }
        
        var cError = CDBus.DBusError()
        dbus_error_init(&cError)
        
        rule.withCString { cRule in
            dbus_bus_remove_match(connection, cRule, &cError)
        }
        
        if dbus_error_is_set(&cError) != 0 {
            let errorMessage = String(cString: cError.message)
            dbus_error_free(&cError)
            throw DBusConnectionError.connectionFailed(errorMessage)
        }
    }
    
    /// Request a name on the bus
    /// - Parameter name: The name to request
    /// - Parameter flags: Flags controlling the name request behavior (default: 0)
    /// - Returns: A result code indicating the outcome of the request
    /// - Throws: DBusConnectionError if the request fails
    public func requestName(name: String, flags: UInt32 = 0) throws -> Int32 {
        guard let connection = connection else {
            throw DBusConnectionError.connectionFailed("No active connection")
        }
        
        var cError = CDBus.DBusError()
        dbus_error_init(&cError)
        
        let result = name.withCString { cName in
            dbus_bus_request_name(connection, cName, flags, &cError)
        }
        
        if dbus_error_is_set(&cError) != 0 {
            let errorMessage = String(cString: cError.message)
            dbus_error_free(&cError)
            throw DBusConnectionError.connectionFailed(errorMessage)
        }
        
        return result
    }
}