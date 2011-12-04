#!/bin/bash
# Moves an Ubuntu install (normal or a loopinstallation e.g. Wubi) 
# to a dedicated partition install. 
# Migration from a Wubi root.disk is supported as well.
# 
# If you have grub legacy installed, it will remove it on the 
# target (only) and replace it with grub2.
#
# While every effort has been made to ensure the script works as
# intended and is bug free, please note you use it AT YOUR OWN RISK.
# Please BACKUP any important data prior to running.
#
# Credits:
# Much of the script's fundamentals are based on the work of
# other people e.g. the original wubi migration script and lupin:
#    Copyright (C) 2007 Agostino Russo <agostino.russo@gmail.com>
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
#
### Variable declaration ###
#
# Options 
no_bootloader=false         # Bypass Grub2 bootloader install
no_mkswap=false             # Skip mkswap on swap partition
assume_yes=false            # Assume "Y" to all prompts
root_disk=                  # path and name of root.disk file 
debug=false                 # Output debug information
dev=                        # target device for migration
swapdev=                    # swap device for migration
rootdiskpath=               # path to root.disk file
resume_prev=false           # resume previous migration attempt
resynch_prev=false          # synch a previously migrated install
homedev=                    # /home device for migration
bootdev=                    # /boot device for migration
usrdev=                     # /usr device for migration
check_only=false            # just do checks - no changes

# Literals 
version=2.2                 # Script version
target=/tmp/wubi-move/target        # target device mountpoint
root_mount=/tmp/wubi-move/rootdisk  # root.disk source mountpoint
other_mount=/tmp/wubi-move/other    # used to check other target partitions
space_buffer=400000         # minimum Kilobytes free space required on target partition(s)
boot_space_buffer=100000    # minimum additional free space required for separate boot partition

# Bools 
formatted_dev=false         # Has the target been formatted?
grub_legacy=false           # Is grub legacy installed?
install_grub=false          # Must the grub2 bootloader be installed?
wubi_install=true           # Is this a Wubi install migration?
internet_connection=false   # Is there an internet connection present?
suppress_chroot_output=true # Default - suppress output of chroot commands
grub_common_exists=true     # Check for grub-common (not on 8.04)

# Working variables
fs=ext4                     # Default file system - else ext3 if detected on install being migrated
rc=                         # Preserve return code
root="/"                    # Default root of the install being migrated
host_mountpoint=            # Host mountpoint for Wubi install
root_device=                # Device that root (/) is mounted on
loop_file=                  # Root.disk for running Wubi install
loop_device=                # Loop device for mounted root.disk
mtpt=                       # Mount point determination working variable
awkscript=                  # Contains AWK script
target_size=                # size of target partition
install_size=               # size of current install

usage () 
{
    cat <<EOF
Usage: sudo bash $0 [OPTION] target_partition [swap_partition]
       e.g. sudo bash $0 /dev/sda5 /dev/sda6

Migrate an ubuntu install (wubi or normal) to partition
  -h, --help              print this message and exit
  -v, --version           print the version information and exit
  --notes                 print the Assumptions and Notes, and exit
  --no-bootloader         do not install the grub2 bootloader
  --shared-swap           share swap partition with an existing install
  -y, --assume-yes        assume yes to all prompts
  --root-disk=<root.disk> Specify a root.disk file to migrate
  --boot=</dev/sdXY>      Specify a separate /boot partition
  --home=</dev/sdXY>      Specify a separate /home partition
  --usr=</dev/sdXY>       Specify a separate /usr partition
  -c, --check-only        Check only - validate target partition(s)
  --resume                Resume a previous migration attempt that ended
                          due to copying errors (rsync).
  --synch                 Synchronize a previously migrated install
EOF
} 
assumptions_notes () 
{
    cat <<EOF
Assumptions: 
  1. The script will detect automatically whether the current install
     to be migrated is a Wubi or normal install. 
  2. If you are running the script from a live CD/USB then the 
     --root-disk= option is required. The grub2 bootloader must be
     installed when using this option. If there are separate virtual
     disks (e.g. usr.disk, home.disk), they must be in the same 
     directory as the root.disk. (Grub-legacy not supported).
  3. The grub2 bootloader will be installed to /dev/sdX where /dev/sdXY
     is the target partition, unless --no-bootloader is specified.
     You will still be prompted whether to install the grub bootloader 
     unless option -y or --assume-yes is supplied.
  4. If the install being migrated contains grub-legacy it will be 
     replaced with Grub2 (only on the migrated install). You are not 
     required to install the Grub2 bootloader, however, if you choose
     not to then you will have to manually modify the menu.lst to boot
     the migrated install.
     NOTE: the grub2 installation takes control and requires user input
     on releases 9.10 and greater. It will also prompt for the bootloader
     install drive/partition.
  5. The target partition file system will be formatted as ext4 (default) 
     or ext3 if detected on the install being migrated. The script will not
     modify the partition type i.e. set it to 83 (linux)
  6. The script supports migrating from multiple partitions, and also
     to multiple partitions. Separate target partitions are supported
     for /boot, /usr and /home.

Notes:
  If you install the grub bootloader, then the grub menu from your migrated
  install will be presented at boot - not the windows menu (for Wubi installs.)
  If you do not install the bootloader, then you will still be able to 
  boot the migrated install from the current install's Grub menu, unless your
  current install uses grub legacy.
  For Wubi users, make sure you install bootloader before uninstalling Wubi. 

  To install the bootloader manually, boot your new installation and run: 
       sudo grub-install /dev/sdX 
  (where X is the drive you boot from e.g. /dev/sda)

Recommended:
  Run "sudo update-grub" on the migrated install after booting the first time
EOF
}

### Check the options and parameters
for option in "$@"; do
    case "$option" in
    -h | --help)
    usage
    exit 0 ;;
    -v | --version)
    echo "$0: Version $version"
    exit 0 ;;
    --notes)
    assumptions_notes
    exit 0 ;;
    --no-bootloader)
    no_bootloader=true
    ;;
    --shared-swap)
    no_mkswap=true
    ;;
    -y | --assume-yes)
    assume_yes=true
    ;;
    --root-disk=*)
    root_disk=`echo "$option" | sed 's/--root-disk=//'` ;;
    --home=*)
    homedev=`echo "$option" | sed 's/--home=//'` ;;
    --boot=*)
    bootdev=`echo "$option" | sed 's/--boot=//'` ;;
    --usr=*)
    usrdev=`echo "$option" | sed 's/--usr=//'` ;;
   --resume)
    resume_prev=true
    ;;
    -c | --check-only)
    check_only=true
    ;;
   --synch)
    resynch_prev=true
    ;;
### undocumented debug option
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
### Positional parameters - Order is important
### Identify the target partition to install to
### and the swap partition (if supplied)
### Any additional parameters are errors
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

# thanks os-prober
log() {
  logger -t "$0" -- "$@"
}

error() {
  log "error: " "$@"
  echo "$0: " "$@"
}

