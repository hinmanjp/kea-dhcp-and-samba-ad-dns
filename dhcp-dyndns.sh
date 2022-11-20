#!/bin/bash
# On FreeBSD change the above line to #!/usr/local/bin/bash
#
# /usr/local/bin/dhcp-dyndns.sh
#
# This script is for secure DDNS updates on Samba,
# it can also add the 'macAddress' to the Computers object.
#
# Version: 0.9.5
#
# Copyright (C) Rowland Penny 2020-2022
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# You may need to ensure that you have a useful path
# If you have 'path' problems, Uncomment the next line and adjust for
# your setup e.g. self-compiled Samba
#export PATH=/usr/local/samba/bin:/usr/local/samba/sbin:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

##########################################################################
#                                                                        #
#    You can optionally add the 'macAddress' to the Computers object.    #
#    Add 'dhcpduser' to the 'Domain Admins' group if used                #
#    Change the next line to 'yes' to make this happen                   #
Add_macAddress='no'
#                                                                        #
##########################################################################

Add_ReverseZones='no'

realm_fromsmbconf='yes'

# On FreeBSD change this to /usr/local/etc/dhcpduser.keytab
keytab=/etc/dhcpduser.keytab

notused_handle() {
    logger "notused function call ${*}"
    exit 123
}
unknown_handle() {
    logger "Unhandled function call ${*}"
    exit 123
}


lease4_recover () {
    ...
}

leases4_committed () {
    logger "leases4_committed function call ${*}"
    exit 123
}

lease4_decline () {
    logger "leases4_committed function call ${*}"
    exit 123
}
case "$1" in
    "lease4_renew")
        action="lease4_renew"
        ;;
    "lease4_expire")
        action="lease4_expire"
        ;;
    "lease4_recover")
        action="lease4_recover"
        ;;
    "leases4_committed")
        leases4_committed
        ;;
    "lease4_release")
        action="lease4_release"
        ;;
    "lease4_decline")
        lease4_decline
        ;;
    "lease6_renew")
        notused_handle
        ;;
    "lease6_rebind")
        notused_handle
        ;;
    "lease6_expire")
        notused_handle
        ;;
    "lease6_recover")
        notused_handle
        ;;
    "leases6_committed")
        notused_handle
        ;;
    "lease6_release")
        notused_handle
        ;;
    "lease6_decline")
        notused_handle
        ;;
    *)
        unknown_handle "${@}"
        ;;
esac

_KERBEROS () {
# get current time as a number
test=$(date +%d'-'%m'-'%y' '%H':'%M':'%S)
# Note: there have been problems with this
# check that 'date' returns something like

# Check for valid kerberos ticket
#logger "${test} [dyndns] : Running check for valid kerberos ticket"
klist -c "${KRB5CCNAME}" -s
if [ "$?" != "0" ]; then
    logger "${test} [dyndns] : Getting new ticket, old one has expired"
    kinit -F -k -t $keytab "${SETPRINCIPAL}"
    # On FreeBSD change the -F to --no-forwardable
    if [ "$?" != "0" ]; then
        logger "${test} [dyndns] : dhcpd kinit for dynamic DNS failed"
        exit 1
   fi
fi
}

rev_zone_info () {
    local RevZone="$1"
    local IP="$2"
    local rzoneip
    rzoneip=$(echo "$RevZone" | sed 's/\.in-addr.arpa//')
    local rzonenum
    rzonenum=$(echo "$rzoneip" |  tr '.' '\n')
    declare -a words
    for n in $rzonenum
    do
      words+=("$n")
    done
    local numwords="${#words[@]}"

    unset ZoneIP
    unset RZIP
    unset IP2add

    case "$numwords" in
        1) # single ip rev zone '192'
           ZoneIP=$(echo "${IP}" | awk -F '.' '{print $1}')
           RZIP="${rzoneip}"
           IP2add=$(echo "${IP}" | awk -F '.' '{print $4"."$3"."$2}')
           ;;
        2) # double ip rev zone '168.192'
           ZoneIP=$(echo "${IP}" | awk -F '.' '{print $1"."$2}')
           RZIP=$(echo "${rzoneip}" | awk -F '.' '{print $2"."$1}')
           IP2add=$(echo "${IP}" | awk -F '.' '{print $4"."$3}')
           ;;
        3) # triple ip rev zone '0.168.192'
           ZoneIP=$(echo "${IP}" | awk -F '.' '{print $1"."$2"."$3}')
           RZIP=$(echo "${rzoneip}" | awk -F '.' '{print $3"."$2"."$1}')
           IP2add=$(echo "${IP}" | awk -F '.' '{print $4}')
           ;;
        *) # should never happen
           exit 1
           ;;
    esac
}

