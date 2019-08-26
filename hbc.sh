#!/bin/bash
# Author: Michael Sevelsted Christensen <mscatdk@gmail.com>

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]
	then echo "Please run as root"
	exit
fi

BASE_PATH=/var/lib/hbc
CONTAINER_HOME=${BASE_PATH}/containers
IMAGE_HOME=${BASE_PATH}/images
APP_HOME=${BASE_PATH}/bin
LOG_FILE=${BASE_PATH}/hbc.log

# You will need to manually remove the bridge and run install when chaning the subnet
# ovs-vsctl del-br br-hbc0
CONTAINER_SUBNET=10.3.0.0
BRIDGE_IP=`echo $CONTAINER_SUBNET | sed "s/\.[^\.]*$//"`.1

BRIDGE_IF=br-hbc0
HOSTIF=$(ip route show | grep default | awk '{print $5}')

###########################################################################################
## Common
###########################################################################################
function generate_id() {
	< /dev/urandom tr -dc A-Za-z0-9 | head -c${1:-32};echo;
}

function mkdir_if_not_exists() {
        [ ! -d $1 ] && mkdir -p $1
}

function create_directory_strcuture() {
	mkdir_if_not_exists $CONTAINER_HOME
	mkdir_if_not_exists $APP_HOME
	mkdir_if_not_exists ${BASE_PATH}/data
	mkdir_if_not_exists $IMAGE_HOME

	[ -f ./bootstrap.sh ] && cp ./bootstrap.sh ${APP_HOME}/bootstrap.sh
}

function create_containter_directories() {
	[ -d ${CONTAINER_HOME}/$1 ] && rm -rf ${CONTAINER_HOME}/$1
	mkdir -p ${CONTAINER_HOME}/$1/rootfs
	mkdir -p ${CONTAINER_HOME}/$1/.locks
	mkdir -p ${CONTAINER_HOME}/$1/config
	mkdir -p ${CONTAINER_HOME}/$1/log
}

function set_container_paths() {
	export CONTAINER_ID=$1

	export FS_ROOT=${CONTAINER_HOME}/$1/rootfs

	export CONFIG_COMPLETED_LOCK_FILE=${CONTAINER_HOME}/$1/.locks/config_completed.lock
	export INITIAL_PID_FILE=${CONTAINER_HOME}/$1/.locks/initial_pid.lock
	export PROCESS_PID_FILE=${CONTAINER_HOME}/$1/config/process_pid
	export UNSHARE_PID_FILE=${CONTAINER_HOME}/$1/config/unshare_pid
	export LOG_HOME=${CONTAINER_HOME}/$1/log
	export IP_FILE=${CONTAINER_HOME}/$1/config/ip
	export CONTAINER_IP=`cat $IP_FILE`
	export CONTAINER_IF_NAME=con`echo $CONTAINER_IP | cut -f4 -d '.'`

	export IMAGE_NAME_FILE=${CONTAINER_HOME}/$1/config/image_name
	export CMD_FILE=${CONTAINER_HOME}/$1/config/cmd

	export CGROUP_MEMORY_HOME=/sys/fs/cgroup/memory/$1
}

function is_active() {
	if [ -d $CONTAINER_HOME/$1 ]
	then
		set_container_paths $1
		if [ ! -f $INITIAL_PID_FILE ]
		then
			false
		elif [ 1 -ne $(ps -ef | grep `cat $INITIAL_PID_FILE` | grep unshare | awk '{print $2}' | wc -l) ]
		then
			false
		else
			true
		fi
	else
		false
	fi
}

