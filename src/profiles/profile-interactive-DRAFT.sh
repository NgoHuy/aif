#!/bin/sh

TARGET_DIR="/mnt"
EDITOR=


# clock
HARDWARECLOCK=
TIMEZONE=

# partitions
PART_ROOT=

# default filesystem specs (the + is bootable flag)
# <mountpoint>:<partsize>:<fstype>[:+]
DEFAULTFS="/boot:32:ext2:+ swap:256:swap /:7500:ext3 /home:*:ext3"

# install stages
S_SRC=0         # choose install medium
S_NET=0         # network configuration
S_CLOCK=0       # clock and timezone
S_PART=0        # partitioning
S_MKFS=0        # formatting
S_MKFSAUTO=0    # auto fs part/formatting TODO: kill this
S_SELECT=0      # package selection
S_INSTALL=0     # package installation
S_CONFIG=0      # configuration editing
S_GRUB=0        # TODO: kill this - if using grub
S_BOOT=""       # bootloader installed (set to loader name instead of 1)

phase_preparation ()
{
	execute worker runtime_packages
	notify "Generating GRUB device map...\nThis could take a while.\n\n Please be patient."
	get_grub_map
}

mainmenu()  
{
    if [ -n "$NEXTITEM" ]; then
        DEFAULT="--default-item $NEXTITEM"
    else
        DEFAULT=""
    fi
    DIALOG $DEFAULT --title " MAIN MENU " \
        --menu "Use the UP and DOWN arrows to navigate menus.  Use TAB to switch between buttons and ENTER to select." 16 55 8 \
        "0" "Select Source" \
        "1" "Set Clock" \
        "2" "Prepare Hard Drive" \
        "3" "Select Packages" \
        "4" "Install Packages" \
        "5" "Configure System" \
        "6" "Install Bootloader" \
        "7" "Exit Install" 2>$ANSWER
    NEXTITEM="$(cat $ANSWER)"
    case $(cat $ANSWER) in
        "0")
            select_source ;;
        "1")
            set_clock ;;
        "2")
            prepare_harddrive ;;
        "3")
            select_packages ;;
        "4")
            installpkg ;;
        "5")
            configure_system ;;
        "6")
            install_bootloader ;;
        "7")
            echo ""
            echo "If the install finished successfully, you can now type 'reboot'"
            echo "to restart the system."
            echo ""
            exit 0 ;;
        *)
            DIALOG --yesno "Abort Installation?" 6 40 && exit 0
            ;;
    esac
}

partition() {
    if [ "$S_MKFSAUTO" = "1" ]; then
        DIALOG --msgbox "You have already prepared your filesystems with Auto-prepare" 0 0
        return 0
    fi

    _umountall

    # Select disk to partition
    DISCS=$(finddisks _)
    DISCS="$DISCS OTHER - DONE +"
    DIALOG --msgbox "Available Disks:\n\n$(_getavaildisks)\n" 0 0
    DISC=""
    while true; do
        # Prompt the user with a list of known disks
        DIALOG --menu "Select the disk you want to partition (select DONE when finished)" 14 55 7 $DISCS 2>$ANSWER || return 1
        DISC=$(cat $ANSWER)
        if [ "$DISC" = "OTHER" ]; then
            DIALOG --inputbox "Enter the full path to the device you wish to partition" 8 65 "/dev/sda" 2>$ANSWER || return 1
            DISC=$(cat $ANSWER)
        fi
        # Leave our loop if the user is done partitioning
        [ "$DISC" = "DONE" ] && break
        # Partition disc
        DIALOG --msgbox "Now you'll be put into the cfdisk program where you can partition your hard drive. You should make a swap partition and as many data partitions as you will need.  NOTE: cfdisk may ttell you to reboot after creating partitions.  If you need to reboot, just re-enter this install program, skip this step and go on to step 2." 18 70 
        cfdisk $DISC
    done
    S_PART=1
}


