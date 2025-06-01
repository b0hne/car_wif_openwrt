#!/bin/sh
###############################################################################
#  VERBOSE Bootstrap – OpenWrt 22.03-snapshot (ramips/mt7620)   2025-05-31
#  --------------------------------------------------------------------------
#  • Car Wi-Fi AP : user-defined SSID/PSK (2.4 GHz, ch 1)
#  • LTE / QMI    : interface “sim4g” on /dev/cdc-wdm0
#  • Firewall     : sim4g joins WAN zone (masq, mtu_fix)
#  • EU-roam guard: hot-plug block + 1-min watchdog
#  • Home hand-over: disables Car Wi-Fi when HOME_SSID is nearby
#  • Idempotent   : safe to rerun after a reset
###############################################################################

set -ex                    # -e = abort on error, -x = echo each command
tag=setup-script
log() { echo "[$tag] $*"; logger -t "$tag" "$*"; }

###############################################################################
# User-configurable parameters
###############################################################################
CAR_SSID="Car Wi-Fi"        # SSID the router broadcasts on the road
CAR_PSK="ChangeMe123"      # WPA2-PSK for the Car Wi-Fi
HOME_SSID="Home Wi-Fi"     # SSID whose presence disables Car Wi-Fi

###############################################################################
# 1. Wi-Fi – regenerate /etc/config/wireless
###############################################################################
log "Resetting Wi-Fi configuration"
/bin/rm -f /etc/config/wireless

set +e                      # wifi config often exits 1
wifi config || true
set -e

uci -q delete wireless.@wifi-iface[0].start_disabled || true

uci batch <<EOF
set wireless.@wifi-iface[0].mode='ap'
set wireless.@wifi-iface[0].ssid='$CAR_SSID'
set wireless.@wifi-iface[0].encryption='psk2'
set wireless.@wifi-iface[0].key='$CAR_PSK'
set wireless.@wifi-iface[0].network='lan'
set wireless.@wifi-iface[0].disabled='0'
set wireless.radio0.channel='1'
EOF
uci commit wireless

wifi reload  || true
wifi up      || true
log "Wi-Fi AP '$CAR_SSID' ready"

###############################################################################
# 2. LTE / QMI – interface “sim4g”
###############################################################################
log "Configuring LTE interface 'sim4g'"
uci -q delete network.sim4g || true
uci batch <<'EOF'
set network.sim4g=interface
set network.sim4g.proto='qmi'
set network.sim4g.device='/dev/cdc-wdm0'
set network.sim4g.apn='internet'
set network.sim4g.auth='none'
set network.sim4g.pdptype='ipv4'
set network.sim4g.auto='1'
set network.sim4g.metric='10'
set network.sim4g.defaultroute='1'
set network.sim4g.peerdns='1'
set network.sim4g.roaming='1'
EOF
uci commit network
log "Interface 'sim4g' defined"

###############################################################################
# 3. Firewall – add sim4g to WAN zone
###############################################################################
log "Updating firewall zones"
WAN_IDX="$(uci -q show firewall | awk -F'[][]' '/\\.name=.wan./{print $2;exit}')"
[ -z "$WAN_IDX" ] && WAN_IDX=1

uci -q get firewall.@zone["$WAN_IDX"].network | grep -qw sim4g || \
    uci add_list firewall.@zone["$WAN_IDX"].network='sim4g'
uci set firewall.@zone["$WAN_IDX"].masq='1'
uci set firewall.@zone["$WAN_IDX"].mtu_fix='1'

LAN_IDX="$(uci -q show firewall | awk -F'[][]' '/\\.name=.lan./{print $2;exit}')"
[ -n "$LAN_IDX" ] && uci set firewall.@zone["$LAN_IDX"].forward='ACCEPT'
uci commit firewall
log "Firewall updated"

###############################################################################
# 4. Hot-plug guard – block non-EU MCCs
###############################################################################
log "Installing non-EU MCC guard"
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-block-non-eu <<"EOF"
#!/bin/sh
IFACE="$INTERFACE"; DEV="/dev/cdc-wdm0"
[ "$IFACE" = "sim4g" ] || exit 0
[ "$ACTION" = "ifup"  ] || exit 0
TRIES=0; MAX=30; MCC=""
while [ $TRIES -lt $MAX ]; do
  MCC=$(uqmi -d "$DEV" --get-serving-system 2>/dev/null |
        grep -o '"plmn_mcc": *[0-9]*' | grep -o '[0-9]*')
  [ -n "$MCC" ] && break
  sleep 1; TRIES=$((TRIES+1))
