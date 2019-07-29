#!/bin/bash

# Input validation
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 <parent_pid>"
    exit 1
fi


NS=$(pgrep -P $1)
FS_ROOT=$PWD/rootfs

# Mount Points
nsenter -t $NS -m -u -i -n -p chroot $FS_ROOT /bin/mount -t proc none /proc
nsenter -t $NS -m -u -i -n -p chroot $FS_ROOT /bin/mount -t sysfs none /sys

# Virtual Network
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

# Package forwarding
HOSTIF='enp0s3'
CONTAINERIF='con0'

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
