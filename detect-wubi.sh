#!/bin/bash
#
### Variable declaration ###
#
# Options 
debug=false                 # Output debug information
host_mount=/tmp/wubi-move/hostmount
target_partitions=          # list of windows partitions to check
wubi_partition=             # set if Wubi install found (/ubuntu/disks/root.disk)

usage () 
{
    cat <<EOF
Usage: sudo bash $0 [option]
       e.g. sudo bash $0

Look for Wubi install by locating the root.disk. This should be run
from a live environment (or normal Ubuntu install), not a Wubi install.
EOF
} 
### Check the options and parameters
for option in "$@"; do
    case "$option" in
    -h | --help)
    usage
    exit 0 ;;
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
  edit_fail=true
  if [ "$0" == "detect-wubi.sh" ]; then
    echo "$0: " "$@" 1>&2
  fi
}

debug() {
  log "debug: " "$@"
}


# List ext2/34 partitions
detect_wubi ()
{
   debug "Retrieving list of possible Wubi host partitions"
   partition_list=`. select-partitions.sh --windows`
   if [ $? -ne 0 ]; then
      debug "Failed to retrieve partition list"
      exit 1
   fi
   
   debug "List of possible windows host partitions: "$partition_list""
   set partition_list
   for partition in $partition_list; do
    debug "Checking "$partition" for Wubi install"
    mkdir -p "$host_mount"
    if mount -t auto --read-only "$partition" "$host_mount" 2> /tmp/wubi-move-error; then
      if [ -f "$host_mount"/ubuntu/disks/root.disk ]; then
        debug "Wubi found on "$partition"/ubuntu/disks/root.disk"
        wubi_partition="$partition"
        sleep 3 # 11.10 auto pops nautilus upon mounts unless switched off
        umount "$host_mount"
        break
      fi
      sleep 3
      umount "$host_mount"
    else
        error "Partition "$partition" could not be mounted. $(cat /tmp/wubi-move-error)"
    fi
   done
   sleep 3
   if [ $(mount | grep "$host_mount"'\ ' | wc -l) -ne 0 ]; then
     umount "$host_mount" > /dev/null 2>&1
     sleep 3 
   fi
   [ -d "$host_mount" ] && rmdir "$host_mount" > /dev/null 2>&1
}

#######################
### Main processing ###
#######################
debug "Parameters passed: "$@""
if [ "$(whoami)" != root ]; then
  error "Admin rights are required to run this program."
  exit 1
fi
if [ -f /host/ubuntu/disks/root.disk ]; then
   error "Invalid usage - do not run from a Wubi install"
   exit 1
fi
detect_wubi
if [ "$wubi_partition" == "" ];then
   error "Wubi install not detected"
   exit 1
fi
echo "$wubi_partition"
exit 0
