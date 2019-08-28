# Hand Build Container (hbc)

The purpose of this repository is to implement containers using generally available Linux commands. The current implementation support some of the most common features e.g. entering a running container. However, the following limitations exists:

* Containers can only be run in interactive mode.

* Port forwarding doesn't work when Docker iptable entries are present.

## Images

The following images are currently available

| Name | Command Example | arm | amd64 |
|---|---|---|---|
|Alpine|hbc start alpine /bin/sh|x|x|
|Nginx |hbc start nginx "nginx -g 'daemon off;'"| |x|
|Apache httpd|hbc start httpd "/usr/local/apache2/bin/httpd -DFOREGROUND"| |x|

## Installation

Run the following command to install the latest version

````bash
curl -s https://raw.githubusercontent.com/mscatdk/handBuildContainer/master/hbc.sh | sudo bash -s install
````

## Testing

Tested on the following Linux distributions

| OS Name | Versions | Comments |
|---|---|---|
| Red Hat (rhel) | 8.0 | |
| CentOS | 7 |  |
| Suse (sles) | 15.1 | |
| Debian | 9 (stretch) | |
| Ubuntu | 18.04.2 LTS | |
| Raspbian | 9 (stretch) | |

## User Guide

The repository contain the alpine image for both arm and amd64. Hence, let's start by lunching the alpine container with the command "/bin/sh"

````bash
sudo hbc start alpine /bin/sh

# Show network interfaces
ifconfig

# Start netcat for later use
nc -l -p 8888
````

Let's assume the container receive the id 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR (You will need to replace it below with our own container id). Let's open a new terminal and try the following:

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
sudo hbc expose 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR 9999 8888

# Point your browser on a different computer to host:9999
# You can alternatively run the following command (you may need to change the IP based on the IP assigned your container)
curl 10.3.0.2:8888  (Pres ctrl + c to exit)

# Stop the running container
sudo hbc stop 4UkcTplBHob0OSWSPz00tYNuiMT7qmTR

# Clean inactive containers
sudo hbc clean
````