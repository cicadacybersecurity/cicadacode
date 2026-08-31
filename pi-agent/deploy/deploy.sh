#!/usr/bin/env bash
# deploy.sh — Build and deploy instagram-hashtag-research-tool to /opt/cicada-lead-app
# Usage: ./deploy.sh [project-dir]
# Must be run as root (sudo ./deploy.sh)

set -euo pipefail

PROJECT_DIR="${1:-$(dirname "$(dirname "$(realpath "$0")")")}"
TARGET_DIR="/opt/cicada-lead-app"
APP_USER="cicadaserver"
APP_GROUP="cicadaserver"
ENV_FILE="/etc/cicada-lead-app.env"
SERVICE_FILE="/etc/systemd/system/cicada-lead-app.service"

# ── Resolve project dir ────────────────────────────────────────────────────────
if [[ ! -d "$PROJECT_DIR/src" ]]; then
    echo "ERROR: $PROJECT_DIR does not look like the project (no src/ dir)"
    exit 1
fi

echo "=== Deploying instagram-hashtag-research-tool ==="
echo "  Project:  $PROJECT_DIR"
echo "  Target:   $TARGET_DIR"
echo ""

# ── Build ─────────────────────────────────────────────────────────────────────
echo "[1/5] Building..."
cd "$PROJECT_DIR"
npm install --silent 2>/dev/null || npm install
npm run build

# ── Copy to target ─────────────────────────────────────────────────────────────
echo "[2/5] Copying to $TARGET_DIR ..."
mkdir -p "$TARGET_DIR"
rsync -a --delete \
    --exclude='.git' \
    --exclude='.playwright-profile*' \
    --exclude='node_modules' \
    --exclude='*.log' \
    --exclude='run-state.json' \
    --exclude='.env' \
    "$PROJECT_DIR/" "$TARGET_DIR/"

# Copy node_modules (needed for production)
cp -r "$PROJECT_DIR/node_modules" "$TARGET_DIR/node_modules"

# ── Environment file ───────────────────────────────────────────────────────────
echo "[3/5] Setting up environment file $ENV_FILE ..."
if [[ ! -f "$ENV_FILE" ]]; then
    # Populate from .env in project, then prompt for any missing values
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        cp "$PROJECT_DIR/.env" "$ENV_FILE"
    else
        touch "$ENV_FILE"
    fi
    echo "NOTE: Review $ENV_FILE before starting the service!"
fi

# ── Symlink playwright profiles so they persist across deploys ──────────────────
echo "[4/5] Symlinking persistent playwright profiles ..."
ln -sfn "$PROJECT_DIR/.playwright-profile"       "$TARGET_DIR/.playwright-profile"
ln -sfn "$PROJECT_DIR/.playwright-profile-maps"  "$TARGET_DIR/.playwright-profile-maps"
ln -sfn "$PROJECT_DIR/.playwright-profile-facebook" "$TARGET_DIR/.playwright-profile-facebook"

# ── Install systemd service ────────────────────────────────────────────────────
echo "[5/5] Installing systemd service ..."
cp "$PROJECT_DIR/deploy/cicada-lead-app.service" "$SERVICE_FILE"
chown root:root "$SERVICE_FILE"
chmod 644 "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable --now cicada-lead-app
echo ""
echo "=== Deployed ==="
systemctl status cicada-lead-app --no-pager | head -10
echo ""
echo "To check logs:  journalctl -u cicada-lead-app -f"
echo "To restart:     sudo systemctl restart cicada-lead-app"
