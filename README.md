# Hosting little.tools

The timetable at `https://little.tools/timetable/`, rebuilt nightly from the
school's public data.

    EventBridge (nightly)  →  Lambda: tt.py  →  S3 (private)  →  CloudFront  →  readers
                                  ↑
                       GitHub Actions, when asked

Nothing is in the request path. Readers get a static object from an edge cache,
so a failed build leaves yesterday's page serving rather than an error. The
generator is deterministic, so a day with no timetable change renders
byte-identical output and the run publishes nothing at all.

The schedule is in AWS rather than in the repository because GitHub switches a
scheduled workflow off after sixty days without repository activity, and a page
that only needs rebuilding — never editing — would reach that and stop quietly.

The workflow remains as a button for when tonight is too far off. It holds no
key: it exchanges a short-lived OIDC token for a role that only `main` of one
named repository can assume, and that role can do exactly one thing — ask the
build function to run. It cannot write to the bucket or reach anything else.

## What is here

| file | |
| --- | --- |
| `site.conf` | the domain, the path and the region — read by everything else |
| `dns.yaml` | the Route 53 hosted zone, on its own |
| `cert.yaml` | the TLS certificate, in us-east-1 because it must be |
| `site.yaml` | bucket, CloudFront, the role Actions assumes |
| `publish.py` | build and publish; run by the Lambda, and by hand |
| `lambda_function.py` | the nightly run's entry point |
| `index.html`, `404.html` | the site root |
| `deploy.sh` | the commands below |

The workflow itself is `.github/workflows/publish.yml`.

## Where the address is configured

`deploy/site.conf`, and only there:

    DOMAIN=little.tools
    PREFIX=timetable        →  https://little.tools/timetable/
    REGION=eu-central-1     →  where the bucket lives

CloudFormation takes the domain from it, `publish.py` builds the S3 key from the
prefix, and the root page's link is substituted at publish time — so moving the
page means editing one line. An environment variable of the same name overrides
any of them for one command, which is how `OIDC=yes ./deploy.sh site` works.

Two more are read from the environment only, since neither belongs in a file
that describes the address:

    REPO=nemecec/little-tools   which repository `./deploy.sh secrets` writes to
    OIDC=yes|no                 whether this stack owns the account's GitHub
                                OIDC provider; normally worked out on its own
    YEAR=2026                   pin the school year the nightly build asks for;
                                unset, it follows the calendar and rolls over
                                in August

**`DOMAIN` is not a thing to change afterwards.** The stack names are derived
from it, so editing it does not move the site — it builds a second one beside
the first and leaves the old zone billing at $0.50 a month. Take the old one
down first; see below.

## Credentials

The deploy needs an AWS profile with room to create CloudFormation stacks, S3
buckets, a CloudFront distribution, a certificate, Route 53 records and an IAM
role. Nothing here is ongoing: once it is up, publishing authenticates with a
short-lived OIDC token and no key exists anywhere.

Mirror the SSO profile pattern already in `~/.aws/config` rather than putting a
long-lived key on disk:

1. In the console, open **IAM Identity Center**, enable it if it is not, and give
   yourself a user with **AdministratorAccess** on the account.
2. `aws configure sso --profile little-tools` — paste the portal's start URL when
   asked, and answer `eu-central-1` for the CLI's default region. Nothing here
   depends on it, since every call these scripts make names its own region; it
   only decides where a bare `aws` command you type lands, and that is where the
   bucket and both main stacks are. The exception is the certificate stack,
   which needs `--region us-east-1` to look at.
3. `aws sso login --profile little-tools`, then `export AWS_PROFILE=little-tools`
   in the shell you deploy from.

An IAM user with an access key works too and is quicker, but it leaves a
long-lived secret on the machine for something used a handful of times. Either
way, not the root user.

## Regions

Sixteen resources across the three templates — fourteen in `site.yaml`, and
one each in `dns.yaml` and `cert.yaml`. One is pinned to a region and one
is a choice; the rest are global or follow the bucket.

