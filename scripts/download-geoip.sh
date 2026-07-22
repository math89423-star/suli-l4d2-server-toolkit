#!/bin/bash
# ============================================
# Download GeoLite2 City database for SourceMod
# ============================================
# SourceMod uses this for geolocation features.
# Requires a free MaxMind license key.
#
# 1. Register at https://www.maxmind.com/en/geolite2/signup
# 2. Get your license key from Account → License Keys
# 3. Run: MAXMIND_KEY=yourkey ./scripts/download-geoip.sh
#
# Or manually download GeoLite2-City.mmdb and place it in:
#   sourcemod/configs/geoip/GeoLite2-City.mmdb

set -e

GEOIP_DIR="$(cd "$(dirname "$0")/../sourcemod/configs/geoip" && pwd)"
mkdir -p "$GEOIP_DIR"

if [ -z "$MAXMIND_KEY" ]; then
    echo "Error: Set MAXMIND_KEY environment variable"
    echo "Usage: MAXMIND_KEY=yourkey $0"
    echo ""
    echo "Get a free key at: https://www.maxmind.com/en/geolite2/signup"
    exit 1
fi

echo "Downloading GeoLite2-City database..."
curl -sS -o "$GEOIP_DIR/GeoLite2-City.tar.gz" \
    "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=${MAXMIND_KEY}&suffix=tar.gz"

echo "Extracting..."
tar -xzf "$GEOIP_DIR/GeoLite2-City.tar.gz" -C "$GEOIP_DIR" --strip-components=1
rm "$GEOIP_DIR/GeoLite2-City.tar.gz"

echo "Done! GeoIP database installed to: $GEOIP_DIR/"
ls -lh "$GEOIP_DIR/GeoLite2-City.mmdb"
