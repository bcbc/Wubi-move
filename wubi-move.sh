#!/bin/bash -e
# Moves a loopinstallation (e.g. Wubi) to a dedicated partition.
# 
# This script was modified from one by Agostino Russo. 
#
# While every effort has been made to ensure the script works as
# intended and is bug free, please note you use it AT YOUR OWN RISK.
# Please BACKUP any important data prior to running.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option) any
# later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA

#######################################################
# Changes to original script
#######################################################
# Added new options and checks
# Attempt partition checks prior to formatting
# Updated commands that no longer work
# Additional comments to aid in debug/enhancements
# This version uses the ext4 file system and grub2
# Check swap partition type, and update hibernation settings
#######################################################


dev=
swapdev=
target=/tmp/wubitarget
swap=/tmp/wubiswap
version=0.0.6beta
debug="false"
no_bootloader="false"
assume_yes="false"
formatted_dev="false"

usage () 
{
    cat <<EOF
Usage: sudo bash $0 [OPTION] target_partition [swap_partition]
       e.g. sudo bash $0 /dev/sda5 /dev/sda6

Migrate a wubi ubuntu install (9.10 or greater) to partition
  -h, --help              print this message and exit
  -v, --version           print the version information and exit
  --no-bootloader         do not install the grub2 bootloader
  -y, --assume-yes        assume yes to all prompts
  
Assumptions: 
  1. grub2 is installed - if the script detects grub-legacy it will exit
  2. the grub2 bootloader will be installed to /dev/sdX where /dev/sdXY
     is the target partition, unless --no-bootloader is specified.
     If -y or --assume-yes is not specified you will still be prompted
     whether to install the grub bootloader.
  3. the target partition file system will be formatted as ext4

Notes:
  If you install the grub2 bootloader then the grub menu from your new partition
  will be presented at boot. Not the windows menu.
  If you do not install the grub2 bootloader, then you will still be able to 
  boot the new partition using the wubi menu. In this case, make sure you
  install the grub2 bootloader before uninstalling wubi.
  To install the bootloader, boot your new installation and run: 
       sudo grub-install /dev/sdX 
  (where X is the drive you boot from e.g. /dev/sda)
EOF
}

# Check the arguments.
for option in "$@"; do
    case "$option" in
    -h | --help)
	usage
	exit 0 ;;
    -v | --version)
	echo "$0: Version $version"
	exit 0 ;;
    --no-bootloader)
	no_bootloader=true
	;;
    -y | --assume-yes)
	assume_yes=true
	;;
#undocumented debug option
    -d | --debug)
	set -x
	debug=true
	;;
    -*)
	echo "$0: Unrecognized option '$option'" 1>&2
	usage
	exit 1
	;;
    *)
# identify the target partition to install to
# and the swap partition (if supplied)
# Any additional parameters are errors
	if test "x$dev" != x; then
	  if  test "x$swapdev" != x; then
	      echo "$0: Too many parameters" 1>&2
	      usage
	      exit 1
	  else
	    swapdev="${option}"
	  fi
	else
	  dev="${option}" 
	fi
	;;
    esac
done


