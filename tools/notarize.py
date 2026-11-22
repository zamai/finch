#!/usr/bin/python3
"""Notarize an app without writing the App Store Connect key to disk.

usage: notarize.py <app> <op://vault/item>

notarytool only accepts a key file, so this talks to Apple's Notary REST API:
https://developer.apple.com/documentation/notaryapi
The 1Password item needs private_key, key_id and issuer_id fields. The key
stays in memory and reaches openssl on stdin. Uses only what macOS ships, plus
op with a service account.
"""
import base64
import datetime
import hashlib
import hmac
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://appstoreconnect.apple.com/notary/v2/submissions"
REGION = "us-west-2"
POLL_SECONDS = 15
TIMEOUT_SECONDS = 60 * 60


def fail(message):
    sys.exit("notarize: " + message)


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


class Notary:
    def __init__(self, item):
        if not os.environ.get("OP_SERVICE_ACCOUNT_TOKEN"):
            fail("OP_SERVICE_ACCOUNT_TOKEN is not set")

        def read(field):
            p = subprocess.run(["op", "read", "--no-newline", f"{item}/{field}"],
                               capture_output=True)
            if p.returncode:
                fail(f"op could not read {field}")
            return p.stdout

        self.key = read("private_key")
        self.key_id = read("key_id").decode()
        self.issuer = read("issuer_id").decode()

    def token(self):
        now = int(time.time())
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        claims = {"iss": self.issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
        message = b".".join(b64(json.dumps(part).encode()) for part in (header, claims))
        # The key takes stdin, so the message goes through a second pipe.
        r, w = os.pipe()
        os.write(w, message)
        os.close(w)
        p = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", "/dev/stdin", f"/dev/fd/{r}"],
                           input=self.key + b"\n", pass_fds=[r], capture_output=True)
        os.close(r)
        if p.returncode:
            fail("could not sign the API token")
        # openssl returns DER; a JWT wants r and s as 32 bytes each.
        der = p.stdout
        size = der[3]
        pair = (der[4:4 + size], der[6 + size:])
        signature = b"".join(int.from_bytes(n, "big").to_bytes(32, "big") for n in pair)
        return (message + b"." + b64(signature)).decode()

    def call(self, path="", body=None):
        request = urllib.request.Request(
            API + path, None if body is None else json.dumps(body).encode(),
            {"Authorization": "Bearer " + self.token(), "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)["data"]

    def wait(self, submission):
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            time.sleep(POLL_SECONDS)
            try:
                status = self.call("/" + submission)["attributes"]["status"]
            except OSError as error:
                # A dropped connection or 5xx should not lose an uploaded submission.
                if isinstance(error, urllib.error.HTTPError) and error.code < 500:
                    raise
                print(f"  status check failed ({error}), retrying", flush=True)
                continue
            print("  " + status, flush=True)
            if status == "Accepted":
                return
            if status != "In Progress":
                url = self.call(f"/{submission}/logs")["attributes"]["developerLogUrl"]
                with urllib.request.urlopen(url, timeout=60) as response:
                    print(response.read().decode(), flush=True)
                fail(f"Apple returned {status}")
        fail(f"no answer from Apple after {TIMEOUT_SECONDS // 60} minutes")


def upload(data, target):
    """PUT to S3 with the temporary credentials Apple returns (AWS SigV4)."""
    digest = hashlib.sha256(data).hexdigest()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    host = f"{target['bucket']}.s3.{REGION}.amazonaws.com"
    path = "/" + urllib.parse.quote(target["object"])
    headers = {"host": host, "x-amz-content-sha256": digest, "x-amz-date": stamp,
               "x-amz-security-token": target["awsSessionToken"]}
    names = ";".join(sorted(headers))
    canonical = "\n".join(["PUT", path, "", "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)),
                           names, digest])
    scope = f"{stamp[:8]}/{REGION}/s3/aws4_request"
    key = ("AWS4" + target["awsSecretAccessKey"]).encode()
    for part in scope.split("/"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={target['awsAccessKeyId']}/{scope}, "
                                f"SignedHeaders={names}, Signature={signature}")
    headers["Content-Type"] = "application/zip"
    request = urllib.request.Request(f"https://{host}{path}", data, headers, method="PUT")
    urllib.request.urlopen(request, timeout=180).close()


def main():
    if len(sys.argv) != 3:
        fail("usage: notarize.py <app> <op://vault/item>")
    app, item = sys.argv[1], sys.argv[2].rstrip("/")
    notary = Notary(item)
    name = os.path.basename(app.rstrip("/"))
    with tempfile.TemporaryDirectory() as directory:
        archive = os.path.join(directory, "app.zip")
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", app, archive], check=True)
        with open(archive, "rb") as file:
            data = file.read()
    submission = notary.call(body={"submissionName": name + ".zip",
                                   "sha256": hashlib.sha256(data).hexdigest()})
    print("Submitted to Apple: " + submission["id"], flush=True)
    upload(data, submission["attributes"])
    notary.wait(submission["id"])


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        fail(f"HTTP {error.code}: {error.read()[:500].decode(errors='replace')}")
    except (OSError, subprocess.CalledProcessError) as error:
        fail(str(error))
    except KeyboardInterrupt:
        fail("interrupted")
