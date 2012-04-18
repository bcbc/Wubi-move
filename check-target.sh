#!/bin/bash
#
### Variable declaration ###
#
empty=false
debug=false                 # Output debug information
dev=                        # target device for migration
swapdev=                    # swap device for migration
homedev=                    # /home device for migration
bootdev=                    # /boot device for migration
usrdev=                     # /usr device for migration
edit_fail=false             # set to true if edit checks failed
check_target_dir=           # /tmp/check-target directory
other_mount=                # target device mountpoint (/tmp/check-target/other)
rc=                         # Preserve return code
root_size=                  # size of target partition
boot_size=                  # size of target partition
home_size=                  # size of target partition
usr_size=                   # size of target partition
target_size=                # working variable
self="`basename $0`"

usage () 
{
    cat <<EOF
Usage: sudo bash $self [OPTION] target_partition [swap_partition]
       e.g. sudo bash $self /dev/sda5 /dev/sda6

Check the target partitiion
Migrate an ubuntu install (wubi or normal) to partition
  -h, --help              print this message and exit
  --root=</dev/sdXY>      Target partition for /
  --swap=</dev/sdXY>      Partition for swap
  --boot=</dev/sdXY>      Partition for /boot
  --home=</dev/sdXY>      Partition for /home
  --usr=</dev/sdXY>       Partition for /usr
EOF
} 

### Check the options and parameters
for option in "$@"; do
    case "$option" in
    -h | --help)
    usage
    exit 0 ;;
    --root=*)
    dev=`echo "$option" | sed 's/--root=//'` ;;
    --swap=*)
    swapdev=`echo "$option" | sed 's/--swap=//'` ;;
    --home=*)
    homedev=`echo "$option" | sed 's/--home=//'` ;;
    --boot=*)
    bootdev=`echo "$option" | sed 's/--boot=//'` ;;
    --usr=*)
    usrdev=`echo "$option" | sed 's/--usr=//'` ;;
### undocumented debug option
    -d | --debug)
    set -x
    debug=true
    ;;
    -*)
    echo "$self: Unrecognized option '$option'" 1>&2
    exit 1
    ;;
    *)
    echo "$self: Unrecognized parameter '$option'" 1>&2
    exit 1
    ;;
    esac
done

# thanks os-prober
log() {
  logger -t "$self" -- "$@"
}

error() {
  log "error: " "$@"
  echo "$self: " "$@" 1>&2
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
      echo $root_size $home_size $usr_size $boot_size $empty
    fi
    exit $1
}

### Unmount and remove mountpoint used
cleanup_for_exit ()
{
# all mount checks with grep add a space to differentiate e.g. /dev/sda1 from /dev/sda11
# Not really necessary for these custom mountpoints but do it anyway.
# Depending on when the exception is encountered there may be nothing to cleanup
# other mountpoint - for checking multi-partition migrations
    if [ $(mount | grep "$other_mount"'\ ' | wc -l) -ne 0 ]; then
      umount $other_mount > /dev/null 2>&1
      sleep 2
    fi
    if [ -d "$other_mount" ]; then
      rmdir "$other_mount" > /dev/null 2>&1 
    fi
    rmdir "$check_target_dir" > /dev/null 2>&1
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
        error "partition "$1" is a drive, not a partition."
    elif [ $(fdisk -l "$partition_disk" 2> /dev/null | grep -i "GPT" | grep "[ \t]ee[ \t]" | wc -l) -ne 0 ]; then
    # bypass GPT disks - doesn't apply
        true
    elif [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]5[ \t]" | grep -i "Extended" | wc -l) -eq 1 ]; then
        error "partition "$1" is an Extended partition."
    elif [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]f[ \t]" | grep -i "W95 Ext'd (LBA)" | wc -l) -eq 1 ]; then
        error "partition "$1" is an Extended partition."
    elif [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]85[ \t]" | grep -i "Linux extended" | wc -l) -eq 1 ]; then
        error "partition "$1" is an Extended partition."
    elif [ "$2" == "83" ]; then
      if [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]"$2"[ \t]" | grep -i "Linux" | wc -l) -eq 0 ]; then
        error "partition "$1" must be type "$2" - Linux."
      fi
    else
      if [ $(fdisk -l "$partition_disk" | grep "$1[ \t]" | grep "[ \t]"$2"[ \t]" | grep -i "Linux swap" | wc -l) -eq 0 ]; then
        error "partition "$1" must be type "$2" - Linux swap."
      fi
    fi
}


