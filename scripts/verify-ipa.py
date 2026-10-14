#!/usr/bin/env python3
"""Comprueba que cada bundle del IPA (app y extensiones) lleva un perfil Ad Hoc.

Uso: scripts/verify-ipa.py RUTA.ipa
Requiere macOS (`security cms` para leer el perfil firmado).
"""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import tempfile
import zipfile


def fail(message: str) -> None:
    print(f"::error title=IPA::{message}", flush=True)
    sys.exit(1)


def main(ipa: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(tmp)
        payload = os.path.join(tmp, "Payload")
        bundles = []
        for root, dirs, _ in os.walk(payload):
            for name in dirs:
                if name.endswith((".app", ".appex")):
                    bundles.append(os.path.join(root, name))
        if not bundles:
            fail("El IPA no contiene ninguna app.")

        device_counts = set()
        for bundle in sorted(bundles):
            relative = os.path.relpath(bundle, payload)
            profile_path = os.path.join(bundle, "embedded.mobileprovision")
            if not os.path.isfile(profile_path):
                fail(f"{relative} no lleva embedded.mobileprovision.")
            decoded = subprocess.run(["security", "cms", "-D", "-i", profile_path],
                                     capture_output=True, check=False)
            if decoded.returncode != 0:
                fail(f"No se pudo leer el perfil de {relative}: {decoded.stderr.decode(errors='replace')}")
            profile = plistlib.loads(decoded.stdout)
            devices = profile.get("ProvisionedDevices") or []
            entitlements = profile.get("Entitlements", {})
            if profile.get("ProvisionsAllDevices"):
                fail(f"{relative} usa un perfil Enterprise, no Ad Hoc.")
            if not devices:
                fail(f"{relative} no usa un perfil Ad Hoc (no incluye dispositivos).")
            if entitlements.get("get-task-allow"):
                fail(f"{relative} lleva un perfil de desarrollo (get-task-allow), no Ad Hoc.")
            device_counts.add(len(devices))
            print(f"✓ {relative}: perfil «{profile.get('Name')}» ({profile.get('TeamName', '')}), "
                  f"{len(devices)} dispositivo(s), caduca {profile.get('ExpirationDate')}")
        print(f"Dispositivos incluidos: {min(device_counts)}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    main(sys.argv[1])
