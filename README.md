# MeshCentral Agent for Ubuntu Core

`meshagent-ubuntu-core` adds a MeshCentral agent for NAT-transparent remote
access to Ubuntu Core devices. It runs in `devmode` because of the broad
permissions the MeshCentral agent requires, so **you install this at your own
risk**.

This is a fork of the unofficial snap originally created by MatinatorX
(https://github.com/MatinatorX/meshagent-ubuntucore), reworked for a supervised
Zero-Touch Provisioning (ZTP) workflow: the agent only starts on a device that
has already been **commissioned** (i.e. has a valid Serial Assertion issued
through the Admission Control Layer / Serial Vault).

MeshCentral is developed by Ylian Saint-Hilaire — https://meshcentral.com/info/

---

## What this fork does

Compared with the original snap (which downloaded the agent binary at runtime),
this fork:

- **Does not bundle the agent binary.** The `meshagent` binary and its
  `meshagent.msh` configuration are provided at runtime by the **gadget snap**
  through a content interface (see [Where the agent binary comes
  from](#where-the-agent-binary-comes-from)).
- **Gates the agent on hardware identity.** The service blocks until the device
  has a Serial Assertion (`snap known serial`). A device that has not been
  commissioned never starts the agent.
- **Keeps the WiFi radio awake** with a small companion daemon
  (`wifi-keepawake`), preventing the idle power-save drops that otherwise break
  SSH and the management tunnel on Raspberry Pi.
- **Auto-connects the telemetry snap's identity interface** as a devmode helper
  (`iot-telemetry:device-identity` → `pi:device-identity`).

---

## How the service works

The `meshagent-ubuntu-core-service` daemon runs `meshservice.sh`, which performs
the following steps on every boot:

1. **Wait for commissioning.** Poll `snap known serial` (6 attempts, 10 s apart).
   If no Serial Assertion is present, the script exits and systemd retries — the
   agent stays down until the device is commissioned.
2. **Locate the agent binary** provided by the gadget snap: preferring the
   content interface at `$SNAP/gadget-bin/meshagent`, and falling back to the
   direct path `/snap/pi/current/meshagent-bin/meshagent` (used in devmode when
   the content interface is not auto-connected).
3. **Wait for network connectivity** by pinging the `MeshServer` host read from
   `meshagent.msh` (up to 30 retries).
4. **Stage the files** into `$SNAP_DATA`. If `meshagent.msh` changed since the
   last run, the local `meshagent.db` is deleted so the agent re-registers.
5. **Connect the telemetry identity interface** (`snap connect
   iot-telemetry:device-identity pi:device-identity`), idempotently, if the
   `iot-telemetry` snap is installed.
6. **Start the MeshCentral agent.**

A second daemon, `wifi-keepawake`, runs `keepawake.sh`: it disables SDIO
runtime power management on the WiFi interface and sends a periodic keepalive to
the default gateway, so the radio never idles into a power-save state.

---

## Where the agent binary comes from

The `meshagent` binary and `meshagent.msh` are **not** part of this snap. They
are delivered by the gadget (`pi`) snap through a content interface:

```yaml
# in this snap (snapcraft.yaml)
plugs:
  gadget-meshagent-bin:
    interface: content
    content: meshagent-bin
    target: $SNAP/gadget-bin
```

The gadget snap must expose a matching `meshagent-bin` content **slot**
containing `meshagent` (executable) and `meshagent.msh` (the MeshCentral server
URL and MeshID for the device group). On Ubuntu Core the connection is
auto-established via the model assertion's `connections` field; in devmode the
service falls back to the direct gadget path.

To obtain the binary and `.msh` for the gadget slot, use your MeshCentral
server (**My Account → Add Agent → Linux / BSD**):

```sh
# ARM64 (Raspberry Pi 4/5, aarch64) — agent id 26
wget "https://YOUR_MESHCENTRAL_SERVER/meshagents?id=26" \
    --no-check-certificate -O meshagent && chmod +x meshagent

wget "https://YOUR_MESHCENTRAL_SERVER/meshsettings?id=YOUR_MESH_ID" \
    --no-check-certificate -O meshagent.msh
```

| Agent id | Architecture                          |
|----------|---------------------------------------|
| 6        | Linux x86 64-bit                      |
| 25       | ARM 32-bit (Raspberry Pi 1/2/3)       |
| 26       | ARM 64-bit (Raspberry Pi 4/5, aarch64)|

Place both files in the gadget snap's content-slot directory, not in this snap.

---

## Building the snap

The snap builds for `arm64`, either natively or cross-built from `amd64`
(see the `platforms` block in `snapcraft.yaml`):

```sh
sudo snap install snapcraft --classic
cd meshagent-ubuntucore/
snapcraft            # produces meshagent-ubuntu-core_3_arm64.snap
```

This snap ships only the service scripts (`meshservice.sh`, `keepawake.sh`) and
stages `iputils-ping` and `iproute2`; the agent binary is not included by design.

### Install on the device

```sh
sudo snap install meshagent-ubuntu-core_*.snap --dangerous --devmode
```

Check both daemons:

```sh
snap services meshagent-ubuntu-core
#  meshagent-ubuntu-core.meshagent-ubuntu-core-service   enabled  active
#  meshagent-ubuntu-core.wifi-keepawake                  enabled  active

sudo journalctl -u snap.meshagent-ubuntu-core.meshagent-ubuntu-core-service -f
```

---

## Security notes

- **Runs in `devmode`** because the MeshCentral agent needs permissions beyond
  what `strict` confinement grants without a super-privileged interface. For a
  production deployment, publish to a Brand Store with an approved
  `snap-declaration`.
- **Commissioning gate:** the agent will not start until the device holds a
  Serial Assertion. Admission (approved-list check + hardware proof-of-possession)
  and revocation are enforced by the Admission Control Layer, which also blocks
  telemetry for revoked devices — this snap only reacts to the locally present
  assertion.
- **Restart policy:** the service is `restart-condition: on-failure`, so a
  not-yet-commissioned device keeps retrying until its identity is issued.

---

## Credits

- Original snap: [MatinatorX](https://github.com/MatinatorX/meshagent-ubuntucore)
- MeshCentral: [Ylian Saint-Hilaire](https://meshcentral.com/info/)
- Fork maintainer: Beatriz Faria <beatrizfaria@ipb.pt>
