import FluentSQLite
import Vapor

/// Called before your application initializes.
public func configure(_ config: inout Config, _ env: inout Environment, _ services: inout Services) throws {
    // Register providers first
    try services.register(FluentSQLiteProvider())

    // Register routes to the router
    let router = EngineRouter.default()
    try routes(router)
    services.register(router, as: Router.self)

    // Register middleware
    var middlewares = MiddlewareConfig() // Create _empty_ middleware config
    // middlewares.use(FileMiddleware.self) // Serves files from `Public/` directory
    middlewares.use(ErrorMiddleware.self) // Catches errors and converts to HTTP response
    services.register(middlewares)

    // Configure a SQLite database
    let sqlite = try SQLiteDatabase(storage: .memory)

    // Register the configured SQLite database to the database config.
    var databases = DatabasesConfig()
    databases.add(database: sqlite, as: .sqlite)
    services.register(databases)

    // Configure migrations
    var migrations = MigrationConfig()
    migrations.add(model: Todo.self, database: .sqlite)
    services.register(migrations)

    let server = OTRNServer()
    server.configure(router: router, services: &services)
}

public final class OTRNServer {

    let server = NIOWebSocketServer.default()
    let mainQueue = DispatchQueue(label: "Main")
    private (set) var sessions = [Session]()

    var onWriteData: ((Block) -> Void)?

    func configure(router: Router, services: inout Services) {

        let websocket = NIOWebSocketServer.websocketOTRN
        services.register(websocket.server, as: WebSocketServer.self)

        let blockchain = Blockchain(Block(data: ""))

        struct Empty: Content { }

        struct OTRNConvoySession: Content {
            let id: String
        }


        router.get { _ in
            "OTRN Server is running"
        }

        /// Create random session
        router.post("session") { req -> String in
            let session = Session()
            self.addSession(session)
            return "Hello, \(session.id)!"
        }

        /// Get/Create session by id
        router.post("session", String.parameter) { req -> String in
            let id = try req.parameters.next(String.self)
            if let session = self.sessions.first(where: {$0.id.elementsEqual(id)}) {
                return "Session found with: \(session.sockets.count) users"
            } else {
                self.addSession(.init(id: id))
                return "Session with id: \(id) created!"
            }
        }

        /// TODO: Return socket id for location following for certain user
        router.post("session", String.parameter, String.parameter) { req -> String in
            throw HTTPError(identifier: HTTPResponseStatus.notFound.reasonPhrase, reason:   "Not implemented")
        }

        /// TODO: Return socket id for location following for certain user
        router.post("group", String.parameter, String.parameter) { req -> String in
            throw HTTPError(identifier: HTTPResponseStatus.notFound.reasonPhrase, reason:   "Not implemented")
        }

        router.post("test") { req -> OTRNConvoySession in
            OTRNConvoySession(
                id: "test"
            )
        }

        addSession(Session(id:"test"))

        router.post("data") { req in
            blockchain.blocks.map { $0.key }.asJSON ?? ""
        }

        self.onWriteData = { block in
            blockchain.addBlock(block)
        }
    }

    func addSession(_ session: Session) {
        mainQueue.sync {
            session.attach(main: self)
            session.attach(websocket: self.server)
            self.sessions.append(session)
            mainQueue.async { [weak self] in
                self?.onWriteData?(Block(data: "Session with \(session.id) is started"))
            }
        }
    }

    func stop(sessionByID id: String) {
        mainQueue.sync {
            if let index = sessions.firstIndex(where: { $0.id.elementsEqual(id)}) {
                sessions[index].stop()
                sessions.remove(at: index)
                mainQueue.async { [weak self] in
                    self?.onWriteData?(Block(data: "Session with \(id) is stopped"))
                }
            }
        }
    }
}

final class Session {

    enum Models {

        struct Message<T: Codable>: Codable {
            let value: T
            let id: String
        }

        struct Player: Codable, Hashable {

            struct Location: Codable, Hashable {
                let latitude: Double
                let longitude: Double
            }

            let location: Location
        }

        struct PeersLocationsUpdated: Codable {
            let players: [Player]
        }

        struct OwnLocation: Codable{
            let current: Player
        }

        struct SessionStarted: Codable {}

        struct SessionFinished: Codable {}
    }

    struct Message: Codable {
        let value: String
        let type: String?
    }

    init(id: String = UUID().uuidString) {
        self.id = id
        print("\(self.id) - Session initialized)")
    }

    let id: String
    private (set) var sockets = [String: (WebSocket,Models.Player?)]()
    private lazy var queue = DispatchQueue(label: id)
    private weak var server: OTRNServer?

    private func broadcastLocations(socketID: String) {
        print("\(self.id) - Broadcasting locations")
        self.queue.sync {
            print("\(self.id) - Resolving locations")

            let anotherConnections = self.sockets
//                .filter { !$0.key.elementsEqual(socketID) }
            let anotherSockets = anotherConnections.map { $1.0 }
            let anotherSocketsIDs = anotherConnections.map { $0 }

            let anotherLocations = self.sockets
                .filter { !$0.key.elementsEqual(socketID) }
                .compactMap { $1.1 }

            let response = Models.PeersLocationsUpdated(players: anotherLocations)
            let message = Models.Message<Models.PeersLocationsUpdated>(value: response, id: self.id)

            if let data = message.asJSON {
                print("\(self.id) - Returning locations: \(response)")
                print("\(self.id) - Sending to ids: \(anotherSocketsIDs)")
                anotherSockets.forEach {
                    $0.send(data)
                }
            }
        }
    }

    func attach(main server: OTRNServer) {
        self.server = server
    }

