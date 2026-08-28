"""What the templates promise, checked against what they say.

The stack is deployed by hand and rarely, so a mistake in it is found late and
in production. These read the templates rather than AWS: no credentials, no
network, and they run in well under a second.

    python3 -m unittest discover -s tests
"""

import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


class TheStack(unittest.TestCase):
    """Counts in prose go stale silently. These are the ones worth pinning."""

    def resources(self, name):
        """The top-level resource names in one template."""
        with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
            body = fh.read().split("\nResources:\n", 1)[1].split("\nOutputs:")[0]
        return re.findall(r"^  ([A-Za-z0-9]+):\s*$", body, re.M)

    def test_a_broken_link_is_counted_but_never_wakes_anybody(self):
        """A handful a week is normal, and none of them is a fault in any page.
        The page marks them opaque; this is the half that skips them. The other
        half is in the tool's repository, where the page is built."""
        with open(os.path.join(ROOT, "site.yaml"), encoding="utf-8") as fh:
            self.assertIn("$.opaque NOT EXISTS", fh.read())

    def test_cloudfront_and_the_report_function_agree_on_the_gate(self):
        """The function URL is open to the world and a header is the only
        thing between it and everybody. If the two spell it differently,
        every report is refused and the page never finds out."""
        with open(os.path.join(ROOT, "site.yaml"), encoding="utf-8") as fh:
            template = fh.read()
        added = re.search(r"HeaderName:\s*(\S+)", template)
        self.assertIsNotNone(added, "CloudFront adds no header")
        checked = re.search(r'headers\.get\("([^"]+)"\)', template)
        self.assertIsNotNone(checked, "the function checks no header")
        self.assertEqual(added.group(1), checked.group(1))
        # And the page posts where CloudFront listens.
        # Without a leading slash. CloudFront matches the pattern against the
        # path with the slash already off, so "/report" matches nothing and the
        # request falls through to the bucket.
        self.assertIn("PathPattern: report\n", template)
        self.assertNotIn("PathPattern: /report", template)
        # And the route the API answers is the path the page posts to.
        self.assertIn("RouteKey: POST /report", template)
        # The tool's own side of this — that its page posts to the path the
        # site answers — is tested in the tool's repository, which is where the
        # page is built.

    def test_the_policy_opens_only_for_something_that_is_there(self):
        """default-src is 'none'. Every hole in it has to be earned by a
        feature that is switched on."""
        with open(os.path.join(ROOT, "site.yaml"), encoding="utf-8") as fh:
            template = fh.read()
        policy = template.split("ContentSecurityPolicy: !Sub", 1)[1]
        self.assertIn("connect-src ${Connect}", policy)
        # 'self' is in the reporting arm and nowhere else.
        arms = policy.split("Connect: !If", 1)[1].split("Beacon:", 1)[0]
        self.assertIn("Reporting", arms)
        self.assertEqual(arms.count("'self'"), 2, "one per counting case")

    def test_the_endpoint_takes_both_kinds_and_counts_them_apart(self):
        """A fault and a message from a reader go the same way, and want
        different treatment at the other end."""
        with open(os.path.join(ROOT, "site.yaml"), encoding="utf-8") as fh:
            template = fh.read()
        self.assertIn('report.get("kind") not in ("page-error", "feedback")', template)
        self.assertIn(
            'FilterPattern: \'{ $.kind = "page-error" && $.opaque NOT EXISTS }\'',
            template, "an unreadable error should not wake anybody")
        self.assertIn('FilterPattern: \'{ $.kind = "feedback" }\'', template)
        for metric in ("PageErrors", "Feedback"):
            self.assertIn("MetricName: %s" % metric, template)
        # That a page has somewhere to write is the tool's half, and is tested
        # in the tool's repository, which is where the page is built.

    def test_the_deploy_readme_counts_the_resources_correctly(self):
        counts = {n: len(self.resources(n))
                  for n in ("site.yaml", "dns.yaml", "cert.yaml")}
        self.assertEqual(counts, {"site.yaml": 21, "dns.yaml": 2, "cert.yaml": 1})
        with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as fh:
            readme = fh.read()
        # The words, not their capitalisation: the sentence around them is
        # free to be reworded.
        self.assertIn("twenty-four resources", readme.lower())
        self.assertIn("twenty-one in `site.yaml`", readme)

