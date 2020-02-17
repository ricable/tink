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
declare preserve_data && set_from_metadata preserve_data 'preserve_data' false <"$metadata"
declare pwhash="5f4dcc3b5aa765d61d8327deb882cf99"
# declare pwhash && set_from_metadata pwhash 'password_hash' <"$metadata"
# declare state && set_from_metadata state 'state' <"$metadata"
declare tag && set_from_metadata tag 'operating_system.image_tag' <"$metadata" || tag=""
declare tinkerbell && set_from_metadata tinkerbell 'phone_home_url' <"$metadata"
declare deprovision_fast && set_from_metadata deprovision_fast 'deprovision_fast' false <"$metadata"

OS=$os${tag:+:$tag}
echo "Number of drives found: ${#disks[*]}"
if ((${#disks[*]} != 0)); then
        echo "Disk candidate check successful"
fi

custom_image=false
target="/mnt/target"
cprconfig=/tmp/config.cpr
cprout=/statedir/cpr.json
mkdir -p /statedir && touch /statedir/cpr.json

# custom
rm -rf /tmp/assets
rm /tmp/fstab.tmpl 
umount /mnt/target/boot/efi/
umount /mnt/target/

echo -e "${GREEN}#### Checking userdata for custom cpr_url...${NC}"
cpr_url=$(sed -nr 's|.*\bcpr_url=(\S+).*|\1|p' "$userdata")

if [[ -z ${cpr_url} ]]; then
	echo "Using default image since no cpr_url provided"
	jq -c '.storage' "$metadata" >$cprconfig
else
	echo "NOTICE: Custom CPR url found!"
	echo "Overriding default CPR location with custom cpr_url"
	if ! curl "$cpr_url" | jq . >$cprconfig; then
		phone_home "${tinkerbell}" '{"instance_id":"'"$(jq -r .id "$metadata")"'"}'
		echo "$0: CPR URL unavailable: $cpr_url" >&2
		exit 1
	fi
fi

stimer=$(date +%s)

# start of the big if
if ! [[ -f /statedir/disks-partioned-image-extracted ]]; then
        ## Fetch install assets via git
	assetdir=/tmp/assets
	mkdir $assetdir
	echo -e "${GREEN}#### Fetching image (and more) via git ${NC}"

	# config hosts entry so git-lfs assets are pulled through our image cache
	githost="images.packet.net"
	images_ip=$(getent hosts $githost | awk '{print $1}')
	cp -a /etc/hosts /etc/hosts.new
	echo "$images_ip        github-cloud.s3.amazonaws.com" >>/etc/hosts.new && cp -f /etc/hosts.new /etc/hosts
	echo -n "LFS pulls via github-cloud will now resolve to image cache:"
	getent hosts github-cloud.s3.amazonaws.com | awk '{print $1}'

	if [[ ${OS} =~ : && $custom_image == false ]]; then
		image_tag=$(echo "$OS" | awk -F':' '{print $2}')

		gitpath="packethost/packet-images.git"
		gituri="https://${githost}/${gitpath}"

		# TODO - figure how we can do SSL passthru for github-cloud to images cache
		git config --global http.sslverify false
	elif [[ $custom_image == true ]]; then
		if [[ ${image_repo} =~ github ]]; then
			git config --global http.sslverify false
		fi
		gituri="${image_repo}"
	fi

        ensure_reachable "$gituri"
	git -C $assetdir init
	git -C $assetdir remote add origin "${gituri}"
	git -C $assetdir fetch origin
	git -C $assetdir checkout "${image_tag}"

	OS=${OS%%:*}

        ## Assemble configurables
	##
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
        
	echo -e "${WHITE}Image: $image${NC}"
	echo -e "${WHITE}Modules: $modules${NC}"
	echo -e "${WHITE}Kernel: $kernel${NC}"
	echo -e "${WHITE}Initrd: $initrd${NC}"
	echo -e "${WHITE}Devices:${disks[*]}${NC}"
	echo -e "${WHITE}CPR: ${NC}"
	jq . $cprconfig

        # make sure the disks are ok to use
	assert_block_or_loop_devs "${disks[@]}"
	assert_same_type_devs "${disks[@]}"

        is_uefi && uefi=true || uefi=false

        if [[ $deprovision_fast == false ]] && [[ $preserve_data == false ]]; then
		echo -e "${GREEN}Checking disks for existing partitions...${NC}"
		if fdisk -l "${disks[@]}" 2>/dev/null | grep Disklabel >/dev/null; then
			echo -e "${RED}Critical: Found pre-exsting partitions on a disk. Aborting install...${NC}"
			fdisk -l "${disks[@]}"
			exit 1
		fi
	fi

        echo "Disk candidates are ready for partitioning."

        echo -e "${GREEN}#### Running CPR disk config${NC}"
	UEFI=$uefi ./cpr.sh $cprconfig "$target" "$preserve_data" "$deprovision_fast" | tee $cprout

	mount | grep $target

        # custom
	rm $assetdir/*gz
    wget $BASEURL/github/image.tar.gz -P $assetdir
	wget $BASEURL/github/kernel.tar.gz -P $assetdir
	wget $BASEURL/github/initrd.tar.gz -P $assetdir
	wget $BASEURL/github/modules.tar.gz -P $assetdir


        echo -e "${GREEN}#### Retrieving image archive and installing to target $target ${NC}"
	tar --xattrs --acls --selinux --numeric-owner --same-owner --warning=no-timestamp -zxpf "$image" -C $target

	# dump cpr provided fstab into $target
	jq -r .fstab "$cprout" >$target/etc/fstab

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

	# custom
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars

	./grub-installer.sh -v -p "$class" -t "$target" -C "$cprout" -D /tmp/grub.default -T /tmp/grub.template

	rootuuid=$(jq -r .rootuuid $cprout)
	[[ -n $rootuuid ]]
	cmdline=$(sed -nr 's|GRUB_CMDLINE_LINUX='\''(.*)'\''|\1|p' /tmp/grub.default)

	cat <<EOF >/statedir/cleanup.sh
#!/bin/sh

kexec -l ./kernel --initrd=./initrd --command-line="BOOT_IMAGE=/boot/vmlinuz root=UUID=$rootuuid ro $cmdline" || reboot
kexec -e || reboot
EOF

        echo -e "${GREEN}#### Clearing init overrides to enable TTY${NC}"
	rm -rf $target/etc/init/*.override

	if [[ $custom_image == false ]]; then
		echo -e "${GREEN}#### Setting up package repos${NC}"
		./repos.sh -a "$arch" -t $target -f "$facility" -M "$metadata"
	fi

	echo -e "${GREEN}#### Configuring cloud-init for Packet${NC}"
	if [ -f $target/etc/cloud/cloud.cfg ]; then
		case ${OS} in
		centos* | rhel* | scientific*) repo_module=yum-add-repo ;;
		debian* | ubuntu*) repo_module=apt-configure ;;
		esac

		cat <<-EOF >$target/etc/cloud/cloud.cfg
			apt:
			  preserve_sources_list: true
			datasource_list: [Ec2]
			datasource:
			  Ec2:
			    timeout: 60
			    max_wait: 120
			    metadata_urls: [ 'https://metadata.packet.net' ]
			    dsmode: net
			disable_root: 0
			package_reboot_if_required: false
			package_update: false
			package_upgrade: false
			phone_home:
			  url: ${tinkerbell}/phone-home
			  post:
			    - instance_id
			  tries: 5
			ssh_genkeytypes: ['rsa', 'dsa', 'ecdsa', 'ed25519']
			ssh_pwauth:   0
			cloud_init_modules:
			 - migrator
			 - bootcmd
			 - write-files
			 - growpart
			 - resizefs
			 - update_hostname
			 - update_etc_hosts
			 - users-groups
			 - rsyslog
			 - ssh
			cloud_config_modules:
			 - mounts
			 - locale
			 - set-passwords
			 ${repo_module:+- $repo_module}
			 - package-update-upgrade-install
			 - timezone
			 - puppet
			 - chef
			 - salt-minion
			 - mcollective
			 - runcmd
			cloud_final_modules:
			 - phone-home
			 - scripts-per-once
			 - scripts-per-boot
			 - scripts-per-instance
			 - scripts-user
			 - ssh-authkey-fingerprints
			 - keys-to-console
			 - final-message
		EOF
		echo "Disabling cloud-init based network config via cloud.cfg.d include"
		echo "network: {config: disabled}" >$target/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
		echo "WARNING: Removing /var/lib/cloud/*"
		rm -rf $target/var/lib/cloud/*
	else
		echo "Cloud-init post-install -  default cloud.cfg does not exist!"
	fi

	if [ -f $target/etc/cloud/cloud.cfg.d/90_dpkg.cfg ]; then
		cat <<EOF >$target/etc/cloud/cloud.cfg.d/90_dpkg.cfg
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ Ec2 ]
EOF
	fi

	if [ -f $target/etc/init/cloud-init-nonet.conf ]; then
		sed -i 's/dowait 120/dowait 1/g' $target/etc/init/cloud-init-nonet.conf
		sed -i 's/dowait 10/dowait 1/g' $target/etc/init/cloud-init-nonet.conf
	else
		echo "Cloud-init post-install - cloud-init-nonet does not exist. skipping edit"
	fi

	# Inform the API about cloud-init complete
# 	phone_home "${tinkerbell}" '{"type":"provisioning.108"}'

	# Adjust failsafe delays for first boot delay
	if [[ -f $target/etc/init/failsafe.conf ]]; then
		sed -i 's/sleep 59/sleep 10/g' $target/etc/init/failsafe.conf
		sed -i 's/Waiting up to 60/Waiting up to 10/g' $target/etc/init/failsafe.conf
	fi


	# custom 
	mkdir /home/packet
	# wget http://147.75.97.234/misc/tinkerbell/workflow/packet-block-storage-attach -P /home/packet
	# wget http://147.75.97.234/misc/tinkerbell/workflow/packet-block-storage-detach -P /home/packet

	wget $BASEURL/github/packet-block-storage-attach -P /home/packet
	wget $BASEURL/github/packet-block-storage-detach -P /home/packet

	echo -e "${GREEN}#### Run misc post-install tasks${NC}"
	install -m755 -o root -g root /home/packet/packet-block-storage-* $target/usr/bin
	if [ -f $target/usr/sbin/policy-rc.d ]; then
		echo "Removing policy-rc.d from target OS."
		rm -f $target/usr/sbin/policy-rc.d
	fi

	echo -e "${GREEN}#### Adding network perf tuning${NC}"
	cat >>$target/etc/sysctl.conf <<EOF
# set default and maximum socket buffer sizes to 12MB
net.core.rmem_default=$((12 * 1024 * 1024))
net.core.wmem_default=$((12 * 1024 * 1024))
net.core.rmem_max=$((12 * 1024 * 1024))
net.core.wmem_max=$((12 * 1024 * 1024))

# set minimum, default, and maximum tcp buffer sizes (10k, 87.38k (linux default), 12M resp)
net.ipv4.tcp_rmem=$((10 * 1024)) 87380 $((12 * 1024 * 1024))
net.ipv4.tcp_wmem=$((10 * 1024)) 87380 $((12 * 1024 * 1024))

# Enable TCP westwood for kernels greater than or equal to 2.6.13
net.ipv4.tcp_congestion_control=westwood
EOF

	# Disable GSSAPIAuthentication to speed up SSH logins
	sed -i 's/GSSAPIAuthentication yes/GSSAPIAuthentication no/g' $target/etc/ssh/sshd_config

	# Setup defaul grub for packet serial console
	echo -e "${GREEN}#### Adding packet serial console${NC}"
	touch $target/etc/inittab
	echo "s0:2345:respawn:/sbin/agetty ttyS1 115200" >>$target/etc/inittab

	mkdir -p $target/etc/init
	cat <<EOF_tty >$target/etc/init/ttyS1.conf
#
# This service maintains a getty on ttyS1 from the point the system is
# started until it is shut down again.
start on stopped rc or RUNLEVEL=[12345]
stop on runlevel [!12345]
respawn
exec /sbin/agetty ttyS1 115200
EOF_tty

fi
# end of the big if

echo -e "${GREEN}#### Setting root password${NC}"
set_root_pw "$pwhash" $target/etc/shadow

# ensure unique dbus/systemd machine-id, will be based off of container_uuid aka instance_id
echo -e "${GREEN}#### Setting machine-id${NC}"
rm -f $target/etc/machine-id $target/var/lib/dbus/machine-id
systemd-machine-id-setup --root=$target
cat $target/etc/machine-id
[[ -d $target/var/lib/dbus ]] && ln -nsf /etc/machine-id $target/var/lib/dbus/machine-id

## End installation
etimer=$(date +%s)
echo -e "${BYELLOW}Install time: $((etimer - stimer))${NC}"

# Bypass kexec for certain OS plan combos
if [[ ${OS} =~ ubuntu_18_04 && ${class} == t1.small.x86 ]]; then
	echo -en '#!/bin/sh\nreboot\n' >/statedir/cleanup.sh
elif [[ ${OS} =~ ubuntu_18_04 && ${class} == c1.bloomberg.x86 ]]; then
	echo -en '#!/bin/sh\nreboot\n' >/statedir/cleanup.sh
elif [[ ${class} == c2.medium.x86 ]]; then
	echo -en '#!/bin/sh\nreboot\n' >/statedir/cleanup.sh
elif [[ ${class} == c3.medium.x86 ]]; then
	echo -en '#!/bin/sh\nreboot\n' >/statedir/cleanup.sh
fi

chmod +x /statedir/cleanup.sh
