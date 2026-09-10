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
# ============================================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?Set CLUSTER_NAME}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_ID=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.id')
OIDC_ENDPOINT=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')
ROLE_NAME="${CLUSTER_NAME}-karpenter"

echo "=== Step 1: Create Karpenter IAM Policy ==="
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

echo "  Policy ARN: $POLICY_ARN"

echo "=== Step 2: Create Karpenter IAM Role with OIDC trust ==="
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

echo "  Role ARN: $ROLE_ARN"

echo "=== Step 3: Tag cluster security group for Karpenter discovery ==="
SG_ID=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.aws.additional_infra_security_group_ids[0] // empty')
if [ -z "$SG_ID" ]; then
  echo "  ⚠ Could not auto-detect SG. Tag your worker SG manually:"
  echo "    aws ec2 create-tags --resources <SG_ID> --tags Key=karpenter.sh/discovery,Value=$CLUSTER_NAME"
else
  aws ec2 create-tags --resources "$SG_ID" --tags "Key=karpenter.sh/discovery,Value=$CLUSTER_NAME"
  echo "  Tagged SG: $SG_ID"
fi

echo "=== Step 4: Enable AutoNode on the cluster ==="
rosa edit cluster -c "$CLUSTER_ID" \
  --autonode=enabled \
  --autonode-iam-role-arn="$ROLE_ARN"

echo ""
echo "✅ AutoNode (Karpenter) enabled on cluster '$CLUSTER_NAME'"
echo "   Role ARN: $ROLE_ARN"
echo ""
echo "Next steps:"
echo "  1. Wait ~5 minutes for Karpenter to become active"
echo "  2. Apply NodePool + EC2NodeClass: oc apply -f 01-nodepool.yaml"
echo "  3. Deploy bursty workload:        oc apply -f 02-burst-workload-karpenter.yaml"