sanity_checks ()
{
# $dev must be a non-empty string and a block device
    if [ -z "$dev" ] || [ ! -b "$dev" ]; then
        echo "$0: target_partition ($dev) must be a valid partition."
        exit 1
    fi
    if [ -n "$swapdev" ] && [ ! -b "$swapdev" ]; then
        echo "$0: swapdevice ($swapdev) is not a block device."            
        exit 1
    fi
    if [ -b "$swapdev" ]; then
        if [ "$(sudo blkid -o value -s TYPE $swapdev)" != "swap" ]; then
            echo "$0: $swapdev is not a swap partition"
            exit 1
        fi
    fi
    if [ "$(whoami)" != root ]; then
        echo "$0: Admin rights are required to run this program."
        exit 1
    fi

# create a temp directory to mount the target partition
    mkdir -p $target

# make sure the target is not already mounted (suppress output)
# if umount failed, then issue 'true' to continue
    umount $target 2> /dev/null || true

# make sure the device is not mounted on a different mount point(s)
    if [ $(mount | grep "$dev"'\ ' | wc -l) -ne 0 ]; then
        echo "$0: $dev is mounted - please unmount and try again"
        exit 1
    fi

# check that grub-legacy isn't installed
    if [ $(grub-install --version | grep "0.97" | wc -l) -ne 0 ]; then
        echo "$0: Grub (legacy) is installed - this code supports grub2"
#        echo "$0: Try lvpm instead"  (lvpm doesn't work - probably
# still uses vol_id instead of blkid so fstab is blank
        exit 1
    fi

# try and mount target partition, and ensure that it is empty
# (note freshly formatted ext2/3/4 contain a single 'lost and found')
# Checks are performed prior to formatting if possible, however,
# if the mount fails, it could be unformatted in which case we
# have to format first
    if mount -t auto "$dev" $target 2> /dev/null; then
        if [ $(ls -1 $target | wc -l) -ne 0 ] ; then
          if [ $(ls -1 $target | wc -l) -gt 1 ] || \
             [ "$(ls -1 $target)" != "lost+found" ]; then
            echo "$0: Partition $dev is not empty. Aborting"
            umount $target || true
            exit 1
          fi
        fi
    else
	format_partition
        mount $dev $target
    fi

# size sums the 6th column (Used space) on the /, /home and /usr partitions
# note you may just have a single / root partition
    size=$(df | awk '$6=="/" || $6=="/home" || $6=="/usr" {sum += $3} END {print sum}')
# just in case of an error, the size might be zero
    if [ $size -eq 0 ]; then
        echo "$0: Error determining size of wubi install. Aborting"
        umount $target || true
        exit 1
    fi
# determine how much available space is on the target partition
# do this check before formatting
# Technically you can have an install less that 5GB but this seems
# too small to be worth allowing
    free_space=$(df $target|tail -n 1|awk '{print $4}')
    if [ $free_space -lt $size ] || [ $free_space -lt 5120000 ]; then
        echo "$0: Target partition ($dev) is not big enough"
        echo "$0: Current install is $size K"
        echo "$0: Free space on target is $free_space K, (min reqd 5 GB)"
        echo "$0: Aborting"
        umount $target || true
        exit 1
    fi
    umount $target
}

# Format the target partition with ext4 file system
# Message to close open programs to prevent partial updates
# being copied as is.
format_partition ()
{
    if [ "$formatted_dev" != true ] ; then
      formatted_dev="true"
      if [ "$assume_yes" != true ] ; then
        echo ""
        echo "$0: Please close all open files before continuing."
        echo "$0: About to format the target partition ($dev)."
        echo "$0: Proceed with format (Y/N)"
        read input
        if [ "$input" = "n" ] || [ "$input" = "N" ]; then
            echo "$0: Request aborted"
            exit 0
        fi
      fi    
      echo "$0: Formatting $dev with ext4 file system"
      mkfs.ext4 $dev > /dev/null 2>&1
    fi
}
# Copy entire wubi install to target partition
# Monitor return code from rsync in case user hits CTRL-C.
# Make fake /host directory to allow override of /host mount 
# and prevent update-grub errors in chroot
# Disable 10_lupin script
migrate_files ()
{
    echo ""
    echo "$0: Copying files - please be patient - this takes some time"
    rsync -a --exclude=/host --exclude=/mnt/* --exclude=/home/*/.gvfs --exclude=/media/*/* --exclude=/tmp/* --exclude=/proc/* --exclude=/sys/* / $target > /dev/null 2>&1
    RETCODE=$?
    if [ "$RETCODE" -ne 0 ]; then
        echo ""
        echo "$0: Copying files FAILED - user canceled?"
        echo "$0: Unmounting target..."
        sleep 3
        umount $dev
        echo "$0: Operation aborted"
        exit 1
    fi 

    mkdir $target/host
    chmod -x $target/etc/grub.d/10_lupin
}

# create swap partition and enable hibernation on new install
# Note: swap must be at least as big as RAM for hibernation
# Note: usually you need to run update-initramfs -u after setting
#       the resume UUID, however it is run automatically when removing
#       lupin-support later.
create_swap ()
{
    if [ -b "$swapdev" ]; then
        echo "$0: Creating swap..."
        mkswap $swapdev > /dev/null 2>&1
        echo "RESUME=UUID=$(blkid -o value -s UUID $swapdev)" > $target/etc/initramfs-tools/conf.d/resume
    fi
}


edit_fstab ()
{
# sed s:regexp:replacement:
# Replace characters matched between 1st ':' and 2nd ':' with 
# whatever is between the 2nd  ':' and 3rd ':' (in this case, we're 
#  replacing with nothing - blanking out)
# .* means match any characters up until the next match
# [\.]disk means match a period followed by disk: '.disk'
# -i replaces file (breaking symbolic links).

# blank any line starting with '/' and containing '.disk'
    sed -i 's:/.*[\.]disk .*::' $target/etc/fstab
# blank out line starting with '/' and containing '/disks.boot'
    sed -i 's:/.*/disks/boot .*::' $target/etc/fstab
# add line to mount $dev as new root (based on UUID)
    echo "# root was on $dev when wubi migrated" >> $target/etc/fstab    
    echo "UUID=$(blkid -o value -s UUID $dev)    /    ext4    errors=remount-ro    0    1" >> $target/etc/fstab
# add line to mount swapdev based on uuid if passed
    if [ -b "$swapdev" ]; then
        echo "# swap was on $swapdev when wubi migrated" >> $target/etc/fstab
        echo "UUID=$(blkid -o value -s UUID $swapdev)    none    swap    sw    0    0" >> $target/etc/fstab
    fi
}

