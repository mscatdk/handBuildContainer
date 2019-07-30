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

###########################################################################################
## Start Container
###########################################################################################
function prepare_image() {
	if [ ! -f "$1" ]; then
		echo "Can't find image $1"
		exit 128
	fi

	# Create/recreate filesystem
	rm -rf $FS_ROOT
	mkdir $FS_ROOT

	echo Prepare fs based on $1
	tar -xf $1 -C $FS_ROOT
	
	echo nameserver 8.8.8.8 > ${FS_ROOT}/etc/resolv.conf 
	echo container > ${FS_ROOT}/etc/hostname
	echo 127.0.0.1        localhost > ${FS_ROOT}/etc/hosts
	echo 10.1.0.1         container > ${FS_ROOT}/etc/hosts
	echo 10.1.0.1         docker > ${FS_ROOT}/etc/hosts
}

function prepare_mount() {
	# Create mount point
	[ -d $HOST_MOUNT ] || mkdir -p $HOST_MOUNT
	[ -d $CON_MOUNT ] || mkdir -p $CON_MOUNT

	mount --make-shared --bind $HOST_MOUNT $CON_MOUNT
	
	mount -t sysfs none ${FS_ROOT}/sys
}

function prepare_devices() {
	mknod -m 666 ${FS_ROOT}/dev/full c 1 7
	mknod -m 666 ${FS_ROOT}/dev/ptmx c 5 2
	mknod -m 644 ${FS_ROOT}/dev/random c 1 8
	mknod -m 644 ${FS_ROOT}/dev/urandom c 1 9
	mknod -m 666 ${FS_ROOT}/dev/zero c 1 5
	mknod -m 666 ${FS_ROOT}/dev/tty c 5 0
	mknod -m 666 ${FS_ROOT}/dev/null c 1 3
}

function prepare_container() {
	prepare_image $1
	prepare_mount
	prepare_devices
}

function cleanup() {
	# Remove mount point
	umount $CON_MOUNT
	umount ${FS_ROOT}/sys

	# Remove iptable entries
	iptables -S | sed "/handBuildContainer/s/-A/iptables -D/e" &> /dev/null
	iptables -t nat -S | sed "/handBuildContainer/s/-A/iptables -t nat -D/e" &> /dev/null
}

function start_container() {
	prepare_container $1

	echo CMD: $2
	sh -c "echo $$; exec unshare --mount --uts --ipc --net --pid -f --user --map-root-user chroot $PWD/rootfs sh -c '/bin/mount -t proc none /proc && $2'"
	
	cleanup
}

###########################################################################################
## Configure Container
###########################################################################################
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
}

function configure_container() {
	NS=$(pgrep -P $1)
	export NS
	
	create_virtual_network
	configure_network
}

###########################################################################################
## Export Image
###########################################################################################
function export_image() {
	CONTAINER_ID=$(docker run -d --rm $1)
	docker export --output=$1.tar $CONTAINER_ID
	docker stop $CONTAINER_ID
}

###########################################################################################
## Expose
###########################################################################################
function expose_port() {
	iptables -t nat -A PREROUTING ! -i con0 -p tcp --dport $1 -j DNAT --to-destination 10.1.0.1:$2 -m comment --comment handBuildContainer 
	iptables -t nat -A POSTROUTING -s 10.1.0.1/32 -d 10.1.0.1/32 -p tcp --dport $2 -j MASQUERADE -m comment --comment handBuildContainer 
	iptables -A FORWARD -d 10.1.0.1/32 ! -i con0 -o con0 -p tcp --dport $2 -j ACCEPT -m comment --comment handBuildContainer 
}

###########################################################################################
## Parse Arguments
###########################################################################################
case "$1" in 
  start)
	if [ $# -ne 3 ]; then
		echo "Usage: $0 start <image file> <cmd>"
		exit 1
	fi
	start_container $2 "$3"
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
  expose)
    if [ $# -ne 3 ]; then
		echo "Usage: $0 expose <host_port> <container_port>"
		exit 1
	fi
	expose_port $2 $3
	;;
  *) echo $"Usage: $0 {start|configure|export|expose}"
     exit 1
esac

exit 0