    func attach(websocket server: NIOWebSocketServer) {
        server.get(at: [
            PathComponent(stringLiteral: "session"),
            PathComponent(stringLiteral: id)
        ]) { ws, req in

            let socketID = UUID().uuidString

            print("\(self.id) - New client: \(socketID)")

            func unmount() {
                self.queue.sync {
                   self.sockets.removeValue(forKey: socketID)
                }
            }

            func add(location:  Models.Message<Models.OwnLocation>) {
                self.queue.sync {
                    print("\(self.id) Client: \(socketID), sent location: \(location.value.current)")
                    print("\(self.id) - Syncing locations")
                    let current = self.sockets[socketID]
                    self.sockets.updateValue((current!.0,location.value.current), forKey: socketID)
                    let anotherConnections = self.sockets
                    let anotherSockets = anotherConnections.map { $1 }
                    let anotherSocketsIDs = anotherConnections.map { $0 }

                    let anotherLocations = self.sockets
                        .compactMap { $1.1 }

                    let message = Models.Message<Models.PeersLocationsUpdated>(value: Models.PeersLocationsUpdated(players: anotherLocations), id: self.id)

                    if let data = message.asJSON {
                        print("\(self.id) - Sending to ids: \(anotherSocketsIDs) locations: \(message.value.players)")
                        anotherSockets.forEach {
                            $0.0.send(data)
                        }
                    }
                }
            }

            func syncSockets() {
                self.queue.sync {
                    print("\(self.id) - Syncing sockets")
                    self.sockets.updateValue((ws,nil), forKey: socketID)
                    print("\(self.id) - Sockets synced: \(self.sockets.map{ $0 })")
                }
            }

            syncSockets()

            ws.onText { websocket, text in
                print("\(self.id) Client: \(socketID), sent message: \(text)")
                if let playersLocation = Models.Message<Models.OwnLocation>.from(jsonString: text) {
                    add(location: playersLocation)
                }
            }

            ws.onCloseCode { _ in
                print("\(self.id) - Connection closed for socket: \(socketID)")
                unmount()
            }

            ws.onError { (_, error) in
                print("\(self.id) - Connection failed for socket: \(socketID)")
                unmount()
            }
        }
    }

    func stop() {
        sockets.forEach { $0.value.0.close() }
        sockets.removeAll()
    }
}

public class Block: Codable {

    var index: Int = 0
    var dateCreated: String
    var previousHash: String!
    var hash: String!
    var data: String
    var nonce: Int
    var key: String { String(index) + dateCreated + previousHash + String(nonce) + data }

    init(data: String) {
        self.data = data
        self.dateCreated = Date().toString()
        self.nonce = 0
    }
}

public class Blockchain: Codable {

    private (set) var blocks :[Block] = [Block]()

    init(_ genesisBlock :Block) {
        addBlock(genesisBlock)
    }

    func addBlock(_ block :Block) {
        if self.blocks.isEmpty {
            block.previousHash = "0"
            block.hash = generateHash(for: block)
        } else {
            let previousBlock = getPreviousBlock()
            block.previousHash = previousBlock.hash
            block.index = self.blocks.count
            block.hash = generateHash(for: block)
        }
        self.blocks.append(block)
        displayBlock(block)
    }

    private func getPreviousBlock() -> Block {
        self.blocks[self.blocks.count - 1]
    }


    private func displayBlock(_ block :Block) {
        print(block.asJSON ?? "N/A")
    }

    private func generateHash(for block: Block) -> String {

        var hash = block.key.sha1Hash()

        while(!hash.hasPrefix("00")) {
            block.nonce += 1
            hash = block.key.sha1Hash()
        }

        return hash
    }

    func check(block: Block) -> Bool {
        let hash = block.key.sha1Hash()
        return hash.elementsEqual(block.hash)
    }

    func checkAll() -> Bool {
        blocks.map { check(block: $0) }.filter { $0 }.count == blocks.count
    }

    func recalc() -> Bool {
        let pairs = stride(from: 0,
                           to: blocks.endIndex,
                           by: 1)
            .map {
                (blocks[$0], $0 < blocks.index(before: blocks.endIndex) ? blocks[$0.advanced(by: 1)] : nil)
            }
        let count =  pairs
            .map {
                guard let second = $0.1 else { return true }
                return $0.0.hash.elementsEqual(second.previousHash)
            }
            .filter { $0 }.count
        return count == (blocks.count)
    }

    func validate() -> Bool {
        checkAll() && recalc()
    }
}



extension String {
    func sha1Hash() -> String {

        let task = Process()
        task.launchPath = "/usr/bin/shasum"
        task.arguments = []

        let inputPipe = Pipe()

        inputPipe.fileHandleForWriting.write(self.data(using: String.Encoding.utf8)!)

        inputPipe.fileHandleForWriting.closeFile()

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardInput = inputPipe
        task.launch()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let hash = String(data: data, encoding: String.Encoding.utf8)!
        return hash.replacingOccurrences(of: "  -\n", with: "")
    }
}

extension Date {

    func toString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: self)
    }
}

extension Services {
    mutating func registerWebsocketBasedProtocol() {
        register(NIOWebSocketServer.websocketOTRN.server, as: WebSocketServer.self)
    }
}

extension NIOWebSocketServer {
    static var websocketOTRN: OTRNServer { OTRNServer() }
}

extension Encodable {
    var asJSON: String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var asData: Data? {
        asJSON?.data(using: .utf8)
    }
}

extension Decodable {

    static func from(jsonString: String?) -> Self? {
        guard let json = jsonString else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(Self.self, from: json.data(using: .utf8)!)
    }

    static func from(data: Data?) -> Self? {
        guard let data = data else { return nil }
        if let string = String(data: data, encoding: .utf8) {
            return Self.from(jsonString: string)
        } else {
            return nil
        }
    }
}
