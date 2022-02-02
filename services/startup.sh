#!/bin/bash

# This script does some early-boot initialization of rooted webOS devices. It's
# meant to be copied over to suitable path (eg. start-devmode.sh) to keep it
# safe from accidental homebrew channel app removal.

# Ensure that startup script runs only once per boot
once=/tmp/webosbrew_startup
exec 200>"${once}.lock"
flock -x -n 200 || exit
trap "rm -f ${once}.lock" EXIT
test -f "${once}" && exit
touch "${once}"

if [[ -f /var/luna/preferences/webosbrew_failsafe ]]; then
    # In case a reboot occured during last startup - open an emergency telnet
    # server and nag user to actually fix this. (since further reboots could
    # lead to devmode removal, etc...)

    telnetd -l /bin/sh
    sleep 1

    while true; do
        luna-send -a webosbrew -f -n 1 luna://com.webos.notification/createToast '{"sourceId":"webosbrew","message": "<b>Failsafe mode!</b> Open telnet and remove<br>/var/luna/preferences/webosbrew_failsafe"}'
        sleep 15;
    done
else
    # Set a failsafe flag and sync filesystem to make sure it actually gets
    # tripped...
    touch /var/luna/preferences/webosbrew_failsafe
    sync
    sleep 2

    # Reset devmode reboot counter
    rm -f /var/luna/preferences/dc*

    # Block software update servers
    if [[ -e /var/luna/preferences/webosbrew_block_updates ]]; then
        cp /etc/hosts /tmp/hosts
        mount --bind /tmp/hosts /etc/hosts

        echo '' >> /etc/hosts
        echo '# This file is dynamically regenerated on boot by webosbrew startup script' >> /etc/hosts
        echo '127.0.0.1 snu.lge.com su-dev.lge.com su.lge.com su-ssl.lge.com' >> /etc/hosts
        echo '::1 snu.lge.com su-dev.lge.com su.lge.com su-ssl.lge.com' >> /etc/hosts
    fi

    # Start root telnet server
    if [[ ! -e /var/luna/preferences/webosbrew_telnet_disabled ]]; then
        telnetd -l /bin/sh
    fi

    # Start sshd
    if [[ -e /var/luna/preferences/webosbrew_sshd_enabled ]]; then
        mkdir -p /var/lib/webosbrew/sshd
        /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/bin/dropbear -R
    fi

    # Set placeholder root password (alpine) unless someone has already
    # provisioned their ssh authorized keys
    if [ ! -f /home/root/.ssh/authorized_keys ]; then
        sed -r 's/root:.?:/root:xGVw8H4GqkKg6:/' /etc/shadow > /tmp/shadow
        chmod 400 /tmp/shadow
        mount --bind /tmp/shadow /etc/shadow

        # Enable root account (only required on old webOS versions)
        if grep -q 'root:\*:' /etc/passwd; then
            sed 's/root:\*:/root:x:/' /etc/passwd > /tmp/passwd
            chmod 444 /tmp/passwd
            mount --bind /tmp/passwd /etc/passwd
        fi

        echo '' >> /tmp/motd
        echo ' /!\ Your system is using a default password.' >> /tmp/motd
        echo ' /!\ Insert SSH public key into /home/root/.ssh/authorized_keys and perform a reboot to remove this warning.' >> /tmp/motd
        echo '' >> /tmp/motd
        mount --bind /tmp/motd /etc/motd
    else
        # Cleanup in case someone accidentally uploads a file with 777
        # permissions
        chmod 600 /home/root/.ssh/authorized_keys
        chown 0:0 /home/root/.ssh/authorized_keys
    fi

    # Do our best to neuter telemetry
    mkdir -p /tmp/.unwritable
    for path in /tmp/rdxd /tmp/uploadd /var/spool/rdxd /var/spool/uploadd/pending /var/spool/uploadd/uploaded; do
        mkdir -p $path
        mount -o bind,ro /tmp/.unwritable $path

        # Some older mount (webOS 3.x) does not support direct ro bind mount, so
        # this needs to be remounted after initial bind...
        mount -o bind,remount,ro /tmp/.unwritable $path
    done

    # Deprecate old path
    chattr -i /home/root/unwritable
    rm -rf /home/root/unwritable

    # Automatically elevate Homebrew Channel service
    if [[ -x /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/elevate-service ]]; then
        /media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service/elevate-service
    fi

    # Run user startup hooks
    if [[ -d /var/lib/webosbrew/init.d ]]; then
        run-parts /var/lib/webosbrew/init.d
    fi

    # Reset failsafe flag after a while
    sleep 10
    rm /var/luna/preferences/webosbrew_failsafe
fi