configure_system()
{
    ## PREPROCESSING ##
    # only done on first invocation of configure_system
    if [ $S_CONFIG -eq 0 ]; then

        # /etc/pacman.d/mirrorlist
        # add installer-selected mirror to the top of the mirrorlist
        if [ "$MODE" = "ftp" -a "${SYNC_URL}" != "" ]; then
            awk "BEGIN { printf(\"# Mirror used during installation\nServer = "${SYNC_URL}"\n\n\") } 1 " "${TARGET_DIR}/etc/pacman.d/mirrorlist"
        fi

        # /etc/rc.conf
        # insert timezone and utc info
        sed -i -e "s/^TIMEZONE=.*/TIMEZONE=\"$TIMEZONE\"/g" \
               -e "s/^HARDWARECLOCK=.*/HARDWARECLOCK=\"$HARDWARECLOCK\"/g" \
               ${TARGET_DIR}/etc/rc.conf
    fi

    ## END PREPROCESS ##

    [ "$EDITOR" ] || geteditor
    FILE=""

    # main menu loop
    while true; do
        if [ -n "$FILE" ]; then
            DEFAULT="--default-item $FILE"
        else
            DEFAULT=""
        fi

        DIALOG $DEFAULT --menu "Configuration" 17 70 10 \
            "/etc/rc.conf"              "System Config" \
            "/etc/fstab"                "Filesystem Mountpoints" \
            "/etc/mkinitcpio.conf"      "Initramfs Config" \
            "/etc/modprobe.conf"        "Kernel Modules" \
            "/etc/resolv.conf"          "DNS Servers" \
            "/etc/hosts"                "Network Hosts" \
            "/etc/hosts.deny"           "Denied Network Services" \
            "/etc/hosts.allow"          "Allowed Network Services" \
            "/etc/locale.gen"           "Glibc Locales" \
            "/etc/pacman.d/mirrorlist"  "Pacman Mirror List" \
            "Root-Password"             "Set the root password" \
            "Return"        "Return to Main Menu" 2>$ANSWER || FILE="Return"
        FILE="$(cat $ANSWER)"
 if [ "$FILE" = "Return" -o -z "$FILE" ]; then       # exit
            break
        elif [ "$FILE" = "Root-Password" ]; then            # non-file
            while true; do
                chroot ${TARGET_DIR} passwd root && break
            done
        else                                                #regular file
            $EDITOR ${TARGET_DIR}${FILE}
        fi
    done  

    ## POSTPROCESSING ##

    # /etc/initcpio.conf
    #
    run_mkinitcpio

    # /etc/locale.gen
    #
    chroot ${TARGET_DIR} locale-gen

    ## END POSTPROCESSING ##

    S_CONFIG=1
}


prepare_harddrive()
{
    S_MKFSAUTO=0
    S_MKFS=0
    DONE=0
    NEXTITEM=""
    while [ "$DONE" = "0" ]; do
        if [ -n "$NEXTITEM" ]; then
            DEFAULT="--default-item $NEXTITEM"
        else
            DEFAULT=""
        fi
        DIALOG $DEFAULT --menu "Prepare Hard Drive" 12 60 5 \
            "1" "Auto-Prepare (erases the ENTIRE hard drive)" \
            "2" "Partition Hard Drives" \
            "3" "Set Filesystem Mountpoints" \
            "4" "Return to Main Menu" 2>$ANSWER
        NEXTITEM="$(cat $ANSWER)"
        case $(cat $ANSWER) in
            "1")
                autoprepare ;;
            "2")
                partition ;;
            "3")
                PARTFINISH=""
                mountpoints ;;
            *)
                DONE=1 ;;
        esac
    done
    NEXTITEM="1"
}


