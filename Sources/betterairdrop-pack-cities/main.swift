// Packs a GeoNames dump (cities15000.txt) into betterairdrop's binary city table.
// Usage: betterairdrop-pack-cities <cities15000.txt> <out.bin>
import BetterAirdropCore
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: betterairdrop-pack-cities <cities15000.txt> <out.bin>\n".utf8))
    exit(2)
}
let text = try String(contentsOfFile: args[1], encoding: .utf8)
let data = try Places.pack(geonamesTSV: text)
try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
let places = try Places(packed: data)
print("packed \(places.count) cities into \(args[2]) (\(data.count / 1024) KB)")
