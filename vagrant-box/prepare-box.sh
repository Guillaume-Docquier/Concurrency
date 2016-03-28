#!/bin/bash -e

remove () { 
    for tf in $@; do
        rm -rf $tf
    done
}

# Remove any temporary work files, including the postinstall.sh script
remove ~/.bash_history ~/.viminfo

# upgrade latest version packages
apt-get update -y

# clean and remove old packages
apt-get clean
apt-get autoremove -yq

# remove logs
remove `find /var/log -type f`

# Make sure Udev doesn't block our network, see: http://6.ptmc.org/?p=164
UDEV=/etc/udev/rules.d
remove $UDEV/70-persistent-net.rules $UDEV/75-persistent-net-generator.rules /dev/.udev/

# flush writes to block storage
sync