info() {
  log "info: " "$@"
  echo "$0: " "$@"
}

warn() {
  log "warning: " "$@"
  echo "$0: " "$@"
}

debug() {
  log "debug: " "$@"
}

result () {
  log "result: " "$@"
  echo "$0: " "$@"
}


### Present Y/N questions and check response 
### (a valid response is required)
### Parameter: the question requiring an answer
### Returns: 0 = Yes, 1 = No
test_YN ()
{
    while true; do 
      info "$@"
      read input
      case "$input" in 
        "y" | "Y" )
          return 0 ;;
        "n" | "N" )
          return 1 ;;
        * )
          warn "Invalid response ('$input')"
      esac
    done
}

### Final exit script
### All cleanup has been done - output the result based on
### the parameter (provided --check-only not used):
###    0 = successful execution
###    1 = exception
final_exit ()
{
    if [ "$check_only" == "true" ]; then
      exit $1
    fi
    echo ""
    if [ $1 -eq 0 ]; then
      result "Migration completed successfully."
      if [ -f $HOME/.wubi-move ]; then
        mv -f $HOME/.wubi-move $HOME/.wubi-move.last
      fi
    else
      result "Migration did not complete successfully."
    fi
    exit $1
}

### Unmount any (loop) devices used in script and remove mountpoints
cleanup_for_exit ()
{
# all mount checks with grep add a space to differentiate e.g. /dev/sda1 from /dev/sda11
# Not really necessary for these custom mountpoints but do it anyway.
# Depending on when the exception is encountered there may be nothing to cleanup

# If the migration is from a named root.disk, unmount if required,
# and then delete mountpoint. Also check home.disk and usr.disk
    if [ ! -z "$root_disk" ]; then
      if [ $(mount | grep "$root_mount"/home'\ ' | wc -l) -ne 0 ]; then
        umount "$root_mount"/home > /dev/null 2>&1
        sleep 3 
        [ -d "$root_mount"/home ] && rmdir "$root_mount"/home > /dev/null 2>&1
      fi
      if [ $(mount | grep "$root_mount"/usr'\ ' | wc -l) -ne 0 ]; then
        umount "$root_mount"/usr > /dev/null 2>&1
        sleep 3 
        [ -d "$root_mount"/usr ] && rmdir "$root_mount"/usr > /dev/null 2>&1
      fi
      if [ $(mount | grep "$root_mount"'\ ' | wc -l) -ne 0 ]; then
        umount "$root_mount" > /dev/null 2>&1
        sleep 3 
      fi
      [ -d "$root_mount" ] && rmdir "$root_mount" > /dev/null 2>&1
    fi

## If a wubi install is being migrated, remove the fake /host
## created to bypass grub errors. Do this before unmounting
#    if [ "$wubi_install" = "true" ] && [ -d "$target"/host ]; then
#      rmdir "$target"/host > /dev/null 2>&1
#    fi

# Now unmount migrated install if required and delete main mountpoint
# If migrating to separate partitions, unmount first but leave these
# mountpoints in place.
    if [ $(mount | grep "$target"/home'\ ' | wc -l) -ne 0 ]; then
      umount "$target"/home > /dev/null 2>&1
      sleep 3
    fi
    if [ $(mount | grep "$target"/usr'\ ' | wc -l) -ne 0 ]; then
      umount "$target"/usr > /dev/null 2>&1
      sleep 3
    fi
    if [ $(mount | grep "$target"/boot'\ ' | wc -l) -ne 0 ]; then
      umount "$target"/boot > /dev/null 2>&1
      sleep 3
    fi
    if [ $(mount | grep "$target"'\ ' | wc -l) -ne 0 ]; then
      umount $target > /dev/null 2>&1
      sleep 1
    fi
    if [ -d "$target" ]; then
      rmdir "$target" > /dev/null 2>&1 
    fi

# other mountpoint - for checking multi-partition migrations
    if [ $(mount | grep "$other_mount"'\ ' | wc -l) -ne 0 ]; then
      umount $other_mount > /dev/null 2>&1
      sleep 1
    fi
    if [ -d "$other_mount" ]; then
      rmdir "$other_mount" > /dev/null 2>&1 
    fi
}

### Early exit - problem detected or user canceled or
### the --check-only option was supplied.
### Call cleanup and final exit, passing parameter:
###    0 = successful execution
###    1 = exception
exit_script ()
{
    cleanup_for_exit
    final_exit $1
}

# Check that a virtual disk is not mounted
check_disk_mount ()
{
# this code goes through each line in /proc/mounts
# and compares the first column ($DEV) to "/dev/loop*"
# If it finds an existing loop mount it retrieves the
# associated filename and compares it to the root.disk
    while read DEV MTPT FSTYPE OPTS REST; do
        case "$DEV" in
          /dev/loop/*|/dev/loop[0-9])
            loop_file=`losetup "$DEV" | sed -e "s/^[^(]*(\([^)]\+\)).*/\1/"`
            if  [ "$loop_file" = "$1" ]; then
                error ""$1" is mounted - please unmount and try again"
                exit_script 1
            fi
          ;;
        esac
    done < /proc/mounts
}

# mount a virtual disk - exit if it fails
mount_virtual_disk()
{
    if mount -o loop "$1" "$2" 2> /tmp/wubi-move-error; then
        true #nothing yet
    else
        error ""$1" could not be mounted"
# Check for 'file system ext4 unknown' message e.g. if you boot an
# 8.04 disk and try to migrate a current ext4 root.disk 
        if [ $(cat /tmp/wubi-move-error | grep "unknown filesystem type 'ext4'" | wc -l) -eq 1 ]; then 
            error "The live environment you are using doesn't support"
            error "the virtual disks ext4 file system. Try using an"
            error "Ubuntu CD containing release 9.10 or later."
        else
            # some other issue - output message
            error "Error is: $(cat /tmp/wubi-move-error)"
            error "Check that the path/name is correct and"
            error "contains a working Wubi install."
        fi
        exit_script 1
    fi
}

check_fstab ()
{
# this code goes through each line in /etc/fstab
# and makes sure the virtual disks are not mounted
# and mountable. It assumes that /host/ubuntu/disks/xxx.disk
# means that xxx.disk is in the same location as the current 
# root.disk that whose /etc/fstab contains xxx.disk
    while read fDEV fMTPT fTYPE fOPTS fDMP fPASS; do
        case "$fMTPT" in 
          /home|/usr)
            disks_path=`echo $fDEV | sed -e "s/\(^\/host\/ubuntu\/disks\/\)\(.*\)/\1/"`
            if [ "$disks_path" = "/host/ubuntu/disks/" ]; then          
                virtual_disk=`echo $fDEV | sed -e "s/\(^\/host\/ubuntu\/disks\/\)\(.*\)/\2/"`
                if [ ! -f "$rootdiskpath"$virtual_disk ]; then
                   error "Root disk contains a reference to: "$virtual_disk""
                   error "This cannot be found in: "$rootdiskpath""
                   error "Please fix and retry"
                   exit_script 1
                fi
                check_disk_mount "$rootdiskpath"$virtual_disk"\ "
                mkdir "$root_mount"$fMTPT
                mount_virtual_disk "$rootdiskpath"$virtual_disk "$root_mount"$fMTPT
            fi    
          ;;
        esac
    done < "$root_mount"/etc/fstab
}



