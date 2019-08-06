#!/bin/bash

function wait_for_file() {
        while [ ! -f $1 ]
        do
                sleep 0.1
		echo -ne .
        done
}

# Wait until configuration has been completed by waiting for the creation of /.locks/config_completed.lock
echo -ne waiting
wait_for_file $1
echo .

# Set hostname
chroot $2 /bin/hostname hbc

# Execute cmd
exec chroot $2 "${@:3}"