### Early checks - must be admin, check target and swap device(s)
### For resume option confirm the targets are the same
### Also check for mounted partitions that aren't excluded by the script
check_targets ()
{
    for i in "$dev" "$homedev" "$bootdev" "$usrdev"; do
      if [ -n "$i" ]; then
        if [ $(mount | grep "$i"'\ ' | wc -l) -ne 0 ]; then
          error ""$i" is mounted - please unmount and try again"
        fi
        if [ ! -b "$i" ]; then
          error ""$i" is not a valid partition."
        fi
        check_partition_type $i "83"
      fi
    done

# if swap device present must be a block device
    if [ -n "$swapdev" ]; then
      if [ ! -b "$swapdev" ]; then
        error "swapdevice ("$swapdev") is not a valid partition."
      else
# swap partition type is '82 - Linux swap / Solaris'
# Blkid will report type "swap" or "swsuspend", the latter if
# the swap partition contains a hibernated image.
        check_partition_type "$swapdev" "82"
        if [ "$(blkid -c /dev/null -o value -s TYPE "$swapdev")" = "swsuspend" ]; then
          error ""$swapdev" contains a hibernated image"
        fi
      fi
    fi
}


# validate other target partitions
# Parameters:
#   $1 = "home" | "usr" | "boot"
#   $2 = target partition for /$1
check_partition ()
{
# create a temp directory to mount the target partition
# make sure the mountpoint is not in use
    if [ "$1" == "/" ]; then
        dir=""
    else
        dir="$1"
    fi
    mkdir -p $other_mount
    umount $other_mount 2> /dev/null

# attempt to mount, determine size of target partition
# check size of directory under current install ($root is either /
# or the path that a root.disk is mounted under)
    debug "Checking target partition for /"$dir""
    if mount -t auto --read-only "$2" $other_mount 2> /dev/null; then
      if [ $(ls -1 $other_mount | wc -l) -ne 0 ] ; then
        if [ $(ls -1 $other_mount | wc -l) -gt 1 ] || \
           [ "$(ls $other_mount)" != "lost+found" ]; then
           empty=false
        fi
      fi
      target_size=$(df $2 | tail -n 1 | awk '{print $2}')
      debug "Size of target for /$dir ($2) is $target_size"
      sleep 1
      umount $other_mount
    else
        error "Partition $2 could not be mounted for validation."
        error "Make sure it is a valid ext2/3/4 partition and try again"
    fi
}

### Check size and whether targets are empty
check_size ()
{
    empty=true
    check_partition "/" $dev
    root_size=$target_size
    home_size=0
    if [ -n "$homedev" ]; then
      check_partition home $homedev
      home_size=$target_size
    fi
    usr_size=0
    if [ -n "$usrdev" ]; then
      check_partition usr $usrdev
      usr_size=$target_size
    fi
    boot_size=0
    if [ -n "$bootdev" ]; then
      check_partition boot $bootdev
      boot_size=$target_size
    fi
}


#######################
### Main processing ###
#######################
debug "Parameters passed: "$@""
if [ "$(whoami)" != root ]; then
  error "Admin rights are required to run this program."
  exit_script 1
fi
check_target_dir=`mktemp -d /tmp/check-targetXXX`
other_mount="$check_target_dir"/other
check_targets
if [ "$edit_fail" == true ]; then
  exit_script 1
fi
check_size
if [ "$edit_fail" == true ]; then
  exit_script 1
fi
exit_script 0

