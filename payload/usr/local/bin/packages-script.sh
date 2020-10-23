#!/bin/bash
# Start script for unattended package installation on a Raspberry Pi

# -----------------------IT ALL STARTS HERE -------------------------
# 1. INTERNAL SCRIPT BUSINESS
# logging of the script's run
# I found when this script crashed, it would lose all log data in /dev/shm
# /dev/shm is shared memory and does not persist.  /boot is accessible on card
# from other devices, too
logfile=config_packages.log;
bootlog=/boot/$logfile;          
log() {
	#echo "$@" >> $templog;
	echo "$@" >> $bootlog;
}

log $'\n\n----------------------------------------------------------\n'
systemctl enable systemd-time-wait-sync && log TIME_SYNC_ON || log TIME_SYNC_FAILED;
log $(date);
log "Unattended package installation by $0";
# log all errors    was #exec 2>>$bootlog;	
# but this should capture all output to bootlog
exec >> $bootlog 2>&1

# parameters - first the default values...
node_js_source_url="";
packages_to_install=();

# ...then see if values can be read from a file, then remove that (may contain password)
[[ -f /boot/one-time-script.conf ]] && source /boot/one-time-script.conf &&\
 rm -f /boot/one-time-script.conf &&\
 log "Read parameters from /boot/one-time-script.conf" || log "Using default parameters";

# 6. PACKAGE INSTALLATION
log $'\nPACKAGE INSTALLATION';
export DEBIAN_FRONTEND=noninteractive;	# avoid debconf error messages

log -n "Update APT package lists: "
apt-get update && log OK || log FAILED;

if [[ $node_js_source_url ]]; then
	log -n "Install nodejs: "
	curl -sL "$node_js_source_url" | bash - && apt-get install -y nodejs && log OK || log FAILED;
fi;

if [[ $packages_to_install ]]; then
	log -n "Install ${packages_to_install[0]}";
	for x in "${packages_to_install[@]:1}"; do
		log -n ", $x";
	done;
	log -n ": ";
	apt-get install -y "${packages_to_install[@]}" && log OK || log FAILED;
fi;

# Append to the log on the boot partition 
# stop this service from running at boot again
log $'Remove automatic running of package installation script: ';
systemctl disable packages-script.service && log OK || log FAILED;
systemctl disable systemd-time-wait-sync && TIME_SYNC_OFF || log TIME_SYNC_FAILED

log $'\nREBOOTING NOW'
log $(date);
log $'\n----------------------------------------------------------\n'
reboot

