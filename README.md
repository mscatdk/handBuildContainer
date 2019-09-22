# Hand Build Container (hbc)

The purpose of this repository is to implement containers using generally available Linux commands. The current implementation support some of the most common features e.g. entering a running container.

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

### Start Simple Alpine Container

````bash
# Start Alpine container in interactive mode
sudo hbc start alpine /bin/sh

# Install tcpdump
apk update && apk add tcpdump

# Exit the container
exit

# Clean inactive containers
sudo hbc clean
````

### Control Group (cgroups)

The container registry contains the alpine image for both arm and amd64. Let's lunch a alpine container in daemon mode, limit the container memory usage to 50 MB and try to breach that limit. We will assume the container id is VpCokegzFqqlmUZ7bUlgzlBEs092B4vw in the following. You will need to update the below with your container id.

````bash
# Start alpine container in daemon mode that will sleep for 30000 [s]
sudo hbc start -d alpine "/bin/sleep 30000"

# List running containers
sudo hbc ps

# Limit the container memory usage to 50 MB using cgroups
sudo hbc memory VpCokegzFqqlmUZ7bUlgzlBEs092B4vw 50000000

# Enter the alpine container
sudo hbc exec VpCokegzFqqlmUZ7bUlgzlBEs092B4vw /bin/sh

# Install dev tools
apk update && apk add git build-base

# Checkout memory eater application
git clone https://github.com/mscatdk/memoryeater.git /tmp

# Compile the memory eater application
cd /tmp/c/ && gcc memoryeater.c -o memoryeater

# Try to allocate 100 MB in 10 MB increments (Should fail before reaching 50 MB)
./memoryeater -s 10 -m 100

# Exit the container
exit

# Stop the running container
sudo hbc stop VpCokegzFqqlmUZ7bUlgzlBEs092B4vw

# Clean inactive containers
sudo hbc clean
````

### Network

Let's have a look at the container network by starting a Nginx container and expose the port 80. We will assume the container id is VpCokegzFqqlmUZ7bUlgzlBEs092B4vw in the following. You will need to update the below with your container id.

````bash
# Start Nginx container
sudo hbc start -d nginx "nginx -g 'daemon off;'"

# Expose port 80 on the container as port 80 on the host
sudo hbc expose VpCokegzFqqlmUZ7bUlgzlBEs092B4vw 80 80

# Run curl towards localhost
curl localhost

# Run curl towards the machine IP (You will need to update the IP and you can also access the page from antoher machine)
curl 10.11.12.4

# Stop the nginx container
sudo hbc stop VpCokegzFqqlmUZ7bUlgzlBEs092B4vw

# Clean inactive containers
sudo hbc clean
````
