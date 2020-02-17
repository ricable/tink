#!/bin/bash

source functions.sh && init
set -o nounset

metadata=/metadata
curl -sSL --connect-timeout 60 https://metadata.packet.net/metadata > $metadata

# defaults
# shellcheck disable=SC2207
disks=($(lsblk -dno name -e1,7,11 | sed 's|^|/dev/|' | sort))
userdata='/dev/null'
arch=$(uname -m)
check_required_arg "$metadata" 'metadata file' '-M'
declare class && set_from_metadata class 'class' <"$metadata"
declare facility && set_from_metadata facility 'facility' <"$metadata"
declare os && set_from_metadata os 'operating_system.slug' <"$metadata"
declare tag && set_from_metadata tag 'operating_system.image_tag' <"$metadata" || tag=""


OS=$os${tag:+:$tag}
echo "Number of drives found: ${#disks[*]}"
if ((${#disks[*]} != 0)); then
        echo "Disk candidate check successful"
fi

custom_image=false
target="/mnt/target"
cprout=/statedir/cpr.json
# mkdir -p /statedir && touch /statedir/cpr.json

# custom
mkdir -p $target
mkdir -p $target/boot
echo "*********************************************in middle of custom"
mount -t efivarfs efivarfs /sys/firmware/efi/efivars
mount -t ext4 /dev/sdd3 $target
mount

if ! [[ -f /statedir/disks-partioned-image-extracted ]]; then
        assetdir=/tmp/assets
        OS=${OS%%:*}

        ls -l $assetdir

        # Kernel to throw on the target
        kernel="$assetdir/kernel.tar.gz"
        # Initrd to throw on the target
        initrd="$assetdir/initrd.tar.gz"
        # Modules to throw on the target
        modules="$assetdir/modules.tar.gz"
        # Image rootfs
        image="$assetdir/image.tar.gz"
        # Grub config
        BASEURL='http://192.168.1.2/misc/osie/current'
        grub="$BASEURL/grub/${OS//_(arm|image)//}/$class/grub.template"

        # Ensure critical OS dirs
        mkdir -p $target/{dev,proc,sys}
        mkdir -p $target/etc/mdadm

        if [[ $class != "t1.small.x86" ]]; then
                echo -e "${GREEN}#### Updating MD RAID config file ${NC}"
                mdadm --examine --scan >>$target/etc/mdadm/mdadm.conf
        fi

    # ensure unique dbus/systemd machine-id
        echo -e "${GREEN}#### Setting machine-id${NC}"
        rm -f $target/etc/machine-id $target/var/lib/dbus/machine-id

    systemd-machine-id-setup --root=$target
        cat $target/etc/machine-id
        [[ -d $target/var/lib/dbus ]] && ln -nsf /etc/machine-id $target/var/lib/dbus/machine-id

        # Install kernel and initrd
        echo -e "${GREEN}#### Copying kernel, modules, and initrd to target $target ${NC}"
        tar --warning=no-timestamp -zxf "$kernel" -C $target/boot
        kversion=$(vmlinuz_version $target/boot/vmlinuz)
        if [[ -z $kversion ]]; then
                echo 'unable to extract kernel version' >&2
                exit 1
        fi

    kernelname="vmlinuz-$kversion"
        if [[ ${OS} =~ ^centos ]] || [[ ${OS} =~ ^rhel ]]; then
                initrdname=initramfs-$kversion.img
                modulesdest=usr
        else
                initrdname=initrd.img-$kversion
                modulesdest=
        fi

    mv $target/boot/vmlinuz "$target/boot/$kernelname" && ln -nsf "$kernelname" $target/boot/vmlinuz
        tar --warning=no-timestamp -zxf "$initrd" && mv initrd "$target/boot/$initrdname" && ln -nsf "$initrdname" $target/boot/initrd
        tar --warning=no-timestamp -zxf "$modules" -C "$target/$modulesdest"
        cp "$target/boot/$kernelname" /statedir/kernel
        cp "$target/boot/$initrdname" /statedir/initrd

    # Install grub
        echo -e "${GREEN}#### Installing GRUB2${NC}"

        wget "$grub" -O /tmp/grub.template
        wget "${grub}.default" -O /tmp/grub.default

        mount -t vfat /dev/sdd1 $target/boot/efi

        ./grub-installer.sh -v -p "$class" -t "$target" -C "$cprout" -D /tmp/grub.default -T /tmp/grub.template

        rootuuid=$(jq -r .rootuuid $cprout)
        [[ -n $rootuuid ]]
        cmdline=$(sed -nr 's|GRUB_CMDLINE_LINUX='\''(.*)'\''|\1|p' /tmp/grub.default)


    echo -e "${GREEN}#### Clearing init overrides to enable TTY${NC}"
        rm -rf $target/etc/init/*.override

        if [[ $custom_image == false ]]; then
                echo -e "${GREEN}#### Setting up package repos${NC}"
                ./repos.sh -a "$arch" -t $target -f "$facility" -M "$metadata"
        fi
fi

