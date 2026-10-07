#!/usr/bin/env python3
"""Persistent self-signed identity for the free distribution channel.

Private material lives outside the repository. Never generate an identity in CI:
import the existing encrypted PKCS#12 instead, and check the committed fingerprint.
"""
import argparse
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import tempfile
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
PIN = ROOT / "Config/CodeSigningIdentity.txt"
DIRECTORY = Path(os.environ.get(
    "QUERYCRAFT_SIGNING_DIRECTORY",
    str(Path.home() / "Library/Application Support/QueryCraftSigning"),
)).expanduser().resolve()
KEYCHAIN = DIRECTORY / "signing.keychain-db"


def run(*args, input=None):
    result = subprocess.run([str(arg) for arg in args], input=input,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        # Do not echo arguments: security commands include keychain passwords.
        raise RuntimeError(f"{args[0]} failed: {result.stderr.decode().strip()}")
    return result.stdout


def search_list():
    return shlex.split(run("security", "list-keychains", "-d", "user").decode())


def fingerprint(certificate):
    output = run("openssl", "x509", "-in", certificate, "-noout", "-fingerprint", "-sha1")
    return output.decode().strip().split("=", 1)[1].replace(":", "").upper()


def expected_identity():
    identity = PIN.read_text().strip()
    if not re.fullmatch(r"[A-F0-9]{40}", identity):
        raise RuntimeError("Invalid Config/CodeSigningIdentity.txt")
    return identity


def activate():
    identity = expected_identity()
    if (DIRECTORY / "identity.txt").read_text().strip() != identity:
        raise RuntimeError("Local certificate does not match the committed fingerprint.")
    password = (DIRECTORY / "keychain-password").read_text().strip()
    run("security", "unlock-keychain", "-p", password, KEYCHAIN)
    paths = search_list()
    if str(KEYCHAIN) not in paths:
        run("security", "list-keychains", "-d", "user", "-s", *paths, KEYCHAIN)
    identities = run("security", "find-identity", "-p", "codesigning", KEYCHAIN).decode()
    if identity not in identities:
        raise RuntimeError("The signing keychain does not contain the pinned certificate and private key.")
    return identity


def install(p12, p12_password, identity):
    password = secrets.token_hex(32)
    (DIRECTORY / "keychain-password").write_text(password)
    run("security", "create-keychain", "-p", password, KEYCHAIN)
    run("security", "unlock-keychain", "-p", password, KEYCHAIN)
    run("security", "set-keychain-settings", "-lut", "21600", KEYCHAIN)
    run("security", "import", p12, "-k", KEYCHAIN, "-P", p12_password,
        "-T", "/usr/bin/codesign")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:",
        "-s", "-k", password, KEYCHAIN)
    (DIRECTORY / "identity.txt").write_text(identity + "\n")
    activate()


