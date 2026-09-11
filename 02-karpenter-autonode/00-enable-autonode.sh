#!/usr/bin/env bash
# ============================================================================
# Enable Karpenter (AutoNode) on ROSA HCP
# ============================================================================
# Prerequisites:
#   - ROSA HCP cluster running OpenShift >= 4.22
#   - rosa CLI >= 1.2.61
#   - AWS CLI configured with permissions to create IAM policies/roles
#   - oc CLI authenticated to the cluster
#   - jq installed
#
# Reference:
#   https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cluster_administration/rosa-nodes-autonode-managing
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${YELLOW}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }
header(){ echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }

# ── Pre-flight checks ──────────────────────────────────────────────
header "Pre-flight checks"

CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME env var}"
AWS_REGION="${AWS_REGION:-$(aws configure get region || echo "")}"
if [ -z "$AWS_REGION" ]; then
  err "AWS_REGION is not set and could not be auto-detected."
  err "Export it:  export AWS_REGION=ap-southeast-1"
  exit 1
fi
info "AWS_REGION: $AWS_REGION"

# Check rosa CLI version (--autonode requires >= 1.2.57, docs recommend >= 1.2.61)
ROSA_VERSION=$(rosa version 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "0.0.0")
ROSA_MINOR=$(echo "$ROSA_VERSION" | cut -d. -f2)
ROSA_PATCH=$(echo "$ROSA_VERSION" | cut -d. -f3)
info "rosa CLI version: $ROSA_VERSION"

if [ "$ROSA_MINOR" -lt 2 ] || { [ "$ROSA_MINOR" -eq 2 ] && [ "$ROSA_PATCH" -lt 57 ]; }; then
  err "rosa CLI version $ROSA_VERSION is too old. The --autonode flag requires >= 1.2.57 (recommended >= 1.2.61)."
  echo ""
  echo -e "  ${BOLD}Upgrade rosa CLI:${NC}"
  echo "    rosa download rosa"
  echo "    # or"
  echo "    sudo dnf install -y rosa-cli   # Fedora/RHEL"
  echo ""
  echo -e "  ${BOLD}Alternative — enable via OCM console:${NC}"
  echo "    1. Open https://console.redhat.com/openshift"
  echo "    2. Select cluster '$CLUSTER_NAME'"
  echo "    3. Click 'Edit' next to Red Hat build of Karpenter status"
  echo "    4. Toggle 'Enable Autonode'"
  echo "    5. Paste the IAM Role ARN (created by this script's Step 2)"
  echo "    6. Click 'Save'"
  echo ""
  echo -e "  ${YELLOW}Continuing with IAM setup only (Steps 1-3)...${NC}"
  SKIP_ROSA_EDIT=true
else
  SKIP_ROSA_EDIT=false
fi

# Resolve cluster ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_ID=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.id')
OIDC_ENDPOINT=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')
ROLE_NAME="${CLUSTER_NAME}-karpenter"

info "Cluster name: $CLUSTER_NAME"
info "Cluster ID:   $CLUSTER_ID"
info "AWS Account:  $AWS_ACCOUNT_ID"
info "OIDC:         $OIDC_ENDPOINT"

# ── Step 1: Create Karpenter IAM Policy ────────────────────────────
header "Step 1: Create Karpenter IAM Policy"

cat > /tmp/karpenter-policy.json <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "KarpenterEC2",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate",
        "ec2:CreateTags",
        "ec2:DeleteLaunchTemplate",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "ec2:RunInstances",
        "ec2:TerminateInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KarpenterPassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "KarpenterPricing",
      "Effect": "Allow",
      "Action": [
        "pricing:GetProducts"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KarpenterSSM",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter"
      ],
      "Resource": "arn:aws:ssm:*:*:parameter/aws/service/*"
    }
  ]
}
POLICY

POLICY_ARN=$(aws iam create-policy \
  --policy-name "${ROLE_NAME}-policy" \
  --policy-document file:///tmp/karpenter-policy.json \
  --query 'Policy.Arn' --output text 2>/dev/null || \
  aws iam list-policies --query "Policies[?PolicyName=='${ROLE_NAME}-policy'].Arn" --output text)

ok "Policy ARN: $POLICY_ARN"

# ── Step 2: Create Karpenter IAM Role with OIDC trust ─────────────
header "Step 2: Create Karpenter IAM Role with OIDC trust"

