#!/bin/bash

function wait_for_file() {
        while [ ! -f $1 ]
        do
                sleep 0.1
		echo -ne .
        done
}

echo -ne waiting
wait_for_file container.log
echo .
exec chroot $1 $2