# start chroot to target install
# (mount empty /host to prevent update-grub errors)
# Prevent upstart jobs running in the chroot
start_chroot ()
{
    echo ""
    echo "$0: Starting CHROOT to the target install."
    for i in dev proc sys dev/pts host; do
        mount --bind /$i $target/$i;
    done
    chroot $target dpkg-divert --local --rename --add /sbin/initctl > /dev/null 2>&1
    chroot $target ln -s /bin/true /sbin/initctl > /dev/null 2>&1

}

# Exit chroot from target install
# remove Upstart workaround so it's available on the target partition
end_chroot ()
{
    chroot $target rm /sbin/initctl > /dev/null 2>&1
    chroot $target dpkg-divert --local --rename --remove /sbin/initctl  > /dev/null 2>&1
    for i in host dev/pts dev proc sys; do 
        umount $target/$i;
    done 
    echo "$0: Exiting from chroot on target install..."
}

# run command in chroot on target install
target_cmd ()
{
    chroot $target $* > /dev/null 2>&1
}

# remove lupin support and update the target install grub menu
chroot_cmds ()
{

    echo "$0: Removing lupin-support on target..."
    target_cmd apt-get -y remove lupin-support
    echo "$0: Updating the target grub menu"
    target_cmd update-grub
}

# Had to add this back to chroot commands due to lupin-support mods to 
# grub-install that prevented it from working with the --root-directory= option
# install the grub2 bootloader unless requested not to. Reasons for not
# installing are e.g. you are installing to /dev/sdbY, but you boot from
# /dev/sda. In this, case you should manually replace the bootloader after
# booting it - you will be able to boot it from the wubi menu to do this. 
grub_bootloader ()
{
    disk=${dev%%[0-9]*}
    if [ "$no_bootloader" = "false" ] ; then
      if [ "$assume_yes" != "true" ] ; then
        echo ""        
        echo "$0: The grub2 bootloader will be installed to drive ($disk)"
        echo "$0: If you select no, you have to boot your new install"
        echo "$0: from the wubi menu and install it later manually."
        echo "$0: Install the grub bootloader to $disk? (Y/N)"
        read input
        if [ "$input" = "n" ] || [ "$input" = "N" ]; then
            echo "$0: Grub bootloader not installed"
        else
            target_cmd grub-install $disk
            echo "$0: Grub bootloader installed to $disk"
        fi
      else
            target_cmd grub-install $disk
            echo "$0: Grub bootloader installed to $disk"
      fi    
    fi
}

# update the wubi grub menu so that you can boot your new partition even if
# you haven't installed the grub2 bootloader.
# (this leaves the windows bootloader in control)
update_grub ()
{
    echo ""
    echo "$0: Updating wubi grub menu to add new install..."
    sleep 1
    update-grub
}

exit_processing ()
{
    rmdir $target/host
    umount $dev
    echo ""
    echo "$0: Operation completed successfully."
}

#Main processing
sanity_checks
format_partition
mount $dev $target
migrate_files
create_swap
edit_fstab
start_chroot
chroot_cmds
grub_bootloader
end_chroot
update_grub
exit_processing
exit 0
