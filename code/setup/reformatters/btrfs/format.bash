#!/usr/bin/env bash
## Copyright © by Miles Bradley Huff from 2016-2019 per the LGPL3 (the Third Lesser GNU Public License)
set -e ## Fail the whole script if any command within it fails.

## Get system info and declare variables
## =====================================================================

## Get the disk
## ---------------------------------------------------------------------
while [[ true ]]; do
	if [[ ! $1 ]]; then
		echo ':: Path to disk: '
		read DISK
	else DISK="$1"
	fi
	[[ -e "$DISK" ]] && break
	echo ':: Invalid disk.' >&2
done
echo

## System information
## ---------------------------------------------------------------------
echo ':: Gathering information...'
NPROC="$(nproc)"
SSD="$(cat /sys/block/$(echo $DISK | sed 's/\/dev\///')/queue/rotational)"
BOOTSIZE="500M" ## 500MB/477MiB is the recommended size for the EFI partition when used as /boot (https://www.freedesktop.org/wiki/Specifications/BootLoaderSpec)
MEMSIZE="$(free -b | grep 'Mem:' | sed 's/Mem:\s*//' | sed 's/\s.*//' )"
PAGESIZE="$(getconf PAGESIZE)"
BLOCKSIZE="$(($PAGESIZE*256))" ## 1M with a 4k pagesize.  Idk if this should be dependent on pagesize.

## Formatting settings
## ---------------------------------------------------------------------
MKFS_BTRFS_OPTS=" --force --data single --metadata single --nodesize $PAGESIZE --sectorsize $PAGESIZE --features extref,skinny-metadata,no-holes "
MKFS_VFAT_OPTS=" -F 32 -b 6 -f 1 -h 6 -r 512 -R 12 -s 1 -S $PAGESIZE "

## Mount options
## ---------------------------------------------------------------------
MOUNTPOINT='/media/format-drives-test'
MOUNT_ANY_OPTS='defaults,rw,async,iversion,nodiratime,relatime,strictatime,lazytime,auto' #mand## Mount options
MOUNT_BTRFS_OPTS="acl,noinode_cache,space_cache=v2,barrier,noflushoncommit,treelog,usebackuproot,datacow,datasum,compress=zstd,fatal_errors=bug,noenospc_debug,thread_pool=$NPROC,max_inline=$(echo $PAGESIZE*0.95 | bc | sed 's/\..*//')" #logreplay
MOUNT_VFAT_OPTS='check=relaxed,errors=remount-ro,tz=UTC,rodir,sys_immutable,flush' #iocharset=utf8
## SSD tweaks
if [[ SSD -gt 0 ]]; then
    MOUNT_BTRFS_OPTS="${MOUNT_BTRFS_OPTS},noautodefrag,discard,ssd_spread"
else
    MOUNT_BTRFS_OPTS="${MOUNT_BTRFS_OPTS},autodefrag,nodiscard,nossd"
fi
echo

## Prepare system
## =====================================================================

## Unmount disk
## ---------------------------------------------------------------------
echo ':: Making sure disk is not mounted...'
set +e ## It's okay if this section fails
swapoff "$MOUNTPOINT/swapfile"
for EACH in "$DISK"*; do
	umount "$EACH"
done
set -e ## Back to failing the script like before
echo

## Reformat the disk
## =====================================================================
read -p ':: Reformat the disk? (y/N) ' INPUT
echo
if [[ "$INPUT" = 'y' || "$INPUT" = 'Y' ]]; then

	## Partition disk
	## ---------------------------------------------------------------------
	echo ':: Partitioning disk...'
	(	echo 'o'          ## Create a new GPT partition table
		echo 'Y'          ## Confirm

		echo 'n'          ## Create a new partition
		echo ''           ## Choose the default partition number  (1)
		echo ''           ## Choose the default start location (2048)
		echo "+$BOOTSIZE" ## Make it as large as $BOOTSIZE
		echo 'ef00'       ## Declare it to be a UEFI partition
		echo 'c'          ## Change a partition's name
		echo '1'          ## The partition whose name to change
		echo 'BOOT'       ## The name of the partition

		echo 'n'          ## Create a new partition
		echo ''           ## Choose the default partition number  (2)
		echo ''           ## Choose the default start location (where the last partition ended)
		echo ''           ## Choose the default end location   (the end of the disk)
		echo '8300'       ## Declare it to be a Linux x86-64 root partition
		echo 'c'          ## Change a partition's name
		echo '2'          ## The partition whose name to change
		echo 'ROOT'       ## The name of the partition

		echo 'w'          ## Write the changes to disk
		echo 'Y'          ## Confirm
	) | gdisk "$DISK"
	sleep 1
	echo

	## Refresh disks
	## ---------------------------------------------------------------------
	echo ':: Refreshing devices...'
	set +e ## It's okay if this section fails
	partprobe
	sleep 1
	set -e ## Back to failing the script like before
	echo