cat > /tmp/karpenter-trust.json <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ENDPOINT}:sub": "system:serviceaccount:kube-system:karpenter"
        }
      }
    }
  ]
}
TRUST

ROLE_ARN=$(aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/karpenter-trust.json \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true

ok "Role ARN: $ROLE_ARN"

# ── Step 3: Tag cluster security group for Karpenter discovery ────
header "Step 3: Tag cluster security group for Karpenter discovery"

# ROSA HCP creates a default SG named "${CLUSTER_ID}-default-sg"
# Ref: https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cluster_administration/rosa-nodes-autonode-managing#rosa-nodes-autonode-karpenter-tag-resources
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${CLUSTER_ID}-default-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$SECURITY_GROUP_ID" = "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
  # Fallback: try matching by cluster tag
  info "Default SG not found by Name tag. Trying red-hat-managed tag..."
  SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=tag:red-hat-managed,Values=true" \
              "Name=tag:api.openshift.com/id,Values=${CLUSTER_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
fi

if [ "$SECURITY_GROUP_ID" = "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
  err "Could not auto-detect the worker security group."
  echo ""
  echo -e "  ${BOLD}Find it manually:${NC}"
  echo "    aws ec2 describe-security-groups --region $AWS_REGION \\"
  echo "      --filters 'Name=tag:Name,Values=*${CLUSTER_ID}*' \\"
  echo "      --query 'SecurityGroups[*].[GroupId,GroupName,Tags[?Key==\`Name\`].Value|[0]]' \\"
  echo "      --output table"
  echo ""
  echo -e "  ${BOLD}Then tag it:${NC}"
  echo "    aws ec2 create-tags --region $AWS_REGION --resources <SG_ID> \\"
  echo "      --tags Key=karpenter.sh/discovery,Value=$CLUSTER_ID"
  echo ""
else
  aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$SECURITY_GROUP_ID" \
    --tags "Key=karpenter.sh/discovery,Value=$CLUSTER_ID"
  ok "Tagged SG $SECURITY_GROUP_ID with karpenter.sh/discovery=$CLUSTER_ID"
fi

# ── Step 4: Enable AutoNode on the cluster ─────────────────────────
header "Step 4: Enable AutoNode on the cluster"

if [ "$SKIP_ROSA_EDIT" = true ]; then
  echo ""
  err "Skipped — rosa CLI too old (need >= 1.2.57)."
  echo ""
  echo -e "  ${BOLD}Option A: Upgrade rosa CLI and re-run this script${NC}"
  echo "    rosa download rosa"
  echo ""
  echo -e "  ${BOLD}Option B: Enable via OCM console${NC}"
  echo "    1. Open https://console.redhat.com/openshift"
  echo "    2. Select cluster '$CLUSTER_NAME'"
  echo "    3. Click 'Edit' next to Red Hat build of Karpenter status"
  echo "    4. Toggle 'Enable Autonode'"
  echo "    5. Paste this Role ARN:"
  echo -e "       ${CYAN}$ROLE_ARN${NC}"
  echo "    6. Click 'Save'"
  echo ""
else
  rosa edit cluster -c "$CLUSTER_ID" \
    --autonode=enabled \
    --autonode-iam-role-arn="$ROLE_ARN"
  ok "AutoNode (Karpenter) enabled on cluster '$CLUSTER_NAME'"
fi

# ── Summary ────────────────────────────────────────────────────────
header "Summary"
echo ""
echo -e "  ${BOLD}Cluster:${NC}    $CLUSTER_NAME ($CLUSTER_ID)"
echo -e "  ${BOLD}Region:${NC}     $AWS_REGION"
echo -e "  ${BOLD}Policy ARN:${NC} $POLICY_ARN"
echo -e "  ${BOLD}Role ARN:${NC}   $ROLE_ARN"
echo -e "  ${BOLD}SG:${NC}         ${SECURITY_GROUP_ID:-not auto-detected}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Wait ~5 minutes for Karpenter to become active"
echo "  2. Verify:   rosa describe cluster -c $CLUSTER_NAME -o json | jq '.aws.sts.auto_mode'"
echo "  3. Apply NodePool:  oc apply -f 01-nodepool.yaml"
echo "  4. Deploy workload: oc apply -f 02-burst-workload-karpenter.yaml"
