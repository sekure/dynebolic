# miscellaneous procedures called by dyne:bolic initialization scripts
#
# Copyleft 2003-2006 by Denis Rojo aka jaromil <jaromil@dyne.org>
# with contributions by Alex Gnoli aka smilzo <smilzo@sfrajone.org>
# (this was started in one night hacking together in Metro Olografix)
#
#  * freely distributed in dyne:bolic GNU/Linux http://dynebolic.org
#  * 
#  * This source code is free software; you can redistribute it and/or
#  * modify it under the terms of the GNU Public License as published 
#  * by the Free Software Foundation; either version 2 of the License,
#  * or (at your option) any later version.
#  *
#  * This source code is distributed in the hope that it will be useful,
#  * but WITHOUT ANY WARRANTY; without even the implied warranty of
#  * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#  * Please refer to the GNU Public License for more details.
#  *
#  * You should have received a copy of the GNU Public License along with
#  * this source code; if not, write to:
#  * Free Software Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

# this script gets sourced by all dyne shell scripts
# we check here against multiple inclusion
if [ -z $DYNE_SHELL_UTILS ]; then
DYNE_SHELL_UTILS=included
  

# list of supported filesystems, used by:
# dynesdk - to copy the needed kernel modules in the initrd
# volumes.sh - to load the modules at startup, for mount autodetection
SUPPORTED_FS="fat,vfat,msdos,ufs,befs,xfs,reiserfs,hfsplus,dm-mod,fuse"

# load dyne environmental variable
if [ -r /boot/dynenv ]; then source /boot/dynenv; fi

# load dyne language settings
if [ -r /etc/LANGUAGE ]; then source /etc/LANGUAGE; fi

# load dyne network settings
if [ -r /etc/NETWORK ]; then source /etc/NETWORK; fi

if [ -r /usr/bin/logger ]; then
  LOGGER=/usr/bin/logger
else
  LOGGER=/bin/logger
fi

notice() {
    $LOGGER -s -p syslog.notice "[*] ${1}"
}
act() {
    $LOGGER -s -p syslog.notice " .  ${1}"
}
error() {
    $LOGGER -s -p syslog.err    "[!] ${1}"
}
warning() {
    $LOGGER -s -p syslog.warn   "[W] ${1}"
}
xosd() {
    echo "${1}" | osd_cat -c lightblue -p middle -A center -s 3 \
      -f "-*-lucidatypewriter-*-*-*-sans-*-190-*-*-*-*-*-*" &
}

# udevstart populates and refreshes /dev directory
udevstart() {
  act "populating device filesystem"

#  udevtrigger --subsystem-match=mem \
#              --subsystem-match=ide \
#              --subsystem-match=net \
#              --subsystem-match=input \
#              --subsystem-match=block \
#              --subsystem-match=tty \
#              --subsystem-match=vc \
#              --subsystem-match=misc \
#              --subsystem-match=acpi \
#              --subsystem-match=sound \
#              --subsystem-match=ieee1394 \
#              --subsystem-match=graphics

  udevtrigger

  sync

  udevtrigger --retry-failed

  udevsettle

}


# configuration handling
# returns the value of a configuration variable
get_config() {
# check for a case insensitive match in the kernel options
# to allow overriding of all settings from boot prompt.
    KERNEL_VAL=`cat /proc/cmdline | awk -v name="$1" '
BEGIN { FS = "="; RS = " "; IGNORECASE = 1; variable = name; }
$1 == variable { print $2; }
'`
    if [ $KERNEL_VAL ]; then
	echo "${KERNEL_VAL}"
	return 0
    fi

    # environmental variable set dinamicly may override config
    ENV_VAL=`export | awk -v name="$1" '
BEGIN { FS = "="; IGNORECASE = 1; variable = name; }
$1 == variable { print $2; }
'`
    if [ $ENV_VAL ]; then
	echo "${ENV_VAL}"
	return 0
    fi

    # check if there is a config file in our dock
    # if yes take the configuration from that
    if [ -r $DYNE_SYS_MNT/dyne.cfg ]; then
	CFG_VAL=`cat $DYNE_SYS_MNT/dyne.cfg | awk -v name="$1" '
BEGIN { FS = "="; IGNORECASE = 1; variable = name; }
$1 == variable { print $2; }
'`
	if [ $CFG_VAL ]; then
	    echo "${CFG_VAL}"
	    return 0
	fi

    fi
	
    return 1
}

