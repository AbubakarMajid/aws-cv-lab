#!/bin/bash
# user-data.sh - runs once as root on first boot (Amazon Linux 2023).
# 1) install + start Apache  2) install sync-cv.sh  3) run it once  4) schedule it every 3 min.
# No access keys: the AWS CLI picks up temporary credentials from the instance role.
set -euxo pipefail

# 1. Web server
dnf install -y httpd
systemctl enable --now httpd

# 2. Sync script (identical copy of ec2/sync-cv.sh from the repository)
cat > /usr/local/bin/sync-cv.sh <<'SYNC_EOF'
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
SYNC_EOF
chmod 755 /usr/local/bin/sync-cv.sh
touch /var/log/cv-sync.log

# 3. Run it once now
/usr/local/bin/sync-cv.sh || true

# 4. Schedule: AL2023 has no cron, so use a systemd timer (every 3 minutes)
cat > /etc/systemd/system/cv-sync.service <<'UNIT_EOF'
[Unit]
Description=Sync CV from S3 into the web root
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
UNIT_EOF

cat > /etc/systemd/system/cv-sync.timer <<'UNIT_EOF'
[Unit]
Description=Run cv-sync every 3 minutes

[Timer]
OnCalendar=*:0/3
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now cv-sync.timer
