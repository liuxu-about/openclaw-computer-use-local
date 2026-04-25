import Dispatch
import Foundation

let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

let rpcEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

private struct RPCEnvelope {
    let id: String
    let command: String
    let payloadData: Data

    init(line: String) throws {
        let data = Data(line.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelperCLIError.invalidInput("RPC request must be a JSON object.")
        }

        guard let id = object["id"] as? String, !id.isEmpty else {
            throw HelperCLIError.invalidInput("RPC request is missing a non-empty id.")
        }
        guard let command = object["command"] as? String, !command.isEmpty else {
            throw HelperCLIError.invalidInput("RPC request is missing a non-empty command.")
        }

        let payloadObject = object["payload"] ?? [:]
        if payloadObject is NSNull {
            self.payloadData = Data("{}".utf8)
        } else {
            guard JSONSerialization.isValidJSONObject(payloadObject) else {
                throw HelperCLIError.invalidInput("RPC payload must be a JSON object.")
            }
            self.payloadData = try JSONSerialization.data(withJSONObject: payloadObject)
        }

        self.id = id
        self.command = command
    }
}

func readStdin() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    if data.isEmpty, let empty = try? decoder.decode(T.self, from: Data("{}".utf8)) {
        return empty
    }
    return try decoder.decode(T.self, from: data)
}

func writeJSON<T: Encodable>(_ value: T) throws {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
}

func usage() -> String {
    """
    Usage: openclaw-computer-helper <health|observe|act|stop|use|serve>
      health   no stdin required
      observe  read ObserveRequest JSON from stdin
      act      read ActionRequest JSON from stdin
      stop     no stdin required
      use      read ComputerUseRequest JSON from stdin
      serve    start a long-lived stdio JSON-RPC loop
    """
}

func jsonObject<T: Encodable>(from value: T) throws -> Any {
    let data = try rpcEncoder.encode(value)
    return try JSONSerialization.jsonObject(with: data)
}

func writeRPCResponse(id: String, ok: Bool, resultObject: Any? = nil, error: String? = nil) throws {
    var envelope: [String: Any] = [
        "id": id,
        "ok": ok,
    ]
    if let resultObject {
        envelope["result"] = resultObject
    }
    if let error {
        envelope["error"] = error
    }

    let data = try JSONSerialization.data(withJSONObject: envelope)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

@MainActor
func rpcResult(for command: String, payloadData: Data, engine: ComputerUseEngine) async throws -> Any {
    switch command {
    case "health":
        return try jsonObject(from: engine.health())
    case "observe":
        return try jsonObject(from: await engine.observe(decodeOrThrow(ObserveRequest.self, from: payloadData)))
    case "act":
        return try jsonObject(from: await engine.act(decodeOrThrow(ActionRequest.self, from: payloadData)))
    case "stop":
        return try jsonObject(from: engine.stop())
    case "use":
        return try jsonObject(from: await engine.useTask(decodeOrThrow(ComputerUseRequest.self, from: payloadData)))
    default:
        throw HelperCLIError.usage("Unknown RPC command: \(command)")
    }
}

@MainActor
func serve() async {
    let engine = ComputerUseEngine()

    while let rawLine = readLine(strippingNewline: true) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            continue
        }

        var requestId = "unknown"
        do {
            let envelope = try RPCEnvelope(line: line)
            requestId = envelope.id
            let result = try await rpcResult(for: envelope.command, payloadData: envelope.payloadData, engine: engine)
            try writeRPCResponse(id: envelope.id, ok: true, resultObject: result)
        } catch {
            try? writeRPCResponse(id: requestId, ok: false, error: String(describing: error))
        }
    }
}

@MainActor
func run() async throws {
    guard CommandLine.arguments.count >= 2 else {
        throw HelperCLIError.usage(usage())
    }

    let engine = ComputerUseEngine()
    let command = CommandLine.arguments[1]
    switch command {
    case "health":
        try writeJSON(engine.health())
    case "observe":
        let request = try decodeOrThrow(ObserveRequest.self, from: readStdin())
        try writeJSON(await engine.observe(request))
    case "act":
        let request = try decodeOrThrow(ActionRequest.self, from: readStdin())
        try writeJSON(await engine.act(request))
    case "stop":
        try writeJSON(engine.stop())
    case "use":
        let request = try decodeOrThrow(ComputerUseRequest.self, from: readStdin())
        try writeJSON(await engine.useTask(request))
    case "serve":
        await serve()
    case "--help", "-h", "help":
        FileHandle.standardOutput.write(Data((usage() + "\n").utf8))
    default:
        throw HelperCLIError.usage("Unknown command: \(command)\n\n\(usage())")
    }
}

Task { @MainActor in
    do {
        try await run()
        Foundation.exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        Foundation.exit(1)
    }
}

dispatchMain()
