#!/bin/bash
# Regenerates Sources/BetterAirdropCore/Resources/cities.bin from GeoNames cities15000
# (all cities with population >= 15,000). Data: GeoNames, CC BY 4.0, https://www.geonames.org
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL https://download.geonames.org/export/dump/cities15000.zip -o "$tmp/cities.zip"
unzip -q "$tmp/cities.zip" -d "$tmp"
swift run -c release betterairdrop-pack-cities "$tmp/cities15000.txt" Sources/BetterAirdropCore/Resources/cities.bin
