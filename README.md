# Hand Build Container (hbc)

The purpose of this repository is to implement containers using generally available Linux commands. The current implementation support some of the most common features e.g. post forwarding. However, you can currently only run one container at a time and port forwarding doesn't work in case the iptable entries created by e.g. Docker are present.

## User Guide

The repository contain the alpine image for both arm and amd64. Hence, let's start by lunching the alpine container with the command "/bin/sh"

````bash
sudo ./hbc.sh start alpine-amd64.tar /bin/sh

# Show network interfaces
ifconfig

# Start netcat for later use
nc -l -p 8888
````

Let's assume the container receive the id 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR. Let's open a new terminal and try the following:

````bash
# List running containers
sudo ./hbc.sh ps

# Enter the running container
sudo ./hbc.sh exec 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR /bin/sh

# Install tcpdump
apk update
apk add tcpdump

# exit the container
exit

# Expose port 8888 as port 9999 on the host
sudo ./hbc.sh expose 9999 8888

# Point your browser on a different computer to host:9999
# You can alternatively run the following command
curl 10.1.0.1:8888  (Pres ctrl + c to exit)

# Stop the running container
sudo ./hbc.sh stop 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR

# Clean inactive containers
sudo ./hbc.sh clean
````
