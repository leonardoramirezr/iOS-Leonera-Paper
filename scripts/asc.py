#!/usr/bin/env python3
"""Utilidades de App Store Connect para el workflow de compilación.

Solo usa la biblioteca estándar de Python y `openssl` (para firmar el JWT ES256).

Variables de entorno:
  ASC_KEY_ID      ID de la clave de API.
  ASC_ISSUER_ID   Issuer ID.
  ASC_KEY_P8      Contenido del archivo .p8 (o ASC_KEY_PATH con su ruta).

Comandos:
  check                         Comprueba que la clave funciona y que hay al menos
                                un dispositivo iOS registrado.
  snapshot-dev-certs FILE       Guarda los números de serie de los certificados
                                «Apple Development» del llavero.
  revoke-new-dev-certs FILE     Revoca por la API los certificados «Apple Development»
                                del llavero que no estaban en FILE.
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def fail(message: str) -> None:
    print(f"::error title=App Store Connect::{message}", flush=True)
    sys.exit(1)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_signature_to_raw(der: bytes, size: int = 32) -> bytes:
    """Convierte una firma ECDSA DER (SEQUENCE {r, s}) al formato r||s de JWS."""
    if not der or der[0] != 0x30:
        raise ValueError("firma DER no válida")
    index = 2
    if der[1] & 0x80:
        index = 2 + (der[1] & 0x7F)
    values = []
    for _ in range(2):
        if der[index] != 0x02:
            raise ValueError("firma DER no válida")
        length = der[index + 1]
        index += 2
        values.append(der[index:index + length].lstrip(b"\x00").rjust(size, b"\x00"))
        index += length
    return values[0] + values[1]


def normalized_pem(content: str) -> str:
    """Acepta el .p8 tal cual o con los saltos de línea perdidos al copiarlo en un secret."""
    content = content.strip().replace("\\n", "\n")
    match = re.search(r"-----BEGIN ([A-Z ]+)-----(.*?)-----END \1-----", content, re.S)
    if not match:
        body = re.sub(r"\s+", "", content)
        label = "PRIVATE KEY"
    else:
        label = match.group(1)
        body = re.sub(r"\s+", "", match.group(2))
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return f"-----BEGIN {label}-----\n" + "\n".join(lines) + f"\n-----END {label}-----\n"


class Client:
    def __init__(self) -> None:
        self.key_id = os.environ.get("ASC_KEY_ID", "").strip()
        self.issuer_id = os.environ.get("ASC_ISSUER_ID", "").strip()
        missing = [name for name, value in (("ASC_KEY_ID", self.key_id), ("ASC_ISSUER_ID", self.issuer_id)) if not value]
        key_path = os.environ.get("ASC_KEY_PATH", "").strip()
        key_content = os.environ.get("ASC_KEY_P8", "")
        if not key_path and not key_content.strip():
            missing.append("ASC_KEY_P8")
        if missing:
            fail(f"Faltan variables: {', '.join(missing)}")
        if key_path:
            with open(key_path, encoding="utf-8") as handle:
                key_content = handle.read()
        handle = tempfile.NamedTemporaryFile("w", suffix=".p8", delete=False)
        handle.write(normalized_pem(key_content))
        handle.close()
        os.chmod(handle.name, 0o600)
        self.key_file = handle.name
        self._token: str | None = None
        self._token_time = 0.0

    def close(self) -> None:
        try:
            os.unlink(self.key_file)
        except OSError:
            pass

    def token(self) -> str:
        if self._token and time.time() - self._token_time < 600:
            return self._token
        now = int(time.time())
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        payload = {"iss": self.issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
        signing_input = ".".join(
            b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, payload)
        )
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.key_file],
            input=signing_input.encode(), capture_output=True, check=False,
        )
        if result.returncode != 0:
            fail("openssl no pudo firmar el JWT; revisa que ASC_KEY_P8 sea el contenido completo del .p8. "
                 + result.stderr.decode(errors="replace").strip())
        self._token = f"{signing_input}.{b64url(der_signature_to_raw(result.stdout))}"
        self._token_time = time.time()
        return self._token

    def request(self, method: str, path: str, params: dict | None = None):
        url = path if path.startswith("http") else API + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, method=method, headers={
            "Authorization": f"Bearer {self.token()}",
            "Accept": "application/json",
        })
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    body = response.read()
                    return json.loads(body) if body else None
            except urllib.error.HTTPError as error:
                body = error.read().decode(errors="replace")
                if error.code in (429, 500, 502, 503, 504) and attempt < 3:
                    time.sleep(2 ** attempt * 2)
                    continue
                raise ApiError(error.code, body) from None
            except urllib.error.URLError as error:
                if attempt < 3:
                    time.sleep(2 ** attempt * 2)
                    continue
                raise ApiError(0, str(error.reason)) from None
        raise ApiError(0, "sin respuesta")

    def paginate(self, path: str, params: dict | None = None):
        page = self.request("GET", path, params)
        while page:
            yield from page.get("data", [])
            next_url = (page.get("links") or {}).get("next")
            page = self.request("GET", next_url) if next_url else None


class ApiError(Exception):
    def __init__(self, status: int, body: str) -> None:
        super().__init__(f"HTTP {status}: {body[:500]}")
        self.status = status
        self.body = body

    def describe(self) -> str:
        try:
            errors = json.loads(self.body).get("errors", [])
            details = "; ".join(f"{e.get('title', '')}: {e.get('detail', '')}".strip(": ") for e in errors)
        except (ValueError, AttributeError):
            details = self.body[:300]
        hints = {
            401: "La clave no es válida (revisa ASC_KEY_ID, ASC_ISSUER_ID y ASC_KEY_P8).",
            403: "La clave no tiene permisos suficientes (se requiere una Team Key con rol Admin).",
        }
        return " ".join(part for part in (hints.get(self.status, f"HTTP {self.status}."), details) if part)


# ---------------------------------------------------------------- comandos


def command_check(client: Client) -> None:
    try:
        devices = list(client.paginate("/v1/devices", {
            "filter[platform]": "IOS",
            "filter[status]": "ENABLED",
            "limit": "200",
        }))
    except ApiError as error:
        fail(f"No se pudo usar la API de App Store Connect. {error.describe()}")
    print("La clave de API de App Store Connect funciona.")
    if not devices:
        fail("No hay ningún dispositivo iOS registrado en Apple Developer. "
             "Registra el UDID de tu iPhone en Certificates, Identifiers & Profiles › Devices.")
    print(f"Dispositivos iOS registrados: {len(devices)}")
    for device in devices:
        attributes = device.get("attributes", {})
        udid = attributes.get("udid", "")
        masked = f"{udid[:6]}…{udid[-4:]}" if len(udid) > 10 else udid
        print(f"  • {attributes.get('name', '?')} ({attributes.get('deviceClass', '?')}, {attributes.get('model') or '—'}) {masked}")


def normalize_serial(serial: str) -> str:
    return serial.strip().upper().replace(":", "").lstrip("0")


def keychain_dev_cert_serials() -> set[str]:
    result = subprocess.run(
        ["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
        capture_output=True, text=True, check=False,
    )
    pems = re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", result.stdout, re.S)
    serials = set()
    for pem in pems:
        output = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=pem,
                                capture_output=True, text=True, check=False).stdout
        match = re.search(r"serial=([0-9A-Fa-f:]+)", output)
        if match:
            serials.add(normalize_serial(match.group(1)))
    return serials


def command_snapshot(path: str) -> None:
    serials = sorted(keychain_dev_cert_serials())
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(serials) + ("\n" if serials else ""))
    print(f"Certificados «Apple Development» en el llavero antes de compilar: {len(serials)}")


def command_revoke(client: Client, path: str) -> None:
    try:
        with open(path, encoding="utf-8") as handle:
            before = {normalize_serial(line) for line in handle if line.strip()}
    except FileNotFoundError:
        print("No hay instantánea previa de certificados; no se revoca nada.")
        return
    new = keychain_dev_cert_serials() - before
    if not new:
        print("xcodebuild no creó certificados de desarrollo nuevos.")
        return
    print(f"Certificados de desarrollo creados en esta ejecución: {len(new)}")
    try:
        certificates = list(client.paginate("/v1/certificates", {
            "limit": "200",
            "fields[certificates]": "serialNumber,certificateType,displayName,name",
        }))
    except ApiError as error:
        print(f"::warning title=Certificados::No se pudieron listar los certificados: {error.describe()}")
        return
    pending = set(new)
    for certificate in certificates:
        attributes = certificate.get("attributes", {})
        serial = normalize_serial(attributes.get("serialNumber") or "")
        if serial not in pending:
            continue
        name = attributes.get("displayName") or attributes.get("name") or certificate["id"]
        try:
            client.request("DELETE", f"/v1/certificates/{certificate['id']}")
            print(f"Revocado: {name} ({attributes.get('certificateType')}, serie {serial})")
            pending.discard(serial)
        except ApiError as error:
            print(f"::warning title=Certificados::No se pudo revocar {name}: {error.describe()}")
    for serial in sorted(pending):
        print(f"::warning title=Certificados::El certificado con serie {serial} no aparece en App Store Connect.")


def main(argv: list[str]) -> None:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    command, args = argv[0], argv[1:]
    if command == "snapshot-dev-certs" and len(args) == 1:
        command_snapshot(args[0])
        return
    client = Client()
    try:
        if command == "check" and not args:
            command_check(client)
        elif command == "revoke-new-dev-certs" and len(args) == 1:
            command_revoke(client, args[0])
        else:
            fail(f"Comando no válido: {' '.join(argv)}")
    finally:
        client.close()


if __name__ == "__main__":
    main(sys.argv[1:])