function get_mounts() {
	tail -n +1 -- /proc/*/mounts 2> /dev/null | grep $CONTAINER_ID | awk '{ print $2 }' | sort | uniq
}

function clean_mounts() {
	# Remove mount point
	num_mounts=$(get_mounts | wc -l)
	if [ $num_mounts -gt 1 ]
	then
		get_mounts | xargs umount
	fi

	# Remove memory cgroup
	[ -d $CGROUP_MEMORY_HOME ] && rmdir $CGROUP_MEMORY_HOME

	# Release IP
	[ -f $IP_FILE ] && rm $IP_FILE
}

function cleanup() {
	clean_mounts

	# Remove iptable entries
	iptables -S | sed "/${CONTAINER_ID}/s/-A/iptables -D/e" &> /dev/null
	iptables -t nat -S | sed "/${CONTAINER_ID}/s/-A/iptables -t nat -D/e" &> /dev/null
	
	ovs-vsctl del-port $BRIDGE_IF $CONTAINER_IF_NAME
}

function info() {
	echo "[`date`] INFO $1" >> $LOG_FILE
}

function error() {
	echo "[`date`] ERROR $1" >> $LOG_FILE
}

###########################################################################################
## Image Handling
###########################################################################################
function get_cpu_arch() {
	MACHINE_TYPE=$(uname -m)
	if [ 1 -eq `echo $MACHINE_TYPE | grep -i x86_64 | wc -l` ]
	then
		echo "amd64"
	elif [ 1 -eq `echo $MACHINE_TYPE | grep -i armv | wc -l` ]
	then
		echo "arm"
	else
		# Signal an error
		echo ""
		exit 128
	fi
}

function locate_image() {
	if [ -f "$1" ]; then
		export IMAGE_PATH=$1
		return
	fi

	NAME=$(cut -d':' -f1 <<<$1)
	VERSION=$(cut -d':' -f2 <<<$1)
	if [ $NAME == $VERSION ]
	then
		VERSION="latest"
	fi
	CPU_ARCH=$(get_cpu_arch)
	if [ "$CPU_ARCH" = "" ]
	then
		echo "Can't determine CPU architecture"
		exit 128
	fi

	RELATIVE_PATH=${NAME}/${CPU_ARCH}/${VERSION}/${NAME}-${CPU_ARCH}-${VERSION}.tar
	if [ -f ${IMAGE_HOME}/${RELATIVE_PATH} ]
	then
		export IMAGE_PATH=${IMAGE_HOME}/${RELATIVE_PATH}
		return
	fi

	mkdir -p $(dirname ${IMAGE_HOME}/${RELATIVE_PATH})
	curl --fail https://msc.webhop.me/hbc/images/$RELATIVE_PATH -o ${IMAGE_HOME}/${RELATIVE_PATH}
	rc=$?
	if [ $rc -eq 0 ]
	then
		export IMAGE_PATH=${IMAGE_HOME}/${RELATIVE_PATH}
		return
	else
		echo "Can't find image remote!"
		exit 12
	fi
}

function prepare_image() {
	# The below function will set IMAGE_PATH
	locate_image $1

	# Create/recreate filesystem
	rm -rf $FS_ROOT
	mkdir $FS_ROOT

	echo Prepare fs based on $IMAGE_PATH
	tar -xf $IMAGE_PATH -C $FS_ROOT
	echo nameserver 8.8.8.8 > ${FS_ROOT}/etc/resolv.conf
	echo hbc > ${FS_ROOT}/etc/hostname
	echo 127.0.0.1        localhost > ${FS_ROOT}/etc/hosts
	echo $CONTAINER_IP         hbc >> ${FS_ROOT}/etc/hosts
}

###########################################################################################
## Configure Container Namespaces
###########################################################################################
function create_virtual_network() {
	mkdir_if_not_exists /var/run/netns

	if [ -f /var/run/netns/$NS ]; then
		rm -rf /var/run/netns/$NS
	fi

	ln -s /proc/$NS/ns/net /var/run/netns/$NS

	# host setup
	ip link add $CONTAINER_IF_NAME type veth peer name eth0 netns $NS
	ip link set $CONTAINER_IF_NAME nomaster
	ip link set $CONTAINER_IF_NAME up
	
	ovs-vsctl add-port $BRIDGE_IF $CONTAINER_IF_NAME

	# Container setup
	ip netns exec $NS ip addr add ${CONTAINER_IP}/24 dev eth0
	ip netns exec $NS ip link set eth0 up
	ip netns exec $NS ip link set lo up

	ip netns exec $NS ip route add default via ${BRIDGE_IP}
}

function create_user_mapping() {
	echo "         0          0 4294967295" > /proc/${NS}/uid_map
	echo "         0          0 4294967295" > /proc/${NS}/gid_map
}

function configure_container() {
	export NS=$1

	create_user_mapping
	create_virtual_network

	touch $CONFIG_COMPLETED_LOCK_FILE
}

###########################################################################################
## Start Container
###########################################################################################
function prepare_mount() {
	mount -t sysfs none ${FS_ROOT}/sys
	# Unshare will do the actual mount later
	mount -t tmpfs tmpfs ${FS_ROOT}/proc
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

function wait_for_unshare_process() {
	while [ ! -f $INITIAL_PID_FILE ]; do sleep 0.001; done
	while [ 1 -ne $(ps -ef | grep `cat $INITIAL_PID_FILE` | grep unshare | awk '{print $2}' | wc -l) ]
	do
		sleep 0.001
	done
	UNSHARE_PID=$(ps -ef | grep `cat $INITIAL_PID_FILE` | grep unshare | awk '{print $2}')
	echo $UNSHARE_PID > $UNSHARE_PID_FILE
	echo $(pgrep -P $UNSHARE_PID) > $PROCESS_PID_FILE
	configure_container $UNSHARE_PID
}

function get_ip() {
	IP_FILE=${CONTAINER_HOME}/$1/config/ip
	IP_BASE=$(echo ${CONTAINER_SUBNET} | sed "s/\.[^\.]*$//")
	cat $CONTAINER_HOME/*/config/ip > ${IP_FILE}.tmp 2> /dev/null
	echo ${IP_BASE}.{2..255} | tr ' ' '\012' | grep -v -f ${IP_FILE}.tmp | head -n 1 > ${IP_FILE}
	rm ${IP_FILE}.tmp
}

