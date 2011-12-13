#!/bin/bash
#
### Variable declaration ###
#
# Options 
root_disk=                  # path and name of root.disk file 
debug=false                 # Output debug information
rootdiskpath=               # path to root.disk file
edit_fail=false             # set to true if edit checks failed

root_mount=/tmp/wubi-move/rootdisk  # root.disk source mountpoint

# Bools 
grub_legacy=false           # Is grub legacy installed?
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
Usage: sudo bash $0 [option]
       e.g. sudo bash $0
            sudo bash $0 --root-disk=<path to root disk>

Check the current install or the loop install based on the named root.disk
EOF
} 
### Check the options and parameters
for option in "$@"; do
    case "$option" in
    -h | --help)
    usage
    exit 0 ;;
    --root-disk=*)
    root_disk=`echo "$option" | sed 's/--root-disk=//'` ;;
### undocumented debug option
    -d | --debug)
    set -x
    debug=true
    ;;
    -*)
    echo "$0: Unrecognized option '$option'" 1>&2
    exit 1
    ;;
    *)
    echo "$0: Unrecognized parameter '$option'" 1>&2
    exit 1
    ;;
    esac
done

# thanks os-prober
log() {
  logger -t "$0" -- "$@"
}

error() {
  log "error: " "$@"
  echo "$0: " "$@" 1>&2
  edit_fail=true
}

debug() {
  log "debug: " "$@"
}

### Final exit script
### All cleanup has been done - output the result based on
### the parameter (provided --check-only not used):
###    0 = successful execution
###    1 = exception
final_exit ()
{
    if [ $1 -eq 0 ]; then
      echo $install_type $grub_type $host_or_root $install_size $home_size $usr_size $boot_size
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
      fi
      if [ $(mount | grep "$root_mount"/usr'\ ' | wc -l) -ne 0 ]; then
        umount "$root_mount"/usr > /dev/null 2>&1
        sleep 3 
      fi
      if [ $(mount | grep "$root_mount"'\ ' | wc -l) -ne 0 ]; then
        umount "$root_mount" > /dev/null 2>&1
        sleep 3 
      fi
      [ -d "$root_mount" ] && rmdir "$root_mount" > /dev/null 2>&1
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
### Returns 0: Wubi, 1: Normal, 2: some other loop install (mint4win?)
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

# Identify migration source and validate
# Can be a wubi install, a standalone root.disk (and other virtual disks),
# a normal ubuntu install - also check whether the install has grub-legacy
# installed.
check_migration_source ()
{
# Check whether we're migrating a Wubi install or normal install.
# The Wubi install can either be running or a root.disk file
    check_wubi
    rc="$?"
    if [ "$rc" -eq "0" ]; then
      debug "Wubi-install migration"
      install_type="Wubi"
    elif [ "$rc" -eq "1" ]; then
      install_type="Normal"
      debug "Normal (non-Wubi) install migration"
    elif [ "$rc" -eq "2" ]; then
      error "Unsupported Wubi install (irregular root.disk or mountpoint)"
      exit_script 1
    fi

# If this isn't a root.disk install, check
# which version of grub is installed.
# Have to use grub-install.real on Wubi or else you
# can get grub-probe and/or permission errors
    grub_type="Grub2"
    if [ -z "$root_disk" ]; then
      if [ -f "/usr/sbin/grub-install.real" ]; then
        if [ $(grub-install.real --version | grep "0.97" | wc -l) -ne 0 ]; then
          grub_type="Grub-legacy"
        fi
      elif [ $(grub-install --version | grep "0.97" | wc -l) -ne 0 ]; then
          grub_type="Grub-legacy"
      fi
    fi
    debug ""$grub_type" detected on migration source"
}

# Check size
check_dir_size ()
{
      curr_size=$(du -s "$root"$1 2> /dev/null | cut -f 1)
      debug "Current size of /$1 is $curr_size"
      # just in case of an error, the size might be zero
      if [ $curr_size = "" ] || [ $curr_size -eq 0 ]; then
        error "Error determining size of /$1. Cancelling"
        exit_script 1
      fi
}

### Validate target device and swap device
### Check size is sufficient
### Check options against type of install
check_size ()
{
# Determine the install size to be migrated and the total size of the target
# Install size sums the 3rd column (Used space) on the /, /home and /usr partitions
# Total size takes the 2nd column on the target partition.
# For root.disk migrations we already know the size and the release is 9.10 or greater
# so just get the target size and don't bother checking for zero based index in awk
    if [ -z "$root_disk" ]; then
        install_size=$(df | awk '$6=="/" || $6=="/home" || $6=="/usr"|| $6=="/boot" {sum += $3} END {print sum}')
        if [ "$install_size" = "" ]; then # 8.04 - awk used zero based column index
          debug "zero-based column index version of awk e.g. on release 8.04"
          install_size=$(df | awk '$5=="/" || $5=="/home" || $5=="/usr" || $5=="/boot" {sum += $2} END {print sum}')
        fi
    fi
    debug "Current total install size (in K):" $install_size

# just in case of an error, the size might be zero
    if [ $install_size = "" ] || [ $install_size -eq 0 ]; then
        error "Error determining size of install. Cancelling"
        exit_script 1
    fi

    # if migrating to multiple partitions, validate each target (other than root)
    # and reduce the root_size for the main target size check
    root_size=$install_size
    check_dir_size home $homedev
    home_size=$curr_size
    check_dir_size usr $usrdev 
    usr_size=$curr_size
    check_dir_size boot $bootdev
    boot_size=$curr_size
    
    debug "Size of data to migrate to / is "$root_size""

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
            /)
                debug "Normal install root (/) mounted on "$DEV""
                host_or_root="$DEV"
                ;;
            /host)
                debug "Wubi host partition is "$DEV""
                host_or_root="$DEV"
                ;;
            /mnt|/media|/home|/usr|/boot|/tmp|/root)
                true #ok
                ;;
            *)
                error ""$DEV" is mounted on "$MTPT""
                error "The migration script does not automatically"
                error "exclude this mountpoint."
                error "Please unmount "$MTPT" and try again."
                ;;
            esac
          ;;
        esac
      done < /proc/mounts
    fi
}

#######################
### Main processing ###
#######################
debug "Parameters passed: "$@""
if [ "$(whoami)" != root ]; then
  error "Admin rights are required to run this program."
  exit 1
fi
check_migration_source
check_size
final_exit 0
