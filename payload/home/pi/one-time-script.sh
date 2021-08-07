#!/bin/bash
# Start script for unattended configuration of a Raspberry Pi
hname=raspberrypi
get_parameters() {
	# first the default values...
	new_partition_size_MB=100
	new_partition_label='logs'
	new_locale='en_GB.UTF-8'
	new_timezone='Europe/London'
	new_hostname_tag=''
	new_ssh_setting=0
	new_wifi_country=GB
	new_wifi_ssid="Our network"
	new_wifi_password="Secret"
	new_boot_behaviour=B4
	sd_card_number=XX

	# ...then see if values can be read from a file
	# then remove that (may contain password)
	# but save parameters for the next script back to the file
	cfgfile='/boot/one-time-script.conf'
	if [[ -f $cfgfile ]]; then
		while IFS='= ' read -r lhs rhs; do
			if [[ ! $lhs =~ ^\ *# && -n $lhs ]]; then	# skip comment-/malformed lines
				rhs="${rhs%%\#*}"    # Del end-of-line comments
				rhs="${rhs%"${rhs##*[^[:blank:]]}"}"  # Del trailing spaces/tabs
				rhs="${rhs%\"}"     # Del opening double-quotes 
				rhs="${rhs#\"}"     # Del closing double-quotes 
				rhs="${rhs%\'}"     # Del opening single-quotes 
				rhs="${rhs#\'}"     # Del closing single-quotes 
				declare -g $lhs="$rhs"
			fi
		done < $cfgfile && log "Read parameters from $cfgfile";
	else
		log "Using default parameters";
	fi;
}

# 2. DISK MANAGEMENT
disk_mgt() {
	# create another FAT32 partition
	ROOT_PART=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p')
	PART_NUM=${ROOT_PART#mmcblk0p}
	LAST_PARTITION=$(parted /dev/mmcblk0 -ms unit s p | tail -n 1 | tr -d 's')
	LAST_PART_NUM=$(echo "$LAST_PARTITION" | cut -f 1 -d:)
	if [[ "$PART_NUM" -ne 2 || $LAST_PART_NUM -ne 2 ]]; then
		log "Did not find the standard partition scheme. Aborting"
		return
	fi
	ROOT_PART_END=$(echo "$LAST_PARTITION" | cut -d ":" -f 3)
	ROOT_DEV_SIZE=$(cat /sys/block/mmcblk0/size)	
	if ((ROOT_PART_END + 2048*new_partition_size_MB >= ROOT_DEV_SIZE)); then
		log "Not enough free space for a $new_partition_size_MB MB partition. Aborting"
		return
	fi
	log -n "Create new FAT32 entry in the partition table: "
	fdisk /dev/mmcblk0 <<-END
	n
	p
	3
	$((ROOT_DEV_SIZE - 2048*new_partition_size_MB))
	$((ROOT_DEV_SIZE - 1))
	t
	3
	C
	w
	END
	[[ $? -eq 0 ]] && log OK || log FAILED

	# reload the partition table (needed on older kernels)
	partprobe /dev/mmcblk0;

	# format the new partition
	log -n "Format the new partition as FAT32: "
	mkfs.fat -F 32 -n $new_partition_label /dev/mmcblk0p3 && log OK || log FAILED;

	# make sure it is owned by user pi, so it can write to it
	log -n "Add the new partition to /etc/fstab for mounting at boot: "
	PART_UUID=$(grep vfat /etc/fstab | sed -E 's|^(\S+)\S .*|\1|;q')3 &&\
	echo "$PART_UUID  /$new_partition_label  vfat  defaults,uid=1000,gid=1000  0  2" >> /etc/fstab && log OK || log FAILED;

	# enlarge the ext4 partition and filesystem
	log -n "Make the ext4 partition take up the remainder of the SD card: "
	parted -m /dev/mmcblk0 u s resizepart 2 $((ROOT_DEV_SIZE-2048*new_partition_size_MB-1)) && log OK || log FAILED;
	log -n "Resize the ext4 file system to take up the full partition: "
	resize2fs /dev/mmcblk0p2 && log OK || log FAILED;
}

# 3. PI USER PROFILE SETUP
# doing this before OS config because until reboot, sudo is confused by a new hostname
user_profile() {
	chmod a+w $templog
	cd /tmp
	sudo -u pi /bin/bash <<-END
		echo -n "Unsetting executable-bits of hidden files: " >> $templog;
		find /home/pi -type f -name '.*' -exec chmod -x \{\} + && echo OK >> $templog || echo FAILED >> $templog;
		if [[ -f /home/pi/.ssh/authorized_keys ]]; then
			echo -n "Making authorized ssh keys private: " >> $templog;
			chmod 0600 /home/pi/.ssh/authorized_keys && chmod 0700 /home/pi/.ssh && echo OK >> $templog || echo FAILED >> $templog;
		fi;
	END
}

# 4. OPERATING SYSTEM CONFIGURATION
os_config() {
	log -n "Change timezone: "
	raspi-config nonint do_change_timezone "$new_timezone" && log OK || log FAILED;

	modelnr=$(sed -E 's/Raspberry Pi ([^ ]+).*/\1/' /proc/device-tree/model);
	serial=$(grep ^Serial /proc/cpuinfo | sed -E 's/^.*: .{10}//');
	[[ $new_hostname_tag ]] && hname="pi$modelnr-$new_hostname_tag-$serial" || hname="pi$modelnr-$serial";
	log -n "Set hostname to $hname: "


	#Write hostname to ip.txt
	echo $hname > /home/pi/ip.txt

	raspi-config nonint do_hostname "$hname" && log OK || log FAILED;

	log -n "Set SSH to "  # 0 = on, 1 = off
	[[ $new_ssh_setting == 0 ]] && log -n "on: " || log -n "off: ";
	raspi-config nonint do_ssh $new_ssh_setting && log OK || log FAILED;

	log -n "Set WiFi country: "
	raspi-config nonint do_wifi_country $new_wifi_country && log OK || log FAILED;

	log -n "Set WiFi login: "
	raspi-config nonint do_wifi_ssid_passphrase "$new_wifi_ssid" "$new_wifi_password" && log OK || log FAILED;

	log -n "Avoid language setting problems when logged in through SSH: "
	sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config && log OK || log FAILED;

	log -n "Change locale: "
	raspi-config nonint do_change_locale "$new_locale" && log OK || log FAILED;
}

# 5. WRITE SOME SYSTEM DATA TO A FILE ON /BOOT
write_card_file() {
	kernel_info=$(uname -a);
	debianv=$(cat /etc/debian_version);
	distro_name=$(lsb_release -ds 2>/dev/null);
	distro_code=$(sed -n -E 's/^.*stage([[:digit:]]).*$/\1/p' /boot/issue.txt 2>/dev/null);
	case $distro_code in
		1) distr=mimimal;;
		2) distr=lite;;
		3) distr="base-desktop";;
		4) distr="small-desktop";;
		5) distr=desktop;;
		*) distr="";;
	esac;
	card=$(cut -dx -f2 /sys/block/mmcblk0/device/serial);
	/bin/cat > "/boot/SD-card-$sd_card_number.txt" <<-END
		SD card nr $sd_card_number with serial number $card
		$distro_name $distr
		(Debian $debianv)
		$kernel_info
	END
	[[ $? -eq 0 ]] && log OK || log FAILED
}

