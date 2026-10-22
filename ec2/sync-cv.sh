#!/bin/bash
# sync-cv.sh - copy s3://<bucket>/site/ into the Apache web root and stamp the footer.
# Runs once from user data, then every 3 minutes from the cv-sync.timer systemd timer.
# Credentials come from the instance role via IMDSv2. There are no access keys here.
set -u

BUCKET="cv-23l-3050"
PREFIX="site/"
STAGING="/opt/cv/site"        # raw copy of S3 (placeholder untouched)
WEBROOT="/var/www/html"       # what Apache serves
LOG="/var/log/cv-sync.log"
IMDS="http://169.254.169.254/latest"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z') $1" >> "$LOG"; }

# --- IMDSv2: get a session token first, then read the instance ID and Region ---
TOKEN=$(curl -sf -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/instance-id")
REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/placement/region")

if [ -z "$INSTANCE_ID" ] || [ -z "$REGION" ]; then
  log "sync=FAILED reason=metadata-unavailable"
  exit 1
fi

mkdir -p "$STAGING" "$WEBROOT"

# --- 1. sync S3 -> staging (needs s3:ListBucket with prefix site/ and s3:GetObject on site/*) ---
if ! OUT=$(aws s3 sync "s3://$BUCKET/$PREFIX" "$STAGING/" --delete --region "$REGION" --only-show-errors 2>&1); then
  log "sync=FAILED instance=$INSTANCE_ID error=$(echo "$OUT" | tr '\n' ' ' | cut -c1-200)"
  exit 1
fi

for f in index.html style.css cv.pdf; do
  if [ ! -s "$STAGING/$f" ]; then
    log "sync=FAILED instance=$INSTANCE_ID reason=missing-$f"
    exit 1
  fi
done

# --- 2. publish to the web root; temp file + mv so visitors never see a half-written file ---
sed "s/{{HOSTED_ON}}/EC2 $INSTANCE_ID/" "$STAGING/index.html" > "$WEBROOT/.index.html.tmp"
mv -f "$WEBROOT/.index.html.tmp" "$WEBROOT/index.html"
for f in style.css cv.pdf; do
  cp -f "$STAGING/$f" "$WEBROOT/.$f.tmp" && mv -f "$WEBROOT/.$f.tmp" "$WEBROOT/$f"
done
chmod 644 "$WEBROOT/index.html" "$WEBROOT/style.css" "$WEBROOT/cv.pdf"

log "sync=OK instance=$INSTANCE_ID files=3"
