#!/usr/bin/env python3
"""Fail closed on private identifiers; diagnostics never include matched content."""
import re
import sys
from pathlib import Path

# Split literals keep this gate from matching its own denylist.
names = ["Server" + "Plus", "our" + "zephyr", "xcx" + "hcprtpj", "mac" + "studio",
         "anth" + "ony", "gall" + "ardo", "jk" + "tv", "kav" + "kom", "tv" + "radiozap",
         "192.168.1." + "87", "192.168.1." + "189", "Q843" + "G8DW6C"]
patterns = [re.compile(re.escape(n), re.I) for n in names]
patterns += [re.compile("/" + "Users/"), re.compile("/" + "Volumes/"),
             re.compile(r"[A-Z0-9._%+-]+@orgista[.]com", re.I),
             re.compile(r"(?:issuer|issuer_id|issuerId)[^\n]*[0-9a-f]{8}-[0-9a-f-]{27,}", re.I),
             re.compile(r"PROVISIONING_PROFILE[^\n]*(?=[A-Z0-9]{10}[^\n]*;)(?=[A-Z0-9]*[0-9])[A-Z0-9]{10}[^\n]*;"),
             re.compile("-----BEGIN " + r"(?:[A-Z ]*PRIVATE KEY)-----")]
root = Path(sys.argv[1]).resolve()
failed = False
for path in sorted(root.rglob("*")):
    if ".git" in path.relative_to(root).parts:
        continue
    if path.is_symlink():
        print(f"{path.relative_to(root)}:1: symlinks are not exported")
        failed = True
        continue
    if not path.is_file():
        continue
    if path.suffix.lower() in {".p8", ".p12", ".mobileprovision", ".ipa"}:
        print(f"{path.relative_to(root)}:1: forbidden artifact")
        failed = True
    text = path.read_bytes().decode("utf-8", errors="replace")
    for number, line in enumerate(text.splitlines(), 1):
        sanitized = line.replace("support@orgista.com", "")
        if any(p.search(sanitized) for p in patterns):
            print(f"{path.relative_to(root)}:{number}: private identifier")
            failed = True
sys.exit(1 if failed else 0)
