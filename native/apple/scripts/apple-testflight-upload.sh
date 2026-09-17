#!/bin/bash
# Upload an existing, reviewed iOS archive using an existing App Store Connect key.
# Usage: OPENSTREAM_ASC_KEY_ID=... OPENSTREAM_ASC_ISSUER_ID=... \
#   bash apple-testflight-upload.sh archive.xcarchive ExportOptions.plist output-directory
set -eu
umask 077

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 archive.xcarchive ExportOptions.plist output-directory" >&2
  exit 64
fi

archive_path="$1"
options_path="$2"
output_path="$3"
key_id="${OPENSTREAM_ASC_KEY_ID:?Set the existing App Store Connect key ID}"
issuer_id="${OPENSTREAM_ASC_ISSUER_ID:?Set the App Store Connect Issuer ID}"
key_path="${OPENSTREAM_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8}"

if [ ! -f "$key_path" ]; then
  echo "The configured App Store Connect private key file is missing." >&2
  exit 66
fi

python3 - "$archive_path" "$options_path" <<'PY'
import plistlib, sys
from pathlib import Path
archive = plistlib.loads((Path(sys.argv[1]) / 'Info.plist').read_bytes())
app = archive.get('ApplicationProperties', {})
options = plistlib.loads(Path(sys.argv[2]).read_bytes())
if app.get('CFBundleIdentifier') != 'com.orgista.openstream':
    raise SystemExit('Expected an OpenStream app archive.')
if not str(app.get('ApplicationPath', '')).endswith('.app'):
    raise SystemExit('Archive has no application product.')
if options.get('method') != 'app-store-connect' or options.get('destination') != 'upload':
    raise SystemExit('Expected App Store Connect upload options.')
if options.get('manageAppVersionAndBuildNumber') is not True:
    raise SystemExit('Enable build-number management to avoid reusing a TestFlight build number.')
if options.get('teamID') != app.get('Team'):
    raise SystemExit('Export options and archive must belong to the same developer team.')
PY

mkdir -p "$output_path"
exec xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist "$options_path" \
  -exportPath "$output_path" \
  -authenticationKeyPath "$key_path" \
  -authenticationKeyID "$key_id" \
  -authenticationKeyIssuerID "$issuer_id"
