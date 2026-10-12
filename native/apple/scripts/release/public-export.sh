#!/bin/bash
# Export only distributable source. Never add owner notes to this allowlist.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
checkout="${1:?usage: public-export.sh <public-checkout>}"
checkout="$(cd "$checkout" && pwd)"
python3 - "$root" "$checkout/native/apple" <<'PYDEST'
from pathlib import Path
import sys
source, destination = (Path(p).resolve() for p in sys.argv[1:])
if source == destination or source in destination.parents or destination in source.parents:
    raise SystemExit('FAIL: destination overlaps private source')
PYDEST
[[ -d "$checkout/.git" ]] || { echo 'FAIL: destination must be a checkout'; exit 1; }
command -v gitleaks >/dev/null || { echo 'FAIL: gitleaks is required'; exit 1; }
stage="$(mktemp -d /tmp/openstream-public-export.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
# Exclusions apply at every depth, including unexpected future output folders.
python3 - "$root" "$stage/files" <<'PYLIST'
import subprocess, sys
from pathlib import Path
root=Path(sys.argv[1])
excluded={'build','xcuserdata','design','verification-artifacts','.claude','signing','.build','dev-sources'}
notes=('AGENTS.md','OWNER-TODO.md','DELIVERIES.md','GUI-AUDIT.md','SHIP-CHECKLIST.md')
items=[]
for name in ['Package.swift','Package.resolved','Sources','Tests','Apps','scripts']:
    entry=root/name
    paths=[entry] if entry.is_file() else sorted(entry.rglob('*'))
    for p in paths:
        if not p.is_file() or p.is_symlink(): continue
        rel=p.relative_to(root)
        if any(part in excluded for part in rel.parts): continue
        if p.name in notes or p.name.startswith(('FEEDBACK','HANDOFF','.env','ExportOptions')): continue
        if p.suffix.lower() in {'.ipa','.xcarchive','.p8','.p12','.mobileprovision','.xcuserstate'}: continue
        if any(part.endswith('.xcarchive') for part in rel.parts): continue
        if rel.parts[:3]==('Tests','Fixtures','private'): continue
        if rel.parts[0]=='Tests' and p.stat().st_size>5*1024*1024: continue
        if 'out' in rel.parts:
            if p.suffix!='.mkv' or subprocess.run(['git','-C',str(root),'ls-files','--error-unmatch',str(rel)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode: continue
        if rel.parts[0]=='scripts' and not (rel.parts[1]=='release' or p.name in {'sdk-floor-check.sh','apple-license-check.sh','check-no-addons-in-release.sh','seed-sim.sh','export-appstore-screenshots.py'}): continue
        items.append(str(rel))
Path(sys.argv[2]).write_text('\n'.join(items)+'\n')
PYLIST
mkdir "$stage/tree"
rsync -a --files-from="$stage/files" "$root/" "$stage/tree/"
# SMB reports executable bits on ordinary source files. Preserve Git's modes,
# with conventional modes for new files, instead of publishing that noise.
python3 - "$root" "$stage/tree" <<'PYMODE'
from pathlib import Path
import subprocess, sys
root, tree = map(Path, sys.argv[1:])
prefix = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--show-prefix'], text=True).strip()
tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--full-name', '--stage', '-z'])
modes = {}
for entry in tracked.split(b'\0'):
    if not entry: continue
    metadata, name = entry.split(b'\t', 1)
    name = name.decode()
    if name.startswith(prefix): modes[name[len(prefix):]] = metadata.split()[0]
for p in tree.rglob('*'):
    if p.is_dir(): p.chmod(0o755)
    elif p.is_file():
        rel = str(p.relative_to(tree))
        mode = modes.get(rel)
        executable = mode == b'100755' or (mode is None and p.read_bytes().startswith(b'#!'))
        p.chmod(0o755 if executable else 0o644)
PYMODE
# Public builds choose their own signing. Private signing files are never edited.
python3 - "$stage/tree/Apps/OpenStreamApps.xcodeproj/project.pbxproj" <<'PYSIGN'
from pathlib import Path
import os,re,sys
p=Path(sys.argv[1]); original=p.stat(); text=p.read_text()
text=re.sub(r'(?m)^(\s*)(DEVELOPMENT_TEAM|PROVISIONING_PROFILE_SPECIFIER|PROVISIONING_PROFILE|CODE_SIGN_IDENTITY)(\[[^\n]*?\])? = [^\n]*;',r'\1\2\3 = "";',text)
text=text.replace('CODE_SIGN_STYLE = Manual;', 'CODE_SIGN_STYLE = Automatic;')
p.write_text(text)
os.utime(p, ns=(original.st_atime_ns, original.st_mtime_ns))
PYSIGN
python3 "$root/scripts/release/public-scrub.py" "$stage/tree"
gitleaks dir "$stage/tree" --redact --no-banner --log-level error > "$stage/gitleaks.log" 2>&1 || { echo 'FAIL: gitleaks found sensitive content (details withheld)'; exit 1; }
mkdir -p "$checkout/native/apple"
rsync -a --checksum --delete "$stage/tree/" "$checkout/native/apple/"
python3 "$root/scripts/release/public-scrub.py" "$checkout"
gitleaks dir "$checkout" --redact --no-banner --log-level error > "$stage/gitleaks-public.log" 2>&1 || { echo 'FAIL: public checkout gitleaks gate'; exit 1; }
echo 'PASS: sanitized allowlist export, scrub gate and gitleaks'