# set_clock()
# prompts user to set hardware clock and timezone
#
# params: none
# returns: 1 on failure
set_clock()   
{
    # utc or local?
    DIALOG --menu "Is your hardware clock in UTC or local time?" 10 50 2 \
        "UTC" " " \
        "local" " " \
        2>$ANSWER || return 1
    HARDWARECLOCK=$(cat $ANSWER)

    # timezone?
    tzselect > $ANSWER || return 1
    TIMEZONE=$(cat $ANSWER)

    # set system clock from hwclock - stolen from rc.sysinit
    local HWCLOCK_PARAMS=""
    if [ "$HARDWARECLOCK" = "UTC" ]; then
        HWCLOCK_PARAMS="$HWCLOCK_PARAMS --utc"
    else
        HWCLOCK_PARAMS="$HWCLOCK_PARAMS --localtime"
    fi  
    if [ "$TIMEZONE" != "" -a -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
        /bin/rm -f /etc/localtime
        /bin/cp "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    fi
    /sbin/hwclock --hctosys $HWCLOCK_PARAMS --noadjfile

    # display and ask to set date/time
    dialog --calendar "Set the date.\nUse <TAB> to navigate and arrow keys to change values." 0 0 0 0 0 2> $ANSWER || return 1
    local _date="$(cat $ANSWER)"
    dialog --timebox "Set the time.\nUse <TAB> to navigate and up/down to change values." 0 0 2> $ANSWER || return 1
    local _time="$(cat $ANSWER)"
    echo "date: $_date time: $_time" >$LOG

    # save the time
    # DD/MM/YYYY hh:mm:ss -> YYYY-MM-DD hh:mm:ss
    local _datetime="$(echo "$_date" "$_time" | sed 's#\(..\)/\(..\)/\(....\) \(..\):\(..\):\(..\)#\3-\2-\1 \4:\5:\6#g')"
    echo "setting date to: $_datetime" >$LOG
    date -s "$_datetime" 2>&1 >$LOG
    /sbin/hwclock --systohc $HWCLOCK_PARAMS --noadjfile

    S_CLOCK=1
}

[ $S_SELECT -eq 0 ] && install_pkg && S_INSTALL=1 # user must first select, then install
# automagic time!
# any automatic configuration should go here
notify "Writing base configuration..."        
auto_fstab
auto_network
auto_locale 

autoprepare()
{
    DISCS=$(finddisks)
    if [ $(echo $DISCS | wc -w) -gt 1 ]; then
        DIALOG --msgbox "Available Disks:\n\n$(_getavaildisks)\n" 0 0
        DIALOG --menu "Select the hard drive to use" 14 55 7 $(finddisks _) 2>$ANSWER || return 1
        DISC=$(cat $ANSWER)
    else
        DISC=$DISCS
    fi
    SET_DEFAULTFS=""
    BOOT_PART_SET=""
    SWAP_PART_SET=""
    ROOT_PART_SET=""
    CHOSEN_FS=""
    # get just the disk size in 1000*1000 MB
    DISC_SIZE=$(hdparm -I /dev/sda | grep -F '1000*1000' | sed "s/^.*:[ \t]*\([0-9]*\) MBytes.*$/\1/")
    while [ "$SET_DEFAULTFS" = "" ]; do
        FSOPTS="ext2 ext2 ext3 ext3"
        [ "$(which mkreiserfs 2>/dev/null)" ] && FSOPTS="$FSOPTS reiserfs Reiser3"
        [ "$(which mkfs.xfs 2>/dev/null)" ]   && FSOPTS="$FSOPTS xfs XFS"
        [ "$(which mkfs.jfs 2>/dev/null)" ]   && FSOPTS="$FSOPTS jfs JFS"
        while [ "$BOOT_PART_SET" = "" ]; do
            DIALOG --inputbox "Enter the size (MB) of your /boot partition.  Minimum value is 16.\n\nDisk space left: $DISC_SIZE MB" 8 65 "32" 2>$ANSWER || return 1
            BOOT_PART_SIZE="$(cat $ANSWER)"
            if [ "$BOOT_PART_SIZE" = "" ]; then
                DIALOG --msgbox "ERROR: You have entered an invalid size, please enter again." 0 0
            else
                if [ "$BOOT_PART_SIZE" -ge "$DISC_SIZE" -o "$BOOT_PART_SIZE" -lt "16" -o "$SBOOT_PART_SIZE" = "$DISC_SIZE" ]; then
                    DIALOG --msgbox "ERROR: You have entered a too large size, please enter again." 0 0
                else
                    BOOT_PART_SET=1
                fi
            fi
        done
        DISC_SIZE=$(($DISC_SIZE-$BOOT_PART_SIZE))
        while [ "$SWAP_PART_SET" = "" ]; do
            DIALOG --inputbox "Enter the size (MB) of your swap partition.  Minimum value is > 0.\n\nDisk space left: $DISC_SIZE MB" 8 65 "256" 2>$ANSWER || return 1
            SWAP_PART_SIZE=$(cat $ANSWER)
            if [ "$SWAP_PART_SIZE" = "" -o  "$SWAP_PART_SIZE" -le "0" ]; then
                DIALOG --msgbox "ERROR: You have entered an invalid size, please enter again." 0 0
            else
                if [ "$SWAP_PART_SIZE" -ge "$DISC_SIZE" ]; then
                    DIALOG --msgbox "ERROR: You have entered a too large size, please enter again." 0 0
                else
                    SWAP_PART_SET=1
                fi
            fi
        done
        DISC_SIZE=$(($DISC_SIZE-$SWAP_PART_SIZE))
        while [ "$ROOT_PART_SET" = "" ]; do
            DIALOG --inputbox "Enter the size (MB) of your / partition.  The /home partition will use the remaining space.\n\nDisk space left:  $DISC_SIZE MB" 8 65 "7500" 2>$ANSWER || return 1
            ROOT_PART_SIZE=$(cat $ANSWER)
            if [ "$ROOT_PART_SIZE" = "" -o "$ROOT_PART_SIZE" -le "0" ]; then
                DIALOG --msgbox "ERROR: You have entered an invalid size, please enter again." 0 0
            else
                if [ "$ROOT_PART_SIZE" -ge "$DISC_SIZE" ]; then
                    DIALOG --msgbox "ERROR: You have entered a too large size, please enter again." 0 0
                else
                    DIALOG --yesno "$(($DISC_SIZE-$ROOT_PART_SIZE)) MB will be used for your /home partition.  Is this OK?" 0 0 && ROOT_PART_SET=1
                fi
            fi
        done
        while [ "$CHOSEN_FS" = "" ]; do
            DIALOG --menu "Select a filesystem for / and /home:" 13 45 6 $FSOPTS 2>$ANSWER || return 1
            FSTYPE=$(cat $ANSWER)
            DIALOG --yesno "$FSTYPE will be used for / and /home. Is this OK?" 0 0 && CHOSEN_FS=1
        done
        SET_DEFAULTFS=1
    done

    DIALOG --defaultno --yesno "$DISC will be COMPLETELY ERASED!  Are you absolutely sure?" 0 0 \
    || return 1

    DEVICE=$DISC
    FSSPECS=$(echo $DEFAULTFS | sed -e "s|/:7500:ext3|/:$ROOT_PART_SIZE:$FSTYPE|g" -e "s|/home:\*:ext3|/home:\*:$FSTYPE|g" -e "s|swap:256|swap:$SWAP_PART_SIZE|g" -e "s|/boot:32|/boot:$BOOT_PART_SIZE|g")
    sfdisk_input=""

    # we assume a /dev/hdX format (or /dev/sdX)
    PART_ROOT="${DEVICE}3"

    if [ "$S_MKFS" = "1" ]; then
        DIALOG --msgbox "You have already prepared your filesystems manually" 0 0
        return 0
    fi

    # validate DEVICE
    if [ ! -b "$DEVICE" ]; then
      DIALOG --msgbox "Device '$DEVICE' is not valid" 0 0
      return 1
    fi

    # validate DEST
    if [ ! -d "$TARGET_DIR" ]; then
        DIALOG --msgbox "Destination directory '$TARGET_DIR' is not valid" 0 0
        return 1
    fi

    # / required
    if [ $(echo $FSSPECS | grep '/:' | wc -l) -ne 1 ]; then
        DIALOG --msgbox "Need exactly one root partition" 0 0
        return 1
    fi

    rm -f /tmp/.fstab

    _umountall

    # setup input var for sfdisk
    for fsspec in $FSSPECS; do
        fssize=$(echo $fsspec | tr -d ' ' | cut -f2 -d:)
        if [ "$fssize" = "*" ]; then
                fssize_spec=';'
        else
                fssize_spec=",$fssize"
        fi
        fstype=$(echo $fsspec | tr -d ' ' | cut -f3 -d:)
        if [ "$fstype" = "swap" ]; then
                fstype_spec=",S"
        else
                fstype_spec=","
        fi
        bootflag=$(echo $fsspec | tr -d ' ' | cut -f4 -d:)
        if [ "$bootflag" = "+" ]; then
            bootflag_spec=",*"
        else
            bootflag_spec=""
        fi
        sfdisk_input="${sfdisk_input}${fssize_spec}${fstype_spec}${bootflag_spec}\n"
    done
    sfdisk_input=$(printf "$sfdisk_input")

    # invoke sfdisk
    printk off
    DIALOG --infobox "Partitioning $DEVICE" 0 0
    sfdisk $DEVICE -uM >$LOG 2>&1 <<EOF
$sfdisk_input
EOF
    if [ $? -gt 0 ]; then
        DIALOG --msgbox "Error partitioning $DEVICE (see $LOG for details)" 0 0
        printk on
        return 1
    fi
    printk on

    # need to mount root first, then do it again for the others
    part=1
    for fsspec in $FSSPECS; do
        mountpoint=$(echo $fsspec | tr -d ' ' | cut -f1 -d:)
        fstype=$(echo $fsspec | tr -d ' ' | cut -f3 -d:)
        if echo $mountpoint | tr -d ' ' | grep '^/$' 2>&1 > /dev/null; then
            _mkfs yes ${DEVICE}${part} "$fstype" "$TARGET_DIR" "$mountpoint" || return 1
        fi
        part=$(($part + 1))
    done

    # make other filesystems
    part=1
    for fsspec in $FSSPECS; do
        mountpoint=$(echo $fsspec | tr -d ' ' | cut -f1 -d:)
        fstype=$(echo $fsspec | tr -d ' ' | cut -f3 -d:)
        if [ $(echo $mountpoint | tr -d ' ' | grep '^/$' | wc -l) -eq 0 ]; then
            _mkfs yes ${DEVICE}${part} "$fstype" "$TARGET_DIR" "$mountpoint" || return 1
        fi
        part=$(($part + 1))
    done

    DIALOG --msgbox "Auto-prepare was successful" 0 0
    S_MKFSAUTO=1
}

mountpoints() {
    if [ "$S_MKFSAUTO" = "1" ]; then
        DIALOG --msgbox "You have already prepared your filesystems with Auto-prepare" 0 0
        return 0
    fi
    while [ "$PARTFINISH" != "DONE" ]; do
        : >/tmp/.fstab
        : >/tmp/.parts

        # Determine which filesystems are available
        FSOPTS="ext2 ext2 ext3 ext3"
        [ "$(which mkreiserfs 2>/dev/null)" ] && FSOPTS="$FSOPTS reiserfs Reiser3"
        [ "$(which mkfs.xfs 2>/dev/null)" ]   && FSOPTS="$FSOPTS xfs XFS"
        [ "$(which mkfs.jfs 2>/dev/null)" ]   && FSOPTS="$FSOPTS jfs JFS"
        [ "$(which mkfs.vfat 2>/dev/null)" ]  && FSOPTS="$FSOPTS vfat VFAT"

        # Select mountpoints
        DIALOG --msgbox "Available Disks:\n\n$(_getavaildisks)\n" 0 0
        PARTS=$(findpartitions _)
        DIALOG --menu "Select the partition to use as swap" 21 50 13 NONE - $PARTS 2>$ANSWER || return 1
        PART=$(cat $ANSWER)
        PARTS="$(echo $PARTS | sed -e "s#${PART}\ _##g")"
        if [ "$PART" != "NONE" ]; then
            DOMKFS="no"
            DIALOG --yesno "Would you like to create a filesystem on $PART?\n\n(This will overwrite existing data!)" 0 0 && DOMKFS="yes"
            echo "$PART:swap:swap:$DOMKFS" >>/tmp/.parts
        fi

        DIALOG --menu "Select the partition to mount as /" 21 50 13 $PARTS 2>$ANSWER || return 1
        PART=$(cat $ANSWER)
        PARTS="$(echo $PARTS | sed -e "s#${PART}\ _##g")"
        PART_ROOT=$PART
        # Select root filesystem type
        DIALOG --menu "Select a filesystem for $PART" 13 45 6 $FSOPTS 2>$ANSWER || return 1
        FSTYPE=$(cat $ANSWER)
        DOMKFS="no"
        DIALOG --yesno "Would you like to create a filesystem on $PART?\n\n(This will overwrite existing data!)" 0 0 && DOMKFS="yes"
        echo "$PART:$FSTYPE:/:$DOMKFS" >>/tmp/.parts

        #
        # Additional partitions
        #
        DIALOG --menu "Select any additional partitions to mount under your new root (select DONE when finished)" 21 50 13 $PARTS DONE _ 2>$ANSWER || return 1
        PART=$(cat $ANSWER)
        while [ "$PART" != "DONE" ]; do
            PARTS="$(echo $PARTS | sed -e "s#${PART}\ _##g")"
            # Select a filesystem type
            DIALOG --menu "Select a filesystem for $PART" 13 45 6 $FSOPTS 2>$ANSWER || return 1
            FSTYPE=$(cat $ANSWER)
            MP=""
            while [ "${MP}" = "" ]; do
                DIALOG --inputbox "Enter the mountpoint for $PART" 8 65 "/boot" 2>$ANSWER || return 1
                MP=$(cat $ANSWER)
                if grep ":$MP:" /tmp/.parts; then
                    DIALOG --msgbox "ERROR: You have defined 2 identical mountpoints! Please select another mountpoint." 8 65
                    MP=""
                fi
            done
            DOMKFS="no"
            DIALOG --yesno "Would you like to create a filesystem on $PART?\n\n(This will overwrite existing data!)" 0 0 && DOMKFS="yes"
            echo "$PART:$FSTYPE:$MP:$DOMKFS" >>/tmp/.parts
            DIALOG --menu "Select any additional partitions to mount under your new root" 21 50 13 $PARTS DONE _ 2>$ANSWER || return 1
            PART=$(cat $ANSWER)
        done
        DIALOG --yesno "Would you like to create and mount the filesytems like this?\n\nSyntax\n------\nDEVICE:TYPE:MOUNTPOINT:FORMAT\n\n$(for i in $(cat /tmp/.parts); do echo "$i\n";done)" 18 0 && PARTFINISH="DONE"
    done

    _umountall

    for line in $(cat /tmp/.parts); do
        PART=$(echo $line | cut -d: -f 1)
        FSTYPE=$(echo $line | cut -d: -f 2)
        MP=$(echo $line | cut -d: -f 3)
        DOMKFS=$(echo $line | cut -d: -f 4)
        umount ${TARGET_DIR}${MP}
        if [ "$DOMKFS" = "yes" ]; then
            if [ "$FSTYPE" = "swap" ]; then
                DIALOG --infobox "Creating and activating swapspace on $PART" 0 0
            else
                DIALOG --infobox "Creating $FSTYPE on $PART, mounting to ${TARGET_DIR}${MP}" 0 0
            fi
            _mkfs yes $PART $FSTYPE $TARGET_DIR $MP || return 1
        else
            if [ "$FSTYPE" = "swap" ]; then
                DIALOG --infobox "Activating swapspace on $PART" 0 0
            else
                DIALOG --infobox "Mounting $PART to ${TARGET_DIR}${MP}" 0 0
            fi
            _mkfs no $PART $FSTYPE $TARGET_DIR $MP || return 1
        fi
        sleep 1
    done

    DIALOG --msgbox "Partitions were successfully mounted." 0 0
    S_MKFS=1
}

# select_packages()
# prompts the user to select packages to install
#
# params: none
# returns: 1 on error
select_packages() {
    # step dependencies
    if [ $S_SRC -eq 0 ]; then
        DIALOG --msgbox "You must select an installation source!" 0 0
        return 1
    fi

    # if selection has been done before, warn about loss of input
    # and let the user exit gracefully
    if [ $S_SELECT -ne 0 ]; then
        DIALOG --yesno "WARNING: Running this stage again will result in the loss of previous package selections.\n\nDo you wish to continue?" 10 50 || return 1
    fi

    DIALOG --msgbox "Package selection is split into two stages.  First you will select package categories that contain packages you may be interested in.  Then you will be presented with a full list of packages for each category, allowing you to fine-tune.\n\n" 15 70

    # set up our install location if necessary and sync up
    # so we can get package lists
    prepare_pacman
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "Pacman preparation failed! Check $LOG for errors." 6 60
        return 1
    fi

    # show group listing for group selection
    local _catlist="base ^ ON"
    for i in $($PACMAN -Sg | sed "s/^base$/ /g"); do
        _catlist="${_catlist} ${i} - OFF"
    done

    DIALOG --checklist "Select Package Categories\nDO NOT deselect BASE unless you know what you're doing!" 19 55 12 $_catlist 2>$ANSWER || return 1
    _catlist="$(cat $ANSWER)"

    # assemble a list of packages with groups, marking pre-selected ones
    # <package> <group> <selected>
    local _pkgtmp="$($PACMAN -Sl core | awk '{print $2}')"
    local _pkglist=''

    $PACMAN -Si $_pkgtmp | \
        awk '/^Name/{ printf("%s ",$3) } /^Group/{ print $3 }' > $ANSWER
    while read pkgname pkgcat; do
        # check if this package is in a selected group
        # slightly ugly but sorting later requires newlines in the variable
        if [ "${_catlist/"\"$pkgcat\""/XXXX}" != "${_catlist}" ]; then
            _pkglist="$(echo -e "${_pkglist}\n${pkgname} ${pkgcat} ON")"
        else
            _pkglist="$(echo -e "${_pkglist}\n${pkgname} ${pkgcat} OFF")"
        fi
    done < $ANSWER

    # sort by category
    _pkglist="$(echo "$_pkglist" | sort -f -k 2)"

    DIALOG --checklist "Select Packages To Install." 19 60 12 $_pkglist 2>$ANSWER || return 1
    PACKAGES="$(cat $ANSWER)"
    S_SELECT=1
}


# donetwork()
# Hand-hold through setting up networking
#
# args: none
# returns: 1 on failure
donetwork() {
    INTERFACE=""
    S_DHCP=""
    local ifaces
    ifaces=$(ifconfig -a |grep "Link encap:Ethernet"|sed 's/ \+Link encap:Ethernet \+HWaddr \+/ /g')

    if [ "$ifaces" = "" ]; then
        DIALOG --msgbox "Cannot find any ethernet interfaces. This usually means udev was\nunable to load the module and you must do it yourself. Switch to\nanother VT, load the appropriate module, and run this step again." 18 70
        return 1
    fi

    DIALOG --nocancel --ok-label "Select" --menu "Select a network interface" 14 55 7 $ifaces 2>$ANSWER
    case $? in
        0) INTERFACE=$(cat $ANSWER) ;;
        *) return 1 ;;
    esac

    DIALOG --yesno "Do you want to use DHCP?" 0 0
    if [ $? -eq 0 ]; then
        DIALOG --infobox "Please wait.  Polling for DHCP server on $INTERFACE..." 0 0
        dhcpcd $INTERFACE >$LOG 2>&1
        if [ $? -ne 0 ]; then
            DIALOG --msgbox "Failed to run dhcpcd.  See $LOG for details." 0 0
            return 1
        fi
        if [ ! $(ifconfig $INTERFACE | grep 'inet addr:') ]; then
            DIALOG --msgbox "DHCP request failed." 0 0 || return 1
        fi
        S_DHCP=1
    else
        NETPARAMETERS=""
        while [ "$NETPARAMETERS" = "" ]; do
            DIALOG --inputbox "Enter your IP address" 8 65 "192.168.0.2" 2>$ANSWER || return 1
            IPADDR=$(cat $ANSWER)
            DIALOG --inputbox "Enter your netmask" 8 65 "255.255.255.0" 2>$ANSWER || return 1
            SUBNET=$(cat $ANSWER)
            DIALOG --inputbox "Enter your broadcast" 8 65 "192.168.0.255" 2>$ANSWER || return 1
            BROADCAST=$(cat $ANSWER)
            DIALOG --inputbox "Enter your gateway (optional)" 8 65 "192.168.0.1" 2>$ANSWER || return 1
            GW=$(cat $ANSWER)
            DIALOG --inputbox "Enter your DNS server IP" 8 65 "192.168.0.1" 2>$ANSWER || return 1
            DNS=$(cat $ANSWER)
            DIALOG --inputbox "Enter your HTTP proxy server, for example:\nhttp://name:port\nhttp://ip:port\nhttp://username:password@ip:port\n\n Leave the field empty if no proxy is needed to install." 16 65 "" 2>$ANSWER || return 1
            PROXY_HTTP=$(cat $ANSWER)
            DIALOG --inputbox "Enter your FTP proxy server, for example:\nhttp://name:port\nhttp://ip:port\nhttp://username:password@ip:port\n\n Leave the field empty if no proxy is needed to install." 16 65 "" 2>$ANSWER || return 1
            PROXY_FTP=$(cat $ANSWER)
            DIALOG --yesno "Are these settings correct?\n\nIP address:         $IPADDR\nNetmask:            $SUBNET\nGateway (optional): $GW\nDNS server:         $DNS\nHTTP proxy server:  $PROXY_HTTP\nFTP proxy server:   $PROXY_FTP" 0 0
            case $? in
                1) ;;
                0) NETPARAMETERS="1" ;;
            esac
        done
        echo "running: ifconfig $INTERFACE $IPADDR netmask $SUBNET broadcast $BROADCAST up" >$LOG
        ifconfig $INTERFACE $IPADDR netmask $SUBNET broadcast $BROADCAST up >$LOG 2>&1 || DIALOG --msgbox "Failed to setup $INTERFACE interface." 0 0 || return 1
        if [ "$GW" != "" ]; then
            route add default gw $GW >$LOG 2>&1 || DIALOG --msgbox "Failed to setup your gateway." 0 0 || return 1
        fi
        if [ "$PROXY_HTTP" = "" ]; then
            unset http_proxy
        else
            export http_proxy=$PROXY_HTTP
        fi
        if [ "$PROXY_FTP" = "" ]; then
            unset ftp_proxy
        else
            export ftp_proxy=$PROXY_FTP
        fi
        echo "nameserver $DNS" >/etc/resolv.conf
    fi
    DIALOG --msgbox "The network is configured." 0 0
    S_NET=1
}