done
EU_MCCS="202 204 206 208 212 213 214 216 218 219 220 222 226 228 230 231 232 \
234 235 238 240 242 244 246 247 248 250 255 257 259 260 262 266 268 270 272 \
274 276 278 280 282 283 284 286 288 292 293 294 295 297 298"
logger -t sim4g-hotplug "Serving MCC=$MCC"
echo "$EU_MCCS" | grep -qw "$MCC" && exit 0
logger -t sim4g-hotplug "Non-EU MCC $MCC – ifdown"
ifdown "$IFACE"
EOF
chmod +x /etc/hotplug.d/iface/99-block-non-eu

###############################################################################
# 5. Roaming watchdog – cron every minute
###############################################################################
log "Installing roaming watchdog"
cat > /root/roaming_recheck.sh <<"EOF"
#!/bin/sh
DEV="/dev/cdc-wdm0"; IFACE="sim4g"
if ifstatus "$IFACE" | grep -q '"up": true'; then exit 0; fi
MCC=$(uqmi -d "$DEV" --get-serving-system 2>/dev/null |
      grep -o '"plmn_mcc": *[0-9]*' | grep -o '[0-9]*')
EU_MCCS="202 204 206 208 212 213 214 216 218 219 220 222 226 228 230 231 232 \
234 235 238 240 242 244 246 247 248 250 255 257 259 260 262 266 268 270 272 \
274 276 278 280 282 283 284 286 288 292 293 294 295 297 298"
logger -t sim4g-recheck "MCC=$MCC"
echo "$EU_MCCS" | grep -qw "$MCC" && ifup "$IFACE"
EOF
chmod +x /root/roaming_recheck.sh
# --- ensure cron spool exists (safe on first boot) --------------------------
[ -d /etc/crontabs ]      || mkdir -p /etc/crontabs
[ -f /etc/crontabs/root ] || touch /etc/crontabs/root
# ---------------------------------------------------------------------------

sed -i '/roaming_recheck\.sh/d' /etc/crontabs/root
echo "* * * * * /root/roaming_recheck.sh" >> /etc/crontabs/root

###############################################################################
# 6. AP auto-toggle – cron every minute
###############################################################################
log "Installing AP auto-toggle"
cat > /root/ap_toggle.sh <<EOF
#!/bin/sh
ORIG_SSID="$CAR_SSID"; TEMP_SSID="1"; SCAN_FOR="$HOME_SSID"
RADIO_IF="wlan0"; IDX=0
log() { logger -t ap-toggle "\$*"; }
ap_enabled() {
  MODE=\$(uci get wireless.@wifi-iface[\$IDX].mode)
  DIS=\$(uci get wireless.@wifi-iface[\$IDX].disabled)
  [ "\$MODE" = "ap" ] && [ "\$DIS" = "0" ]
}
scan_seen() { iwinfo "\$RADIO_IF" scan | grep -q "ESSID: \"\$SCAN_FOR\""; }
if ap_enabled; then
  log "AP on – scanning for \$SCAN_FOR"
  if scan_seen; then
    log "\$SCAN_FOR present – disabling AP"
    uci set wireless.@wifi-iface[\$IDX].disabled='1'
    uci commit wireless && wifi reload
  fi
else
  log "AP off – temp enable \$TEMP_SSID"
  uci set wireless.@wifi-iface[\$IDX].ssid="\$TEMP_SSID"
  uci set wireless.@wifi-iface[\$IDX].disabled='0'
  uci commit wireless && wifi reload
  sleep 5
  if scan_seen; then
    log "\$SCAN_FOR present – keeping AP off"
    uci set wireless.@wifi-iface[\$IDX].disabled='1'
  else
    log "\$SCAN_FOR absent – restoring \$ORIG_SSID"
    uci set wireless.@wifi-iface[\$IDX].ssid="\$ORIG_SSID"
    uci set wireless.@wifi-iface[\$IDX].disabled='0'
  fi
  uci commit wireless && wifi reload
fi
EOF
chmod +x /root/ap_toggle.sh
sed -i '/ap_toggle\.sh/d' /etc/crontabs/root
echo "* * * * * /root/ap_toggle.sh" >> /etc/crontabs/root

###############################################################################
# 7. Kick services
###############################################################################
log "Restarting network, firewall, cron"
/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/cron restart
log "✅ Setup complete – AP '$CAR_SSID', LTE fallback, EU-roam guard ready"
