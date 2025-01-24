#!/bin/bash
# On FreeBSD change the above line to #!/usr/local/bin/bash
#
# /usr/local/bin/dhcp-dyndns.sh
#
# This script is for secure DDNS updates on Samba.
#
# Version: 0.9.5 patch-mkaraki-1
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
#
# LEGAL INFORMATION:
#  Original Script: Rowland Penny
#   Original Source: https://wiki.samba.org/index.php/Configure_DHCP_to_update_DNS_records
#  Modify script for kea-dhcp: Jean-Philippe Martin
#   Original Source: https://www.spinics.net/lists/samba/msg176222.html
#
# Merge scripts and fix some bugs: mkaraki

# You may need to ensure that you have a useful path
# If you have 'path' problems, Uncomment the next line and adjust for
# your setup e.g. self-compiled Samba
#export PATH=/usr/local/samba/bin:/usr/local/samba/sbin:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

# ******  PREREQUISITES  ******
<<comment
# create a user that will run the script
samba-tool user create dhcpduser --description="Unprivileged user for TSIG-GSSAPI DNS updates via ISC DHCP server" --random-password

# never expire password
samba-tool user setexpiry dhcpduser --noexpiry

# add user the the DnsAdmins group
samba-tool group addmembers DnsAdmins dhcpduser

# export keytab
# On FreeBSD change /etc/dhcpduser.keytab to /usr/local/etc/dhcpduser.keytab
DOMAIN=$(hostname -d)
REALM=${DOMAIN^^}
samba-tool domain exportkeytab --principal=dhcpduser@$REALM /etc/dhcpduser.keytab

# change owner to the system running the kea dhcp service
KEA_USER=$(ps aux | grep kea-dhcp4 | grep -v grep | head -n 1 | grep -Eo "^[^ ]+")
chown $KEA_USER:$KEA_USER  /etc/dhcpduser.keytab
chmod 400  /etc/dhcpduser.keytab

comment



##########################################################################
#                                                                        #
#    You can optionally add the 'macAddress' to the Computers object.    #
#    Add 'dhcpduser' to the 'Domain Admins' group if used                #
#    Change the next line to 'yes' to make this happen                   #
#    ldb-tools packages is required for this to work                     #
#    apt install -y ldb-tools
Add_macAddress='no'
#                                                                        #
##########################################################################

Add_ReverseZones='yes'

realm_fromsmbconf='yes'

# Samba DNS Server hostname
Server=$(hostname -s)

# On FreeBSD change this to /usr/local/etc/dhcpduser.keytab
keytab=/etc/dhcpduser.keytab


if ! [[ "$1" =~ ^(lease4_renew|lease4_recover|lease4_expire|lease4_release|leases4_committed)$ ]]; then 
    logger "kea hookpoint not used: ${*}"
    exit 123
fi


calculate_reverse_dns_zones() {
    local ip="$1"

    # Split the IPv4 address into its octets
    IFS='.' read -r octet1 octet2 octet3 octet4 <<< "$ip"
    
    # Create an array to store reverse DNS zones
    zones=()
    
    # Most specific to least specific
    zones+=("$octet4.$octet3.$octet2.$octet1.in-addr.arpa") # Full IP
    zones+=("$octet3.$octet2.$octet1.in-addr.arpa")       # Subnet
    zones+=("$octet2.$octet1.in-addr.arpa")               # Class C
    zones+=("$octet1.in-addr.arpa")                        # Class B

    echo "${zones[@]}"
}


BINDIR=$(samba -b | grep 'BINDIR' | grep -v 'SBINDIR' | awk '{print $NF}')
[[ -z $BINDIR ]] && logger "Cannot find the 'samba' binary, is it installed?\nOr is your path set correctly ?\n"
WBINFO="$BINDIR/wbinfo"

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
    members=$(samba-tool group listmembers "Domain Admins")

   # Loop through members to find the first enabled one
    for user in $members; do
        # Check if the user is enabled
        status=$(samba-tool user show "$user" | grep -c 'objectClass: user' )
        if [ "$status" -gt 0 ]; then
            break
        fi
    done
    
    logger "kinit $user@${REALM}"
    logger "samba-tool user create dhcpduser --random-password --description='Unprivileged user for DNS updates via ISC DHCP server'"
    logger "samba-tool user setexpiry dhcpduser --noexpiry"
    logger "samba-tool group addmembers DnsAdmins dhcpduser"
    exit 1