dogrub() {
    get_grub_map
    local grubmenu="$TARGET_DIR/boot/grub/menu.lst"
    if [ ! -f $grubmenu ]; then
        DIALOG --msgbox "Error: Couldn't find $grubmenu.  Is GRUB installed?" 0 0
        return 1
    fi
    # try to auto-configure GRUB...
    if [ "$PART_ROOT" != "" -a "$S_GRUB" != "1" ]; then
        grubdev=$(mapdev $PART_ROOT)
        local _rootpart="${PART_ROOT}"
        local _uuid="$(getuuid ${PART_ROOT})"
        # attempt to use a UUID if the root device has one
        if [ -n "${_uuid}" ]; then
            _rootpart="/dev/disk/by-uuid/${_uuid}"
        fi
        # look for a separately-mounted /boot partition
        bootdev=$(mount | grep $TARGET_DIR/boot | cut -d' ' -f 1)
        if [ "$grubdev" != "" -o "$bootdev" != "" ]; then
            subdir=
            if [ "$bootdev" != "" ]; then
                grubdev=$(mapdev $bootdev)
            else
                subdir="/boot"
            fi
            # keep the file from being completely bogus
            if [ "$grubdev" = "DEVICE NOT FOUND" ]; then
                DIALOG --msgbox "Your root boot device could not be autodetected by setup.  Ensure you adjust the 'root (hd0,0)' line in your GRUB config accordingly." 0 0
                grubdev="(hd0,0)"
            fi
            # remove default entries by truncating file at our little tag (#-*)
            sed -i -e '/#-\*/q'
            cat >>$grubmenu <<EOF

# (0) Arch Linux
title  Arch Linux
root   $grubdev
kernel $subdir/vmlinuz26 root=${_rootpart} ro
initrd $subdir/kernel26.img

# (1) Arch Linux
title  Arch Linux Fallback
root   $grubdev
kernel $subdir/vmlinuz26 root=${_rootpart} ro
initrd $subdir/kernel26-fallback.img

# (2) Windows
#title Windows
#rootnoverify (hd0,0)
#makeactive
#chainloader +1
EOF
        fi
    fi

    DIALOG --msgbox "Before installing GRUB, you must review the configuration file.  You will now be put into the editor.  After you save your changes and exit the editor, you can install GRUB." 0 0
    [ "$EDITOR" ] || geteditor
    $EDITOR $grubmenu

    DEVS=$(finddisks _)
    DEVS="$DEVS $(findpartitions _)"
    if [ "$DEVS" = "" ]; then
        DIALOG --msgbox "No hard drives were found" 0 0
        return 1
    fi
    DIALOG --menu "Select the boot device where the GRUB bootloader will be installed (usually the MBR and not a partition)." 14 55 7 $DEVS 2>$ANSWER || return 1
    ROOTDEV=$(cat $ANSWER)
    DIALOG --infobox "Installing the GRUB bootloader..." 0 0
    cp -a $TARGET_DIR/usr/lib/grub/i386-pc/* $TARGET_DIR/boot/grub/
    sync
    # freeze xfs filesystems to enable grub installation on xfs filesystems
    if [ -x /usr/sbin/xfs_freeze ]; then
        /usr/sbin/xfs_freeze -f $TARGET_DIR/boot > /dev/null 2>&1
        /usr/sbin/xfs_freeze -f $TARGET_DIR/ > /dev/null 2>&1
    fi
    # look for a separately-mounted /boot partition
    bootpart=$(mount | grep $TARGET_DIR/boot | cut -d' ' -f 1)
    if [ "$bootpart" = "" ]; then
        if [ "$PART_ROOT" = "" ]; then
            DIALOG --inputbox "Enter the full path to your root device" 8 65 "/dev/sda3" 2>$ANSWER || return 1
            bootpart=$(cat $ANSWER)
        else
            bootpart=$PART_ROOT
        fi
    fi
    DIALOG --defaultno --yesno "Do you have your system installed on software raid?\nAnswer 'YES' to install grub to another hard disk." 0 0
    if [ $? -eq 0 ]; then
        DIALOG --menu "Please select the boot partition device, this cannot be autodetected!\nPlease redo grub installation for all partitions you need it!" 14 55 7 $DEVS 2>$ANSWER || return 1
        bootpart=$(cat $ANSWER)
    fi
    bootpart=$(mapdev $bootpart)
    bootdev=$(mapdev $ROOTDEV)
    if [ "$bootpart" = "" ]; then
        DIALOG --msgbox "Error: Missing/Invalid root device: $bootpart" 0 0
        return 1
    fi
    if [ "$bootpart" = "DEVICE NOT FOUND" -o "$bootdev" = "DEVICE NOT FOUND" ]; then
        DIALOG --msgbox "GRUB root and setup devices could not be auto-located.  You will need to manually run the GRUB shell to install a bootloader." 0 0
        return 1
    fi
    $TARGET_DIR/sbin/grub --no-floppy --batch >/tmp/grub.log 2>&1 <<EOF
root $bootpart
setup $bootdev
quit
EOF
    cat /tmp/grub.log >$LOG
    # unfreeze xfs filesystems
    if [ -x /usr/sbin/xfs_freeze ]; then
        /usr/sbin/xfs_freeze -u $TARGET_DIR/boot > /dev/null 2>&1
        /usr/sbin/xfs_freeze -u $TARGET_DIR/ > /dev/null 2>&1
    fi

    if grep "Error [0-9]*: " /tmp/grub.log >/dev/null; then
        DIALOG --msgbox "Error installing GRUB. (see $LOG for output)" 0 0
        return 1
    fi
    DIALOG --msgbox "GRUB was successfully installed." 0 0
    S_GRUB=1
}

        
#####################
## begin execution ##

DIALOG --msgbox "Welcome to the Arch Linux Installation program. The install \
process is fairly straightforward, and you should run through the options in \
the order they are presented. If you are unfamiliar with partitioning/making \
filesystems, you may want to consult some documentation before continuing. \
You can view all output from commands by viewing your VC7 console (ALT-F7). \
ALT-F1 will bring you back here." 14 65

while true; do
    mainmenu
    done
    
    exit 0
    
    