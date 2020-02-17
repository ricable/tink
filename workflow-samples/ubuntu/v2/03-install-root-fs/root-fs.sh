#!/bin/bash

source functions.sh && init
set -o nounset

# TODO: should come from ephemeral data
metadata=/metadata
curl -sSL --connect-timeout 60 https://metadata.packet.net/metadata > $metadata
declare os && set_from_metadata os 'operating_system.slug' <"$metadata"
declare tag && set_from_metadata tag 'operating_system.image_tag' <"$metadata" || tag=""

target="/mnt/target"
OS=$os${tag:+:$tag}

if ! [[ -f /statedir/disks-partioned-image-extracted ]]; then
    ## Fetch install assets via git
    assetdir=/tmp/assets
    mkdir $assetdir
    echo -e "${GREEN}#### Fetching image for ${OS//_(arm|image)} root fs  ${NC}"
    OS=${OS%%:*}

    # Image rootfs
    image="$assetdir/image.tar.gz"

    # TODO: should come as ENV
    BASEURL='http://192.168.1.2/misc/osie/current'

    # custom
    wget "$BASEURL/${OS//_(arm|image)//}/image.tar.gz" -P $assetdir

    mkdir -p $target
    mount -t ext4 /dev/sdd3 $target
    echo -e "${GREEN}#### Retrieving image and installing to target $target ${NC}"
    tar --xattrs --acls --selinux --numeric-owner --same-owner --warning=no-timestamp -zxpf "$image" -C $target
    echo -e "${GREEN}#### Success installing root fs ${NC}"   
fi

