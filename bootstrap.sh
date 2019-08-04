#!/bin/bash

function wait_for_file() {
        while [ ! -f $1 ]
        do
                sleep 0.1
		echo -ne .
        done
}

echo -ne waiting
wait_for_file $1
echo .
exec chroot $2 "${@:3}"