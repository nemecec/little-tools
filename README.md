# Hosting little.tools

The timetable at `https://little.tools/tera-timetable/`, rebuilt nightly from the
school's public data.

    GitHub Actions (nightly)
       └→ tt.py  →  S3 (private)  →  CloudFront  →  readers

Nothing is in the request path. Readers get a static object from an edge cache,
so a failed build leaves yesterday's page serving rather than an error. The
generator is deterministic, so a day with no timetable change renders
byte-identical output and the run publishes nothing at all.

The workflow authenticates with a short-lived OIDC token: there is no access key
in the repository, in a secret, or on a laptop. AWS holds a role that only
`main` of one named repository can assume, and that role can do nothing but
write to this bucket and invalidate this distribution.

## What is here

| file | |
| --- | --- |
| `dns.yaml` | the Route 53 hosted zone, on its own |
| `site.yaml` | bucket, CloudFront, certificate, the role Actions assumes |
| `publish.py` | build and publish; run by the workflow, and by hand |
| `index.html`, `404.html` | the site root |
| `deploy.sh` | the commands below |

The workflow itself is `.github/workflows/publish.yml`.

## First deploy

Everything goes in **us-east-1** — a CloudFront certificate has to be issued
there.

**1. Count visits (optional).** Register a site at
[goatcounter.com](https://www.goatcounter.com/) and note the code; the page will
be counted at `<code>.goatcounter.com`. Without it no analytics script is
embedded at all, and the footer says nothing about counting.

**2. The hosted zone, and the delegation.**

    ./deploy.sh dns

It prints four nameservers. Set them for `little.tools` at Gandi, replacing the
parking ones, then wait until `dig +short NS little.tools` answers with them.

This is a separate step for a reason: the certificate is validated over DNS, so
it cannot be issued until Route 53 is actually answering for the domain. Deploy
it all at once and CloudFormation sits waiting for a validation that can never
succeed until you finish the registrar side.

**3. Everything else.**

    ./deploy.sh site

Certificate, bucket, distribution and the publish role. Ten to twenty minutes,
most of it CloudFront. It works out on its own whether the account already has a
GitHub OIDC provider — there can only be one — and reuses it if so.

**4. Hand the outputs to the repository.**

    ./deploy.sh secrets
    gh variable set GOATCOUNTER_SITE --repo nemecec/little-tools --body your-code

**5. Publish.** Either push to `main`, run the workflow by hand from the Actions
tab, or do it from here without waiting for CI:

    ./deploy.sh publish

## Afterwards

Publishing happens on the nightly schedule and when you press *Run workflow* —
never on a push. The school's server rations how often one address may ask for
everything, and it starts timing out a caller that has just done so several
times over; a day of ordinary commits could spend that ration before the nightly
run gets its turn. After changing the generator, publish deliberately: the
button, or `./deploy.sh publish` from a machine that has not been hammering the
API. For the same reason the determinism check in `check.yml` only fetches when
run by hand.

Where the page opens, which language it starts in and the path it is served at
are environment values in `.github/workflows/publish.yml`; the rest is
`site.yaml`. A fetch that stalls is retried three times, waiting 5, 20 and 60
seconds, which is enough to ride out the throttling seen in practice. If it
still fails, nothing is published and yesterday's page keeps serving.

**Scheduled workflows stop after 60 days without repository activity.** GitHub
warns the owner by email first. A term-time timetable changes often enough that
this rarely bites, but a quiet summer can reach it — if the page looks stale,
check the Actions tab before suspecting the generator. Worth confirming the
current rule; it has changed before.

## Cost

Storage and requests are rounding errors: half a megabyte, 38 KB gzipped per
reader, and a minute of Actions a day. CloudFront's free tier should cover the traffic
outright; past it, ten thousand visits a month is a few cents.

The real line item is the **Route 53 hosted zone at $0.50/month**. The
certificate is free. Confirm the current free-tier terms rather than taking this
paragraph's word for it.

## Before it is public

The page republishes TERA's timetable — every class, teachers' full names, rooms
— under your domain. All of it is already publicly readable on
`tera.edupage.org`, which is where it is fetched from, anonymously and without a
login. So nothing new is exposed. But an aggregated copy on someone else's domain
can read as official, and it goes stale silently if the build stops.

The footer says the page is unofficial, links the school's own page for each
timetable, and prints the date the data was fetched. Telling the school before
you publish is still worth the five minutes.

## Taking it down

    aws --region us-east-1 cloudformation delete-stack --stack-name little-tools-site

The bucket is versioned, so empty it first if CloudFormation refuses. Deleting
the site stack also removes the publish role, which is the whole of what the
repository can reach — revoking it needs nothing done on the GitHub side. The DNS
stack can stay; deleting it releases the nameservers, which means pointing the
registrar somewhere else again if you ever come back.
