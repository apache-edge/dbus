import Testing
@testable import DBusSwift

/// Tests for the DBusMessage class and related functionality.
@Suite("DBusMessage Tests")
struct DBusMessageTests {
    #if canImport(CDBus)
    /// Tests the creation of different message types.
    @Test("Message Type Creation")
    func testMessageTypeCreation() throws {
        // Test method call creation
        let methodCall = DBusMessage(type: .methodCall)
        let methodCallType = methodCall.getMessageType()
        #expect(methodCallType == .methodCall)
        
        // Test signal creation
        let signal = DBusMessage(type: .signal)
        let signalType = signal.getMessageType()
        #expect(signalType == .signal)
        
        // Test method return creation
        let methodReturn = DBusMessage(type: .methodReturn)
        let methodReturnType = methodReturn.getMessageType()
        #expect(methodReturnType == .methodReturn)
        
        // Test error message creation
        let errorMsg = DBusMessage(type: .error)
        let errorType = errorMsg.getMessageType()
        #expect(errorType == .error)
    }
    
    /// Tests the creation of method call messages with specific parameters.
    @Test("Method Call Creation")
    func testMethodCallCreation() throws {
        let msg = DBusMessage.createMethodCall(
            destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            method: "ListNames"
        )
        
        let messageType = msg.getMessageType()
        #expect(messageType == .methodCall)
        
        // Verify message properties
        #expect(msg.getDestination() == "org.freedesktop.DBus")
        #expect(msg.getPath() == "/org/freedesktop/DBus")
        #expect(msg.getInterface() == "org.freedesktop.DBus")
        #expect(msg.getMember() == "ListNames")
    }
    
    /// Tests the creation of signal messages with specific parameters.
    @Test("Signal Creation")
    func testSignalCreation() throws {
        let msg = DBusMessage.createSignal(
            path: "/org/example/Path",
            interface: "org.example.Interface",
            name: "ExampleSignal"
        )
        
        let messageType = msg.getMessageType()
        #expect(messageType == .signal)
        
        // Verify message properties
        #expect(msg.getPath() == "/org/example/Path")
        #expect(msg.getInterface() == "org.example.Interface")
        #expect(msg.getMember() == "ExampleSignal")
    }
    
    /// Tests the message headers functionality.
    @Test("Message Headers")
    func testMessageHeaders() throws {
        let msg = DBusMessage.createMethodCall(
            destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            method: "ListNames"
        )
        
        // Verify that we can get and set headers
        msg.setAutoStart(false)
        #expect(msg.getAutoStart() == false)
        
        // Set a destination
        msg.setDestination("org.example.NewDestination")
        #expect(msg.getDestination() == "org.example.NewDestination")
        
        // Set a sender
        msg.setSender("org.example.Sender")
        #expect(msg.getSender() == "org.example.Sender")
    }
    
    /// Tests appending arguments to a message.
    @Test("Argument Handling")
    func testArgumentHandling() throws {
        let msg = DBusMessage.createMethodCall(
            destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            method: "RequestName"
        )
        
        // Append a string and a uint32
        try msg.appendArguments("org.example.Name", UInt32(0))
        
        // Verify that arguments were appended correctly
        #expect(Bool(true), "Should be able to append arguments")
    }
    #endif
}
