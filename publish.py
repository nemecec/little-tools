"""Build the timetable page and publish it to the site bucket.

Run by the repository's publish workflow, and usable by hand for the first
upload or a one-off. Talks to AWS through the CLI, so it needs nothing installed
beyond what `tt.py` already needs: nothing.

    BUCKET=... DISTRIBUTION=... PREFIX=tera-timetable python3 deploy/publish.py
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

BUCKET = os.environ["BUCKET"]
DISTRIBUTION = os.environ["DISTRIBUTION"]
PREFIX = os.environ.get("PREFIX", "").strip("/")
GOATCOUNTER = os.environ.get("GOATCOUNTER", "")
EDUPAGE = os.environ.get("EDUPAGE", "tera")
YEAR = int(os.environ.get("YEAR", "2026"))
INITIAL_SCHOOL = os.environ.get("INITIAL_SCHOOL", "")
INITIAL_CLASS = os.environ.get("INITIAL_CLASS", "")
LANGUAGE = os.environ.get("SITE_LANGUAGE", "en")
REGION = os.environ.get("AWS_REGION", "us-east-1")

HTML = "text/html; charset=utf-8"
CACHE = "public, max-age=300"


def aws(*args, **kw):
    return subprocess.run(["aws", "--region", REGION, *args],
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
    here = pathlib.Path(__file__).resolve().parent

    current = published(key)
    if current is not None and same(current, body):
        print(f"{key}: unchanged, nothing published")
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        page = pathlib.Path(tmp, "index.html")
        page.write_bytes(body)
        upload(str(page), key)
    for name in ("index.html", "404.html"):
        upload(str(here / name), name)

    aws("cloudfront", "create-invalidation", "--distribution-id", DISTRIBUTION,
        "--paths", "/*")
    print(f"published {key}: {schools} schools, {slots} lesson slots, {len(body)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
