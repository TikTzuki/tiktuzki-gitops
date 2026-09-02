---
title: "Static IP on node1 (Netplan)"
tags: [networking]
sidebar_position: 2
---

# Static IP for node1 with Netplan

A DHCP lease that moves node1's address breaks two things at once: the MicroK8s API
certificates (SANs are pinned to the node IP) and every NPM proxy host on the VPS pointing
at the overlay peer. This pins the address with Netplan.

## Starting state

Ubuntu with **`systemd-networkd`** as the renderer (`NetworkManager` inactive), one config
file at `/etc/netplan/00-installer-config.yaml`.

| Interface | Kind     | State        | Address                            |
|-----------|----------|--------------|------------------------------------|
| `enp4s0`  | Ethernet | `NO-CARRIER` | —                                  |
| `wlp9s0`  | Wi-Fi    | UP, **DHCP** | `192.168.1.5/24`, gw `192.168.1.1` |
| `wt0`     | NetBird  | UP           | `100.66.50.60/16`                  |

```bash
ip -o link show; ip -4 -o addr show; ip route
systemctl is-active systemd-networkd NetworkManager
```

:::danger[Keep the address the node already has]
MicroK8s puts the node IP in its API-server cert SANs and Calico registers the node by it.
Moving to a *different* IP means regenerating certs
(`sudo microk8s refresh-certs --cert server.crt`) and re-checking Calico. Also make sure
the address is outside the router's DHCP pool, or reserved for the NIC's MAC.
:::

## Prerequisite for Wi-Fi

`wifis:` under the `networkd` renderer needs **`wpasupplicant`** — netplan doesn't speak WPA
itself. `netplan generate` writes `/run/netplan/wpa-wlp9s0.conf` plus a
`netplan-wpa-wlp9s0.service` that wraps `wpa_supplicant`.

```bash
dpkg -l wpasupplicant >/dev/null 2>&1 && echo present || sudo apt install -y wpasupplicant
sudo apt install -y iw          # optional, but the only way to debug association later
```

:::danger[Missing `wpasupplicant` fails silently]
`netplan apply` still **exits 0**. The generated unit fails, the interface never associates,
and no address appears — with no error pointing at the cause. Confirm with
`systemctl status netplan-wpa-wlp9s0.service` rather than trusting the exit code.
:::

Ubuntu Server's minimal profile omits it; desktop installs usually get it via
NetworkManager, which is inactive here. Also check `linux-firmware` is present — a missing
chipset blob produces the identical symptom. Skip this section entirely if Wi-Fi already
associates on the box, which proves both are installed.

## Option 1 — Wi-Fi only

No cable, no cluster disruption.

```yaml title="/etc/netplan/00-installer-config.yaml"
network:
  version: 2
  renderer: networkd
  wifis:
    wlp9s0:
      dhcp4: false
      addresses: [ 192.168.1.5/24 ]
      routes:
        - { to: default, via: 192.168.1.1 }
      nameservers:
        addresses: [ 1.1.1.1, 8.8.8.8 ]
      access-points:
        "YOUR_SSID":
          password: "YOUR_PSK"
```

## Option 2 — Ethernet only (best for a k8s node)

Wi-Fi roaming and power-save cause intermittent API timeouts. **Confirm carrier before
applying** (`ip -o link show enp4s0` must not say `NO-CARRIER`) or the box drops off the
network.

```yaml title="/etc/netplan/00-installer-config.yaml"
network:
  version: 2
  renderer: networkd
  ethernets:
    enp4s0:
      dhcp4: false
      addresses: [ 192.168.1.5/24 ]
      routes:
        - { to: default, via: 192.168.1.1 }
      nameservers:
        addresses: [ 1.1.1.1, 8.8.8.8 ]
```

## Option 3 — Both, Ethernet preferred

Wired carries the cluster address; Wi-Fi holds a second address behind a higher-metric
default route, used only when the cable is out.

