import Foundation

/// A city from the bundled GeoNames table (CC BY 4.0, https://www.geonames.org).
public struct Place: Codable, Sendable, Equatable {
    public var city: String          // ASCII name, e.g. "Montreal"
    public var countryCode: String   // ISO 3166-1 alpha-2, e.g. "CA"
    public var distanceKm: Double
}

/// Offline reverse geocoding: nearest city with population >= 15,000 within `maxDistanceKm`.
///
/// Packed format (`cities.bin`, little-endian):
///   magic "AIRCITY1" · UInt32 count · UInt32 stringBytes
///   count × record { Int32 latE5, Int32 lonE5, UInt32 nameOffset, UInt8 nameLength, 2×UInt8 country, UInt8 popClass }
///   (popClass = round(8·log2(population)), so population ≈ 2^(popClass/8))
///   stringBytes of ASCII names
public final class Places: @unchecked Sendable {
    struct Record { var lat: Double; var lon: Double; var name: String; var country: String; var population: Double }

    static let magic = Array("AIRCITY1".utf8)
    static let recordSize = 16
    let records: [Record]
    public var count: Int { records.count }

    public enum Error: Swift.Error, CustomStringConvertible {
        case badFormat(String), notFound
        public var description: String {
            switch self {
            case .badFormat(let why): "cities table is corrupt: \(why)"
            case .notFound: "cities table not found (set BETTERAIRDROP_CITIES or reinstall)"
            }
        }
    }

    public init(packed data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 16, Array(b[0..<8]) == Self.magic else { throw Error.badFormat("bad magic") }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24 }
        let n = Int(u32(8)), sLen = Int(u32(12))
        let sBase = 16 + n * Self.recordSize
        guard b.count == sBase + sLen else { throw Error.badFormat("size mismatch") }
        var out: [Record] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let o = 16 + i * Self.recordSize
            let lat = Double(Int32(bitPattern: u32(o))) / 1e5
            let lon = Double(Int32(bitPattern: u32(o + 4))) / 1e5
            let off = Int(u32(o + 8)), len = Int(b[o + 12])
            guard sBase + off + len <= b.count else { throw Error.badFormat("name out of range") }
            let name = String(decoding: b[(sBase + off)..<(sBase + off + len)], as: UTF8.self)
            let cc = String(decoding: b[(o + 13)..<(o + 15)], as: UTF8.self)
            let pop = pow(2, Double(b[o + 15]) / 8)
            out.append(Record(lat: lat, lon: lon, name: name, country: cc, population: pop))
        }
        records = out
    }

    /// Loads the table: `$BETTERAIRDROP_CITIES`, then `<prefix>/share/betterairdrop/cities.bin`, then the SwiftPM resource bundle.
    public static func load() throws -> Places {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["BETTERAIRDROP_CITIES"] { candidates.append(URL(fileURLWithPath: env)) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exe.appendingPathComponent("../share/betterairdrop/cities.bin").standardized)
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try Places(packed: Data(contentsOf: url))
        }
        if let url = Bundle.module.url(forResource: "cities", withExtension: "bin") {
            return try Places(packed: Data(contentsOf: url))
        }
        throw Error.notFound
    }

    /// Shared instance, loaded lazily. `nil` if the table is missing (place is then simply omitted).
    public static let shared: Places? = try? load()

    /// The city a photo was taken in: the most populous city whose radius covers the point
    /// (radius grows with population: 3 km at 100k people, ~15 km for Toronto), otherwise the nearest
    /// city within `maxDistanceKm`. This keeps downtown Montreal "Montreal", not the borough "Ville-Marie",
    /// while a photo in Mississauga stays "Mississauga".
    public func nearest(latitude: Double, longitude: Double, maxDistanceKm: Double = 25) -> Place? {
        let dLat = maxDistanceKm / 110.0 + 0.01
        let dLon = dLat / max(cos(latitude * .pi / 180), 0.01)
        var nearest: (Record, Double)?
        var covering: (Record, Double)?
        for r in records where abs(r.lat - latitude) <= dLat {
            var dl = abs(r.lon - longitude)
            if dl > 180 { dl = 360 - dl }
            guard dl <= dLon else { continue }
            let d = Self.haversineKm(latitude, longitude, r.lat, r.lon)
            guard d <= maxDistanceKm else { continue }
            if d < (nearest?.1 ?? .infinity) { nearest = (r, d) }
            if d <= Self.radiusKm(population: r.population), r.population > (covering?.0.population ?? 0) { covering = (r, d) }
        }
        return (covering ?? nearest).map { Place(city: $0.0.name, countryCode: $0.0.country, distanceKm: ($0.1 * 10).rounded() / 10) }
    }

    static func radiusKm(population: Double) -> Double {
        min(25, max(3, 3 * (population / 100_000).squareRoot()))
    }

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, p = Double.pi / 180
        let a = sin((lat2 - lat1) * p / 2), b = sin((lon2 - lon1) * p / 2)
        let h = a * a + cos(lat1 * p) * cos(lat2 * p) * b * b
        return 2 * r * asin(min(1, sqrt(h)))
    }

    // MARK: Packing

    static let skippedFeatureCodes: Set<String> = ["PPLX", "PPLH", "PPLQ", "PPLW", "PPLCH"]

    /// Packs GeoNames dump rows (tab-separated, the `cities15000.txt` format) into the binary table.
    /// Columns used: 2 asciiname, 4 latitude, 5 longitude, 7 feature code, 8 country code, 14 population.
    /// City sections (PPLX, e.g. "Indre By" inside Copenhagen) and historical/abandoned places are dropped,
    /// so a photo in central Copenhagen gets "copenhagen", not a district name.
    public static func pack(geonamesTSV text: String) throws -> Data {
        var recs: [(Int32, Int32, String, String, UInt8)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count > 8, let lat = Double(f[4]), let lon = Double(f[5]) else { continue }
            guard !skippedFeatureCodes.contains(String(f[7])) else { continue }
            let name = String(f[2]).filter { $0.isASCII }
            let cc = String(f[8])
            guard !name.isEmpty, name.utf8.count <= 255, cc.utf8.count == 2 else { continue }
            let pop = max(1, Double(f.count > 14 ? f[14] : "") ?? 15_000)
            let popClass = UInt8(min(255, max(0, (8 * log2(pop)).rounded())))
            recs.append((Int32((lat * 1e5).rounded()), Int32((lon * 1e5).rounded()), name, cc, popClass))
        }
        recs.sort { $0.0 < $1.0 }
        var strings: [UInt8] = []
        var offsets: [String: UInt32] = [:]
        var body: [UInt8] = []
        func put32(_ v: UInt32, _ a: inout [UInt8]) { for s in stride(from: 0, to: 32, by: 8) { a.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        for (lat, lon, name, cc, popClass) in recs {
            let off: UInt32
            if let o = offsets[name] { off = o } else { off = UInt32(strings.count); offsets[name] = off; strings += Array(name.utf8) }
            put32(UInt32(bitPattern: lat), &body); put32(UInt32(bitPattern: lon), &body); put32(off, &body)
            body.append(UInt8(name.utf8.count)); body += Array(cc.utf8); body.append(popClass)
        }
        var out = magic
        put32(UInt32(recs.count), &out); put32(UInt32(strings.count), &out)
        return Data(out + body + strings)
    }
}