def provision(from_ci):
    if from_ci:
        for name in ("QUERYCRAFT_SIGNING_P12_BASE64", "QUERYCRAFT_SIGNING_P12_PASSWORD"):
            if not os.environ.get(name):
                raise RuntimeError("Required GitHub Actions secret is missing: " + name)
    if KEYCHAIN.exists():
        print("Using existing identity: " + activate())
        return
    if DIRECTORY.exists() and any(DIRECTORY.iterdir()):
        raise RuntimeError("Signing directory contains material but no keychain. Restore it; do not replace the certificate.")
    if not from_ci and PIN.exists():
        raise RuntimeError("A certificate is already pinned. Restore its private key instead of generating a replacement.")
    DIRECTORY.mkdir(parents=True, mode=0o700, exist_ok=True)
    DIRECTORY.chmod(0o700)
    previous_paths = search_list()
    try:
        p12 = DIRECTORY / "identity.p12"
        if from_ci:
            p12.write_bytes(base64.b64decode(os.environ["QUERYCRAFT_SIGNING_P12_BASE64"], validate=True))
            p12_password = os.environ["QUERYCRAFT_SIGNING_P12_PASSWORD"]
            with tempfile.TemporaryDirectory(dir=DIRECTORY) as temporary:
                certificate = Path(temporary) / "certificate.pem"
                run("openssl", "pkcs12", "-in", p12, "-passin", "stdin",
                    "-clcerts", "-nokeys", "-out", certificate,
                    input=(p12_password + "\n").encode())
                identity = fingerprint(certificate)
            if identity != expected_identity():
                raise RuntimeError("Imported certificate does not match Config/CodeSigningIdentity.txt")
        else:
            p12_password = secrets.token_hex(32)
            with tempfile.TemporaryDirectory(dir=DIRECTORY) as temporary:
                temporary = Path(temporary)
                config = temporary / "certificate.cnf"
                config.write_text("""[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = QueryCraft Code Signing
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
                key = temporary / "private.pem"
                certificate = DIRECTORY / "certificate.pem"
                run("openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes",
                    "-x509", "-days", "3650", "-config", config,
                    "-keyout", key, "-out", certificate)
                run("openssl", "pkcs12", "-export", "-inkey", key, "-in", certificate,
                    "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                    "-macalg", "sha1", "-out", p12, "-passout", "stdin",
                    input=(p12_password + "\n").encode())
                identity = fingerprint(certificate)
            PIN.write_text(identity + "\n")
        (DIRECTORY / "p12-password").write_text(p12_password)
        install(p12, p12_password, identity)
        print("Signing identity ready: " + identity)
        print("Private backup directory: " + str(DIRECTORY))
    except Exception:
        # Retain generated material for recovery; never silently regenerate it.
        run("security", "list-keychains", "-d", "user", "-s", *previous_paths)
        raise


def verify(app):
    run("codesign", "--verify", "--deep", "--strict", app)
    with tempfile.TemporaryDirectory() as temporary:
        prefix = Path(temporary) / "certificate"
        run("codesign", "-d", "--extract-certificates=" + str(prefix), app)
        certificate = Path(str(prefix) + "0")
        if not certificate.exists():
            raise RuntimeError("Application is ad-hoc or unsigned; persistent signing is required.")
        pem = Path(temporary) / "leaf.pem"
        pem.write_bytes(run("openssl", "x509", "-inform", "DER", "-in", certificate))
        if fingerprint(pem) != expected_identity():
            raise RuntimeError("Application certificate does not match the pinned identity.")
    print("Verified persistent signature: " + str(app))


def sign(app):
    identity = activate()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] not in (
        "io.github.future0923.QueryCraft", "io.github.future0923.QueryCraft.Dev"
    ):
        raise RuntimeError("Only QueryCraft application bundles can be signed.")
    entitlements = run("codesign", "-d", "--entitlements", ":-", app)
    if entitlements and plistlib.loads(entitlements).get("com.apple.security.app-sandbox"):
        raise RuntimeError("The free self-signed distribution channel requires the non-sandboxed configuration.")
    spec = importlib.util.spec_from_file_location("credential_helper", ROOT / "scripts/credential-helper.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    # This helper has a separate, stable installation version. Main app updates
    # never overwrite an already installed helper of that version.
    helper.embed(app, SimpleNamespace(run=run, KEYCHAIN=KEYCHAIN), identity)
    # Keep Sparkle's upstream signatures. Only re-sign our framework and host app.
    framework = app / "Contents/Frameworks/QueryCraftFeature.framework"
    run("codesign", "--force", "--sign", identity, "--keychain", KEYCHAIN,
        "--timestamp=none", framework)
    run("codesign", "--force", "--sign", identity, "--keychain", KEYCHAIN,
        "--timestamp=none", "--entitlements", ROOT / "Config/Release.entitlements", app)
    verify(app)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["init", "import-ci", "check", "sign", "verify", "cleanup-ci"])
    parser.add_argument("app", nargs="?", type=Path)
    args = parser.parse_args()
    if args.command in ("init", "import-ci"):
        provision(args.command == "import-ci")
    elif args.command == "check":
        print("Signing identity ready: " + activate())
    elif args.command == "cleanup-ci":
        if os.environ.get("CI") != "true" or "QUERYCRAFT_SIGNING_DIRECTORY" not in os.environ:
            raise RuntimeError("Cleanup is restricted to an explicitly configured CI signing directory.")
        if KEYCHAIN.exists():
            run("security", "delete-keychain", KEYCHAIN)
        for name in ("identity.p12", "p12-password", "keychain-password", "identity.txt"):
            (DIRECTORY / name).unlink(missing_ok=True)
    elif args.app is None:
        parser.error("sign and verify require an application path")
    elif args.command == "sign":
        sign(args.app.resolve())
    else:
        verify(args.app.resolve())


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
