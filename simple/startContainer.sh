#!/bin/bash

# Input validation
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

FS_ROOT=$PWD/rootfs
HOST_MOUNT=$PWD/data
CON_MOUNT=$FS_ROOT/etc/demo

# Create/recreate filesystem
rm -rf $FS_ROOT

mkdir $FS_ROOT

tar -xf alpine.tar -C $FS_ROOT

# Create mount point
[ -d $HOST_MOUNT ] || mkdir -p $HOST_MOUNT
[ -d $CON_MOUNT ] || mkdir -p $CON_MOUNT

mount --make-shared --bind $HOST_MOUNT $CON_MOUNT

sh -c 'echo $$; exec unshare --mount --uts --ipc --net --pid -f --user --map-root-user chroot $PWD/rootfs /bin/sh'

# Clean-up

# Remove mount point
umount $CON_MOUNT

# Remove iptable entries
iptables -S | sed "/handBuildContainer/s/-A/iptables -D/e" &> /dev/null
iptables -t nat -S | sed "/handBuildContainer/s/-A/iptables -t nat -D/e" &> /dev/null
