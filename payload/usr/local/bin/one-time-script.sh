#!/bin/bash
# Start script for unattended configuration of a Raspberry Pi
#
# Since this script has a NASTY habit of quietly crashing and losing
# the logs, it's very hard to debug.   Logging is critical.
#
# 10/22/20  I'm about done messing with this brittle script.  It seems
# that a single error in the chain of events and it just STOPS DEAD.  I 
# really miss python's try:except:finally: blocks here.   At this point
# I have the core features I care about set.  If I start with a built-up
# RaspberryPi install, then I only need to use this script to tweak a 
# few things at most.  The rest is just a house of cards.

get_parameters() {
	# first the default values...
	new_partition_size_MB=100
	new_partition_label='LOGS'
	new_locale='en_US.UTF-8'
	new_timezone='America/Los_Angeles'
	new_hostname_tag=''
	new_ssh_setting=0
	new_wifi_country=US
	new_wifi_ssid="Our network"
	new_wifi_password="Secret"
	new_boot_behaviour=B1
	sd_card_number=XX
	packages_to_install=''
	node_js_source_url=""

	# ...then see if values can be read from a file
	# then remove that (may contain password)
	# but save parameters for the next script back to the file
	cfgfile='/boot/one-time-script.conf';
	if [[ -f $cfgfile ]] 
	then
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
		echo "node_js_source_url='$node_js_source_url'" >> $cfgfile;
		echo "packages_to_install=($packages_to_install)" >> $cfgfile;
	else
		log "Using default parameters";
	fi;
}

