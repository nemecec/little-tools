# Hosting little.tools

The site itself: the domain, the certificate, the bucket every tool publishes
into, the CloudFront distribution in front of it, the landing page, and the
endpoint a page posts a fault or a word of feedback to.

    tool repository  →  S3 (private)  →  CloudFront  →  readers
                             ↑
                    this stack owns the bucket

**The tools live in their own repositories.** Each one publishes under its own
prefix and brings its own build. Today there is one:

| prefix | repository |
| --- | --- |
| `/timetable/` | [nemecec/edupage-timetable](https://github.com/nemecec/edupage-timetable) |

Nothing sits in the request path. Readers get a static object from an edge
cache, so a failed build leaves yesterday's page in service rather than an
error.

An account holds one GitHub OIDC provider, and this stack owns it. Each tool's
own stack makes a role against it, trusting `main` of one named repository and
able to do exactly one thing: ask that tool's build function to run. No such
role can write to the bucket or reach anything else.

## What is here

| file | |
| --- | --- |
| `site.conf` | the domain, the region, the analytics code — read by everything else |
| `dns.yaml` | the Route 53 hosted zone, on its own |
| `cert.yaml` | the TLS certificate, in us-east-1 because it must be |
| `site.yaml` | bucket, CloudFront, the report endpoint, the alarms |
| `index.html`, `404.html` | the site root, listing the tools |
| `deploy.sh` | the commands below |

## Where the address is configured

In `site.conf`, and only there:

    DOMAIN=little.tools     →  https://little.tools/

Each tool sets its own prefix in its own repository. `PREFIX=timetable` used to
live here, back when the timetable and the site were one thing.
    REGION=eu-central-1     →  where the bucket lives

CloudFormation takes the domain from this file. An environment variable of the
same name overrides any of them for one command. That is how `OIDC=yes
./deploy.sh site` works.

Three more settings are read from the environment only, because none of them
describes the address:

    ALARM_EMAIL=you@example.com where to write when a build fails. Unset means
                                no alarm and no topic. The tools' alarms write
                                to the same one.
    OIDC=yes|no                 whether this stack owns the account's GitHub
                                OIDC provider. Normally worked out on its own.
                                Unset, it follows the calendar and rolls over
                                in August.

CAUTION: Do not change `DOMAIN` after the first deploy. The stack names come
from it, so an edit does not move the site. It builds a second site beside the
first, and leaves the old zone billing at $0.50 a month. Take the old one down
first. The last section of this file says how.

## Credentials

The deploy needs an AWS profile with room to create CloudFormation stacks and S3
buckets. It also creates a CloudFront distribution, a certificate, Route 53
records and an IAM role. Nothing here is ongoing. Once the site is up,
publishing authenticates with a short-lived OIDC token, and no key exists
anywhere.

Follow the SSO profile pattern already in `~/.aws/config`, rather than put a
long-lived key on disk:

1. In the console, open **IAM Identity Center**. If it is not enabled, enable
   it. Give yourself a user with **AdministratorAccess** on the account.
2. Run `aws configure sso --profile little-tools`. Paste the start URL of the
   portal when it asks. Answer `eu-central-1` for the default region of the CLI.
3. Run `aws sso login --profile little-tools`. Then run
   `export AWS_PROFILE=little-tools` in the shell you deploy from.

Note: nothing here depends on the default region, because every call these
scripts make names its own region. The default region decides only where a bare
`aws` command that you type lands. That is where the bucket and both main stacks
are. The certificate stack is the exception, and needs `--region us-east-1`.

An IAM user with an access key also works, and is quicker. But it leaves a
long-lived secret on the machine, for something you use a handful of times.
Either way, do not use the root user.

## Regions

The three templates hold thirty-three resources: thirty in `site.yaml`, two in
`dns.yaml` (the zone and its CAA record) and one in `cert.yaml`. Some of the
thirty exist only on a condition. Four need an alarm address: two alarms and the
topic they write to, plus the filter that notices a stale day plan. Eleven more
are the endpoint the page reports faults and feedback to, and two of those need
the alarm address as well. One resource is pinned to a region, and one is a
choice. The rest are global, or they follow the bucket.

**The certificate must be in us-east-1.** CloudFront reads certificates from
nowhere else, whatever region the rest of the site is in. That is why the
certificate is its own stack.

**The bucket is the choice**, and it is in **eu-central-1**. The data belongs to
a European school, and there is no reason to keep a copy in Virginia. The cost
is nothing. CloudFront pays no egress to read from its origin, and a
five-minute cache sits in front of one small object. A reader never waits on it.

Everything else is global: CloudFront, Route 53 and IAM. The region of those
stacks decides only where the bookkeeping lives, so they sit with the bucket.

## Setting it up

**1. Count visits (optional).** Register a site at
[goatcounter.com](https://www.goatcounter.com/). Put the code in `site.conf`.
The page is then counted at `<code>.goatcounter.com`. If you leave the code
empty, the file holds no analytics script at all, and the page says nothing
about counting.

Note: visits arrive one row for each class, such as `/timetable/68/8`, titled
with the school's own name for it. That is a label in the beacon, not the
address a reader sees. Nothing a reader types is part of it. The privacy note in
the main README says why that took deliberate work.

**2. Make the hosted zone, and delegate to it.**

    export AWS_PROFILE=little-tools
    ./deploy.sh dns

The command prints four nameservers. Set them for `little.tools` at Gandi, in
place of the parking ones. Then wait until `dig +short NS little.tools` answers
with them.

Note: this is a separate step for a reason. A certificate is validated over DNS,
so ACM cannot issue one until Route 53 answers for the domain. If you deploy
everything at once, CloudFormation waits for a validation that cannot succeed.

**3. Deploy everything else.**

    ./deploy.sh site

This makes the certificate in us-east-1, then the bucket, the distribution and
the publish role in `REGION`. It takes ten to twenty minutes, mostly CloudFront.
The stack works out on its own whether the account already has a GitHub OIDC
provider, and reuses it. An account can hold only one.

**4. Put the landing page up.**

    ./deploy.sh pages

**5. Bring up a tool.** Each one is deployed from its own repository, which
gives the build function its code and hands the stack's outputs to GitHub as
secrets. For the timetable, see the deploy notes in
[nemecec/edupage-timetable](https://github.com/nemecec/edupage-timetable).

**6. Get told when a build breaks.** Do this one: EventBridge invokes the
function asynchronously, retries twice, and then drops the failure. Without an
alarm, nothing anywhere says that the page stopped being rebuilt.

    ALARM_EMAIL=you@example.com ./deploy.sh site

This makes an SNS topic and a CloudWatch alarm on the `Errors` metric of the
function. AWS sends a confirmation mail. Click the link in it, or nothing is
delivered.

Note: a night when the schedule never fires is deliberately not an alarm here.
That is a different fault from a build that breaks.

## Afterwards

Each tool publishes deliberately, from its own repository. The schedules and the
retry behaviour live with the tool that owns them.

The distribution speaks **HTTP/2 and not HTTP/3**, deliberately. An
advertisement for HTTP/3 sets an `alt-svc: h3` header. A browser then tries QUIC
over UDP. A network that carries TCP perfectly well can drop or mangle that.
A corporate VPN is the usual cause. The browser caches the advertisement for a
day and keeps retrying. So the site fails now and then with
`ERR_QUIC_PROTOCOL_ERROR`, while DNS, TCP and curl all look healthy. For one
small file behind a cache, HTTP/3 wins nothing.

Three things cost real time to work out. Read them before you touch the OIDC
role:

- GitHub now issues subjects with immutable ids appended to both names, as in
  `repo:owner@1180780/name@1343690401:ref:…`. The trust policy that everybody
  copies never matches that form. This stack accepts both forms.
- If you omit `ThumbprintList`, CloudFormation fills in one of its own. A token
  signed under a different chain is then refused, with nothing more useful than
  *the web identity token provided could not be validated*.
- The first deploy decides whether this stack owns the account's OIDC provider,
  and then keeps the answer. A second look finds the stack's own provider,
  answers "no", and the next update deletes the thing it was asked about. If the
  answer ever needs a correction, run `OIDC=yes ./deploy.sh site`.

## Cost

Storage and requests are rounding errors. The page is about 700 KB on the shelf,
and 104 KB over the wire for each reader once compressed. The nightly build takes
a few seconds of Lambda.
The free tier of CloudFront covers the traffic outright. Past the free tier, ten
thousand visits a month is a few cents.

The real line item is the **Route 53 hosted zone at $0.50/month**. The
certificate is free. Check the current free-tier terms yourself, rather than
take this paragraph at its word.

## When it goes wrong

**The site loads from a terminal but not in a browser.** Every command-line
check speaks HTTP/1.1 or HTTP/2, and a browser can be trying HTTP/3. So `curl`,
`dig` and `openssl` all pass while Chrome shows `ERR_QUIC_PROTOCOL_ERROR`. That
is why the distribution is set to `HttpVersion: http2`. The setting stops
CloudFront advertising `alt-svc: h3` on a network where QUIC does not survive.
If the fault comes back, look at the response headers for `alt-svc` first.

**The address resolves to the wrong place after a change.** macOS keeps its own
resolver cache. `dig` goes around that cache, so the two disagree for a while.
Run
`sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`. Then try the
browser again, and give it a minute, because Chrome caches separately too.

**`./deploy.sh site` says the OIDC provider is not authorized, cannot be
validated, or already exists.** An account holds exactly one GitHub OIDC
provider. The stack works out on its own whether it is the owner. If that
answer is wrong, usually because somebody created or deleted a provider
elsewhere, say so once. Run `OIDC=yes ./deploy.sh site` to take ownership, or
`OIDC=no` to leave it alone. Do not let CloudFormation fill in a thumbprint by
itself. `site.yaml` pins one deliberately.

**A build fails with something about JSON.** EduPage answers a lapsed session
with a login page and HTTP 200. The error quotes what came back. There is
nothing to fix locally, so run it again.

## Taking it down

    aws --region eu-central-1 cloudformation delete-stack --stack-name little-tools-site
    aws --region us-east-1    cloudformation delete-stack --stack-name little-tools-cert

`delete-stack` returns at once and the work carries on behind it. Wait for each
stack before you start the next one, or the certificate deletion fails while the
distribution still holds it:

    aws --region eu-central-1 cloudformation wait stack-delete-complete --stack-name little-tools-site
    aws --region us-east-1    cloudformation wait stack-delete-complete --stack-name little-tools-cert

The site stack takes about fifteen minutes, CloudFront again. The bucket is
versioned. If CloudFormation refuses to delete it, empty it first.

Deletion of the site stack also removes the publish role, which is the whole of
what the repository can reach. Revoking it needs nothing on the GitHub side.

The DNS stack can stay. Deletion of it releases the nameservers, so you have to
point the registrar somewhere else again if you ever come back.
