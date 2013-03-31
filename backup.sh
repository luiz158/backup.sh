#!/bin/bash
#
# backup.sh - rsync directories to a mount point (e.g. external USB drive).
# Copyright (C) 2012,2013 Eric Turner
#
# LICENSE:
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# USAGE:
#
# 1. You need to have a /mnt/backup entry in your fstab. Mine looks like:
#
#    UUID=2e36cace-6a61-4af6-96ef-6e91a0fc4df8 /mnt/backup	ext3	user,noauto,rw
#
# where the uuid was obtained from
#
#    blkid -o full -s UUID
#
# 2. Create an /etc/rsync.backup.exclude file. You can use the one that came with this
# script as a starting point. This allows you to skip rsyncing some files (e.g. /etc/passwd).
#
# 3. Modify any of the variables you want to (e.g. to change where the log file is written)
#
# 4. At the bottom of the script you should change the directores that you want to rsync.
#
# 5. You can use cron to run this script. I run mine every morning at 5am with a crontab entry that looks like:
#
#    0 5 * * * /opt/backup.sh
#
# 5. You can temporarily disable your backup by creating an /etc/nobackup file. If that file
# exists then this script exits.
#
# NOTES:
#
# The destination of the rsync is /mnt/backup/<hostname>_<distro name>_<distro version>.
# For example: /mnt/backup/foobar_Ubuntu_11.10/
#
# This script also makes a copy of the previous versions of files into a directory for
# the day the backup is run, so that you can access older versions.
# For example: /mnt/backup/foobar_Ubuntu_11.10/backups/20120924/etc/hosts
#
# I encrypt all of my home directories, so this script only rsyncs home directories
# that are not encrypted (i.e. home directories of logged-in users). This works fine for
# me because I usually just lock the screen on my laptop when I'm at home and it's in
# its docking station (which my external USB drive is connected to). You'll probably need
# to do something different that that. See USAGE.
#
# If /mnt/backup is already mounted at the time the script is run, it will leave it mounted.
# Otherwise it will unmount /mnt/backup.
#
# If /mnt/backup cannot be mounted, the script aborts.
#
# If backup.sh is already running, the script aborts.
#
# CONTACT:
#
# If you have questions or suggestions, contact me through GitHub at http://www.github.com/erturne/backup.sh
#

OUTPUT_LOG=/var/tmp/backup.log
SKIP_FILE=/etc/nobackup
LOCK_FILE=/tmp/backup.lck
RSYNC_EXCLUDE_FILE=/etc/rsync.backup.exclude
DESTINATION_MOUNT=/mnt/backup
SOURCE_HOSTNAME=`/bin/uname -n`_`cat /etc/*-release | grep "ID" | cut -f 2 -d "="`_`cat /etc/*-release | grep "RELEASE" | cut -f 2 -d "="`
DESTINATION_DIR=$DESTINATION_MOUNT/$SOURCE_HOSTNAME
BACKUP_DIR=$DESTINATION_DIR/backups/`date +%Y%m%d`
ALREADY_MOUNTED_AT_STARTUP=0
IS_MOUNTED=0

################################################################################
# Changes stdout and stderr to go to the output log.
################################################################################
redirect_output()
{
   # Save off this script's stdout and stderr, then redirect
   # this script's stdout and stderr to go to a log file.
   exec 3>&1 4>&2
   exec > $OUTPUT_LOG 2>&1
}

restore_output()
{
    # Restore the script's stdout and stderr, and close the temporary
    # file descriptors.
    exec 1>&3 3>&- 2>&4 4>&-
}

################################################################################
# Determines if the backup disk is mounted, and sets the IS_MOUNTED global.
################################################################################
is_mounted()
{
   echo "Checking if $DESTINATION_MOUNT is already mounted"
   MOUNTED=`cat /proc/mounts | cut -d' ' -f2 | grep "$DESTINATION_MOUNT"`
   echo "Result: $MOUNTED"
   if [ -z "$MOUNTED" ]; then
      IS_MOUNTED=0
   else
      IS_MOUNTED=1
   fi
}

