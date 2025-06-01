# Car Wi‑Fi Bootstrap 🐾

*Turn an OpenWrt 22.03‑snapshot (ramips/mt7620) router into a **Car Wi‑Fi** hotspot that politely backs off whenever your **Home Wi‑Fi** is nearby.*

---

## Why?

You need Internet on the road (*Car Wi‑Fi*), but the moment you park at home you’d rather let your main router (*Home Wi‑Fi*) take over. This script delivers exactly that:

* **Car Wi‑Fi AP** — SSID `Car Wi-Fi` (WPA2‑PSK, channel 1)
* **LTE fallback WAN** via QMI interface **`sim4g`** (`/dev/cdc-wdm0`)
* **EU‑only roaming guard** (hot‑plug + watchdog)
* **Automatic hand‑over:** when your *Home Wi‑Fi* is detected, the *Car Wi‑Fi* AP disables itself and stays silent until the home SSID disappears again.
* Fully **idempotent** — safe to rerun after a reset ✔️

No extra packages and no Internet connection are required.

---

## Quick‑start — install Car Wi‑Fi

```sh
# copy script to the router
scp setup.sh root@192.168.1.1:/root/
# execute once
ssh root@192.168.1.1 'chmod +x /root/setup.sh && /root/setup.sh'
# watch syslog  (-x output also echoes on the SSH console)
```

*≈ 15 s later* you should see `✅ Setup complete – Car Wi‑Fi ready` in the log.

---

### User‑configurable parameters

Edit the three variables at the very top of **setup.sh** before running:

```sh
CAR_SSID="Car Wi-Fi"
CAR_PSK="ChangeMe123"
HOME_SSID="Home Wi-Fi"
```

They propagate automatically to the Wi‑Fi configuration and the hand‑over logic.

## Features in detail

| Block                  | Purpose                                                | Car Wi‑Fi ⇆ Home Wi‑Fi angle             |
| ---------------------- | ------------------------------------------------------ | ---------------------------------------- |
| **1 Wi‑Fi (Car)**      | Creates the **Car Wi‑Fi AP**                           | Active only when *Home Wi‑Fi* is absent  |
| **2 LTE (Car)**        | Defines `sim4g` LTE WAN                                | Provides Internet to Car Wi‑Fi           |
| **3 Firewall**         | Adds `sim4g` to WAN zone                               | NAT + MSS‑clamp for clients              |
| **4 Hot‑plug guard**   | Drops LTE outside EU                                   | Prevents pricey roaming while travelling |
| **5 Roaming watchdog** | Checks every minute; re‑enables LTE when back in EU    |                                          |
| **6 AP auto‑toggle**   | Detects **Home Wi‑Fi** SSID and disables **Car Wi‑Fi** | Seamless hand‑over                       |
| **7 Kick services**    | Restarts network, firewall, cron                       |                                          |

---

## How the hand‑over works

1. **Driving around** — only *Car Wi‑Fi* exists; your devices connect to it and use LTE.
2. **Arrive home** — router sees *Home Wi‑Fi* SSID ➜ disables its own AP.
3. Your phone/laptop hops to *Home Wi‑Fi* automatically.
4. **Leaving again** — *Home Wi‑Fi* disappears; after one scan cycle the script restores the *Car Wi‑Fi* AP and you’re back online via LTE.

All events are logged under the tag `ap-toggle`.

---

## Requirements

* **OpenWrt 22.03‑snapshot** (also tested on stable 22.03.x)
* Target **ramips/mt7620** (e.g. GL‑MT300N‑V2, TP‑Link TL‑WR841 v9/v11, …)
* USB LTE modem exposed as **QMI** (`/dev/cdc-wdm0`)
* BusyBox `sh` (standard in OpenWrt)

---

## Customisation cheat‑sheet

| Need                          | Edit                                            | Car⁄Home relevance               |
| ----------------------------- | ----------------------------------------------- | -------------------------------- |
| **Car Wi‑Fi SSID / key**      | Top‑of‑script variables `CAR_SSID` / `CAR_PSK`) |                                  |
| **Home Wi‑Fi SSID to detect** | Section 6 `SCAN_FOR="Home Wi-Fi"`               | Replace with your real home SSID |
| **APN / auth**                | Section 2 (`network.sim4g`)                     |                                  |
| **EU MCC list**               | Sections 4 & 5 `EU_MCCS=…`                      |                                  |
| **Cron intervals**            | Last two lines in `/etc/crontabs/root`          |                                  |

---

## Logs

* **Setup run:** `logread -e setup-script`
* **LTE guard:** `logread -e sim4g-hotplug -e sim4g-recheck`
* **AP toggle:** `logread -e ap-toggle`

---


## Uninstall

```sh
rm -f /etc/hotplug.d/iface/99-block-non-eu
sed -i '/roaming_recheck\.sh/d;/ap_toggle\.sh/d' /etc/crontabs/root
# revert configs manually or factory-reset(firstboot && reboot)
```