fi

# Check for Kerberos keytab
if [ ! -f "$keytab" ]; then
    logger "Required keytab $keytab not found, it needs to be created."
    logger "Use the following commands as root"
    logger "samba-tool domain exportkeytab --principal=${SETPRINCIPAL} $keytab"
    logger "chown XXXX:XXXX $keytab"
    logger "Replace 'XXXX:XXXX' with the user & group that kea dhcp runs as on your distro"
    logger "chmod 400 $keytab"
    exit 1
fi


# Check for valid kerberos ticket
#logger "${test} [dyndns] : Running check for valid kerberos ticket"
klist -c -s 2>/dev/null
if [ "$?" != "0" ]; then
    logger "${test} [dyndns] : Getting new kerberos ticket, old one has expired"
    kinit -F -k -t $keytab "${SETPRINCIPAL}" 
    # On FreeBSD change the -F to --no-forwardable
    if [ "$?" != "0" ]; then
        logger "${test} [dyndns] : dhcpd kinit for dynamic DNS failed"
        exit 1
   fi
fi


# Variables supplied by dhcpd.conf
if [ "$1" = "leases4_committed" ]; then
    # can also lookup look up useful data based on the leases_committed query4_hwaddr value. 
    # Example query: SELECT INET_NTOA(address), hostname FROM lease4 WHERE hwaddr = UNHEX('2CAA8ED7632C');
    # Can also use:  echo '{"command":"lease4-get","arguments":{"identifier":"2c:aa:8e:d7:63:2c", "identifier-type": "hw-address", "subnet-id":2886799616}}' | socat UNIX:/tmp/kea4-ctrl-socket -,ignoreeof
    ip="${LEASES4_AT0_ADDRESS}"
    DHCID="${LEASES4_AT0_HWADDR}"
    name="${LEASES4_AT0_HOSTNAME}"
else
    ip="${LEASE4_ADDRESS}"
    DHCID="${LEASE4_CLIENT_ID}"
    name="${LEASE4_HOSTNAME%%.*}"
fi

logger "Hook event: ${1}, IP: ${ip}, HWID: ${DHCID}, Name: ${name}"
# Exit if both ip address & mac address are missing
if [ -z "${ip}" ] && [ -z "$DHCID" ]; then
    logger "NO IP or MAC address"
    exit 1
fi

# Exit if no computer name supplied - kea dhcp should always provide the hostname
if [ -z "${name}" ]; then
    logger "No hostname"
    exit 1
fi

# exit if name contains a space
case ${name} in
  *\ * ) logger "Invalid hostname '${name}' ...Exiting"
         exit
         ;;
esac


if [ "$Add_ReverseZones" != 'no' ]; then
    dns_zones=( $(calculate_reverse_dns_zones "$ip") )
    revzone=$(samba-tool dns zonelist ${Server} --use-kerberos=required | grep "pszZoneName" | grep -m 1 -o -P "( \K${dns_zones[1]})|( \K${dns_zones[2]})|( \K${dns_zones[3]})")
    revip={dns_zones[0]}
fi