function start_container() {
	export CONTAINER_ID=$(generate_id)
	IMAGE_NAME=$1
	CMD=$2

	create_containter_directories $CONTAINER_ID
	
	get_ip $CONTAINER_ID
	echo `cat ${IP_FILE}`
	
	set_container_paths $CONTAINER_ID
	echo $CMD > $CMD_FILE
	echo $IMAGE_NAME > $IMAGE_NAME_FILE

	info "Starting CMD: $CMD Container ID: $CONTAINER_ID Image: $IMAGE_NAME"
	prepare_container $IMAGE_NAME

	echo CMD: $CMD
	echo Container ID: $CONTAINER_ID

	# Create process that will complete the configuration once unshare has completed
	wait_for_unshare_process &> ${LOG_HOME}/config.log &

	# Enable user namespaces on Red Hat and CentOS
	[ -f /proc/sys/user/max_user_namespaces ] && [ 0 -eq `cat /proc/sys/user/max_user_namespaces` ] && echo 640 > /proc/sys/user/max_user_namespaces

	# Unshare -> Create namespaces and mount proc
	sh -i -c "echo $$ > $INITIAL_PID_FILE; exec unshare --mount --uts --ipc --net --pid -f --user --mount-proc=${FS_ROOT}/proc ${APP_HOME}/bootstrap.sh $CONFIG_COMPLETED_LOCK_FILE $FS_ROOT $2"

	cleanup
}

###########################################################################################
## Stop Container
###########################################################################################
function stop_container() {
	CONTAINER_ID=$1
	if [ -d ${CONTAINER_HOME}/${CONTAINER_ID} ]
	then
		if is_active $CONTAINER_ID
		then
			set_container_paths $CONTAINER_ID

			# Kill the initial process first to get a clean shell exit
			kill `cat $INITIAL_PID_FILE`
			# Kill the unshare process and the parent process in the new PID Namespace
			kill `cat $UNSHARE_PID_FILE`
			kill -9 `cat $PROCESS_PID_FILE`
			cleanup
		else
			echo Container isn\'t running
		fi
	else
		echo Container with id: ${CONTAINER_ID} doesn\'t exist
	fi
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
	CONTAINER_ID=$1
	if [ -d ${CONTAINER_HOME}/${CONTAINER_ID} ]
	then
		if is_active $CONTAINER_ID
		then
			# Set container IP
			set_container_paths $CONTAINER_ID
			HOST_PORT=$2
			CONTAINER_PORT=$3
			if [ 0 -eq $(iptables -t nat -S | grep "N DOCKER" | wc -l) ]
			then
				iptables -t nat -A PREROUTING ! -i con0 -p tcp --dport $HOST_PORT -j DNAT --to-destination ${$CONTAINER_IP}:${CONTAINER_PORT} -m comment --comment $CONTAINER_ID
				iptables -t nat -A POSTROUTING -s ${$CONTAINER_IP}/32 -d ${$CONTAINER_IP}/32 -p tcp --dport ${CONTAINER_PORT} -j MASQUERADE -m comment --comment $CONTAINER_ID
				iptables -A FORWARD -d ${CONTAINER_IP}/32 ! -i con0 -o con0 -p tcp --dport ${CONTAINER_PORT} -j ACCEPT -m comment --comment $CONTAINER_ID
			else
				echo "Expose doesn't work when Docker iptable entries are present"
			fi
		else
			echo "Container isn't running"
		fi
	else
		echo "Container with id: ${CONTAINER_ID} doesn't exist"
	fi
}