```yaml title="/etc/netplan/00-installer-config.yaml"
network:
  version: 2
  renderer: networkd
  ethernets:
    enp4s0:
      dhcp4: false
      optional: true                    # don't block boot waiting for carrier
      addresses: [ 192.168.1.5/24 ]
      routes:
        - { to: default, via: 192.168.1.1, metric: 100 }
      nameservers:
        addresses: [ 1.1.1.1, 8.8.8.8 ]
  wifis:
    wlp9s0:
      dhcp4: false
      optional: true
      addresses: [ 192.168.1.4/24 ]
      routes:
        - { to: default, via: 192.168.1.1, metric: 600 }
      nameservers:
        addresses: [ 1.1.1.1, 8.8.8.8 ]
      access-points:
        "YOUR_SSID":
          password: "YOUR_PSK"
```

:::caution[The node IP moves on failover]
The interfaces must **not** share `192.168.1.5` — duplicate addresses on one L2 segment
cause ARP conflicts. So with the cable out, the node's source address becomes
`192.168.1.4`, which isn't in the cert SANs: SSH and NetBird keep working, but
kubelet ↔ API-server may error until the cable is back. This is a rescue path, not HA.
Add `IP.4 = 192.168.1.4` to `/var/snap/microk8s/current/certs/csr.conf.template` and run
`sudo microk8s refresh-certs --cert server.crt` to make failover clean.
:::

## Applying safely over SSH

Changing the network through the link you're connected on can lock you out.

Interactive — auto-reverts unless you press Enter:

```bash
sudo netplan try --timeout 120
```

Non-interactive — an armed rollback that survives losing the link:

```bash
sudo mkdir -p /root/netplan-backup
sudo cp -a /etc/netplan/00-installer-config.yaml /root/netplan-backup/

# edit the file, then validate WITHOUT applying
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan generate

sudo systemd-run --on-active=180 --unit=netplan-rollback \
  /bin/bash -c 'cp -a /root/netplan-backup/00-installer-config.yaml /etc/netplan/ && netplan apply'

sudo netplan apply
sudo systemctl stop netplan-rollback.timer     # disarm, once you know you're still reachable
```

If the last line never runs, the old config comes back on its own after 180 s.

:::tip[Preserve the Wi-Fi PSK]
The file is `root:root 0600` because it holds the Wi-Fi password. Copy the whole
`access-points:` block out of the backup rather than retyping it, and keep mode `600`.
:::

## Verify

```bash
ip -4 -o addr show enp4s0 wlp9s0     # static, no "dynamic" flag
ip route                             # default via 192.168.1.1 dev enp4s0 metric 100
ping -c2 1.1.1.1
netbird status                       # Management/Signal: Connected
microk8s kubectl get nodes -o wide   # INTERNAL-IP still 192.168.1.5
```

## Troubleshooting

| Symptom                          | Cause / fix                                                                                                                       |
|----------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| Locked out after `netplan apply` | The armed `netplan-rollback` unit restores the backup after 180 s. Otherwise restore from `/root/netplan-backup/` at the console. |
| Wi-Fi never associates, no error | `wpasupplicant` not installed — `netplan apply` exits 0 regardless. Check `systemctl status netplan-wpa-wlp9s0.service`.          |
| Wi-Fi never associates           | The `access-points:` block was lost or mis-indented. Restore from the backup.                                                     |
| Both up but traffic uses Wi-Fi   | Metrics inverted — the *lower* metric wins.                                                                                       |
| `x509` errors mentioning an IP   | Node IP moved away from the cert SAN. Move it back, or add it to `csr.conf.template` + `refresh-certs --cert server.crt`.         |
| NetBird peer unreachable         | `sudo netbird down && sudo netbird up` to rebind `wt0` to the new source address.                                                 |
| Random disconnects / conflicts   | The static IP sits inside the router's DHCP pool.                                                                                 |
