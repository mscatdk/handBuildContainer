#!/bin/bash
# Author: Michael Sevelsted Christensen <mscatdk@gmail.com>

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]
	then echo "Please run as root"
	exit
fi

FS_ROOT=$PWD/rootfs
HOST_MOUNT=$PWD/data
CON_MOUNT=$FS_ROOT/etc/demo

HOSTIF='enp0s3'
CONTAINERIF='con0'

function cleanup() {
	# Remove mount point
	umount $CON_MOUNT

	# Remove iptable entries
	iptables -S | sed "/handBuildContainer/s/-A/iptables -D/e" &> /dev/null
	iptables -t nat -S | sed "/handBuildContainer/s/-A/iptables -t nat -D/e" &> /dev/null
}

function prepare_image() {
	# Create/recreate filesystem
	rm -rf $FS_ROOT
	mkdir $FS_ROOT

	echo Prepare fs based on $1
	tar -xf $1 -C $FS_ROOT
}

function prepare_mount() {
	# Create mount point
	[ -d $HOST_MOUNT ] || mkdir -p $HOST_MOUNT
	[ -d $CON_MOUNT ] || mkdir -p $CON_MOUNT

	mount --make-shared --bind $HOST_MOUNT $CON_MOUNT
}

function mount_virtual_fs() {
	echo $NS
	# Mount Virtual File Systems
	nsenter -t $NS -m -u -i -n -p chroot $FS_ROOT /bin/mount -t proc none /proc
	nsenter -t $NS -m -u -i -n -p chroot $FS_ROOT /bin/mount -t sysfs none /sys
}

function create_virtual_network() {
	if [ ! -d /var/run/netns ]; then
		mkdir /var/run/netns
	fi
	if [ -f /var/run/netns/$NS ]; then
		rm -rf /var/run/netns/$NS
	fi

	ln -s /proc/$NS/ns/net /var/run/netns/$NS

	ip link add con0 type veth peer name eth0

	ip link set eth0 netns $NS

	ip addr add 10.1.0.10/24 dev con0
	ip netns exec $NS ip addr add 10.1.0.1/24 dev eth0
	ip link set con0 up
	ip netns exec $NS ip link set eth0 up
	ip netns exec $NS ip link set lo up

	ip netns exec $NS route add default gw 10.1.0.10 eth0
}

function configure_network() {
	# Package forwarding
	/bin/echo 1 > /proc/sys/net/ipv4/ip_forward

	iptables -t nat -A POSTROUTING -o $CONTAINERIF -j MASQUERADE -m comment --comment "handBuildContainer"
	iptables -A FORWARD -i $CONTAINERIF -o $HOSTIF -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment "handBuildContainer" 
	iptables -A FORWARD -i $HOSTIF -o $CONTAINERIF -j ACCEPT -m comment --comment "handBuildContainer"

	iptables -t nat -A POSTROUTING -o $HOSTIF -j MASQUERADE -m comment --comment "handBuildContainer"
	iptables -A FORWARD -i $HOSTIF -o $CONTAINERIF -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment "handBuildContainer"
	iptables -A FORWARD -i $CONTAINERIF -o $HOSTIF -j ACCEPT -m comment --comment "handBuildContainer"

	# DNS and hostname
	nsenter -t $NS -m -u -i -n -p chroot $PWD/rootfs /bin/sh -c 'echo nameserver 8.8.8.8 > /etc/resolv.conf'
	nsenter -t $NS -m -u -i -n -p chroot $PWD/rootfs /bin/sh -c 'echo container > /etc/hostname'
}

function prepare_container() {
	prepare_image $1
	prepare_mount
}

function start_container() {
	prepare_container $1

	sh -c 'echo $$; exec unshare --mount --uts --ipc --net --pid -f --user --map-root-user chroot $PWD/rootfs /bin/sh'
	
	cleanup
}

function configure_container() {
	NS=$(pgrep -P $1)
	export NS
	
	mount_virtual_fs
	create_virtual_network
	configure_network
}

function export_image() {
	CONTAINER_ID=$(docker run -d --rm $1)
	docker export --output=$1.tar $CONTAINER_ID
	docker stop $CONTAINER_ID
}

case "$1" in 
  start)
	if [ $# -ne 2 ]; then
		echo "Usage: $0 start <image file>"
		exit 1
	fi
	start_container $2
	;;
	
  configure)
	if [ $# -ne 2 ]; then
		echo "Usage: $0 configure <parent pid>"
		exit 1
	fi
	configure_container $2
	;;
  
  export)
    if [ $# -ne 2 ]; then
		echo "Usage: $0 export <image name>"
		exit 1
	fi
	export_image $2
	;;
  *) echo $"Usage: $0 {start|configure|export}"
     exit 1
esac

exit 0