# 2. DISK MANAGEMENT
disk_mgt() {
	# create another FAT32 partition
	ROOT_PART=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p');
	PART_NUM=${ROOT_PART#mmcblk0p};
	LAST_PARTITION=$(parted /dev/mmcblk0 -ms unit s p | tail -n 1 | tr -d 's');
	LAST_PART_NUM=$(echo "$LAST_PARTITION" | cut -f 1 -d:);
	log $'\nlsblk:';
	lsblk;
	log $'\nblkid:';
	blkid;
	log $'\ndf -a:';
	df -a;
	log $'\nparted -l:';
	parted -l;
	if [[ "$PART_NUM" -ne 2 || $LAST_PART_NUM -ne 2 ]] 
	then
		log "Did not find the standard partition scheme. Looking into it...";
		if [[ -d /$new_partition_label ]]
		then
			log 'Parition 3 is mounted under new partition label. Exiting.';
			return
		else
			log 'partition label not mounted. Will attempt fix.';
		fi		
		
		if (PART_UUID=$(grep vfat /etc/fstab | sed -E 's|^(\S+)\S .*|\1|;q')3); 
		then 
			log 'However partition 3 does exist in the table.'; 
		else
			log 'partition 3 does not exist.  Weird. Abort!';
		    return
		fi
	else		 # only 2 partitions, create the third
		ROOT_PART_END=$(echo "$LAST_PARTITION" | cut -d ":" -f 3);
		ROOT_DEV_SIZE=$(cat /sys/block/mmcblk0/size);
		if ((ROOT_PART_END + 2048*new_partition_size_MB >= ROOT_DEV_SIZE)); 
		then
			log "Not enough free space for a $new_partition_size_MB MB partition. Aborting";
			return
		fi
	
		log -n "Using FDISK to create new FAT32 entry in the partition table: ";
		log -n "NOTE: This only works if you started with a BLANK card.";
		# I THINK you need to have a freshly formatted card for this to work!!!
		#
		# The following gets tripped up super easy if there are mor ethan 2 partitions
		# or if the moon is out of phase or if there is remnants of the partiion 
		# from a prior attempt.	 Then everything else in this script just hangs up!
		#	You'll get the error:  Partition #3 contains a vfat signature.
		#	and you have to "Y w" (remove and write and then start over, or "d 3" to delete
		# Explanation of next step:
		# n, add new partition	 p, primary,  3 (partition number...only works on bootup)
		# t, change part type, 3 (part#), C = W95 FAT32, w (write table and exit) 
		fdisk /dev/mmcblk0 <<-FDEND
		n
		p
		3
		$(($ROOT_DEV_SIZE - 2048 * $new_partition_size_MB))
		$(($ROOT_DEV_SIZE - 1))
		t
		3
		C
		w
		FDEND
		# instead could we use:   parted /dev/mmcblk0 mkpart primary fat32 <start> <end>
		# here-document EOF has to be at beginnign of line without spaces or trailing spaces
		[[ $? -eq 0 ]] && log PARTITION_CREATION_OK || log PARTITION_CREATION_FAILED;
		
		# reload the partition table (needed on older kernels)
		partprobe /dev/mmcblk0;
		log "partprobe was a success.";
	fi
	
	# We have 3 partitions, but it's not in /etc/fstab or mounted.
	# format the new partition
	log -n "Format the new partition as FAT32: ";
	mkfs.fat -F 32 -n $new_partition_label /dev/mmcblk0p3 && log OK || log FAILED;

	# make sure it is owned by user pi, so it can write to it
	log -n "Add the new partition to /etc/fstab for mounting at boot: ";
	PART_UUID=$(grep vfat /etc/fstab | sed -E 's|^(\S+)\S .*|\1|;q')3 &&\
	echo "$PART_UUID  /$new_partition_label  vfat  defaults,uid=1000,gid=1000  0  2" >> /etc/fstab && log OK || log FAILED;

	# enlarge the ext4 partition and filesystem
	log $'Make the ext4 partition take up the remainder of the SD card:\n';
	log $(parted -l);
	ROOT_DEV_SIZE=$(cat /sys/block/mmcblk0/size);
	parted -m /dev/mmcblk0 u s resizepart 2 $(($ROOT_DEV_SIZE - 2048*new_partition_size_MB - 1)) && log OK || log FAILED;
	log $(parted -l);
	log $'Resize the ext4 file system to take up the full partition:\n';
	#e2fsck -f /dev/mmcblk0p2 && log _CLEANED || log FAILED_CLEAN   # must unmount to clean
	resize2fs /dev/mmcblk0p2 && log RESIZED_OK || log FAILED_RESIZE;
	log -n "Completed disk management operations.";
	log $'\nlsblk:';
	lsblk;
	log $'\nblkid:';
	blkid;
	log $'\ndf -a:';
	df -a;
	log $'\nparted -l:';
	parted -l;
}

# 3. PI USER PROFILE SETUP
# doing this before OS config because until reboot, sudo is confused by a new hostname
user_profile() {
	# this line seems to hang the script sometimes.	 And only .nanorc seems
	# to be copied over as executable.
	log "Unsetting executable-bits of hidden files in /home/pi";
	log $(find /home/pi -type f -name '.*' -exec chmod -x \{\} \;);
	log "Completed setting permissions for /home/pi files.";
}

# 4. OPERATING SYSTEM CONFIGURATION
os_config() {
   
	CURRENT_USER=whoami
	log 'Running os_config as user: ';
	log $(whoami);
	
	log -n "Set WiFi country: ";
	raspi-config nonint do_wifi_country $new_wifi_country && log OK || log FAILED;

	log -n "Set WiFi login: ";
	raspi-config nonint do_wifi_ssid_passphrase "$new_wifi_ssid" "$new_wifi_password" && log OK || log FAILED;
	
	log -n "Set SSH to ";  # 0 = on, 1 = off
	[[ $new_ssh_setting == 0 ]] && log -n "on: " || log -n "off: ";
	raspi-config nonint do_ssh $new_ssh_setting && log OK || log FAILED;
	
	log -n "Avoid language setting problems when logged in through SSH: ";
	sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config && log OK || log FAILED;

	log -n "Set standard boot to text console without auto-login: ";
	raspi-config nonint do_boot_behaviour $new_boot_behaviour && log OK || log FAILED;
	
	log -n "Change timezone to: ";
	log -n "$new_timezone";
	log -n "  ";
	raspi-config nonint do_change_timezone "$new_timezone" && log OK || log FAILED;

	log -n "Change locale: ";
	raspi-config nonint do_change_locale "$new_locale" && log OK || log FAILED;
	log -n "Change locale through other means.";
	locale-gen "$new_locale";
	update-locale "$new_locale";
	
	modelnr=$(sed -E 's/Raspberry Pi ([^ ]+).*/\1/' /proc/device-tree/model);
	serial=$(grep ^Serial /proc/cpuinfo | sed -E 's/^.*: .{10}//');
	[[ $new_hostname_tag ]] && hname="$new_hostname_tag-pi$modelnr-$serial" || hname="pi$modelnr-$serial";
	log -n "Set hostname to $hname: ";
	raspi-config nonint do_hostname "$hname" && log OK || log FAILED;

	log -n 'os_config section is complete.';	
}

# 5. WRITE SOME SYSTEM DATA TO A FILE ON /BOOT
write_card_file() {
	kernel_info=$(uname -a);    # this will write OLD host name.  Needs a reboot to be correct
	host_name=$(hostname);
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
	cat > "/boot/SD-card-$sd_card_number.txt" <<-SDEND
		SD card nr $sd_card_number with serial number $card
		$distro_name $distr
		(Debian $debianv)
		$kernel_info
		On reboot, host will become $host_name
		SDEND
	[[ $? -eq 0 ]] && log OK || log FAILED;
	log -n 'write_card_file section complete.'
}


# -----------------------IT ALL STARTS HERE -------------------------
# 1. INTERNAL SCRIPT BUSINESS
# logging of the script's run
# I found when this script crashed, it would lose all log data in /dev/shm
# /dev/shm is shared memory and does not persist
logfile=config_onetime.log;
#templog=/dev/shm/$logfile;         # not used
bootlog=/boot/$logfile
log() {
	#echo "$@" >> $templog;
	echo "$@" >> $bootlog;
}
# log all errors    was #exec 2>>$bootlog;	
# but this should capture all output to bootlog
exec >> $bootlog 2>&1

log $'\n\n----------------------------------------------------------\n'
## make sure it runs only after time synchronization (to avoid apt update errors)
# alternative --> sudo date --set='TZ="America/Chicago" 8 Oct 2017 14:32'
systemctl enable systemd-time-wait-sync && log TIME_SYNC_ON || log TIME_SYNC_FAILED
log $(date);

log "Unattended one-time configuration by $0";

log $'\n\nLOADING PARAMETERS'
get_parameters;

log $'\n\nDISK MANAGEMENT';
if (( $(cut /etc/debian_version -f1 -d.) >= 10 )) && (( new_partition_size_MB > 0 ))
then
	disk_mgt
else
	# partitioning commands fail on Raspbian Stretch (9) and earlier;
	# use the built-in resizing script
	log -n "Wrong debian version, only doing expansion of the root partition: ";
	raspi-config nonint do_expand_rootfs && log OK || log FAILED;
fi

log $'\n\nPI USER PROFILE SETUP';
# before os_config because until reboot, sudo is confused by a new hostname
user_profile

log $'\n\nOPERATING SYSTEM CONFIGURATION';
os_config

log $'\n\nWRITE SOME SYSTEM DATA TO A FILE ON boot';
write_card_file

# stop this service from running at boot again   -- 
# MOVED TO END OF SCRIPT..which only works if packages-script manages itself
# THIS MAKES THE SCRIPT EXECUTE 2 times...which is what it seems to take
# to get raspi-config to work.
log $'\nRemove automatic running of config script: ';
systemctl disable one-time-script.service && log OK || log FAILED;
systemctl disable systemd-time-wait-sync && log TIME_SYNC_OFF || log TIME_SYNC_FAILED

## prepare for the package installation script to run on the next boot
## This script has its own shutdown logic.
#log -n "Set up automatic running of package installation script on next reboot: ";
#systemctl enable packages-script.service && log OK || log FAILED;

# Write the log to the boot partition 
log $'\n\nREBOOTING NOW';
log $(date);
log $'\n----------------------------------------------------------\n'
# cat $templog >> /boot/$logfile;
# cat $templog >> /$new_partition_label/$logfile;

reboot