# Attempt to migrate from a root.disk. The root.disk must be a fully
# contained Ubuntu install with /, /boot, /home, /usr (note this excludes
# grub-legacy Ubuntu since /boot is on the windows partition).
# The checks performed here are pretty basic.
# The onus is on the user to have a working Wubi root.disk
root_disk_migration () 
{
    debug "Checking --root-disk option"
    if [ ! -f "$root_disk" ]; then
        error "root disk not found: "$root_disk""
        exit_script 1
    fi
# Since the migration can be from a live CD
    if [ "$no_bootloader" = "true" ]; then
        error "You cannot use --no-bootloader with --root-disk"
        exit_script 1
    fi
    install_grub=true


# mount the root.disk and check it is a fully contained install
# or else the /etc/fstab links to additional virtual disks and 
# these can be validated.
# /usr, /home, and /boot are present. If this is a grub legacy
# migration /boot is always separate so it's not possible to migrate 
    mkdir -p $root_mount

# make sure the root.disk is not already mounted
    check_disk_mount "$root_disk""\ "

# mount it - fail if the mount fails
    mount_virtual_disk "$root_disk" "$root_mount"

# override root for the copy command.
    root="$root_mount"/

# read the /etc/fstab and check for other virtual disks, make sure they are there, and unmounted.
# Create mountpoints for /usr and /home if they exist and mount them
    rootdiskpath=${root_disk%/*}/
    check_fstab    
    
# determine size of install
    awkscript="\$6==\""$root_mount"\" || \$6==\""$root_mount"/usr\" || \$6==\""$root_mount"/home\" {sum += \$3} END {print sum}"
    install_size=$(df | awk "$awkscript")
    awkscript="\$2==\""$root_mount"/home\ \" {total = \$1} END {print total}"

# check we have all the required files - grub legacy won't work as
# we never mount /boot separately
    if [ $(ls -1 "$root_mount"/usr | wc -l) -eq 0 ] || \
       [ $(ls -1 "$root_mount"/home | wc -l) -eq 0 ] || \
       [ $(ls -1 "$root_mount"/boot | wc -l) -eq 0 ]; then
        error "Root disk ("$root_disk") missing required directories."
        error "If the original release was prior to 9.10 then it can"
        error "not be migrated from the root.disk."
        exit_script 1
    fi

# make sure the architecture matches
    if [ $(file /bin/bash | grep '32-bit' | wc -l) -eq 1 ]; then
      if [ $(file "$root_mount"/bin/bash | grep '64-bit' | wc -l) -eq 1 ]; then
        error "Current Ubuntu architecture is 32-bit but root.disk contains a 64-bit install."
        error "You need to migrate from a 64-bit environment"
        exit_script 1
      fi
    elif [ $(file "$root_mount"/bin/bash | grep '32-bit' | wc -l) -eq 1 ]; then
      error "Current Ubuntu architecture is 64-bit but root.disk contains a 32-bit install."
      error "You need to migrate from a 32-bit environment"
      exit_script 1
    fi
    debug "Validated --root-disk option"
}

### Determine whether this is a wubi install or not
### Returns 0: Wubi, 1: Not wubi
check_wubi ()
{
# first check for a root_disk - always wubi
    if [ ! -z "$root_disk" ]; then
        root_disk_migration
        return 0 # wubi
    fi

# Identify root device - looking for /dev/loop , and then identify the loop file (root.disk)
# Note for Grub legacy, the /boot device is the windows host. 
# For releases without grub-probe the mount output directly refers to root.disk on Wubi
    if ! type grub-probe > /dev/null 2>&1 ; then
      if [ $(mount | grep ' / ' | grep '/host/ubuntu/disks/root.disk' | wc -l) -eq 1 ]; then
        return 0 # e.g. wubi in release 8.04
      elif [ $(mount | grep ' / ' | wc -l) -eq 1 ]; then
        fs=ext3
        return 1
      else
        error "Cannot migrate from a Live CD/USB"
        error "unless you use option: --root-disk= "
        exit_script 1
      fi
    fi

# Check what device root (/) is mounted on
    root_device="`grub-probe --target=device / 2> /dev/null`"
    if [ -z "$root_device" ]; then
        error "Cannot migrate from a Live CD/USB"
        error "unless you use option: --root-disk= "
        exit_script 1
    fi

# identify root.disk if a Wubi install
    case ${root_device} in
      /dev/loop/*|/dev/loop[0-9])
        loop_file=`losetup ${root_device} | sed -e "s/^[^(]*(\([^)]\+\)).*/\1/"`
      ;;
    esac

    # Check whether booted from loop device 
    # Check whether ext3 - stick with that (not supporting ext2)
    if [ "x${loop_file}" = x ] || [ ! -f "${loop_file}" ]; then
        # not wubi - but before leaving, check whether the file system is ext3
        if [ "$(blkid -c /dev/null -o value -s TYPE "$root_device")" = "ext3" ]; then
            fs=ext3
        fi
        return 1 # not wubi
    fi

    # Irregular root.disk - don't allow (at this time) since it's possible
    # to migrate using the --root-disk= option anyway.
    if [ "$loop_file" != "/host/ubuntu/disks/root.disk" ]; then
        return 2 # migrate not permitted
    fi

    # find the mountpoint for the root.disk - basically strip
    # /host/ubuntu/disks/root.disk down from the right to the left
    # until it is a mountpoint (/host/ubuntu/disks, /host/ubuntu, /host)
    # We're expecting /host
    mtpt="${loop_file%/*}"
    while [ -n "$mtpt" ]; do
        while read DEV MTPT FSTYPE OPTS REST; do
            if [ "$MTPT" = "$mtpt" ]; then
                loop_file=${loop_file#$MTPT}
                host_mountpoint=$MTPT
                break
            fi
        done < /proc/mounts
        mtpt="${mtpt%/*}"
        [ -z "$host_mountpoint" ] || break
    done

    #keep it to the known scenarios
    if [ "$host_mountpoint" != "/host" ]; then
        return 2 # irregular - avoid
    fi
}

# Check partition - user friendly checks to let users know if they've selected
# a drive or an extended partition; then make sure it's type '83'
# Bypass check for GPT for now. (fdisk kicks out an error for GPT)
# Parameters:
#   $1 = partition
#   $2 = type ( "83" or "82")
check_partition_type ()
{
    partition_disk=${1%%[0-9]*}
    if [ "$1" = "$partition_disk" ]; then
        error "target_partition "$1" is a drive, not a partition."
        exit_script 1
    fi
    if [ $(fdisk -l "$partition_disk" 2> /dev/null | grep -i "GPT" | grep "[ \t]ee[ \t]" | wc -l) -ne 0 ]; then
    # bypass GPT disks - assume okay
        return
    fi 
    if [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]5[ \t]" | grep -i "Extended" | wc -l) -eq 1 ]; then
        error "target_partition "$1" is an Extended partition."
        exit_script 1
    fi
    if [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]f[ \t]" | grep -i "W95 Ext'd (LBA)" | wc -l) -eq 1 ]; then
        error "target_partition "$1" is an Extended partition."
        exit_script 1
    fi
    if [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]85[ \t]" | grep -i "Linux extended" | wc -l) -eq 1 ]; then
        error "target_partition "$1" is an Extended partition."
        exit_script 1
    fi
    if  [ "$2" == "83" ]; then
      if [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]"$2"[ \t]" | grep -i "Linux" | wc -l) -eq 0 ]; then
        error "partition "$1" must be type "$2" - Linux."
        exit_script 1
      fi
    else
      if [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]"$2"[ \t]" | grep -i "Linux swap" | wc -l) -eq 0 ]; then
        error "partition "$1" must be type "$2" - Linux swap."
        exit_script 1
      fi
    fi
}

### other device prechecks
precheck_other ()
{
    for i in "$homedev" "$bootdev" "$usrdev"; do
      if [ -n "$i" ]; then
        if [ $(mount | grep "$i"'\ ' | wc -l) -ne 0 ]; then
          error ""$i" is mounted - please unmount and try again"
          exit_script 1
        fi
        if [ ! -b "$i" ]; then
          error ""$i" is not a block device."
          exit_script 1
        fi
        check_partition_type $i "83"
      fi
    done
}

# check partition uuid is the same as saved uuid (for --resume)
# parameters
#   $1 = uuid | "none"
#   $2 = "/usr" | "/home" | "/boot" | "swap"
#   $3 = device | ""
resume_precheck ()
{
      if [ "$1" != "none" ]; then
        if [ ! -n "$3" ]; then
          error "The $2 partition is no longer present"
          return 1
        elif [ "$1" != "$(blkid -c /dev/null -o value -s UUID $3)" ]; then
          error "The UUID on $2 partition $3 has changed"
          return 1
        fi
      elif [ -n "$3" ]; then
          error "A $2 partition cannot be added for a resumed migration"
          return 1
      fi
      return 0
}

# Validate --resume and --synch options
# Both use a save file to match the target partitions, the
# resume file is on the current install; the synch file is
# on the target. Other than that they are the same
#   $1 = "--synch" | "--resume"
validate_resume_synch ()
{
    info "Validating "$1" option"
    if [ "$1" == "--synch" ]; then
        check_file="$target""$HOME"/.wubi-move
    else
        check_file="$HOME/.wubi-move"
    fi

    if [ ! -f "$check_file" ]; then
        error "The "$1" option cannot be used as the"
        error "control file is missing."
        exit_script 1
    fi
    read tRoot tSwap tBoot tUsr tHome tError < "$check_file" 2> /dev/null
    okay=true
    if [ "$tHome" == "" ] || [ -n "$tError" ]; then
        error "The "$1" option cannot be used as the"
        error "control file is invalid"
        exit_script 1
    fi
    if [ "$tRoot" != "$(blkid -c /dev/null -o value -s UUID $dev)" ]; then
        error "The UUID on target partition "$dev" has changed"
        okay=false
    fi
    resume_precheck $tSwap "swap" $swapdev
    if [ "$?" -ne "0" ]; then
        okay=false
    fi
    resume_precheck $tBoot "/boot" $bootdev
    if [ "$?" -ne "0" ]; then
        okay=false
    fi
    resume_precheck $tUsr "/usr" $usrdev
    if [ "$?" -ne "0" ]; then
        okay=false
    fi
    resume_precheck $tHome "/home" $homedev
    if [ "$?" -ne "0" ]; then
        okay=false
    fi
    if [ "$okay" == "false" ]; then
        error "The target partitions cannot be changed"
        error "when using the "$1" option"
        exit_script 1
    fi
    info ""$1" option validated"
    if [ -n "$swapdev" ]; then
        no_mkswap=true
    fi
}

### Early checks - must be admin, check target and swap device(s)
### Determine migration type - can be a normal Ubuntu install
### or a Wubi install (running or from a root.disk)
pre_checks ()
{
    if [ "$(whoami)" != root ]; then
      error "Admin rights are required to run this program."
      exit 1  # exit immediately no cleanup required
    fi

# target device must be a non-empty string and a block device
# make sure the device is not mounted already
    if [ -z "$dev" ] || [ ! -b "$dev" ]; then
        error "target_partition ("$dev") must be a valid partition."
        exit_script 1
    fi

# determine drive of target partition - make sure the user hasn't 
# specified the drive instead of the partition
    disk=${dev%%[0-9]*}
    check_partition_type "$dev" "83"

    if [ $(mount | grep "$dev"'\ ' | wc -l) -ne 0 ]; then
        error ""$dev" is mounted - please unmount and try again"
        exit_script 1
    fi

# precheck separate target partitions for /boot /usr /home
    precheck_other

# swap device must be the correct type
    if [ -n "$swapdev" ] && [ ! -b "$swapdev" ]; then
        error "swapdevice ("$swapdev") is not a block device."
        exit_script 1
    fi
# swap partition type is '82 - Linux swap / Solaris'
# Blkid will report type "swap" or "swsuspend", the latter if
# the swap partition contains a hibernated image.
    if [ -b "$swapdev" ]; then
        check_partition_type "$swapdev" "82"
        if [ "$(blkid -c /dev/null -o value -s TYPE "$swapdev")" = "swsuspend" ]; then
            error ""$swapdev" contains a hibernated image"
            exit_script 1
        fi
    fi
# Option --shared-swap is when you want to share the swap partition that is 
# already in use by another install. So you want to avoid running mkswap as
# this will change the UUID (and you have to update the other install)
# So make sure a) a swap partition has been supplied, and b) that is is valid
    if [ -z "$swapdev" ] && [ "$no_mkswap" = "true" ]; then
        error "Option --shared-swap only valid with a swap partition"
        exit_script 1
    fi

# When using --resume option, also set --shared-swap (mkswap already run)
# Make sure that the target partitions are the same as when the resume
# file was created (with this option we are picking up after rsync errors
# so no formatting of target partitions, checking they are empty, or that
# there is enough space - so it's important that the partitions haven't 
# changed.)
# If the --resume option is not used, remove the old .wubi-move file.
    if [ "$resume_prev" != "true" ]; then
      if [ -f $HOME/.wubi-move ]; then
        mv -f $HOME/.wubi-move $HOME/.wubi-move.last
      fi
    else
      validate_resume_synch "--resume"
    fi

    if [ "$no_mkswap" = "true" ]; then
      if [ $(swapon -s | grep "$swapdev"'\ ' | wc -l) -eq 0 ]; then
        swapon $swapdev > /dev/null 2>&1
        if [ $? -ne 0 ]; then 
            error ""$swapdev" is not an existing swap partition"
            error "Option --shared-swap cannot be used"
            exit_script 1
        else
          swapoff $swapdev > /dev/null 2>&1
        fi
      fi
    fi

# check for partitions mounted on 'unexpected' mountpoints. These aren't
# included in the space check and can cause the migration to run out of space
# during the rsync copy. Mountpoints under /mnt or /media and of course
# /boot, /usr, /home, /root, /tmp and /host are not a problem.
# This check doesn't apply to a root.disk migration
    mtpt=
    if [ -z "$root_disk" ]; then
      while read DEV MTPT FSTYPE OPTS REST; do
        case "$DEV" in
          /dev/sd[a-z][0-9])
            mtpt=$MTPT
            work=$MTPT
            while true; do
                work=${mtpt%/*}
                if [ "$work" == "" ]; then
                    break
                fi
                mtpt=$work
            done
            case $mtpt in
            /mnt|/media|/host|/home|/usr|/boot|/tmp|/root)
                true #ok
                ;;
            *)
                error ""$DEV" is mounted on "$MTPT""
                error "The migration script does not automatically"
                error "exclude this mountpoint."
                error "Please unmount "$MTPT" and try again."
                exit_script 1
                ;;
            esac
          ;;
        esac
      done < /proc/mounts
    fi

# Ubuntu releases prior to 9.10 don't support ext4 (default)
    if ! type mkfs.ext4 > /dev/null 2>&1 ; then
        fs=ext3
    fi

# Check whether we're migrating a Wubi install or normal install.
# The Wubi install can either be running or a root.disk file
    check_wubi
    rc="$?"
    if [ "$rc" -ne "0" ]; then
      wubi_install=false
    fi
    if [ "$rc" -eq "2" ]; then
      error "Unsupported Wubi install (irregular root.disk or mountpoint)"
      exit_script 1
    fi

# create a temp directory to mount the target partition
    mkdir -p $target

# make sure the mountpoint is not in use
    umount $target 2> /dev/null

# check whether connected to internet - required when converting
# a grub-legacy install to grub2.
    ping -c 1 google.com > /dev/null 2>&1
    if [ "$?" -eq 0 ]; then         
        internet_connection=true
    fi

# If this isn't a root.disk install, check
# which version of grub is installed.
# Have to use grub-install.real on Wubi or else you
# can get grub-probe and/or permission errors
    if [ -z "$root_disk" ]; then
      if [ -f "/usr/sbin/grub-install.real" ]; then
        if [ $(grub-install.real --version | grep "0.97" | wc -l) -ne 0 ]; then
            grub_legacy=true
        fi
      elif [ $(grub-install --version | grep "0.97" | wc -l) -ne 0 ]; then
          grub_legacy=true
      fi        
      if [ "$grub_legacy" = "true" ]; then
        if [ "$internet_connection" = "false" ]; then
          error "You need an active internet connection to replace"
          error "Grub legacy with Grub2 on the migrated install"
          exit_script 1
        fi
        info "Grub (legacy) is installed - this will be replaced"
        info "with Grub2 (only on the migrated install)."
        if [ "$no_bootloader" = "true" ]; then
          info "You have selected --no-bootloader with grub-legacy"
          info "You will have to manually modify your current grub"
          info "menu.lst to boot the migrated install."
        else
          info "The Grub2 bootloader will be installed on "$disk""
          install_grub=true
        fi
        # grub legacy wubi is always ext3
        if [ "$wubi_install" = "true" ]; then
          fs=ext3
        fi
        if [ "$assume_yes" = "false" ] ; then
          test_YN "Continue and replace Grub legacy? (Y/N)"
          # User pressed N
          if [ "$?" -eq "1" ]; then
            info "Migration request canceled by user"
            exit_script 1
          fi
        fi
        # for old installs (8.04, 8.10?) there is no grub-common package
        if dpkg -s grub-common > /dev/null 2>&1; then
          grub_common_exists=true
        else
          grub_common_exists=false
        fi
      fi
    fi
}

# validate other target partitions
# Parameters:
#   $1 = "home" | "usr" | "boot"
#   $2 = target partition for /$1
sanitycheck_other ()
{
# create a temp directory to mount the target partition
# make sure the mountpoint is not in use
    mkdir -p $other_mount
    umount $other_mount 2> /dev/null

# attempt to mount, determine size of target partition
# check size of directory under current install ($root is either /
# or the path that a root.disk is mounted under)
    info "Checking target partition for /"$1""
     if mount -t auto "$2" $other_mount 2> /dev/null; then
       if [ "$resume_prev" != "true" ]; then # skip check if --resume or --synch
        if [ $(ls -1 $other_mount | wc -l) -ne 0 ] ; then
          if [ $(ls -1 $other_mount | wc -l) -gt 1 ] || \
             [ "$(ls $other_mount)" != "lost+found" ]; then
            error "Partition $2 is not empty. Cancelling"
            if [ "$debug" = "true" ]; then
                test_YN "DEBUG mode: do you want to continue anyway?"
                if [ $? -ne 0 ]; then
                    exit_script 1
                fi
            else
               exit_script 1
            fi
          fi
        fi
      fi
      targ_size=$(df $2 | tail -n 1 | awk '{print $2}')
      curr_size=$(du -s "$root"$1 2> /dev/null | cut -f 1)
      debug "Current size of /$1 is $curr_size"
      debug "Size of target for /$1 ($2) is $targ_size"
      # just in case of an error, the size might be zero
      if [ $curr_size = "" ] || [ $curr_size -eq 0 ]; then
        error "Error determining size of /$1. Cancelling"
        exit_script 1
      fi
      if [ $targ_size = "" ] || [ $targ_size -eq 0 ]; then
        error "Error determining size of $2. Cancelling"
        exit_script 1
      fi
      if [ "$1" == "boot" ]; then
        temp_size=`echo "$curr_size + $boot_space_buffer" | bc` 
      else
        temp_size=`echo "$curr_size + $space_buffer" | bc` 
      fi
      if [ $targ_size -lt $temp_size ]; then
        error "Target partition for /$1 is not big enough"
        error "The current install /$1 is $curr_size K"
        error "The target partition "$2" is $targ_size K"
        error "The minimum allowed is "$temp_size" K"
        error "Cancelling"
        exit_script 1 
      fi
      root_size=`echo "$root_size - $curr_size" | bc`
      debug "Remaining size of / reduced to: $root_size"
      umount $other_mount
    else
        error "Partition $2 could not be mounted for validation."
        error "Make sure it is a valid ext2/3/4 partition and try again"
        exit_script 1
    fi
}

### Validate target device and swap device
### Check size is sufficient
### Check options against type of install
sanity_checks ()
{
# try and mount target partition, and ensure that it is empty
# (note freshly formatted ext2/3/4 contain a single 'lost and found'
# and freshly formatted ntfs contains a "System Volume Information")
# Checks are performed prior to formatting if possible, however,
# if the mount fails, it could be unformatted in which case we
# have to format first
    echo ""
    if mount -t auto "$dev" $target 2> /dev/null; then
# User wants to resynch a previous migrated install (useful for maintaining
# a bootable backup on an external drive)
# resuming and synching are similar - no format of target partitions
# a valid synch file must exist on target with exact matching partition UUID(s)
        if [ "$resynch_prev" = "true" ]; then
          resume_prev=true
          validate_resume_synch "--synch"
        fi

# If --resume or --synch it's expected that the target partition(s) are not
# empty - otherwise, they have to be empty.
        if [ "$resume_prev" != "true" ]; then # skip check if --resume or --synch
         if [ $(ls -1 $target | wc -l) -ne 0 ] ; then
          if [ $(ls -1 $target | wc -l) -gt 1 ] || \
             [ "$(ls $target)" != "lost+found" ]; then
            error "Partition $dev is not empty. Cancelling"
            if [ "$debug" = "true" ]; then
                test_YN "DEBUG mode: do you want to continue anyway?"
                if [ $? -ne 0 ]; then
                    exit_script 1
                fi
            else
               exit_script 1
            fi
          fi
         fi
        fi
    else
        info "Partition $dev could not be mounted for validation."
        info "This is normal if the partition is unformatted or the file"
        info "system is corrupted. It could also mean you have entered"
        info "the wrong partition. The partition will have to be formatted"
        info "in order to complete validation."
        info "PLEASE MAKE SURE YOU HAVE SELECTED THE CORRECT PARTITION."
        # have to interrupt if the user has select --assume-yes, otherwise the
        # format_partition function will ask to continue.
        if [ "$check_only" = "true" ]; then
          exit_script 1
        fi
        if [ "$assume_yes" = "true" ]; then
          test_YN "Continue? (Y/N)"
          # User pressed N
          if [ "$?" -eq "1" ]; then
            info "Migration request canceled by user"
            exit_script 1
          fi
        fi
        format_partition
        mount $dev $target
    fi

# Determine the install size to be migrated and the total size of the target
# Install size sums the 3rd column (Used space) on the /, /home and /usr partitions
# Total size takes the 2nd column on the target partition.
# For root.disk migrations we already know the size and the release is 9.10 or greater
# so just get the target size and don't bother checking for zero based index in awk
    target_size=$(df $target|tail -n 1|awk '{print $2}')
    if [ -z "$root_disk" ]; then
        install_size=$(df | awk '$6=="/" || $6=="/home" || $6=="/usr"|| $6=="/boot" {sum += $3} END {print sum}')
        if [ "$install_size" = "" ]; then # 8.04 - awk used zero based column index
          debug "zero-based column index version of awk e.g. on release 8.04"
          install_size=$(df | awk '$5=="/" || $5=="/home" || $5=="/usr" || $5=="/boot" {sum += $2} END {print sum}')
          target_size=$(df $target|tail -n 1|awk '{print $1}')
        fi
    fi
    debug "Target root partition size (in K):" $target_size
    debug "Current total install size (in K):" $install_size

# just in case of an error, the size might be zero
    if [ $install_size = "" ] || [ $install_size -eq 0 ]; then
        error "Error determining size of install. Cancelling"
        exit_script 1
    fi

    # if migrating to multiple partitions, validate each target (other than root)
    # and reduce the root_size for the main target size check
    root_size=$install_size
    if [ -n "$homedev" ]; then
      sanitycheck_other home $homedev
    fi
    if [ -n "$usrdev" ]; then
      sanitycheck_other usr $usrdev
    fi
    if [ -n "$bootdev" ]; then
      sanitycheck_other boot $bootdev
    fi
    
# Ensure the target partition is large enough 
# There must be some free space ($space_buffer)
    info "Checking target partition for / (root)"
    temp_size=`echo "$root_size + $space_buffer" | bc` 
    if [ $target_size -lt $temp_size ]; then
        error "Target partition ($dev) is not big enough"
        error "Size of data to migrate is $root_size K"
        error "Total space on target is $target_size K"
        error "There must be at least $space_buffer K free space"
        error "Cancelling"
        exit_script 1
    fi
    debug "Size of data to migrate to / is "$root_size""
    umount $target
}

### get all user interaction out of the way so that the 
### migration can proceed unattended
final_questions ()
{
    if [ "$check_only" = "true" ]; then
      info "Option --check-only: All tests succeeded"
      exit_script 0
    fi
    if [ "$resume_prev" = "true" ]; then
      info "The previous migration attempt to "$dev""
      if [ "$resynch_prev" = "true" ]; then
        info "will be resynchronized."
        info "CAUTION: files that have been deleted on the"
        info "current install will also be deleted on the"
        info "target. This includes files that were added"
        info "only to the target."
      else
        info "will be resumed."
      fi
      if [ "$no_bootloader" = "true" ] ; then
        test_YN "Continue without installing the bootloader? (Y/N)"
      else
        install_grub=true
        test_YN "Continue and install Grub2 to "$disk?" (Y/N)"
      fi
      # User pressed N
      if [ "$?" -eq "1" ]; then
        info "User canceled resume attempt."
        exit_script 1 
      fi
      return 0
    fi

    # Already notified grub-legacy users about grub2 upgrade
    if [ "$grub_legacy" = "true" ] ; then
       return 0
    fi
    # No opt out for --root-disk= option, but user can cancel migration
    if [ ! -z "$root_disk" ] ; then
      info "The Grub2 bootloader will be installed to "$disk"."
      info "This is required when a migration is performed"
      info "from a named root.disk file."
      test_YN "Continue and install Grub2 to "$disk?" (Y/N)"
      # User pressed N
      if [ "$?" -eq "1" ]; then
        info "User canceled migration."
        exit_script 1 
      fi
      return 0
    fi
    if [ "$no_bootloader" = "true" ] ; then
       return 0
    fi
    if [ "$assume_yes" = "true" ] ; then
       install_grub=true
       return 0
    fi

    echo ""        
    info "Would you like the grub2 bootloader to be installed"
    info "to drive "$disk"? If you choose not to, you will"
    info "still be able to boot your migrated install from"
    info "your current install."
    test_YN "Install grub bootloader to "$disk?" (Y/N)"
    # User pressed Y
    if [ "$?" -eq "0" ]; then
      install_grub=true 
    fi
}

# Format separate partitions if required
# separate later
format_other ()
{
    for i in "$homedev" "$bootdev" "$usrdev"; do
      if [ -n "$i" ]; then
        info "Formatting "$i" with "$fs" file system"
        mkfs."$fs" "$i" > /dev/null 2> /tmp/wubi-move-error
        if [ "$?" != 0 ]; then
          error "Formatting "$i" failed or was canceled"
          error "Error is: $(cat /tmp/wubi-move-error)"
          exit_script 1
        fi
      fi
    done
}

# Format the target partition file system
# Message to close open programs to prevent partial updates
# being copied as is.
format_partition ()
{
    if [ "$resume_prev" = "true" ]; then
      return 0
    fi

    if [ "$formatted_dev" != true ] ; then
      formatted_dev="true"
      if [ "$assume_yes" != true ] ; then
        info "Please close all open files before continuing."
        info "About to format the target partition ($dev)."
        test_YN "Proceed with format (Y/N)"
        # User pressed N
        if [ "$?" -eq "1" ]; then
          info "Migration request canceled by user"
          exit_script 1
        fi
      fi    
      info "Formatting $dev with "$fs" file system"
      mkfs."$fs" $dev > /dev/null 2> /tmp/wubi-move-error
      if [ "$?" != 0 ]; then
        error "Formatting "$dev" failed or was canceled"
        error "Error is: $(cat /tmp/wubi-move-error)"
        exit_script 1
      fi
      format_other
    fi
# garbage collection to refresh cache
    blkid -g
}

# Mount separate partitions if required - this is a hack to get it working
# separate later
mount_other ()
{
    if [ -n "$homedev" ]; then
        mkdir -p "$target"/home
        mount $homedev "$target"/home
        if [ "$?" != 0 ]; then
            error ""$homedev" failed to mount for /home"
            error "Migration request canceled"
            exit_script 1
        fi
    fi
    if [ -n "$bootdev" ]; then
        mkdir -p "$target"/boot
        mount $bootdev "$target"/boot
        if [ "$?" != 0 ]; then
            error ""$bootdev" failed to mount for /boot"
            error "Migration request canceled"
            exit_script 1
        fi
    fi
    if [ -n "$usrdev" ]; then
        mkdir -p "$target"/usr
        mount $usrdev "$target"/usr
        if [ "$?" != 0 ]; then
            error ""$usrdev" failed to mount for /usr"
            error "Migration request canceled"
            exit_script 1
        fi
    fi
}

# Target partition UUID's are saved in the resume file
# This can be used to resume a migration that fails with
# an rsync error e.g. file corruption. Once the issue is
# corrected you can resume (without reformatting and starting
# from scratch) - so it's important to ensure that the 
# partitions have not been changed in the interim.
create_resumefile ()
{
      tRoot=$(blkid -c /dev/null -o value -s UUID $dev)
      if [ -n "$swapdev" ]; then
        tSwap=$(blkid -c /dev/null -o value -s UUID $swapdev)
      else
        tSwap="none"
      fi
      if [ -n "$bootdev" ]; then
        tBoot=$(blkid -c /dev/null -o value -s UUID $bootdev)
      else
        tBoot="none"
      fi
      if [ -n "$usrdev" ]; then
        tUsr=$(blkid -c /dev/null -o value -s UUID $usrdev)
      else
        tUsr="none"
      fi
      if [ -n "$homedev" ]; then
        tHome=$(blkid -c /dev/null -o value -s UUID $homedev)
      else
        tHome="none"
      fi
      echo "$tRoot $tSwap $tBoot $tUsr $tHome" > "$HOME"/.wubi-move
}

# Copy entire install to target partition
# Monitor return code from rsync in case user hits CTRL-C.
## Make fake /host directory to allow override of /host mount 
# and prevent update-grub errors in chroot
# Disable 10_lupin script
migrate_files ()
{
    create_resumefile
    mount $dev $target # should't fail ever - freshly formatted
    if [ "$?" != 0 ]; then
        error ""$dev" failed to mount"
        error "Migration request canceled"
        exit_script 1
    fi
    mount_other
    echo ""
    info "Copying files - please be patient - this takes some time"
    rsync -a --delete --exclude="$root"host --exclude="$root"mnt/* --exclude="$root"home/*/.gvfs --exclude="$root"var/lib/lightdm/.gvfs --exclude="$root"media/*/* --exclude="$root"tmp/* --exclude="$root"proc/* --exclude="$root"sys/* $root $target # let errors show
    if [ "$?" -ne 0 ]; then
        echo ""
        error "Copying files failed. If the failure is due"
        error "to file corruption, correct the problem and"
        error "rerun with the --resume option."
        error "Unmounting target..."
        sleep 3
        exit_script 1
    fi
    # When migrating from a live CD, the .wubi-move hasn't been copied
    # For a normal migration it's already copied. This supports the --synch option
    cp -n "$HOME"/.wubi-move "$target""$HOME"/.wubi-move
    if [ "$wubi_install" = "true" ]; then
      chmod -x $target/etc/grub.d/10_lupin > /dev/null 2>&1
    fi    
} 

### Run mkswap on swap partition and enable hibernation 
### Note: swap must be at least as big as RAM for hibernation
### It's possible to bypass mkswap if you would like to share
### an existing swap partition from another install
create_swap ()
{
    if [ -b "$swapdev" ]; then
        if [ "$no_mkswap" = "false" ]; then
          info "Creating swap..."
          mkswap $swapdev > /dev/null
          if [ "$?" != 0 ]; then
            warn "Command mkswap on "$swapdev" failed"
            warn "Migration will continue without swap"
            swapdev=
          fi
        fi
    fi
    if [ -b "$swapdev" ]; then
        echo "RESUME=UUID=$(blkid -c /dev/null -o value -s UUID $swapdev)" > $target/etc/initramfs-tools/conf.d/resume
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
# blank out line starting with ' /host ' mounted (some wubi users do this)
    sed -i 's:.*[ \t]/host[ \t].*::' $target/etc/fstab

# for non-wubi blank out line mounting root or swap (and comments "root was..." / "swap was")
    if [ "$wubi_install" = "false" ]; then
      sed -i 's:.*[ \t]/[ \t].*::' $target/etc/fstab
      sed -i 's:#.*[ \t]root[ \t].*::' $target/etc/fstab
      sed -i 's:.*[ \t]swap[ \t].*::' $target/etc/fstab
    fi

# the migration can 'merge' installs with separated /home, /boot, /usr
# or separate installs with a single / (root) partition. Either way,
# remove the separate source mounts and then add back according to the 
# target requirements.
    if [ "$wubi_install" = "true" ]; then
      sed -i 's:/.*home[\.]disk .*::' $target/etc/fstab
      sed -i 's:/.*usr[\.]disk .*::' $target/etc/fstab
      sed -i 's:/.*boot[\.]disk .*::' $target/etc/fstab
    else
      sed -i 's:.*[ \t]/home[ \t].*::' $target/etc/fstab
      sed -i 's:.*[ \t]/usr[ \t].*::' $target/etc/fstab
      sed -i 's:.*[ \t]/boot[ \t].*::' $target/etc/fstab
    fi

# add line to mount $dev as new root (based on UUID)
    echo "# root was on "$dev" when migrated" >> $target/etc/fstab    
    echo "UUID=$(blkid -c /dev/null -o value -s UUID "$dev")    /    "$fs"    errors=remount-ro    0    1" >> $target/etc/fstab
# add line to mount swapdev based on uuid if passed
    if [ -b "$swapdev" ]; then
        echo "# swap was on "$swapdev" when migrated" >> $target/etc/fstab
        echo "UUID=$(blkid -c /dev/null -o value -s UUID $swapdev)    none    swap    sw    0    0" >> $target/etc/fstab
    fi
    if [ -b "$homedev" ]; then
        echo "# /home was on "$homedev" when migrated" >> $target/etc/fstab
        echo "UUID=$(blkid -c /dev/null -o value -s UUID $homedev)    /home    "$fs"    errors=remount-ro    0    2" >> $target/etc/fstab
    fi
    if [ -b "$bootdev" ]; then
        echo "# /boot was on "$bootdev" when migrated" >> $target/etc/fstab
        echo "UUID=$(blkid -c /dev/null -o value -s UUID $bootdev)    /boot    "$fs"    errors=remount-ro    0    2" >> $target/etc/fstab
    fi
    if [ -b "$usrdev" ]; then
        echo "# /usr was on "$usrdev" when migrated" >> $target/etc/fstab
        echo "UUID=$(blkid -c /dev/null -o value -s UUID $usrdev)    /usr    "$fs"    errors=remount-ro    0    2" >> $target/etc/fstab
    fi
}

# Start chroot to target install
## (mount empty /host to prevent update-grub errors for Wubi)
start_chroot ()
{
    echo ""
    info "Starting chroot to the target install."
# Note: for internet connection on chroot, the /etc/resolv.conf
# is already copied - unless migrating from
# root.disk - but this only supports grub2 right now so 
# not required to connect to net
#    cp /etc/resolv.conf $target/etc/resolv.conf
    for i in dev proc sys dev/pts; do
        mount --bind /$i $target/$i;
    done
#    if [ "$wubi_install" = "true" ] && [ -z "$root_disk" ]; then
#      mount --bind /host $target/host
#    fi
}

# Exit chroot from target install
end_chroot ()
{
    info "Exiting from chroot on target install..."
#    if [ "$wubi_install" = "true" ] && [ -z "$root_disk" ]; then
#        umount $target/host
#    fi
    for i in dev/pts dev proc sys; do 
        umount $target/$i;
    done 
}

# Run command in chroot on target install - suppress output
# Check return code - if an error is encountered try to 
# exit the chroot in an orderly fashion before terminating.
# Allow command suppression unless in debug mode, or if 
# requested - e.g. to allow user interaction in chroot 
target_cmd ()
{
    if  [ "$debug" = "true" ] || [ "$suppress_chroot_output" = "false" ]; then
        chroot $target $*
    else
        chroot $target $* > /dev/null 2> /tmp/wubi-move-error
    fi
    if [ $? -ne 0 ]; then
        error "An error occurred within chroot"
        error "Error is: $(cat /tmp/wubi-move-error)"        
        error "Attempting to exit chroot normally..."
        end_chroot
        exit_script 1
    fi
}

# Prevent upstart jobs running in the chroot
bypass_upstart()
{
    target_cmd dpkg-divert --local --rename --add /sbin/initctl
    target_cmd ln -s /bin/true /sbin/initctl
}

# remove Upstart bypass
remove_upstart_bypass()
{
    target_cmd rm /sbin/initctl
    target_cmd dpkg-divert --local --rename --remove /sbin/initctl
}

### remove lupin support and update the target install grub menu
### if no lupin, then rebuild initrd image to permit hibernation
### (done automatically when lupin removed)
chroot_cmds ()
{
    if [ "$wubi_install" = "true" ]; then
      info "Removing lupin-support on target..."
      target_cmd apt-get -y remove lupin-support
    else 
      target_cmd update-initramfs -u
    fi
}

### replace grub legacy with grub2
### if version 10.04 or greater, grub-pc should prompt 
### where to install and run update-grub
grub_legacy()
{
    info "Removing Grub Legacy on target..."
    if [ "$grub_common_exists" = "true" ]; then
      target_cmd apt-get -y purge grub grub-common
    else
      target_cmd apt-get -y purge grub
    fi
    target_cmd mv /boot/grub /boot/grubold
    info "Installing Grub2 on target..."
    info "Transferring control to grub2 install process:"
    sleep 5
# installing grub-pc in release 9.10 and greater requires user interaction
# so don't suppress chroot output 
    suppress_chroot_output=false
    if [ "$grub_common_exists" = "true" ]; then
      target_cmd apt-get -y install grub-pc grub-common
    else
      target_cmd apt-get -y install grub-pc
    fi
    suppress_chroot_output=true
# For 9.10 and later, installing grub-pc will already have prompted
# the user where to install the grub2 bootloader, and run update-grub.
# But as a safeguard - do it anyway (if requested)
    echo ""
    echo ""
    sleep 2
    if [ "$install_grub" = "true" ]; then
        target_cmd grub-install $disk
        info "Grub bootloader installed to $disk"
    fi
    info "Updating the target grub menu"
    target_cmd update-grub

}

# Check whether there is a need to install the grub2 bootloader on the 
# target drive MBR. Divert to separate grub legacy code as appropriate.
# Reasons for not installing are e.g.
# you are installing to /dev/sdbY, but you boot from # /dev/sda. In this 
# case you should manually replace the bootloader after booting it.
# You will also be able to boot it from the menu of your current install
# This code sets or resets the grub install device on the target so that
# grub knows where to update itself later (or not to). These commands are
# run direct to the chroot to avoid error handling logic (grub2 changes a lot
# and these aren't relevant on earlier installs, 1.96 for instance). 
grub_bootloader ()
{
    if  [ "$grub_legacy" = "true" ]; then
      grub_legacy
    else
      if [ "$install_grub" = "true" ]; then
        target_cmd grub-install $disk
        info "Grub bootloader installed to $disk"
        echo SET grub-pc/install_devices $disk | chroot $target debconf-communicate > /dev/null 2>&1
      else
        echo RESET grub-pc/install_devices | chroot $target debconf-communicate > /dev/null 2>&1
      fi
      info "Updating the target grub menu..."
      target_cmd update-grub
    fi
}

# Update the local install grub menu to add the new install
# (If you haven't installed the grub2 bootloader then this is
# the only way to boot the migrated install. For Wubi this 
# leaves the windows bootloader in control)
# Migrating from a root.disk will bypass this step
# From a grub legacy install this is left to the user to do manually
update_grub ()
{
    if [ -z "$root_disk" ] && [ "$grub_legacy" = "false" ]; then
        echo ""
        info "Updating current grub menu to add new install..."
        sleep 1
        update-grub
    fi
}

#######################
### Main processing ###
#######################
debug "Parameters passed: "$@""
pre_checks
sanity_checks
final_questions
format_partition
migrate_files
create_swap
edit_fstab
start_chroot
bypass_upstart
chroot_cmds
grub_bootloader
remove_upstart_bypass
end_chroot
cleanup_for_exit
update_grub
final_exit 0
