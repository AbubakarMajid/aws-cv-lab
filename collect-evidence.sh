#!/bin/bash
# collect-evidence.sh <bucket-name> <ec2-address> <lambda-address>
# Writes 11 sections to evidence.txt (next to this script) and prints DONE.
# A failing command is noted in its section and the script carries on.
# Run it where the AWS CLI already has credentials (AWS CloudShell is ideal), in the class Region.

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <bucket-name> <ec2-address> <lambda-address>" >&2
  exit 1
fi

BUCKET="$1"
EC2_URL="$2"
LAMBDA_URL="$3"
OUT="$(cd "$(dirname "$0")" && pwd)/evidence.txt"

# Normalise addresses: add a scheme if missing, drop a trailing slash.
case "$EC2_URL" in http://*|https://*) ;; *) EC2_URL="http://$EC2_URL" ;; esac
case "$LAMBDA_URL" in http://*|https://*) ;; *) LAMBDA_URL="https://$LAMBDA_URL" ;; esac
EC2_URL="${EC2_URL%/}"
LAMBDA_URL="${LAMBDA_URL%/}"

: > "$OUT"
section() { printf '\n== %s ==\n' "$1" >> "$OUT"; }

# run "<shell command>" : output goes to the file; a failure is noted and we continue.
run() {
  local output rc
  output=$(bash -o pipefail -c "$1" 2>&1)
  rc=$?
  [ -n "$output" ] && printf '%s\n' "$output" >> "$OUT"
  if [ "$rc" -ne 0 ]; then
    printf '!! FAILED (exit %s): %s\n' "$rc" "$1" >> "$OUT"
  fi
  return 0
}

{
  echo "Evidence collected $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "bucket=$BUCKET ec2=$EC2_URL lambda=$LAMBDA_URL"
} >> "$OUT"

# Roll number comes from the bucket's Owner tag, so names never need to be typed twice.
ROLL=$(aws s3api get-bucket-tagging --bucket "$BUCKET" \
        --query "TagSet[?Key=='Owner'].Value | [0]" --output text 2>/dev/null)
if [ -z "$ROLL" ] || [ "$ROLL" = "None" ]; then
  ROLL="${BUCKET#cv-}"   # fallback: cv-<roll>
fi
EC2_ROLE="cv-ec2-role-$ROLL"
LAMBDA_ROLE="cv-lambda-role-$ROLL"
FUNC="cv-func-$ROLL"
INSTANCE_NAME="cv-ec2-$ROLL"
LOG_GROUP="/aws/lambda/$FUNC"
echo "roll=$ROLL" >> "$OUT"

# Bucket Region, for the direct S3 address (us-east-1 is reported as None).
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text 2>/dev/null)
if [ -z "$BUCKET_REGION" ] || [ "$BUCKET_REGION" = "None" ]; then BUCKET_REGION="us-east-1"; fi
S3_URL="https://$BUCKET.s3.$BUCKET_REGION.amazonaws.com/site/index.html"

# 1
section "caller"
run "aws sts get-caller-identity --output json"

# 2
section "public-access"
run "aws s3api get-public-access-block --bucket '$BUCKET' --output json"

# 3
section "versioning"
run "aws s3api get-bucket-versioning --bucket '$BUCKET' --output json"

# 4  (whole bucket, recursive: proves the only keys are the three under site/)
section "objects"
run "aws s3 ls 's3://$BUCKET/' --recursive"

# 5
section "ec2-policy"
run "aws iam list-role-policies --role-name '$EC2_ROLE' --output json"
run "for p in \$(aws iam list-role-policies --role-name '$EC2_ROLE' --query 'PolicyNames[]' --output text); do aws iam get-role-policy --role-name '$EC2_ROLE' --policy-name \"\$p\" --output json; done"
run "aws iam list-attached-role-policies --role-name '$EC2_ROLE' --output json"

# 6
section "lambda-policy"
run "aws iam list-attached-role-policies --role-name '$LAMBDA_ROLE' --output json"
run "for p in \$(aws iam list-role-policies --role-name '$LAMBDA_ROLE' --query 'PolicyNames[]' --output text); do aws iam get-role-policy --role-name '$LAMBDA_ROLE' --policy-name \"\$p\" --output json; done"

# 7
section "security-group"
SG_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text 2>/dev/null)
if [ -n "$SG_IDS" ]; then
  run "aws ec2 describe-security-groups --group-ids $SG_IDS --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,InboundRules:IpPermissions}' --output json"
else
  echo "!! FAILED: no running instance named $INSTANCE_NAME, so no security group found" >> "$OUT"
fi

# 8
section "instance"
run "aws ec2 describe-instances --filters 'Name=tag:Name,Values=$INSTANCE_NAME' 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].{InstanceId:InstanceId,Type:InstanceType,State:State.Name,HttpTokens:MetadataOptions.HttpTokens,HttpEndpoint:MetadataOptions.HttpEndpoint,InstanceProfile:IamInstanceProfile.Arn,PublicIp:PublicIpAddress}' --output json"

# 9
section "endpoints"
probe() {  # probe <label> <url>
  local res
  res=$(curl -s -o /dev/null --max-time 20 -w '%{http_code} %{content_type}' "$2")
  [ $? -ne 0 ] && res="$res (curl failed)"
  printf '%-14s %-70s -> %s\n' "$1" "$2" "$res" >> "$OUT"
}
probe "ec2"        "$EC2_URL/"
probe "ec2"        "$EC2_URL/style.css"
probe "ec2"        "$EC2_URL/cv.pdf"
probe "lambda"     "$LAMBDA_URL/"
probe "lambda"     "$LAMBDA_URL/style.css"
probe "lambda"     "$LAMBDA_URL/cv.pdf"
probe "lambda"     "$LAMBDA_URL/anything"
probe "s3-direct"  "$S3_URL"
echo "ec2 footer:    $(curl -s --max-time 20 "$EC2_URL/" | grep -o 'Hosted on:[^<]*')" >> "$OUT"
echo "lambda footer: $(curl -s --max-time 20 "$LAMBDA_URL/" | grep -o 'Hosted on:[^<]*')" >> "$OUT"

# 10  (wait a little so the requests above reach CloudWatch)
section "lambda-logs"
sleep 15
run "aws logs tail '$LOG_GROUP' --since 1h --format short | tail -n 20"

# 11
section "log-retention"
run "aws logs describe-log-groups --log-group-name-prefix '$LOG_GROUP' --query 'logGroups[].{logGroup:logGroupName,retentionInDays:retentionInDays}' --output json"

echo "DONE"
