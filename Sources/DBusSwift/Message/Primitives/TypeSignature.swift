// D-Bus Type Signature Parser for SwiftNIO-only implementation
// No Foundation usage

/// A type signature parser for D-Bus messages.
///
/// Type signatures in D-Bus are strings of type codes that describe the types of values
/// in a message. This struct parses these signatures into a list of `DBusType` values.
///
/// According to the D-Bus specification, valid signatures must:
/// - Contain only type codes, parentheses, and curly braces
/// - Not nest containers more than 32 levels deep
/// - Not exceed 255 bytes in length
/// - Consist of complete types (all arrays must have element types, all structs must have open and close parentheses)
///
/// - SeeAlso: [D-Bus Type Signatures](https://dbus.freedesktop.org/doc/dbus-specification.html#type-system)
public struct DBusTypeSignature {
  /// The parsed D-Bus types contained in this signature
  public let types: [DBusType]

  /// The raw signature string
  public let raw: String

  /// Creates a new type signature by parsing the given string.
  ///
  /// - Parameter signature: The D-Bus type signature to parse
  /// - Throws: `Error` if the signature is invalid according to D-Bus rules
  public init(_ signature: String) throws {
    // According to the spec, signatures must not exceed 255 bytes
    guard signature.utf8.count <= 255 else {
      throw Error.tooLong
    }

    self.raw = signature
    var parser = Parser(signature)
    self.types = try parser.parseAll()
    if !parser.isAtEnd {
      throw Error.extraCharacters
    }
  }

  // MARK: - Parser

  /// Internal parser for D-Bus type signatures
  internal struct Parser {
    let signature: String
    var index: String.Index
    var isAtEnd: Bool { index == signature.endIndex }

    /// Track container nesting depth to enforce D-Bus limit of 32 levels
    private var arrayDepth = 0
    private var structDepth = 0

    init(_ signature: String) {
      self.signature = signature
      self.index = signature.startIndex
    }

    mutating func parseAll() throws -> [DBusType] {
      var result: [DBusType] = []
      while !isAtEnd {
        result.append(try parseType())
      }
      return result
    }

    mutating func parseType() throws -> DBusType {
      guard !isAtEnd else { throw Error.unexpectedEnd }
      let c = signature[index]
      index = signature.index(after: index)
      switch c {
      case "y": return .byte
      case "b": return .boolean
      case "n": return .int16
      case "q": return .uint16
      case "i": return .int32
      case "u": return .uint32
      case "x": return .int64
      case "t": return .uint64
      case "d": return .double
      case "s": return .string
      case "o": return .objectPath
      case "g": return .signature
      case "h": return .unixFd
      case "v": return .variant
      case "a":
        // Check array nesting depth (limited to 32 per the spec)
        arrayDepth += 1
        if arrayDepth > 32 {
          throw Error.tooDeep
        }
        let element = try parseType()
        arrayDepth -= 1
        return .array(element)
      case "(":
        // Check struct nesting depth (limited to 32 per the spec)
        structDepth += 1
        if structDepth > 32 {
          throw Error.tooDeep
        }

        var fields: [DBusType] = []
        while !isAtEnd, signature[index] != ")" {
          fields.append(try parseType())
        }

        guard !isAtEnd, signature[index] == ")" else { throw Error.unmatchedParenthesis }
        index = signature.index(after: index)

        // Empty structs are not allowed per the spec
        if fields.isEmpty {
          throw Error.emptyStruct
        }

        structDepth -= 1
        return .structure(fields)
      case "{":
        // Check for dictionary entry completeness
        // We need at least one character for the key type
        guard !isAtEnd else { throw Error.unmatchedBrace }

        // Dictionary entries must be inside arrays
        let key = try parseType()

        // Key type must be a basic type, not a container
        // According to the spec, only basic types can be dictionary keys
        switch key {
        case .byte, .boolean, .int16, .uint16, .int32, .uint32, .int64, .uint64,
          .double, .string, .objectPath, .signature, .unixFd:
          break  // These are valid basic types for dict keys
        default:
          throw Error.invalidDictKey
        }

        // Make sure we have a value type as well
        guard !isAtEnd else { throw Error.unmatchedBrace }

        let value = try parseType()
        guard !isAtEnd, signature[index] == "}" else { throw Error.unmatchedBrace }
        index = signature.index(after: index)
        return .dictEntry(key: key, value: value)
      default:
        throw Error.invalidTypeChar(c)
      }
    }
  }

  /// Errors that can occur during signature parsing
  internal enum Error: Swift.Error, CustomStringConvertible {
    case unexpectedEnd
    case unmatchedParenthesis
    case unmatchedBrace
    case invalidTypeChar(Character)
    case extraCharacters
    case tooLong
    case tooDeep
    case emptyStruct
    case invalidDictKey

    public var description: String {
      switch self {
      case .unexpectedEnd: return "Unexpected end of signature string."
      case .unmatchedParenthesis: return "Unmatched parenthesis in signature."
      case .unmatchedBrace: return "Unmatched brace in signature."
      case .invalidTypeChar(let c): return "Invalid type character: \(c)"
      case .extraCharacters: return "Extra characters after valid signature."
      case .tooLong: return "Signature exceeds maximum length of 255 bytes."
      case .tooDeep: return "Container nesting exceeds maximum depth of 32."
      case .emptyStruct: return "Empty structs are not allowed in D-Bus."
      case .invalidDictKey: return "Dictionary entry keys must be basic types."
      }
    }
  }
}