## Figure out the partition prefix
## ---------------------------------------------------------------------
fi
[[ ! -f "${DISK}1" ]] && PART='p'
if [[ "$INPUT" = 'y' || "$INPUT" = 'Y' ]]; then


	## Format partitions
	## ---------------------------------------------------------------------
	echo ':: Formatting partitions...'
	mkfs.vfat  $MKFS_VFAT_OPTS   -n     'BOOT' "${DISK}${PART}1"
	mkfs.btrfs $MKFS_BTRFS_OPTS --label 'ROOT' "${DISK}${PART}2"
	sleep 1
	echo

fi

## Prepare for Linux
## =====================================================================

## First mounts (sanity check -- remember `set -e`?)
## ---------------------------------------------------------------------
echo ':: Mounting partitions...'
mkdir -p "$MOUNTPOINT"
## BOOT (only temporarily mounted)
mount -o "$MOUNT_ANY_OPTS,$MOUNT_VFAT_OPTS"  "${DISK}${PART}1" "$MOUNTPOINT"
umount   "$MOUNTPOINT"
sleep 1
## ROOT (stays mounted)
mount -o "$MOUNT_ANY_OPTS,$MOUNT_BTRFS_OPTS" "${DISK}${PART}2" "$MOUNTPOINT"
sleep 1
echo

## Create swapfile
## ---------------------------------------------------------------------
## Using a swapfile instead of a swap partition makes it a lot easier to resize in the future.
## Placing the swapfile at the root of the btrfs tree and outside of a subvol also makes it very portable and excludes it from snapshots.
## Linux v5+ required!
## Root-level swapfiles are usually called "swapfile" in Linux distros, and we keep that convention here.
## Creating the swapfile before anything else should give it a privileged position in spinning hard disks if they put their fastest sectors at the start of the disk.
read -p ':: Create swapfile? (y/N) ' INPUT
echo
if [[ "$INPUT" = 'y' || "$INPUT" = 'Y' ]]; then
	echo ':: Creating swapfile...'
	truncate -s '0' "$MOUNTPOINT/swapfile" ## We have to create a 0-length file so we can use chattr
	chattr   +C     "$MOUNTPOINT/swapfile" ## We have to disable copy-on-write
	chattr   -c     "$MOUNTPOINT/swapfile" ## We have to make sure compression isn't enabled for it
	chmod     '600' "$MOUNTPOINT/swapfile" ## The swapfile should NOT be world-readable!
	fallocate -l "$MEMSIZE" "$MOUNTPOINT/swapfile" #NOTE:  May not work on all systems
	#dd if='/dev/zero' of="$MOUNTPOINT/swapfile" bs="$BLOCKSIZE" count="$(($MEMSIZE/$BLOCKSIZE))" status='progress' #TODO:  This may create a file that is a little smaller than $MEMSIZE, due to integer truncation.
	mkswap -p "$PAGESIZE" -L 'SWAP' "$MOUNTPOINT/swapfile"
	swapon "$MOUNTPOINT/swapfile"
	sleep 1
	echo
fi

## Create subvolumes
## ---------------------------------------------------------------------
## The idea with subvolumes is principally to ensure that
## (1) as little information is snapshotted as possible, and
## (2) different snapshots of different subvols should be able to work together.
## Also, there's a (3), which is that I'm hesitant to use subsubvolumes, because since they're excluded from their parent subvol's snapshots, I'm not sure whether they would still exist if I were to replace their parent subvol with a snapshot.  I'd rather use a .subvolignore list or something.
## Additionally, snapshots should be independent of any subvols, so that production subvols can easily be wholesale replaced by their snapshots.
## In order to meet requirement #1, child subvols should be created for temporary data.
## In order to meet requirement #2, directories like /etc and / should not be on different subvols.
## Making /home into an independent subvol meets both requirements.
## Also, I'm naming system root subvols after their distros, since that allows me to dual-boot from within the same partition.
read -p ':: Create subvolumes? (y/N) ' INPUT
echo
if [[ "$INPUT" = 'y' || "$INPUT" = 'Y' ]]; then
	echo ':: Creating subvolumes...'
	mkdir -p "$MOUNTPOINT/snapshots"       \
	         "$MOUNTPOINT/snapshots/@arch" \
	         "$MOUNTPOINT/snapshots/@home" \
	         "$MOUNTPOINT/snapshots/@srv"
	btrfs subvolume create      "$MOUNTPOINT/@arch"
	btrfs subvolume create      "$MOUNTPOINT/@home"
	btrfs subvolume create      "$MOUNTPOINT/@srv"
	btrfs subvolume set-default "$MOUNTPOINT/@arch"
	sleep 1
	echo
fi

## Unmount everything
## ---------------------------------------------------------------------
echo ':: Unmounting partitions...'
set +e ## It's okay if this section fails
swapoff "$MOUNTPOINT/swapfile"
umount  "$MOUNTPOINT"
sleep 1
set -e ## Back to failing the script like before
echo

## Cleanup
## ---------------------------------------------------------------------
echo ':: Done.'
exit 0
