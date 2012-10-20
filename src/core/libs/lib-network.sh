#!/bin/bash

# configures network on host system according to installer settings
# if some variables are not set, we handle that transparantly
# however, at least $DHCP must be set, so we know what do to
# we assume that you checked whether networking has been setup before calling us
target_configure_network()
{
	# networking setup could have happened in a separate process (eg partial-configure-network),
	# so check if the settings file was created to be sure
	if [[ -f "$RUNTIME_DIR/aif-network-settings" ]]; then

		debug NETWORK "Configuring network settings on target system according to installer settings"

		source "$RUNTIME_DIR/aif-network-settings" 2>/dev/null || return 1

		IFN=${INTERFACE:-eth0} # new iface: a specified one, or the arch default

		if [[ -f "${var_TARGET_DIR}/etc/profile.d/proxy.sh" ]]; then
			sed -i "s/^export/#export/" "${var_TARGET_DIR}/etc/profile.d/proxy.sh" || return 1
		fi
		
		cp ${var_TARGET_DIR}/etc/network.d/examples/ethernet-dhcp ${var_TARGET_DIR}/etc/network.d/interfaces/ethernet0-dhcp
		
		if (( ! DHCP )); then
			cp ${var_TARGET_DIR}/etc/network.d/examples/ethernet-static ${var_TARGET_DIR}/etc/network.d/interfaces/ethernet0-static
			sed -i -e "s/ADDR.*/ADDR=$IPADDR/" \
			       -e "s/DNS.*/DNS=$DNS/" \
			       -e "s/GATEWAY.*/GATEWAY=$GW/" "${var_TARGET_DIR}/etc/network.d/interfaces/ethernet0-static" || return 1

			if [[ $DNS ]]; then
				for prev_dns in "${auto_added_dns[@]}"; do
					sed -i "/nameserver $prev_dns$/d" "${var_TARGET_DIR}/etc/resolv.conf"
				done
				echo "nameserver $DNS" >> "${var_TARGET_DIR}/etc/resolv.conf" || return 2
				auto_added_dns+=("$DNS")
			fi
		fi

		if [[ $PROXY_HTTP ]]; then
			echo "export http_proxy=$PROXY_HTTP" >> "${var_TARGET_DIR}/etc/profile.d/proxy.sh" || return 1
			chmod a+x "${var_TARGET_DIR}/etc/profile.d/proxy.sh" || return 1
		fi

		if [[ $PROXY_FTP ]]; then
			echo "export ftp_proxy=$PROXY_FTP" >> "${var_TARGET_DIR}/etc/profile.d/proxy.sh" || return 1
			chmod a+x "${var_TARGET_DIR}/etc/profile.d/proxy.sh" || return 1
		fi
	else
		debug NETWORK "Skipping Host Network Configuration - aif-network-settings not found"
	fi
	return 0
}
