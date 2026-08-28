#!/usr/bin/env bash
# Set up little.tools itself: the domain, the certificate, the bucket and the
# CloudFront distribution in front of it, the landing page, and the endpoint
# that a page posts a fault or a word of feedback to.
#
#   ./deploy.sh dns       once, first: the hosted zone, and the nameservers to
#                         set at the registrar
#   ./deploy.sh site      certificate, bucket, CloudFront, publish role
#   ./deploy.sh pages     put the landing page and the 404 up
#
# Each tool the site hosts lives in its own repository and publishes into this
# bucket under its own prefix. The timetable is at
# https://github.com/nemecec/edupage-timetable — it holds the generator, the
# Lambda that runs it nightly, and its own deploy step.
#
# The bucket and the stacks live in REGION from site.conf. The certificate is
# its own stack in us-east-1, because CloudFront reads certificates from nowhere
# else. Everything else here — CloudFront, Route 53, IAM — is global anyway.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# site.conf is the one place the address is written down. The environment wins
# over it, so you can try something out without an edit to the file.
from_env_domain="${DOMAIN:-}" from_env_region="${REGION:-}"
from_env_gc="${GOATCOUNTER:-}" from_env_alarm="${ALARM_EMAIL:-}"
from_env_reports="${REPORT_ERRORS:-}"
# shellcheck source=site.conf
. "$here/site.conf"
DOMAIN="${from_env_domain:-$DOMAIN}"
REGION="${from_env_region:-$REGION}"
GOATCOUNTER="${from_env_gc:-${GOATCOUNTER:-}}"
ALARM_EMAIL="${from_env_alarm:-${ALARM_EMAIL:-}}"   # a failed build writes here
REPORT_ERRORS="${from_env_reports:-${REPORT_ERRORS:-yes}}"

CERT_REGION="us-east-1"          # not a preference. CloudFront allows no other
DNS_STACK="${DOMAIN//./-}-dns"
CERT_STACK="${DOMAIN//./-}-cert"
SITE_STACK="${DOMAIN//./-}-site"

aws() { command aws --region "$REGION" "$@"; }
aws_cert() { command aws --region "$CERT_REGION" "$@"; }

output() {  # stack, key, [region]
  command aws --region "${3:-$REGION}" cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# "The stack is not there" and "I cannot ask" are different answers, and the
# guards below act on the first. Conflating them turned an expired SSO token
# into "run ./deploy.sh dns first". That advice builds a second hosted zone beside the
# one already serving the site.
maybe_output() {  # stack, key, [region] — empty if absent, exits if unreachable
  local out status
  out="$(output "$1" "$2" "${3:-}" 2>&1)"; status=$?
  if [ $status -eq 0 ]; then printf '%s' "$out"; return 0; fi
  case "$out" in
    *"does not exist"*|*ValidationError*) return 0 ;;
    *) echo "cannot reach CloudFormation: $out" >&2
       echo "  aws sso login --profile ${AWS_PROFILE:-default}" >&2
       exit 1 ;;
  esac
}

case "${1:-}" in

dns)
  aws cloudformation deploy --stack-name "$DNS_STACK" \
    --template-file "$here/dns.yaml" \
    --parameter-overrides "DomainName=$DOMAIN"
  echo
  echo "Set these as the nameservers for $DOMAIN at the registrar:"
  output "$DNS_STACK" NameServers | tr ' ' '\n' | sed 's/^/    /'
  echo
  echo "Then wait for the delegation to take effect — check with"
  echo "    dig +short NS $DOMAIN"
  echo "and only then run ./deploy.sh site. The certificate is validated over"
  echo "DNS, so it cannot be issued until Route 53 is answering for the domain."
  ;;

site)
  zone="$(maybe_output "$DNS_STACK" HostedZoneId)"
  [ -n "$zone" ] || { echo "no hosted zone; run ./deploy.sh dns first" >&2; exit 1; }

  # The certificate first, in the only region CloudFront will take one from.
  # It cannot be issued until the nameservers point here: validation is by DNS.
  aws_cert cloudformation deploy --stack-name "$CERT_STACK" \
    --template-file "$here/cert.yaml" \
    --parameter-overrides "DomainName=$DOMAIN" "HostedZoneId=$zone"
  cert="$(output "$CERT_STACK" CertificateArn "$CERT_REGION")"

  # An account holds one GitHub OIDC provider. Whether this stack owns it is
  # decided once, on the first deploy, and then kept: asking the question again
  # later finds the stack's own provider, answers "no", and makes the next
  # update delete the very thing it was asked about.
  # OIDC=yes|no overrides, for putting it right if it was ever answered wrongly.
  # The alarm address is the same shape of question, and it bit: an address
  # given once on the command line lives only in the stack, so the next deploy
  # without it in the environment passed an empty string and deleted the alarm
  # and its topic. Nothing failed. The site simply stopped being watched.
  # ALARM_EMAIL= (empty, explicitly) still turns it off.
  if [ -z "${from_env_alarm:-}" ] && [ -z "${ALARM_EMAIL:-}" ]; then
    deployed="$(aws cloudformation describe-stacks --stack-name "$SITE_STACK" \
      --query "Stacks[0].Parameters[?ParameterKey=='AlarmEmail'].ParameterValue" \
      --output text 2>/dev/null || true)"
    if [ -n "$deployed" ] && [ "$deployed" != "None" ]; then
      ALARM_EMAIL="$deployed"
      echo "keeping the alarm address already deployed"
    fi
  fi

  oidc="${OIDC:-}"
  [ -n "$oidc" ] || oidc="$(aws cloudformation describe-stacks --stack-name "$SITE_STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='CreateOidcProvider'].ParameterValue" \
    --output text 2>/dev/null || true)"
  if [ -z "$oidc" ] || [ "$oidc" = "None" ]; then
    if aws iam list-open-id-connect-providers \
         --query "OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')]" \
         --output text | grep -q .; then
      oidc=no
      echo "reusing the GitHub OIDC provider already in this account"
    else
      oidc=yes
    fi
  fi

  aws cloudformation deploy --stack-name "$SITE_STACK" \
    --template-file "$here/site.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      "DomainName=$DOMAIN" "HostedZoneId=$zone" "CertificateArn=$cert" \
      "CreateOidcProvider=$oidc" \
      "CounterSite=${GOATCOUNTER:-}" "AlarmEmail=${ALARM_EMAIL:-}" \
      "ReportErrors=${REPORT_ERRORS:-yes}"
  echo
  echo "Live at $(output "$SITE_STACK" SiteUrl) once something has been published."
  ;;

pages)
  # The landing page and the 404. They belong to the site rather than to any
  # tool on it: the timetable used to upload them on its nightly run, back when
  # it was the only tool and lived in the same repository, and a page that lists
  # every tool cannot be published by one of them.
  bucket="$(maybe_output "$SITE_STACK" BucketName)"
  [ -n "$bucket" ] || { echo "no site stack; run ./deploy.sh site first" >&2; exit 1; }
  for name in index.html 404.html; do
    aws s3 cp "$here/$name" "s3://$bucket/$name" \
      --content-type "text/html; charset=utf-8" --cache-control "max-age=300"
  done
  aws cloudfront create-invalidation --output text --query Invalidation.Id \
    --distribution-id "$(output "$SITE_STACK" DistributionId)" \
    --paths /index.html /404.html /
  echo "put the landing page up"
  ;;

*)
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