BINDIR=$(samba -b | grep 'BINDIR' | grep -v 'SBINDIR' | awk '{print $NF}')
[[ -z $BINDIR ]] && logger "Cannot find the 'samba' binary, is it installed?\\nOr is your path set correctly ?\\n"
WBINFO="$BINDIR/wbinfo"

# DHCP Server hostname
Server=$(hostname -s)

if [ "$realm_fromsmbconf"=='yes' ]; then
  if [ ! -f /etc/samba/smb.conf ]; then
      logger "Required /etc/samba/smb.conf not found, it needs to be created."
      exit 1
  fi
  source <( grep realm /etc/samba/smb.conf | grep =  | sed 's/ //g' )

  REALM=$(echo ${realm^^})
  domain=$(echo ${realm,,})
else
  # DNS doma/etc/samba/smb.confin
  domain=$(hostname -d)
  if [ -z ${domain} ]; then
      logger "Cannot obtain domain name, is DNS set up correctly?"
      logger "Cannot continue... Exiting."
      exit 1
  fi
  # Samba realm
  REALM=$(echo ${domain^^})
fi


# krbcc ticket cache
export KRB5CCNAME="/tmp/dhcp-dyndns.cc"

# Kerberos principal
SETPRINCIPAL="dhcpduser@${REALM}"
# Kerberos keytab as above
# krbcc ticket cache : /tmp/dhcp-dyndns.cc
TESTUSER="$($WBINFO -u | grep 'dhcpduser')"
if [ -z "${TESTUSER}" ]; then
    logger "No AD dhcp user exists, need to create it first.. exiting."
    logger "you can do this by typing the following commands"
    logger "kinit Administrator@${REALM}"
    logger "samba-tool user create dhcpduser --random-password --description='Unprivileged user for DNS updates via ISC DHCP server'"
    logger "samba-tool user setexpiry dhcpduser --noexpiry"
    logger "samba-tool group addmembers DnsAdmins dhcpduser"
    exit 1
fi

# Check for Kerberos keytab
if [ ! -f /etc/dhcpduser.keytab ]; then
    logger "Required keytab $keytab not found, it needs to be created."
    logger "Use the following commands as root"
    logger "samba-tool domain exportkeytab --principal=${SETPRINCIPAL} $keytab"
    logger "chown XXXX:XXXX $keytab"
    logger "Replace 'XXXX:XXXX' with the user & group that dhcpd runs as on your distro"
    logger "chmod 400 $keytab"
    exit 1
fi


# Variables supplied by dhcpd.conf
#action="$1"
ip="${LEASE4_ADDRESS}"
DHCID="${LEASE4_CLIENT_ID}"
name="${LEASE4_HOSTNAME%%.*}"

# Exit if no ip address or mac-address
if [ -z "${ip}" ]; then
    logger "NO IP"
    exit 1
fi

# Exit if no computer name supplied, unless the action is 'delete'
if [ -z "${name}" ]; then
# change action label and test command
    if [ "${action}" = "delete" ]; then
        name=$(host -t PTR "${ip}" | awk '{print $NF}' | awk -F '.' '{print $1}')
    else
        logger "No hostname"
        exit 1
    fi
fi

# exit if name contains a space
case ${name} in
  *\ * ) logger "Invalid hostname '${name}' ...Exiting"
         exit
         ;;
esac