# 6. Install packages, enable i2c, enable oled stats screen and clean up
install_packages() {

	#Install packages from /boot/package-list
	< /boot/package-list xargs sudo apt install -y

	#Write IP to ip.txt which is the file we upload to a fileshare if that's not uncommented
	hostname -I >> /home/pi/ip.txt

	#Upload txt file containing Hostname and IP to a local samba share
	#This uses the local IP of my ubuntu server which has a samba share, replace with your own IP and the credentials needed
	#If not, leave it uncommented
	#smbmap -H 192.168.1.114 --upload /home/pi/ip.txt fileshare/$hname.txt

	#Enable OLED stats script to launch at future bots
	sudo systemctl enable oled-stats.service

	#Enable i2c, set to 1 to disable
	sudo raspi-config nonint do_i2c 0

	#Pip install library needed for OLED screen to work
	sudo pip3 install adafruit-circuitpython-ssd1306

	#Remove the payload since all files and scripts are already moved/used at this point
	sudo rm -rf /boot/payload
	sudo rm /boot/one-time-script.conf /boot/package-list
	sudo rm /boot/unattended /home/pi/one-time-script.sh
	
	#Uncomment this to send a push notification with the IP to your phone if you're running gotify
	#curl -X POST "192.168.1.114/message?token=GOTIFYTOKEN" -F title="Pi configuration complete" -F message="$(hostname -I)"
	
}

# 1. INTERNAL SCRIPT BUSINESS
# logging of the script's run
logfile=configuration.log
templog=/dev/shm/$logfile
log() {
	echo "$@" >> $templog;
}
log "Unattended configuration by $0";
exec 2>>$templog;	# log all errors

# stop this service from running at boot again
log -n "Remove automatic running of config script: ";
systemctl disable one-time-script.service && log OK || log FAILED;

get_parameters

log $'\nDISK MANAGEMENT';
if (( $(cut /etc/debian_version -f1 -d.) >= 10 )) && (( new_partition_size_MB > 0 )); then
	disk_mgt
else
	# partitioning commands fail on Raspbian Stretch (9) and earlier;
	# use the built-in resizing script
	log -n "Expansion of the root partition: "
	raspi-config nonint do_expand_rootfs && log OK || log FAILED;
fi

log $'\nPI USER PROFILE SETUP';
user_profile # before os_config because until reboot, sudo is confused by a new hostname

log $'\nOPERATING SYSTEM CONFIGURATION';
os_config

log $'\nWRITE SOME SYSTEM DATA TO A FILE ON /BOOT';
write_card_file

# Write the log to the boot partition 
date > /boot/$logfile
cat $templog >> /boot/$logfile

#clean up and install packages
install_packages

sudo reboot