## create / update dns record ##
case "$1" in
    lease4_renew|lease4_recover|leases4_committed)

        count=0
        # does host have an existing 'A' record ?
        A_REC=$(samba-tool dns query ${Server} ${domain} ${name} A --use-kerberos=required 2>/dev/null | grep 'A:' | awk '{print $2}')
        if [[ -z $A_REC ]]; then
            # no A record to delete
            result1=0
            samba-tool dns add ${Server} ${domain} "${name}" A ${ip} --use-kerberos=required 2>/dev/null
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
              samba-tool dns delete ${Server} ${domain} "${name}" A ${A_REC} --use-kerberos=required 2>/dev/null
              result1="$?"
              samba-tool dns add ${Server} ${domain} "${name}" A ${ip} --use-kerberos=required 2>/dev/null
              result2="$?"
        fi

        # get existing reverse zones (if any)
        if [ "$Add_ReverseZones" != 'no' ]; then
            
            if [ -z $revzone ] ; then
                # create a reverse lookup zone using the most specific zone
                logger "No matching reverse zone found. Attempting to create ${dns_zones[0]}"
                samba-tool dns zonecreate ${Server} ${dns_zones[1]} --use-kerberos=required >/dev/null
                if [ $? -ne 0 ] ; then
                    logger "Failed to create the reverse lookup zone. Can't do any updates. Exiting."
                    break
                else
                    revzone=${dns_zones[0]}
                fi
            fi
            
            # does host have an existing 'PTR' record ?
            PTR_REC=$(samba-tool dns query ${Server} ${revzone} ${revip} PTR --use-kerberos=required 2>/dev/null | grep 'PTR:' | awk '{print $2}' | awk -F '.' '{print $1}')
            if [[ -z $PTR_REC ]]; then
              # no existing record. Create one.
              result3=0
              samba-tool dns add ${Server} ${revzone} ${ip} PTR "${name}".${domain} --use-kerberos=required 2>/dev/null
              result4="$?"
            elif [ "$PTR_REC" = "${name}" ]; then
                # Correct PTR record exists, do nothing
                logger "Correct 'PTR' record exists, not updating."
                result3=0
                result4=0
                count=$((count+1))
            elif [ "$PTR_REC" != "${name}" ]; then
                # Wrong PTR record exists
                # delete the existing record and create the correct one.
                logger "'PTR' record changed, updating record."
                samba-tool dns delete ${Server} ${revzone} ${revip} PTR "${PTR_REC}".${domain} --use-kerberos=required 2>/dev/null
                result3="$?"
                samba-tool dns add ${Server} ${revzone} ${revip} PTR "${name}".${domain} --use-kerberos=required 2>/dev/null
                result4="$?"
            fi
  
        fi
        ;;
 lease4_expire|lease4_release)

        count=0
        samba-tool dns delete ${Server} ${domain} "${name}" A ${ip} --use-kerberos=required 2>/dev/null
        result1="$?"
        
        # get existing reverse zones (if any)
        if [ "$Add_ReverseZones" != 'no' ]; then
            if [ -z "$revzone" ]; then
                logger "No reverse zone found, not updating"
                result2='0'
                count=$((count+1))
            else
                # does a reverse lookup record exist for this ip address?
                host -t PTR ${ip} > /dev/null 2>&1
                if [ "$?" -eq 0 ]; then
                  samba-tool dns delete ${Server} ${revzone} ${revip} PTR "${name}".${domain} --use-kerberos=required 2>/dev/null
                  result2="$?"
                fi
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



if [ "$Add_macAddress" != 'no' ]
then
	if [ -n "$DHCID" ]
	then
		Computer_Object=$(ldbsearch "$KTYPE" -H ldap://"$Server" "(&(objectclass=computer)(objectclass=ieee802Device)(cn=$name))" | grep -v '#' | grep -v 'ref:')
		if [ -z "$Computer_Object" ]
		then
			# Computer object not found with the 'ieee802Device' objectclass, does the computer actually exist, it should.
			Computer_Object=$(ldbsearch "$KTYPE" -H ldap://"$Server" "(&(objectclass=computer)(cn=$name))" | grep -v '#' | grep -v 'ref:')
			if [ -z "$Computer_Object" ]
			then
				logger "Computer '$name' not found. Exiting."
				exit 68
			else
				DN=$(echo "$Computer_Object" | grep 'dn:')
				objldif="$DN
changetype: modify
add: objectclass
objectclass: ieee802Device"

				attrldif="$DN
changetype: modify
add: macAddress
macAddress: $DHCID"

				# add the ldif
				echo "$objldif" | ldbmodify "$KTYPE" -H ldap://"$Server"
				ret="$?"
				if [ $ret -ne 0 ]
				then
					logger "Error modifying Computer objectclass $name in AD."
					exit "${ret}"
				fi
				sleep 2
				echo "$attrldif" | ldbmodify "$KTYPE" -H ldap://"$Server"
				ret="$?"
				if [ "$ret" -ne 0 ]; then
					logger "Error modifying Computer attribute $name in AD."
					exit "${ret}"
				fi
				unset objldif
				unset attrldif
				logger "Successfully modified Computer $name in AD"
			fi
	else
		DN=$(echo "$Computer_Object" | grep 'dn:')
		attrldif="$DN
changetype: modify
replace: macAddress
macAddress: $DHCID"

		echo "$attrldif" | ldbmodify "$KTYPE" -H ldap://"$Server"
		ret="$?"
		if [ "$ret" -ne 0 ]
		then
			logger "Error modifying Computer attribute $name in AD."
			exit "${ret}"
		fi
			unset attrldif
			logger "Successfully modified Computer $name in AD"
		fi
	fi
fi


exit 0