**The certificate must be in us-east-1.** CloudFront reads certificates from
nowhere else, whatever region the rest of the site is in. That is why it is its
own stack.

**The bucket is the choice**, and it is in **eu-central-1**: the data is a
European school's, and there is no reason to park a copy in Virginia. The cost
is nothing — CloudFront pays no egress to fetch from its origin, and with a
five-minute cache in front of one small object, a reader never waits on it.

Everything else — CloudFront, Route 53, IAM — is global. The region those stacks
are deployed in only decides where the bookkeeping lives, so they sit with the
bucket.

## Setting it up

**1. Count visits (optional).** Register a site at
[goatcounter.com](https://www.goatcounter.com/) and put the code in
`site.conf`; the page is then counted at `<code>.goatcounter.com`. Leave it
empty and no analytics script is embedded at all, and the page says nothing
about counting.

Visits arrive one row per class — `/timetable/68/8`, titled with the school's
own name for it. That is a label in the beacon, not the address a reader sees.
Nothing a reader types is part of it; see the privacy note in the main README
for why that took deliberate work.

**2. The hosted zone, and the delegation.**

    export AWS_PROFILE=little-tools
    ./deploy.sh dns

It prints four nameservers. Set them for `little.tools` at Gandi, replacing the
parking ones, then wait until `dig +short NS little.tools` answers with them.

This is a separate step for a reason: the certificate is validated over DNS, so
it cannot be issued until Route 53 is actually answering for the domain. Deploy
it all at once and CloudFormation sits waiting for a validation that can never
succeed until you finish the registrar side.

**3. Everything else.**

    ./deploy.sh site

The certificate in us-east-1, then bucket, distribution and publish role in
`REGION`. Ten to twenty minutes, most of it CloudFront. It works out on its own
whether the account already has a GitHub OIDC provider — there can only be one —
and reuses it if so.

**4. Hand the outputs to the repository**, so the button works. This sets two
secrets — `AWS_PUBLISH_ROLE` and `AWS_BUILD_FUNCTION`. The workflow checks for
both and stops if either is missing, so a fork of this repository can never
authenticate against someone else's account by accident. It writes to `REPO`,
which defaults to `nemecec/little-tools`; set it if yours is elsewhere.

    gh auth switch --user <the account that owns the repo>
    ./deploy.sh secrets

**5. Publish.** Either press *Run workflow* on the Actions tab, or do it from
here without waiting:

    ./deploy.sh publish

## Afterwards

Publishing happens on the nightly EventBridge schedule and when you press *Run
workflow* — never on a push. The school's server rations how often one address may ask for
everything, and it starts timing out a caller that has just done so several
times over; a day of ordinary commits could spend that ration before the nightly
run gets its turn. After changing the generator, publish deliberately: the
button, or `./deploy.sh publish` from a machine that has not been hammering the
API. For the same reason the determinism check in `check.yml` only fetches when
run by hand.

Where the page opens and which language it starts in are environment variables
on the build function, set by `./deploy.sh code` from `INITIAL_SCHOOL`,
`INITIAL_CLASS` and `SITE_LANGUAGE` (defaults ProTERA, 8, et). The path, the
domain, the region and the GoatCounter code come from `site.conf`, which travels
in the bundle. The rest is `site.yaml`.

The schedule is `cron(20 3 * * ? *)` — 03:20 UTC. A fetch that stalls is retried
three times, waiting 5, 20 and 60 seconds, which is enough to ride out the
throttling seen in practice. If it still fails, nothing is published and
yesterday's page keeps serving.

Changing the generator does not republish anything on its own. Push it to the
function and run it:

    ./deploy.sh code && ./deploy.sh publish

The distribution speaks **HTTP/2 and not HTTP/3**, deliberately. Advertising
HTTP/3 sets an `alt-svc: h3` header, a browser then tries QUIC over UDP, and a
network that carries TCP perfectly well may drop or mangle that — a corporate
VPN being the usual culprit. The browser caches the advertisement for a day and
keeps retrying, so the site fails intermittently with `ERR_QUIC_PROTOCOL_ERROR`
while DNS, TCP and curl all look healthy. For one small file behind a cache
there is nothing to win by it.

Two things cost real time to work out, and are worth knowing before touching the
OIDC role:

- GitHub now issues subjects with immutable ids appended to both names —
  `repo:owner@1180780/name@1343690401:ref:…` — which the trust policy everyone
  copies never matches. Both forms are accepted.
- Omit `ThumbprintList` and CloudFormation fills in one of its own. A token
  signed under a different chain is then refused with nothing more useful than
  *the web identity token provided could not be validated*.
- Whether this stack owns the account's OIDC provider is decided on the first
  deploy and then kept. Asking again later finds the stack's own provider,
  answers "no", and the next update deletes the thing it was asked about. If the
  answer ever needs correcting: `OIDC=yes ./deploy.sh site`.

## Cost

Storage and requests are rounding errors: half a megabyte on the shelf, about
56 KB over the wire per reader once compressed, and a few seconds of Lambda a night. CloudFront's free tier should cover the traffic
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

The page says it is unofficial under its heading, beside a link to the school's
own page for whichever timetable is shown and the date the data was read. A
printed sheet carries the date and a QR code back to the page rather than the
whole notice — worth knowing if sheets are what circulate. Telling the school
before you publish is still worth the five minutes.

## When it goes wrong

**The site loads from a terminal but not in a browser.** Every command-line
check speaks HTTP/1.1 or HTTP/2, and a browser may be trying HTTP/3 — so `curl`,
`dig` and `openssl` can all pass while Chrome shows `ERR_QUIC_PROTOCOL_ERROR`.
That is why the distribution is set to `HttpVersion: http2`: it stops CloudFront
advertising `alt-svc: h3` on a network where QUIC does not survive. If it comes
back, check the response headers for `alt-svc` before looking anywhere else.

**The address resolves to the wrong place after a change.** macOS keeps its own
resolver cache that `dig` goes around, so the two can disagree for a while.
`sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`, then try the
browser again — and give it a minute, because Chrome caches separately too.

**`./deploy.sh site` says the OIDC provider is not authorized, cannot be
validated, or already exists.** An account holds exactly one GitHub OIDC
provider and the stack works out on its own whether it is the owner. If that
answer is wrong — usually because a provider was created or deleted elsewhere —
say so once: `OIDC=yes ./deploy.sh site` to take ownership, `OIDC=no` to leave
it alone. Do not let CloudFormation fill in a thumbprint by itself; `site.yaml`
pins one deliberately.

**The nightly run publishes nothing.** Two reasons are normal: the timetable did
not change (the generator is deterministic, so the page is byte-identical), or a
school failed to fetch and the run refused to replace a full page with a
smaller one. The second is a hard error and the log names the counts. Once the
cause is understood, `PUBLISH_ANYWAY=1 ./deploy.sh publish` overrides it.

**A build fails with something about JSON.** EduPage answers a lapsed session
with a login page and HTTP 200. The error quotes what came back; there is
nothing to fix locally, so try again.

## Taking it down

    aws --region eu-central-1 cloudformation delete-stack --stack-name little-tools-site
    aws --region us-east-1    cloudformation delete-stack --stack-name little-tools-cert

`delete-stack` returns straight away and the work carries on behind it. Wait for
each before starting the next, or the certificate deletion fails while the
distribution still holds it:

    aws --region eu-central-1 cloudformation wait stack-delete-complete --stack-name little-tools-site
    aws --region us-east-1    cloudformation wait stack-delete-complete --stack-name little-tools-cert

The site stack takes fifteen minutes or so — CloudFront again. The bucket is
versioned, so empty it first if CloudFormation refuses. Deleting
the site stack also removes the publish role, which is the whole of what the
repository can reach — revoking it needs nothing done on the GitHub side. The DNS
stack can stay; deleting it releases the nameservers, which means pointing the
registrar somewhere else again if you ever come back.
