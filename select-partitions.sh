#!/bin/bash
#
### Variable declaration ###
#
# Options 
debug=false                 # Output debug information
target=                     # type of partitions we're interested in
                            # linux (ext2/3/4) windows (ntfs/fat32) swap (swap)

usage () 
{
    cat <<EOF
Usage: sudo bash $0 [option]
       e.g. sudo bash $0 --linux

Choose candidate partitions for migration
Options:
  --linux   return list of ext2/3/4 partitions
  --windows return list of ntfs/fat32 partitions
  --swap    return list of swap partitions
EOF
} 
### Check the options and parameters
for option in "$@"; do
    case "$option" in
    -h | --help)
    usage
    exit 0 ;;
    --linux)
    if [ "$target" == "" ]; then
        target="linux"
    else
        error "Only one of --linux / --windows / --swap permitted"
        exit 1
    fi
    ;;
    --windows)
    if [ "$target" == "" ]; then
        target="windows"
    else
        error "Only one of --linux / --windows / --swap permitted"
        exit 1
    fi
    ;;
    --swap)
    if [ "$target" == "" ]; then
        target="swap"
    else
        error "Only one of --linux / --windows / --swap permitted"
        exit 1
    fi
    ;;
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


# List ext2/34 partitions
select_linux ()
{
   partition_list=`blkid | grep -i 'TYPE="ext[234]"' | cut -d ' ' -f 1 | grep -i '^/dev/' | grep -v '/dev/loop' | sed "s/://g"`
}
# List ntfs/fat32 partitions
select_windows ()
{
   partition_list=`blkid | egrep -i 'TYPE="(vfat|ntfs|fat32)"' | cut -d ' ' -f 1 | sed "s/://g"`
}
# List ext2/34 partitions
select_swap ()
{
   partition_list=`blkid | grep -i 'TYPE="swap"' | cut -d ' ' -f 1 | sed "s/://g"`
}

#######################
### Main processing ###
#######################
debug "Parameters passed: "$@""
if [ "$(whoami)" != root ]; then
  error "Admin rights are required to run this program."
  exit 1
fi
if [ "$target" == "" ]; then
    error "Missing required option - one of --linux / --windows / --swap"
    exit 1
fi
case "$target" in
    linux)
    select_linux
    ;;
    windows)
    select_windows
    ;;
    swap)
    select_swap
    ;;
esac
echo "$partition_list"
#set $partition_list
#echo $1 $2 $3
exit 0
