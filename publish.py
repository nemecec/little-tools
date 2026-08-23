"""Build the timetable page and publish it to the site bucket.

Run by the repository's publish workflow, and usable by hand for the first
upload or a one-off. Talks to AWS through the CLI, so it needs nothing installed
beyond what `tt.py` already needs: nothing.

    BUCKET=... DISTRIBUTION=... python3 deploy/publish.py

The address it publishes to comes from site.conf; the environment overrides it.
"""

import datetime
import os
import pathlib
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tt

HERE = pathlib.Path(__file__).resolve().parent


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
GOATCOUNTER = os.environ.get("GOATCOUNTER", "")
EDUPAGE = os.environ.get("EDUPAGE", "tera")
YEAR = int(os.environ.get("YEAR", "2026"))
INITIAL_SCHOOL = os.environ.get("INITIAL_SCHOOL", "")
INITIAL_CLASS = os.environ.get("INITIAL_CLASS", "")
LANGUAGE = os.environ.get("SITE_LANGUAGE", "en")
REGION = os.environ.get("AWS_REGION") or configured("REGION", "eu-central-1")
CLOUDFRONT_REGION = "us-east-1"   # global service; the CLI wants a region anyway

HTML = "text/html; charset=utf-8"
CACHE = "public, max-age=300"


def aws(*args, region=REGION, **kw):
    return subprocess.run(["aws", "--region", region, *args],
                          check=True, capture_output=True, **kw)


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
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "current")
        try:
            aws("s3", "cp", f"s3://{BUCKET}/{key}", out)
        except subprocess.CalledProcessError:
            return None
        return pathlib.Path(out).read_bytes()


def same(a, b):
    """Equal but for the build stamp, which moves every day on its own."""
    strip = lambda x: re.sub(rb'"built":\s*"[^"]*"', b'"built":""', x)
    return strip(a) == strip(b)


def upload(path, key):
    aws("s3", "cp", path, f"s3://{BUCKET}/{key}",
        "--content-type", HTML, "--cache-control", CACHE)


def main():
    body, schools, slots = build()
    key = f"{PREFIX}/index.html" if PREFIX else "index.html"

    current = published(key)
    if current is not None and same(current, body):
        print(f"{key}: unchanged, nothing published")
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        page = pathlib.Path(tmp, "index.html")
        page.write_bytes(body)
        upload(str(page), key)
        # The root page links to whatever the prefix says, rather than keeping
        # its own copy of it to fall out of step with.
        for name in ("index.html", "404.html"):
            local = pathlib.Path(tmp, "root-" + name)
            local.write_text(
                (HERE / name).read_text(encoding="utf-8").replace("__PREFIX__", PREFIX),
                encoding="utf-8")
            upload(str(local), name)

    aws("cloudfront", "create-invalidation", "--distribution-id", DISTRIBUTION,
        "--paths", "/*", region=CLOUDFRONT_REGION)
    print(f"published {key}: {schools} schools, {slots} lesson slots, {len(body)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
