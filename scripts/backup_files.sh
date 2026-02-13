#!/bin/bash

# Get the current date in dd.mm.yy format
DATE=$(date +"%d.%m.%y")

# Define backup directory with date in the name
BACKUP_DIR="/home/ahaan/backup-$DATE"

# Remove any existing backup with the same name (optional, but ensures fresh backups)
rm -rf "$BACKUP_DIR"

# Create the backup directory
mkdir -p "$BACKUP_DIR"

# Copy directories
cp -r /home/ahaan/ahahahaan "$BACKUP_DIR"
cp -r /home/ahaan/college "$BACKUP_DIR"
cp -r /home/ahaan/Documents "$BACKUP_DIR"
cp -r /home/ahaan/L4-strat-dev "$BACKUP_DIR"
cp -r /home/ahaan/Pictures "$BACKUP_DIR"
cp -r /home/ahaan/SYSTEMS "$BACKUP_DIR"
cp -r /home/ahaan/TRW "$BACKUP_DIR"
cp -r /home/ahaan/physics.txt "$BACKUP_DIR"
cp -r /home/ahaan/Videos "$BACKUP_DIR"
cp -r /home/ahaan/journal.txt "$BACKUP_DIR"
cp -r /home/ahaan/reflections.txt "$BACKUP_DIR"
cp -r /home/ahaan/memes "$BACKUP_DIR"
cp -r /home/ahaan/Extra "$BACKUP_DIR"

# Log the backup
echo "Backup completed at $(date)" >> "$BACKUP_DIR/backup.log"

echo "Backup has been created at: $BACKUP_DIR"