################################################################################
# Starts the backup.
################################################################################
start_backup()
{
   # Only start if there isn't a skip file
   if [ -e $SKIP_FILE ]; then
      echo "Backup didn't run because $SKIP_FILE exists"
      exit 0
   fi

   # Only start if a lock isn't being held.
   if [ -e $LOCK_FILE ]; then
       # Exit if the process that created the lock is still running
       LOCK_PID=`cat $LOCK_FILE`
       if [ -n "$LOCK_PID" ]; then
	   FOUND_PROCESS=`ps --pid $LOCK_PID -o comm=`
	   # TODO: process should also be a backup process.
	   if [ -n "$FOUND_PROCESS" ]; then
	       echo "Backup didn't run because another backup ($LOCK_PID) is still running"
	       exit 0
	   else
	       echo $$ > $LOCK_FILE
	   fi
       else
	   echo $$ > $LOCK_FILE
       fi
   else
       echo $$ > $LOCK_FILE
   fi

   redirect_output
   echo "Backup started on `date`"

   # If the $DESTINATION_MOUNT directory doesn't exist then create it.
   echo "Ensuring that $DESTINATION_MOUNT exists"
   /bin/mkdir --parents $DESTINATION_MOUNT

   # If the backup disk isn't mounted, try mounting it then exit if there is a problem.
   is_mounted
   echo "Mounted? $IS_MOUNTED"
   if [ $IS_MOUNTED -eq 0 ]; then
      ALREADY_MOUNTED_AT_STARTUP=0
      echo "Mounting $DESTINATION_MOUNT"
      /bin/mount $DESTINATION_MOUNT
      is_mounted
      if [ $IS_MOUNTED -eq 0 ]; then
	  backup_failed "Unable to mount the backup disk"
      fi
   else
      ALREADY_MOUNTED_AT_STARTUP=1
   fi

   # The exclusion file tells rsync what to ignore. Create it if we need to.
   if [ ! -e $RSYNC_EXCLUDE_FILE ]; then
       touch $RSYNC_EXCLUDE_FILE
   fi
}

################################################################################
# Ends the backup script gracefully. Syncs disk buffers before unmounting
# the backup mount and calling exit.
#
# Params:
#   Exit status (e.g. 0 for success)
################################################################################
end_backup()
{
    # Ensure that disk buffers are written before unmounting so that if
    # umount fails, and disk is unplugged, we don't end up in a bad state.
    sync
    sleep 2

    is_mounted
    if [ $ALREADY_MOUNTED_AT_STARTUP -eq 0 -a $IS_MOUNTED -eq 1 ]; then
	echo "Unmounting $DESTINATION_MOUNT"
	/bin/umount $DESTINATION_MOUNT
	sync
	sleep 2
    fi

    rm -f $LOCK_FILE

    echo "Backup ended on `date`"

    restore_output

    exit $1
}


################################################################################
# Logs an error before ending the backup with a failure status.
#
# Params:
#   Message to log
################################################################################
backup_failed()
{
    echo "$1" >&2
    end_backup 1
}

################################################################################
# Ends the backup with a success status.
################################################################################
backup_succeeded()
{
    end_backup 0
}

################################################################################
# Syncs filesystems using rsync with arguments for preserving file ownership,
# permissions, etc. If the destination doesn't exist then it creates it.
#
# Params:
#   Source directory (e.g. /home)
#   Destination directory (e.g. /mnt/backup/hostname_distro_version)
#   Backup directory (e.g. /mnt/backup/hostname_Ubuntu_11.10/backups/20120102)
#   File used to exclude synchronization of specific files and directories.
#
#   If the source directory is /home, and the destination directory is
#   /mnt/backup/, then the result will be a copy of /home in /mnt/backup/home
################################################################################
rsync_files()
{
    src=$1
    dest=$2
    backup=$3
    exclude=$4

    # If the destination directory doesn't exist then make it.
    echo "Ensuring that $dest exists"
    /bin/mkdir --parents $dest

    # If the backup directory doesn't exist then make it.
    echo "Ensuring that $backup exists"
    /bin/mkdir --parents $backup

    echo "Backing up $src"

    /usr/bin/rsync --verbose \
       --backup \
       --backup-dir=$backup \
       --relative \
       --archive \
       --hard-links \
       --sparse \
       --numeric-ids \
       --delete \
       --delete-excluded \
       --delete-after \
       $src $dest \
       --exclude-from=$exclude

    # TODO: archive old backup directories
}

################################################################################
# Run the backup
################################################################################

start_backup

# Synchronize files

# Only back up home directories if the user is logged in. Otherwise everything
# is encrypted and doesn't work well with rsync. Also, changes are most likely
# to need backup when the user is logged in rather than when they are not.

for U in `ls /home`; do
    if [ ! -e "/home/$U/Access-Your-Private-Data.desktop" ]; then
       rsync_files /home/$U $DESTINATION_DIR $BACKUP_DIR $RSYNC_EXCLUDE_FILE
    else
       echo "Skipping /home/$U because the encrypted file system is not mounted"
    fi
done


rsync_files /boot             $DESTINATION_DIR $BACKUP_DIR $RSYNC_EXCLUDE_FILE
rsync_files /etc              $DESTINATION_DIR $BACKUP_DIR $RSYNC_EXCLUDE_FILE
rsync_files /root             $DESTINATION_DIR $BACKUP_DIR $RSYNC_EXCLUDE_FILE
rsync_files /scanned_docs     $DESTINATION_DIR $BACKUP_DIR $RSYNC_EXCLUDE_FILE

backup_succeeded