# dyne:II kernel module loading wrapper
# supports .gz and .bz2 compressed modules
# searches for modules in ramdisk and dock
# and at last in the usual /lib/modules
loadmod() {

    MODULE=${1}

    # check if the module is already loaded
    for checkmod in `lsmod | awk '{ print $1 }'`; do
        if [ "$checkmod" = "$MODULE" ]; then
            return 0
        fi
    done

    if [ $2 ]; then  # there are arguments
      MODARGS=`echo $@ | cut -d' ' -f 2-`
    else
      MODARGS=""
    fi

    # check if it is a denied module we skip
    MODULES_DENY="`get_config modules_deny`"
    for m in `iterate ${MODULES_DENY}`; do
        if [ x$MODULE = x$m ]; then
           act "$MODULE denied ... SKIPPED"
           return 0
        fi
    done

    # in interactive mode we ask 
    INTERACTIVE="`get_config modules_prompt`"
    if [ $INTERACTIVE ]; then 
	ask_yesno 10 "Load kernel module $MODULE ?"
	if [ $? = 1 ]; then
	    act "Loading kernel module $MODULE"
	else
	    act "Skipped kernel module $MODULE"
            return 0
	fi
    fi

    KRN=`uname -r`
    
    ##################################
    # look for the module in the docks
    if [ -r /boot/hdsyslist ]; then

      for HD in `cat /boot/hdsyslist | awk '{print $2}'`; do

        if [ -x ${HD}/dyne/kernel ]; then

          TRYMOD=`find ${HD}/dyne/kernel -name "${MODULE}"`

          if [ ${TRYMOD} ]; then

            insmod ${TRYMOD} ${MODARGS}
            if [ $? = 0 ]; then
              act "kernel module $MODULE loaded from docked dyne"
            else
              error "error loading kernel module $TRYMOD"
            fi
            return 0

          fi

        fi 

      done

    fi



    ################################
    # look for the module in ramdisk
    if [ -x /boot/modules/${KRN} ]; then

      TRYMOD=`find /boot/modules/${KRN} -name "${MODULE}.ko*"`
      if [ ${TRYMOD} ]; then
        # FOUND!
        mod_name=`basename ${TRYMOD}`
        if [ `echo ${mod_name} | grep ko.bz2` ]; then
          # it is a COMPRESSED module
          cd /boot/modules/${KRN}

          mod_name=`basename ${TRYMOD} .bz2`
          # uncompress it in /tmp
          bunzip2 -c ${TRYMOD} > ${mod_name}
          # load it
          insmod ${mod_name} ${MODARGS}
	  if [ $? = 0 ]; then
	    act "kernel module $TRYMOD $MODARGS loaded from ramdisk"
          else
            error "error loading kernel module $TRYMOD"
	  fi

          # remove the uncompressed module in /tmp
          rm -f ${mod_name}
          cd -
	  return 0

        else # it's non-compressed in ramdisk

          insmod ${TRYMOD} ${MODARGS}
          if [ $? = 0 ]; then
            act "kernel module $MODULE loaded from ramdisk"
          else
            error "error loading kernel module $TRYMOD"
          fi
          return 0

        fi

      fi

    fi # the module it's not in the ramdisk

    ###############################################
    # look for the kernel module in the dyne modules
    if [ -x /opt ]; then
      for dynemod in `ls /opt`; do

        if [ -x /opt/${dynemod}/kernel ]; then

          TRYMOD=`find /opt/${dynemod}/kernel -name "${MODULE}.ko*"`
        
          if [ ${TRYMOD} ]; then

            insmod ${TRYMOD} ${MODARGS}
            if [ $? = 0 ]; then
              act "kernel module $MODULE loaded from ${dynemod}.dyne"
            else
              error "error loading kernel module $TRYMOD"
            fi
            return 0

          fi

        fi

      done

    fi


    ###############################################
    # at last if the system is mounted try modprobe
    if [ -x /usr/sbin/modprobe ]; then

#	if [ -r /etc/modules.deny ]; then
#	    if [ "`cat /etc/modules.deny | grep -E $1`" ]; then
#	        # skip modules included in /etc/modules.deny
#		act "skipping kernel module $MODULE (match in /etc/modules.deny)"
#		return
#	    fi
#	fi

        # finally we do it
	/usr/sbin/modprobe ${MODULE} ${MODARGS}
	if [ $? = 0 ]; then
	    act "kernel module $MODULE loaded with modprobe"
	else
	    error "error loading kernel module $MODULE"
	fi
	return 0
   
    fi

    ###############################################
    # load from modules directory without modprobe
    if [ -x /lib/modules/${KRN}/kernel ]; then
      TRYMOD=`find /lib/modules/$KRN -name "${MODULE}.ko"`
        if [ ${TRYMOD} ]; then

          insmod ${TRYMOD} ${MODARGS} 1>/dev/null 2>/dev/null
          if [ $? = 0 ]; then
            act "${MODULE} kernel module loaded"
          else
            error "error loading kernel module $TRYMOD"
          fi
          return 0

        fi
    fi


    error "kernel module $MODULE not found"
}


# iterates the values of a comma separated array on stdout
# (good for use in for cycles on modules lists)
iterate() {
    echo "$1" | awk '
    BEGIN { RS = "," }
          { print $0 }';
}

iterate_backwards() {
    echo "$1" | awk '
    BEGIN { FS = "," }
          { for(c=NF+1; c>0; c--) print $c }';
}
# I LOVE AWK \o/


