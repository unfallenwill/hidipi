/// Port of hidipi/src/hidipi/errors.py
public struct HiDPIError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
