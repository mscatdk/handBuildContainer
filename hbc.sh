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

HOSTIF=$(ip route show | grep default | awk '{print $5}')
CONTAINERIF='con0'

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
}

function set_container_paths() {
	export FS_ROOT=${CONTAINER_HOME}/$1/rootfs
	export HOST_MOUNT=${BASE_PATH}/data
	export CON_MOUNT=$FS_ROOT/etc/demo

	export CONFIG_COMPLETED_LOCK_FILE=${CONTAINER_HOME}/$1/.locks/config_completed.lock
	export INITIAL_PID_FILE=${CONTAINER_HOME}/$1/.locks/initial_pid.lock
	export PROCESS_PID_FILE=${CONTAINER_HOME}/$1/config/process_pid
	export UNSHARE_PID_FILE=${CONTAINER_HOME}/$1/config/unshare_pid

	export IMAGE_NAME_FILE=${CONTAINER_HOME}/$1/config/image_name
	export CMD_FILE=${CONTAINER_HOME}/$1/config/cmd
}

function is_active() {
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
}

function clean_mounts() {
        # Remove mount point
        umount $CON_MOUNT >> $LOG_FILE 2>&1
        umount ${FS_ROOT}/sys >> $LOG_FILE 2>&1
        umount ${FS_ROOT}/proc >> $LOG_FILE 2>&1
}

function cleanup() {
	clean_mounts

	# Remove iptable entries
	iptables -S | sed "/handBuildContainer/s/-A/iptables -D/e" &> /dev/null
	iptables -t nat -S | sed "/handBuildContainer/s/-A/iptables -t nat -D/e" &> /dev/null
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
	echo 10.1.0.1         hbc >> ${FS_ROOT}/etc/hosts
	echo 10.1.0.1         docker >> ${FS_ROOT}/etc/hosts
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

	ip link add con0 type veth peer name eth0 netns $NS

	ip addr add 10.1.0.10/24 dev con0
	ip netns exec $NS ip addr add 10.1.0.1/24 dev eth0
	ip link set con0 up
	ip netns exec $NS ip link set eth0 up
	ip netns exec $NS ip link set lo up

	ip netns exec $NS ip route add default via 10.1.0.10
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

function create_user_mapping() {
	echo "         0          0 4294967295" > /proc/${NS}/uid_map
	echo "         0          0 4294967295" > /proc/${NS}/gid_map
}

function configure_container() {
	export NS=$1

	create_user_mapping
	create_virtual_network
	configure_network

	touch $CONFIG_COMPLETED_LOCK_FILE
}

###########################################################################################
## Start Container
###########################################################################################
function prepare_mount() {
	# Create mount point
	mkdir_if_not_exists $HOST_MOUNT
	mkdir_if_not_exists $CON_MOUNT

	mount --make-shared --bind $HOST_MOUNT $CON_MOUNT

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

function start_container() {
	export CONTAINER_ID=$(generate_id)
	IMAGE_NAME=$1
	CMD=$2

	create_containter_directories $CONTAINER_ID
	set_container_paths $CONTAINER_ID
	echo $CMD > $CMD_FILE
	echo $IMAGE_NAME > $IMAGE_NAME_FILE

	info "Starting CMD: $CMD Container ID: $CONTAINER_ID Image: $IMAGE_NAME"
	prepare_container $IMAGE_NAME

	echo CMD: $CMD
	echo Container ID: $CONTAINER_ID

	# Create process that will complete the configuration once unshare has completed
	wait_for_unshare_process &

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
	if [ 0 -eq $(iptables -t nat -S | grep "N DOCKER" | wc -l) ]
	then
		iptables -t nat -A PREROUTING ! -i con0 -p tcp --dport $1 -j DNAT --to-destination 10.1.0.1:$2 -m comment --comment handBuildContainer
		iptables -t nat -A POSTROUTING -s 10.1.0.1/32 -d 10.1.0.1/32 -p tcp --dport $2 -j MASQUERADE -m comment --comment handBuildContainer
		iptables -A FORWARD -d 10.1.0.1/32 ! -i con0 -o con0 -p tcp --dport $2 -j ACCEPT -m comment --comment handBuildContainer
	else
		echo Expose doesn\'t work when Docker iptable entries are present
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

	echo "Installation of $VERSION has completed"
}

###########################################################################################
## Parse Arguments
###########################################################################################
create_directory_strcuture
case "$1" in
  start)
	if [ $# -ne 3 ]; then
		echo "Usage: $0 start <image file> <cmd>"
		exit 1
	fi
	start_container $2 "$3"
	;;
  stop)
    if [ $# -ne 2 ]; then
		echo "Usage: $0 stop <container id>"
		exit 1
    fi
    stop_container $2
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
		echo "Usage: $0 expose <host port> <container port>"
		exit 1
	fi
	expose_port $2 $3
	;;
  exec)
    if [ $# -ne 3 ]; then
		echo "Usage: $0 exec <container id> <cmd>"
        exit 1
    fi
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
  *) echo $"Usage: $0 {start|stop|exec|ps|clean|export}"
	 echo "start -> start new container"
	 echo "stop -> stop running container"
	 echo "ps -> list running containers"
	 echo "clean -> delete all inactive containers"
	 echo "export -> Create image from docker image"
     exit 1
esac

exit 0
