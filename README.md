# Hand Build Container (hbc)

The purpose of this repository is to implement containers using generally available Linux commands. The current implementation support some of the most common features e.g. post forwarding. However, you can currently only run one container at a time and port forwarding doesn't work in case the iptable entries created by e.g. Docker are present.

## Images

The following images are currently available

| Name | Command Example | arm | amd64 |
|---|---|---|---|
|Alpine|./hbc.sh start alpine /bin/sh|x|x|
|Nginx |./hbc.sh start nginx "nginx -g 'daemon off;'"| |x|
|Apache httpd|./hbc.sh start httpd "/usr/local/apache2/bin/httpd -DFOREGROUND"| |x|

## Installation
Run the following command to install the latest version

````bash
curl -s https://raw.githubusercontent.com/mscatdk/handBuildContainer/master/hbc.sh | sudo bash -s install
````

## User Guide

The repository contain the alpine image for both arm and amd64. Hence, let's start by lunching the alpine container with the command "/bin/sh"

````bash
sudo hbc start alpine /bin/sh

# Show network interfaces
ifconfig

# Start netcat for later use
nc -l -p 8888
````

Let's assume the container receive the id 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR. Let's open a new terminal and try the following:

````bash
# List running containers
sudo hbc ps

# Enter the running container
sudo hbc exec 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR /bin/sh

# Install tcpdump
apk update
apk add tcpdump

# exit the container
exit

# Expose port 8888 as port 9999 on the host
sudo hbc expose 9999 8888

# Point your browser on a different computer to host:9999
# You can alternatively run the following command
curl 10.1.0.1:8888  (Pres ctrl + c to exit)

# exit the container
exit

# Stop the running container
sudo hbc stop 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR

# Clean inactive containers
sudo hbc clean
````