## update ##
case "${action}" in
    lease4_renew|lease4_recover|lease4_release)

        _KERBEROS
        count=0
        # does host have an existing 'A' record ?
        A_REC=$(samba-tool dns query ${Server} ${domain} ${name} A -k yes 2>/dev/null | grep 'A:' | awk '{print $2}')
        if [[ -z $A_REC ]]; then
            # no A record to delete
            result1=0
            samba-tool dns add ${Server} ${domain} "${name}" A ${ip} -k yes
            result2="$?"
        elif [ "$A_REC" = "${ip}" ]; then
              # Correct A record exists, do nothing
              logger "Correct 'A' record exists, not updating."
              result1=0
              result2=0
              count=$((count+1))
        elif [ "$A_REC" != "${ip}" ]; then
              # Wrong A record exists
              logger "'A' record changed, updating record."
              samba-tool dns delete ${Server} ${domain} "${name}" A ${A_REC} -k yes
              result1="$?"
              samba-tool dns add ${Server} ${domain} "${name}" A ${ip} -k yes
              result2="$?"
        fi

        # get existing reverse zones (if any)
        if [ "$Add_ReverseZones" != 'no' ]; then
            ReverseZones=$(samba-tool dns zonelist ${Server} -k yes --reverse | grep 'pszZoneName' | awk '{print $NF}')
            if [ -z "$ReverseZones" ]; then
                logger "No reverse zone found, not updating"
                result3='0'
                result4='0'
                count=$((count+1))
            else
                for revzone in $ReverseZones
                do
                  rev_zone_info "$revzone" "${ip}"
                  logger "rev_zone_info $revzone ${ip}"
                  if [[ ${ip} = $ZoneIP* ]] && [ "$ZoneIP" = "$RZIP" ]; then
                      logger "rev_zone_info zoneip $revzone ${ip} $ZoneIP ${IP2add}"
                      # does host have an existing 'PTR' record ?
                      PTR_REC=$(samba-tool dns query ${Server} ${revzone} ${IP2add} PTR -k yes 2>/dev/null | grep 'PTR:' | awk '{print $2}' | awk -F '.' '{print $1}')
                      if [[ -z $PTR_REC ]]; then
                          # no PTR record to delete
                          result3=0
                          samba-tool dns add ${Server} ${revzone} ${IP2add} PTR "${name}".${domain} -k yes
                          result4="$?"
                          break
                      elif [ "$PTR_REC" = "${name}" ]; then
                            # Correct PTR record exists, do nothing
                            logger "Correct 'PTR' record exists, not updating."
                            result3=0
                            result4=0
                            count=$((count+1))
                            break
                      elif [ "$PTR_REC" != "${name}" ]; then
                            # Wrong PTR record exists
                            # points to wrong host
                            logger "'PTR' record changed, updating record."
                            samba-tool dns delete ${Server} ${revzone} ${IP2add} PTR "${PTR_REC}".${domain} -k yes
                            result3="$?"
                            samba-tool dns add ${Server} ${revzone} ${IP2add} PTR "${name}".${domain} -k yes
                            result4="$?"
                            break
                      fi
                  else
                      continue
                  fi
                done
            fi
        fi
        ;;
 lease4_expire)
        _KERBEROS

        count=0
        samba-tool dns delete ${Server} ${domain} "${name}" A ${ip} -k yes
        result1="$?"
        # get existing reverse zones (if any)
        if [ "$Add_ReverseZones" != 'no' ]; then
            ReverseZones=$(samba-tool dns zonelist ${Server} --reverse -k yes | grep 'pszZoneName' | awk '{print $NF}')
            if [ -z "$ReverseZones" ]; then
                logger "No reverse zone found, not updating"
                result2='0'
                count=$((count+1))
            else
                for revzone in $ReverseZones
                do
                  rev_zone_info "$revzone" "${ip}"
                  if [[ ${ip} = $ZoneIP* ]] && [ "$ZoneIP" = "$RZIP" ]; then
                      host -t PTR ${ip} > /dev/null 2>&1
                      if [ "$?" -eq 0 ]; then
                          samba-tool dns delete ${Server} ${revzone} ${IP2add} PTR "${name}".${domain} -k yes
                          result2="$?"
                      else
                          result2='0'
                          count=$((count+1))
                      fi
                      break
                  else
                      continue
                  fi
                done
            fi
        fi
        result3='0'
        result4='0'
        ;;
      *)
        logger "Invalid action specified"
        exit 103
        ;;
esac

result="${result1}:${result2}:${result3}:${result4}"

if [ "$count" -eq 0 ]; then
    if [ "${result}" != "0:0:0:0" ]; then
        logger "DHCP-DNS $action failed: ${result}"
        exit 1
    else
        logger "DHCP-DNS $action succeeded"
    fi
fi

exit 0
