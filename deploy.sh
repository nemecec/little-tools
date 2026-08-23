#!/usr/bin/env bash
# Set up the AWS side of little.tools. The publishing itself lives in the
# repository's workflow; this only builds what that workflow publishes into.
#
#   ./deploy.sh dns       once, first: the hosted zone, and the nameservers to
#                         set at the registrar
#   ./deploy.sh site      certificate, bucket, CloudFront, publish role
#   ./deploy.sh code      push the generator to the Lambda that runs nightly
#   ./deploy.sh secrets   hand the stack's outputs to the GitHub repository
#   ./deploy.sh publish   build and publish from here, without waiting for anything
#
# The bucket and the stacks live in REGION from site.conf. The certificate is
# its own stack in us-east-1, because CloudFront reads certificates from nowhere
# else; everything else here — CloudFront, Route 53, IAM — is global anyway.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# site.conf is the one place the address is written down; the environment wins
# over it, for trying something out without editing the file.
from_env_domain="${DOMAIN:-}" from_env_prefix="${PREFIX:-}" from_env_region="${REGION:-}"
from_env_gc="${GOATCOUNTER:-}"
# shellcheck source=site.conf
. "$here/site.conf"
DOMAIN="${from_env_domain:-$DOMAIN}"
PREFIX="${from_env_prefix:-$PREFIX}"
REGION="${from_env_region:-$REGION}"
GOATCOUNTER="${from_env_gc:-${GOATCOUNTER:-}}"

REPO="${REPO:-nemecec/little-tools}"
CERT_REGION="us-east-1"          # not a preference; CloudFront allows no other
DNS_STACK="${DOMAIN//./-}-dns"
CERT_STACK="${DOMAIN//./-}-cert"
SITE_STACK="${DOMAIN//./-}-site"

aws() { command aws --region "$REGION" "$@"; }
aws_cert() { command aws --region "$CERT_REGION" "$@"; }

output() {  # stack, key, [region]
  command aws --region "${3:-$REGION}" cloudformation describe-stacks --stack-name "$1" \
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

  # The certificate first, in the only region CloudFront will take one from.
  # It cannot be issued until the nameservers point here: validation is by DNS.
  aws_cert cloudformation deploy --stack-name "$CERT_STACK" \
    --template-file "$here/cert.yaml" \
    --parameter-overrides "DomainName=$DOMAIN" "HostedZoneId=$zone"
  cert="$(output "$CERT_STACK" CertificateArn "$CERT_REGION")"

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
      "DomainName=$DOMAIN" "HostedZoneId=$zone" "CertificateArn=$cert" \
      "GitHubRepo=$REPO" "CreateOidcProvider=$oidc"
  "$here/deploy.sh" code
  echo
  echo "Live at $(output "$SITE_STACK" SiteUrl) once something has been published."
  ;;

code)
  # The nightly build runs from a bundle rather than the checkout, so the layout
  # is flattened: publish.py finds tt.py beside it either way.
  fn="$(output "$SITE_STACK" BuildFunctionName)"
  [ -n "$fn" ] || { echo "no site stack; run ./deploy.sh site first" >&2; exit 1; }
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  cp "$here/../tt.py" "$here/publish.py" "$here/lambda_function.py" \
     "$here/site.conf" "$here/index.html" "$here/404.html" "$work/"
  cp -R "$here/../vendor" "$work/vendor"
  (cd "$work" && zip -qr bundle.zip .)
  aws lambda update-function-code --function-name "$fn" \
    --zip-file "fileb://$work/bundle.zip" --output text --query LastModified
  aws lambda wait function-updated --function-name "$fn"
  aws lambda update-function-configuration --function-name "$fn" \
    --environment "Variables={BUCKET=$(output "$SITE_STACK" BucketName),\
DISTRIBUTION=$(output "$SITE_STACK" DistributionId),\
GOATCOUNTER=${GOATCOUNTER:-},INITIAL_SCHOOL=${INITIAL_SCHOOL:-ProTERA},\
INITIAL_CLASS=${INITIAL_CLASS:-8},SITE_LANGUAGE=${SITE_LANGUAGE:-et}}" \
    --output text --query LastModified
  echo "pushed the generator to $fn"
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
  gh secret set AWS_PUBLISH_ROLE  --repo "$REPO" --body "$(output "$SITE_STACK" PublishRoleArn)"
  gh secret set AWS_BUILD_FUNCTION --repo "$REPO" --body "$(output "$SITE_STACK" BuildFunctionName)"
  echo "set AWS_PUBLISH_ROLE and AWS_BUILD_FUNCTION on $REPO"
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
