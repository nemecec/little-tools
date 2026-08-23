"""Build the timetable page and publish it to the site bucket.

Run by the repository's publish workflow, and usable by hand for the first
upload or a one-off. Talks to AWS through the CLI, so it needs nothing installed
beyond what `tt.py` already needs: nothing.

    BUCKET=... DISTRIBUTION=... python3 deploy/publish.py

The address it publishes to comes from site.conf; the environment overrides it.
"""

import datetime
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import tempfile

# Run from a checkout, tt.py is one directory up; run from the Lambda bundle,
# it sits alongside. Both are on the path so neither layout is special.
_here = pathlib.Path(__file__).resolve().parent
for candidate in (_here.parent, _here):
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

import tt

HERE = _here


def configured(name, fallback=""):
    """From the environment, else from site.conf, which is the one place the
    site's address is written down."""
    if os.environ.get(name):
        return os.environ[name]
    for line in (HERE / "site.conf").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith(f"{name}=") and not line.startswith("#"):
            return line.split("=", 1)[1].strip()
    return fallback


BUCKET = os.environ["BUCKET"]
DISTRIBUTION = os.environ["DISTRIBUTION"]
PREFIX = configured("PREFIX").strip("/")
GOATCOUNTER = configured("GOATCOUNTER")
EDUPAGE = os.environ.get("EDUPAGE", "tera")
YEAR = int(os.environ.get("YEAR", "2026"))
INITIAL_SCHOOL = os.environ.get("INITIAL_SCHOOL", "")
INITIAL_CLASS = os.environ.get("INITIAL_CLASS", "")
LANGUAGE = os.environ.get("SITE_LANGUAGE", "en")
REGION = os.environ.get("AWS_REGION") or configured("REGION", "eu-central-1")
CLOUDFRONT_REGION = "us-east-1"   # global service; the CLI wants a region anyway

HTML = "text/html; charset=utf-8"
CACHE = "public, max-age=300"


# S3 and CloudFront are reached through boto3 where it exists — inside a Lambda
# — and through the CLI everywhere else, so a checkout needs nothing installed.
try:
    import boto3
except ImportError:
    boto3 = None


class ThroughCli:
    def get(self, key):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "current")
            done = subprocess.run(["aws", "--region", REGION, "s3", "cp",
                                   f"s3://{BUCKET}/{key}", out], capture_output=True)
            return pathlib.Path(out).read_bytes() if done.returncode == 0 else None

    def put(self, key, body):
        with tempfile.TemporaryDirectory() as tmp:
            local = pathlib.Path(tmp, "upload")
            local.write_bytes(body)
            subprocess.run(["aws", "--region", REGION, "s3", "cp", str(local),
                            f"s3://{BUCKET}/{key}", "--content-type", HTML,
                            "--cache-control", CACHE], check=True, capture_output=True)

    def invalidate(self, paths):
        subprocess.run(["aws", "--region", CLOUDFRONT_REGION, "cloudfront",
                        "create-invalidation", "--distribution-id", DISTRIBUTION,
                        "--paths", *paths], check=True, capture_output=True)


class ThroughBoto:
    def __init__(self):
        self.s3 = boto3.client("s3", region_name=REGION)
        self.cloudfront = boto3.client("cloudfront", region_name=CLOUDFRONT_REGION)

    def get(self, key):
        try:
            return self.s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
        except self.s3.exceptions.NoSuchKey:
            return None

    def put(self, key, body):
        self.s3.put_object(Bucket=BUCKET, Key=key, Body=body,
                           ContentType=HTML, CacheControl=CACHE)

    def invalidate(self, paths):
        self.cloudfront.create_invalidation(
            DistributionId=DISTRIBUTION,
            InvalidationBatch={"Paths": {"Quantity": len(paths), "Items": list(paths)},
                               "CallerReference": hashlib.sha256(
                                   "".join(paths).encode()).hexdigest()[:32] + str(len(paths))})


store = ThroughBoto() if boto3 else ThroughCli()


def build():
    client = tt.EduPage(EDUPAGE, cache_dir=os.environ.get("CACHE_DIR"), refresh=True)
    schools = tt.collect(client, YEAR, None, False)
    school, klass = tt.pick_initial(schools, INITIAL_SCHOOL or None, INITIAL_CLASS or None)
    page = tt.render_html(schools, EDUPAGE, YEAR, school, klass, LANGUAGE,
                          built=datetime.date.today().isoformat(), goatcounter=GOATCOUNTER)
    slots = sum(len(c["entries"]) for s in schools for c in s["classes"])
    return page.encode("utf-8"), len(schools), slots


def published(key):
    """What is on the site now, or None if nothing is."""
    return store.get(key)


def same(a, b):
    """Equal but for the build stamp, which moves every day on its own."""
    strip = lambda x: re.sub(rb'"built":\s*"[^"]*"', b'"built":""', x)
    return strip(a) == strip(b)


def upload(text, key):
    store.put(key, text if isinstance(text, bytes) else text.encode("utf-8"))


def main():
    body, schools, slots = build()
    key = f"{PREFIX}/index.html" if PREFIX else "index.html"

    current = published(key)
    if current is not None and same(current, body):
        print(f"{key}: unchanged, nothing published")
        return 0

    upload(body, key)
    # The root page links to whatever the prefix says, rather than keeping its
    # own copy of it to fall out of step with.
    for name in ("index.html", "404.html"):
        upload((HERE / name).read_text(encoding="utf-8").replace("__PREFIX__", PREFIX), name)

    store.invalidate(["/*"])
    print(f"published {key}: {schools} schools, {slots} lesson slots, {len(body)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