# simple alphabet shell function by Jaromil
ALPHABET="abcdefghijklmnopqrstuvwxyz"
# takes an alphabet letter as argument
# can return the next or previous letter
# or simply the index position in the alphabet
# or if the argument is a number
#    returns the letter in the specified position of the alphabet
alphabet() { # args: letter (next|prev)

    IDX=`expr index $ALPHABET $1`

    if [ $IDX = 0 ]; then # number argument

	if [ "$2" = "next" ]; then
	    num="`expr $1 + 1`"
	elif [ "$2" = "prev" ]; then
	    num="`expr $1 - 1`"
	else
	    num=$1
	fi
	RES="`expr substr ${ALPHABET} $num 1`"

    elif   [ "$2" = "next" ]; then

	NUM="`expr ${IDX} + 1`"	
	RES="`expr substr ${ALPHABET} ${NUM} 1`"

    elif [ "$2" = "prev" ]; then

	NUM="`expr ${IDX} - 1`"
	RES="`expr substr ${ALPHABET} ${NUM} 1`"

    else
 	RES=${IDX}
    fi

    echo ${RES}
}


# checks if a mountpoint is mounted
is_mounted() { # arg: mountpoint or device
  mnt=$1
  grep ${mnt} /etc/mtab > /dev/null
  if [ $? = 0 ]; then
    echo "true"
  else
    echo "false"
  fi
}

# checks if a file is writable
# differs from -w coz returns true if does not exist but can be created
is_writable() { # arg: filename

  file=$1
  writable=false

  if [ -r $file ]; then # file exists

    if [ -w $file ]; then writable=true; fi

  else # file does not exist

    touch $file 1>/dev/null 2>/dev/null
    if [ $? = 0 ]; then
      writable=true
      rm $file
    fi 

  fi

  if [ x$writable = xtrue ]; then
    echo "true"
  else
    echo "false"
  fi
}

# checks if a process is running
# returns "true" or "false"
# arg 1: process name
is_running() {
  result="`ps ax | awk -v proc=$1 '$5 == proc { print "true"; found="yes" }
                                   END        { if(found!="yes") print "false" }'`"
  echo $result
}

# returns the file extension: all chars after the last dot
file_ext() {
  echo $1 | awk -F. '{print $NF}'
}

# appends a new line to a text file, if not duplicate
# it sorts alphabetically the original order of line entries
# defines the APPEND_FILE_CHANGED variable if file changes
append_line() { # args:   file    new-line

    # first check if the file is writable
    # this also creates the file if doesn't exists
    if [ `is_writable $1` = false ]; then
      error "file $1 is not writable"
      error "can't insert line: $2"
      return
    fi

    tempfile="`basename $1`.append.tmp"

    # create a temporary file and add the line there
    cp $1 /tmp/$tempfile
    echo "$2" >> /tmp/$tempfile

    # sort and uniq the temp file to temp.2
    cat /tmp/$tempfile | sort | uniq > /tmp/${tempfile}.2

    SIZE1="`ls -l /tmp/$tempfile | awk '{print $5}'`"
    SIZE2="`ls -l /tmp/${tempfile}.2 | awk '{print $5}'`"
    if [ $SIZE != $SIZE ]; then
      # delete the original
      rm -f $1
      # replace it
      cp -f /tmp/${tempfile}.2 $1
      # signal the change
      APPEND_FILE_CHANGED=true
    fi

    # remove the temporary files
    rm -f /tmp/$tempfile
    rm -f /tmp/${tempfile}.2
     
    # and we are done
}


cleandir() {
    DIR=${1}
    act "cleaning all files in ${DIR}"
    mkdir -p ${DIR}
    if [ "`ls -A ${DIR}/`" ]; then
	rm -rf ${DIR}/*
    fi
}

# takes two arguments, first is old version and second is newer
# in case the second is really newer returns 0 otherwise 1
is_new_version() {
    old="$1"
    new="$2"
    c=0

    # cycle thru major.minor numbers from left to right
    for n in `echo ${new} | awk 'BEGIN{RS="."} {print $1}'`; do

	c=`expr $c + 1`

	n="`echo $n | cut -d- -f1`" # strip dashed codenames

	o="`echo ${old} | awk -v c=$c '
 BEGIN{RS="."}

 { if(NR==c) { print $1
               exit
             }
 }
'`"
	o="`echo $o | cut -d- -f1`" # strip dashed codenames

        # old misses a minor version, so new is newer
        if [ "$o" = "" ]; then return 0; fi

	if [ `echo "${o} > ${n}"|bc` = 1 ]; then return 1; fi
	if [ `echo "${n} > ${o}"|bc` = 1 ]; then return 0; fi
      

    done

    # return 1 (not new) if same version 
    if [ `echo "${o} == ${n}"|bc` = 1 ]; then return 1; fi

    return 0
}

fi # DYNE_SHELL_UTILS=included
