#!/bin/bash

# --- CONFIGURATION ---
OLD_USER="root"              # The username on the old server
OLD_IP="139.59.77.187"      # The IP of the old server
OLD_PATH="/var/www/html"      # Path to WP on old server
NEW_PATH="/var/www/html"      # Path to WP on new server
SSH_KEY="~/.ssh/id_ed25519"   # Path to your private key

OLD_DOMAIN="https://www.avm.edu.in"
NEW_DOMAIN="https://new.avm.edu.in"
BACKUP_PATH="/root/backup" # Where to store backups

# Define the SSH command
SSH_CMD="ssh -i $SSH_KEY -o ServerAliveInterval=60 -o ServerAliveCountMax=10"
TIMESTAMP=$(date +%F_%H-%M-%S)

echo "🚀 Starting Robust Migration with Local Backup..."

# 0. Create Local Backup of the NEW Server
echo "📂 Creating a safety backup of existing files and DB on this server..."
mkdir -p $BACKUP_PATH
cd $NEW_PATH

# Backup Database
wp db export "$BACKUP_PATH/local_db_$TIMESTAMP.sql" --allow-root
# Backup Files (Compressed)
tar -czf "$BACKUP_PATH/local_files_$TIMESTAMP.tar.gz" .

echo "✅ Local backup saved to $BACKUP_PATH"

# 1. Export Database on Old Server
echo "📦 Exporting database on old server..."
$SSH_CMD $OLD_USER@$OLD_IP "cd $OLD_PATH && wp db export remote-db.sql --allow-root"

# 2. Sync Files (with --delete to prevent "Cannot redeclare" errors)
echo "📂 Transferring files..."
# Added --delete to remove files on the new server that aren't on the old one.
# This fixes the "Cannot redeclare function" error by ensuring a clean file set.
rsync -avz -e "$SSH_CMD" \
    --timeout=120 \
    --partial \
    --delete \
    --exclude 'wp-config.php' \
    --exclude '.htaccess' \
    $OLD_USER@$OLD_IP:$OLD_PATH/ $NEW_PATH/

# 3. Import Database on New Server
echo "📥 Importing database..."
cd $NEW_PATH
php -d memory_limit=512M $(which wp) db import remote-db.sql --allow-root

# 4. Search and Replace URLs
echo "🔄 Updating URLs from $OLD_DOMAIN to $NEW_DOMAIN..."
wp search-replace "$OLD_DOMAIN" "$NEW_DOMAIN" --allow-root

# 5. Cleanup
echo "🧹 Cleaning up temporary SQL files..."
rm remote-db.sql
$SSH_CMD $OLD_USER@$OLD_IP "rm $OLD_PATH/remote-db.sql"

echo "✅ Migration Complete!"