###########################################################################################
## Exec
###########################################################################################
function exec_container() {
	set_container_paths $1
	nsenter -m -u -i -n -p -t `cat $PROCESS_PID_FILE` chroot $FS_ROOT "$2"
}

###########################################################################################
## ps
###########################################################################################
function list_active_containers() {
	printf '%32s %10s %25s %50s\n' "CONTAINER ID" "PID" "IMAGE" "CMD"
	for d in $CONTAINER_HOME/*/
	do
		if [ -d $d ]
		then
			CONTAINER_ID=$(basename $d)
			if is_active $CONTAINER_ID
			then
				set_container_paths $CONTAINER_ID
				printf '%32s %10s %25s %50s\n' $CONTAINER_ID `cat $PROCESS_PID_FILE` `cat $IMAGE_NAME_FILE` `cat $CMD_FILE`
			fi
		fi
	done
}

###########################################################################################
## clean
###########################################################################################
function delete_inactive_containers() {
	for d in $CONTAINER_HOME/*/
	do
		if [ -d $d ]
		then
			CONTAINER_ID=$(basename $d)
			if ! is_active $CONTAINER_ID
			then
				echo Deleting $CONTAINER_ID
				clean_mounts
				rm -rf ${CONTAINER_HOME}/${CONTAINER_ID}
			fi
		fi
	done
}

###########################################################################################
## Installation
###########################################################################################
function install_OpenvSwitch() {
	if VERB="$( which apt-get )" 2> /dev/null; then
		apt-get update
		apt-get install -y openvswitch-switch
	elif VERB="$( which yum )" 2> /dev/null; then
		yum -y update
		yum -y install openvswitch
		systemctl start openvswitch
	else
		echo "No supported package manager installed on system"
		exit 1
	fi
}

function create_network_bridge() {
	if [ `ovs-vsctl show | grep $BRIDGE_IF | wc -l` -eq 0 ]
	then
		ovs-vsctl add-br $BRIDGE_IF
	fi
}

function config_network_bridge() {
	ifconfig $BRIDGE_IF | grep $BRIDGE_IP &> /dev/null
	rc=$?
	if [ $rc -ne 0 ]
	then
		echo "Set bridge ip to $BRIDGE_IP"
		ip addr add $BRIDGE_IP/24 dev $BRIDGE_IF
		ip link set $BRIDGE_IF up
	fi
}

function create_bridge_iptable_entries() {
	# Enable Package forwarding
	/bin/echo 1 > /proc/sys/net/ipv4/ip_forward

	# Remove existing iptable entries
	iptables -S | sed "/hbcBridge/s/-A/iptables -D/e" &> /dev/null
	iptables -t nat -S | sed "/hbcBridge/s/-A/iptables -t nat -D/e" &> /dev/null

	iptables -t nat -A POSTROUTING -s ${CONTAINER_SUBNET}/24 -o $HOSTIF -j MASQUERADE -m comment --comment hbcBridge
	iptables -A FORWARD -s ${CONTAINER_SUBNET}/24 -o $HOSTIF -j ACCEPT -m comment --comment hbcBridge
	iptables -A FORWARD -d ${CONTAINER_SUBNET}/24 -i $HOSTIF -j ACCEPT -m comment --comment hbcBridge
}

function install_network_bridge() {
	install_OpenvSwitch
	create_network_bridge
	config_network_bridge
	create_bridge_iptable_entries
}

function download_file() {
	curl -s --fail $1 -o $2
	RC=$?
	if [ $RC -ne 0 ]
	then
		echo "Unable to download app version $3"
		exit 127
	fi
}

function install_app() {
	if [ -z $1 ]
	then
		VERSION=latest
	else
		VERSION=$1
	fi

	download_file "https://msc.webhop.me/hbc/app/${VERSION}/hbc.sh" "${APP_HOME}/hbc.sh" $VERSION
	download_file "https://msc.webhop.me/hbc/app/${VERSION}/bootstrap.sh" "${APP_HOME}/bootstrap.sh" $VERSION

	chmod 755 "${APP_HOME}/hbc.sh"
	chmod 755 "${APP_HOME}/bootstrap.sh"

	[ -f /usr/bin/hbc ] && rm /usr/bin/hbc
	ln -s ${APP_HOME}/hbc.sh /usr/bin/hbc
	
	install_network_bridge

	echo "Installation of $VERSION has completed"
}

