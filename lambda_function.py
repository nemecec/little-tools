"""Rebuild the page on a timer.

Not in anyone's request path: readers are served a static object from an edge
cache, and this only replaces that object. A failed run leaves the previous page
serving, which is the right failure — a timetable a day stale beats an error.

The build itself is publish.py, the same code a person runs by hand.
"""

import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent


def handler(event, context):
    """Run the publisher and hand its output back to whoever is watching."""
    result = subprocess.run(
        [sys.executable, str(HERE / "publish.py")],
        capture_output=True, text=True,
        # /tmp is the only writable place in a Lambda, and the AWS CLI wants a
        # home to put its cache in.
        env={**os.environ, "HOME": "/tmp", "AWS_CONFIG_FILE": "/tmp/aws-config"},
    )
    print(result.stdout.strip() or "(no output)")
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        raise RuntimeError(f"publish.py exited {result.returncode}")
    return {"ok": True, "output": result.stdout.strip()}
