#!/bin/bash

source functions.sh && init
set -o nounset

# TODO: repeated
metadata=/metadata
custom_image=false
target="/mnt/target"
cprout=/statedir/cpr.json
# mkdir -p /statedir && touch /statedir/cpr.json
curl -sSL --connect-timeout 60 https://metadata.packet.net/metadata > $metadata
declare class && set_from_metadata class 'class' <"$metadata"
declare os && set_from_metadata os 'operating_system.slug' <"$metadata"
declare tag && set_from_metadata tag 'operating_system.image_tag' <"$metadata" || tag=""
OS=$os${tag:+:$tag}

if ! [[ -f /statedir/disks-partioned-image-extracted ]]; then
    ## Fetch install assets via git
    assetdir=/tmp/assets
    # mkdir $assetdir
    echo -e "${GREEN}#### Fetching image (and more) via git ${NC}"

    # config hosts entry so git-lfs assets are pulled through our image cache
    # githost="images.packet.net"
    # images_ip=$(getent hosts $githost | awk '{print $1}')
    # cp -a /etc/hosts /etc/hosts.new
    # echo "$images_ip        github-cloud.s3.amazonaws.com" >>/etc/hosts.new && cp -f /etc/hosts.new /etc/hosts
    # echo -n "LFS pulls via github-cloud will now resolve to image cache:"
    # getent hosts github-cloud.s3.amazonaws.com | awk '{print $1}'

    # if [[ ${OS} =~ : && $custom_image == false ]]; then
    #         image_tag=$(echo "$OS" | awk -F':' '{print $2}')

    #         gitpath="packethost/packet-images.git"
    #         gituri="https://${githost}/${gitpath}"

    #         # TODO - figure how we can do SSL passthru for github-cloud to images cache
    #         git config --global http.sslverify false
    # elif [[ $custom_image == true ]]; then
    #         if [[ ${image_repo} =~ github ]]; then
    #                 git config --global http.sslverify false
    #         fi
    #         gituri="${image_repo}"
    # fi

    # ensure_reachable "$gituri"
    # git -C $assetdir init
    # git -C $assetdir remote add origin "${gituri}"
    # git -C $assetdir fetch origin
    # git -C $assetdir checkout "${image_tag}"

    OS=${OS%%:*}

    ## Assemble configurables
    # Kernel to throw on the target
    kernel="$assetdir/kernel.tar.gz"
    # Initrd to throw on the target
    initrd="$assetdir/initrd.tar.gz"
    # Modules to throw on the target
    modules="$assetdir/modules.tar.gz"
    # Image rootfs
    image="$assetdir/image.tar.gz"

#    mkdir /assets
    cp -a $assetdir/*.gz /assets/

    # Grub config

    # TODO: should come as ENV
    BASEURL='http://192.168.1.2/misc/osie/current'
    grub="$BASEURL/grub/${OS//_(arm|image)//}/$class/grub.template"

    echo -e "${WHITE}Image: $image${NC}"
    echo -e "${WHITE}Modules: $modules${NC}"
    echo -e "${WHITE}Kernel: $kernel${NC}"
    echo -e "${WHITE}Initrd: $initrd${NC}"
    # echo -e "${WHITE}Devices:${disks[*]}${NC}"
    echo -e "${WHITE}CPR: ${NC}"

    # custom
    #wget "$BASEURL/${OS//_(arm|image)//}/image.tar.gz" -P $assetdir
    #wget "$BASEURL/${OS//_(arm|image)//}/kernel.tar.gz" -P $assetdir
    #wget "$BASEURL/${OS//_(arm|image)//}/initrd.tar.gz" -P $assetdir
    #wget "$BASEURL/${OS//_(arm|image)//}/modules.tar.gz" -P $assetdir

    mkdir -p $target
    mount -t ext4 /dev/sdd3 $target

    ls -l $assetdir
    echo -e "${GREEN}#### Retrieving image archive and installing to target $target ${NC}"
    tar --xattrs --acls --selinux --numeric-owner --same-owner --warning=no-timestamp -zxpf "$image" -C $target

    echo -e "${GREEN}#### Fetching assets complete ${NC}"   

fi