###########################################################################################
## Memory CGROUP
###########################################################################################
function memory_cgroup() {
	if is_active $1
	then
		set_container_paths $1

		mkdir_if_not_exists $CGROUP_MEMORY_HOME
		echo $2 > ${CGROUP_MEMORY_HOME}/memory.limit_in_bytes
		cat $PROCESS_PID_FILE > ${CGROUP_MEMORY_HOME}/cgroup.procs
		echo "The process will be killed in case more than $2 Bytes of memory is allocated"
	else
		echo "Container $1 is active or doesn't exist"
	fi
}

###########################################################################################
## cp
###########################################################################################
function copy_into_container() {
	if is_active $1
	then
		if [ -f $2 ]
		then
			cp $2 ${FS_ROOT}$3
		elif [ -d $2 ]
		then
			cp -rf $2 ${FS_ROOT}$3
		else
			echo "Can't find $2"
		fi
	else
		echo "Container is inactive or doesn't exist"
	fi
}

###########################################################################################
## mount
###########################################################################################
function bind_mount() {
	set_container_paths $1
	if [ -d $2 ]
	then
		if [ -d $FS_ROOT ]
		then
			HOST_PATH=${FS_ROOT}/$3
			mkdir_if_not_exists $HOST_PATH
			nsenter -m -t `cat $PROCESS_PID_FILE` mount --make-shared --bind $2 $HOST_PATH
		else
			echo "Container root filesystem doesn't exist"
		fi
	else
		echo "The path $2 doesn't exist"
	fi
}

###########################################################################################
## Ensure network configuration is still intact
###########################################################################################
config_network_bridge

if [ `iptables -t nat -S | grep hbcBridge | wc -l` -ne 1 ] || [ `iptables -S | grep hbcBridge | wc -l` -ne 2 ]
then
	echo "Repair iptable entries"
	create_bridge_iptable_entries
fi 

###########################################################################################
## Parse Arguments
###########################################################################################
create_directory_strcuture
case "$1" in
  start)
	if [ $# -ne 3 ]; then echo "Usage: $0 start <image file> <cmd>"; exit 1; fi
	start_container $2 "$3"
	;;
  stop)
    if [ $# -ne 2 ]; then echo "Usage: $0 stop <container id>"; exit 1; fi
    stop_container $2
	;;
  export)
    if [ $# -ne 2 ]; then echo "Usage: $0 export <image name>"; exit 1; fi
    export_image $2
	;;
  expose)
    if [ $# -ne 4 ]; then echo "Usage: $0 expose <container id> <host port> <container port>"; exit 1; fi
	expose_port $2 $3 $4
	;;
  exec)
    if [ $# -ne 3 ]; then echo "Usage: $0 exec <container id> <cmd>"; exit 1; fi
    exec_container $2 $3
    ;;
  ps)
	list_active_containers
    ;;
  clean)
	delete_inactive_containers
	;;
  install)
	install_app $2
	;;
  memory)
        if [ $# -ne 3 ]; then echo "Usage: $0 memory <container id> <memory limit in bytes>"; exit 1; fi
        memory_cgroup $2 $3
	;;
  mount)
		if [ $# -ne 4 ]; then echo "Usage: $0 mount <container id> <host path> <container path>"; exit 1; fi
		bind_mount $2 $3 $4
	;;
  cp)
	if [ $# -ne 4 ]; then echo "Usage: $0 cp <container id> <host path> <container path>"; exit 1; fi
	copy_into_container $2 $3 $4
	;;
  *) echo $"Usage: $0 {start|stop|ps|exec|expose|clean|export|memory|cp}"
	 echo "start <image name> <cmd> -> start new container"
	 echo "stop <container id> -> stop running container"
	 echo "ps -> list running containers"
	 echo "exec <container id> <cmd> -> Enter a running container"
	 echo "expose <container id> <host port> <container port> -> Port forwading a host port to a container port"
	 echo "clean -> delete all inactive containers"
	 echo "export <image name> -> Create image from docker image"
	 echo "memory <container id> <memory limit in bytes> -> Create cgroup memory constaint"
	 echo "cp <container id> <host path> <container path> -> Copy file or directory into container"
	 echo "mount <container id> <host path> <container path> -> mount an exist directory inside the container"
     exit 1
esac

exit 0
