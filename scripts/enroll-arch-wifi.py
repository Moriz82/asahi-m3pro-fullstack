#!/usr/bin/env python3
"""Create a private NetworkManager keyfile without printing its secret."""
import getpass
import os
from pathlib import Path
import sys
import uuid

destination = Path(sys.argv[1])
ssid = sys.argv[2]
if not 1 <= len(ssid.encode()) <= 32 or any(c in ssid for c in "\r\n\\"):
    raise SystemExit("Unsupported SSID encoding")
psk = getpass.getpass("Wi-Fi password (hidden): ")
if not 8 <= len(psk) <= 63 or any(c in psk for c in "\r\n\\"):
    raise SystemExit("Expected an 8-63 character WPA passphrase without line breaks or backslashes")
profile = (f"[connection]\nid=M3 development Wi-Fi\nuuid={uuid.uuid4()}\ntype=wifi\nautoconnect=true\n\n"
           f"[wifi]\nmode=infrastructure\nssid={ssid}\n\n"
           f"[wifi-security]\nkey-mgmt=wpa-psk\npsk={psk}\n\n"
           "[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n")
with os.fdopen(os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as stream:
    stream.write(profile)
print("Private Wi-Fi profile written; secret not displayed.")
