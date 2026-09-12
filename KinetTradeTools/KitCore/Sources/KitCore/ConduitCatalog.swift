import Foundation

/// benddata.json 加载器
public enum ConduitCatalog {

    public struct Database: Codable {
        public let version: String
        public let source: String
        public let conduits: [ConduitSpec]
    }

    public static func load(bundle: Bundle? = nil) -> Database {
        let bundle = bundle ?? .module
        guard let url = bundle.url(forResource: "benddata", withExtension: "json") else {
            fatalError("KitCore: benddata.json missing from bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Database.self, from: data)
        } catch {
            fatalError("KitCore: benddata.json decode failed: \(error)")
        }
    }

    public static func specs(type: String? = nil, database: Database) -> [ConduitSpec] {
        let all = database.conduits
        guard let type else { return all }
        return all.filter { $0.type == type }
    }
}
