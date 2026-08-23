#!/usr/bin/env bash
# Set up the AWS side of little.tools. The publishing itself lives in the
# repository's workflow; this only builds what that workflow publishes into.
#
#   ./deploy.sh dns       once, first: the hosted zone, and the nameservers to
#                         set at the registrar
#   ./deploy.sh site      bucket, CloudFront, certificate, publish role
#   ./deploy.sh secrets   hand the stack's outputs to the GitHub repository
#   ./deploy.sh publish   build and publish from here, without waiting for CI
#
# Everything lives in us-east-1: a CloudFront certificate has to be issued there,
# and one region is one less thing to get wrong.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# site.conf is the one place the address is written down; the environment wins
# over it, for trying something out without editing the file.
from_env_domain="${DOMAIN:-}" from_env_prefix="${PREFIX:-}"
# shellcheck source=site.conf
. "$here/site.conf"
DOMAIN="${from_env_domain:-$DOMAIN}"
PREFIX="${from_env_prefix:-$PREFIX}"

REPO="${REPO:-nemecec/little-tools}"
REGION="us-east-1"
DNS_STACK="${DOMAIN//./-}-dns"
SITE_STACK="${DOMAIN//./-}-site"

aws() { command aws --region "$REGION" "$@"; }

output() {  # stack, key
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
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
  zone="$(output "$DNS_STACK" HostedZoneId)"
  [ -n "$zone" ] || { echo "no hosted zone; run ./deploy.sh dns first" >&2; exit 1; }

  # An account holds one GitHub OIDC provider; reuse it if something else made it.
  if aws iam list-open-id-connect-providers \
       --query "OpenIDConnectProviderList[?contains(Arn,'token.actions.githubusercontent.com')]" \
       --output text | grep -q .; then
    oidc=no
    echo "reusing the GitHub OIDC provider already in this account"
  else
    oidc=yes
  fi

  aws cloudformation deploy --stack-name "$SITE_STACK" \
    --template-file "$here/site.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      "DomainName=$DOMAIN" "HostedZoneId=$zone" \
      "GitHubRepo=$REPO" "CreateOidcProvider=$oidc"
  echo
  echo "Live at $(output "$SITE_STACK" SiteUrl) once something has been published."
  ;;

secrets)
  # gh keeps several accounts and only one is active; the wrong one gets a 403
  # here that reads like a permissions bug rather than a wrong-hat bug.
  if ! gh api "repos/$REPO" --jq .permissions.push 2>/dev/null | grep -q true; then
    echo "the active gh account cannot write to $REPO." >&2
    echo "  gh auth status          # see which accounts are logged in" >&2
    echo "  gh auth switch --user <account>" >&2
    exit 1
  fi
  gh secret set AWS_PUBLISH_ROLE --repo "$REPO" --body "$(output "$SITE_STACK" PublishRoleArn)"
  gh secret set AWS_BUCKET       --repo "$REPO" --body "$(output "$SITE_STACK" BucketName)"
  gh secret set AWS_DISTRIBUTION --repo "$REPO" --body "$(output "$SITE_STACK" DistributionId)"
  echo "set AWS_PUBLISH_ROLE, AWS_BUCKET and AWS_DISTRIBUTION on $REPO"
  echo
  echo "For page counts, also:  gh variable set GOATCOUNTER_SITE --repo $REPO --body <code>"
  ;;

publish)
  BUCKET="$(output "$SITE_STACK" BucketName)" \
  DISTRIBUTION="$(output "$SITE_STACK" DistributionId)" \
  PREFIX="$PREFIX" \
  GOATCOUNTER="${GOATCOUNTER:-}" \
  INITIAL_SCHOOL="${INITIAL_SCHOOL:-ProTERA}" \
  INITIAL_CLASS="${INITIAL_CLASS:-8}" \
  SITE_LANGUAGE="${SITE_LANGUAGE:-et}" \
  AWS_REGION="$REGION" \
    python3 "$here/publish.py"
  ;;

*)
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
