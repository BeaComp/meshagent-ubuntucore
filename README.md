# MeshCentral Agent for Ubuntu Core

Adds a MeshCentral agent for remote access to Ubuntu Core devices.
Requires devmode and beta options due to the permissions required by the
meshagent binary. As such, YOU INSTALL THIS AT YOUR OWN RISK.

MeshCentral is developed by the very talented Ylian Saint-Hilaire.
This is a fork of the unofficial snap originally created by MatinatorX
(https://github.com/MatinatorX/meshagent-ubuntucore), modified to support
Serial Assertion verification via a Serial Vault proxy before allowing
remote management access.

Please visit the main MeshCentral website for more information:
https://meshcentral.com/info/

---

## What's different in this fork

The original snap downloaded the MeshCentral agent binary at runtime from
the server. This fork bundles the agent binary and `.msh` configuration
directly inside the snap, and adds the following security features:

- **Serial Assertion verification**: before starting the agent, the script
  reads the device's Serial Assertion from the snapd assertions store and
  sends it (base64-encoded) to a Serial Vault proxy for cryptographic
  verification.
- **Device status enforcement**: the proxy returns the device status
  (commissioned / quarantine / revoked). Revoked devices are blocked from
  connecting to MeshCentral.

---

## Prerequisites — preparing the meshsource folder

Before building the snap, you must download the MeshCentral agent binary
and its configuration file and place them in the `meshsource/` folder.

### 1. Download the agent binary

Go to your MeshCentral server, navigate to **My Account → Add Agent →
Linux / BSD**, and copy the install command. It will contain your server
URL and MeshID.

Then download the binary directly (replace the URL and MeshID with yours):

```sh
# For ARM64 (Raspberry Pi 5 / Ubuntu Core on aarch64) — agent ID 26
wget "https://YOUR_MESHCENTRAL_SERVER/meshagents?id=26" \
    --no-check-certificate \
    -O meshsource/meshagent

chmod +x meshsource/meshagent
```

Agent IDs by architecture:

| ID | Architecture                          |
|----|---------------------------------------|
| 5  | Linux x86 32-bit                      |
| 6  | Linux x86 64-bit                      |
| 25 | ARM 32-bit (Raspberry Pi 1/2/3)       |
| 26 | ARM 64-bit (Raspberry Pi 5 / aarch64) |

### 2. Download the .msh configuration file

The `.msh` file contains the MeshCentral server URL, MeshID and ServerID
for your device group. Download it with:

```sh
wget "https://YOUR_MESHCENTRAL_SERVER/meshsettings?id=YOUR_MESH_ID" \
    --no-check-certificate \
    -O meshsource/meshagent.msh
```

### 3. Verify the meshsource folder

After downloading, your `meshsource/` folder should contain:

```
meshsource/
├── meshagent        ← agent binary (executable)
├── meshagent.msh    ← server configuration
├── meshinstall.sh   ← install script (included in repo)
└── meshservice.sh   ← service script (included in repo)
```

Confirm the binary is executable:

```sh
ls -la meshsource/meshagent
# Should show: -rwxr-xr-x
```

### 4. Configure the service script

Edit `meshsource/meshservice.sh` and set your server details:

```sh
MESH_SERVER_IP="YOUR_MESHCENTRAL_SERVER_IP"
PROXY_URL="http://YOUR_SERIAL_VAULT_PROXY_IP:8082"
```

---

## Installing from the Snap Store (when available)

```sh
sudo snap install meshagent-ubuntucore --beta --devmode
```

---

## Building the Snap

### On a standard Ubuntu machine (recommended)

Install snapcraft and build:

```sh
sudo snap install snapcraft --classic
cd meshagent-ubuntucore/
snapcraft --destructive-mode
```

The output snap file will be created in the same directory.

### On an Ubuntu Core device

Install the classic snap first, then enter the classic shell:

```sh
sudo snap install classic --beta --devmode
classic
```

Install snapcraft inside classic:

```sh
sudo snap install snapcraft
# Or on older Ubuntu Core:
apt install snapcraft
```

Copy the source to your home directory and run:

```sh
snapcraft
```

### Installing the built snap on the device

```sh
sudo snap install meshagent-ubuntucore_*.snap --dangerous --devmode
```

---

## Serial Vault Proxy

This fork requires a Serial Vault proxy running at `PROXY_URL`. The proxy
must expose the following endpoint:

```
POST /v1/verify-assertion
Content-Type: application/json

{ "assertion": "<base64-encoded Serial Assertion>" }
```

Response:

```json
{ "status": "commissioned" | "quarantine" | "revoked" | "rejected" }
```

---

## Security notes

- This snap runs in `devmode` because reading the Serial Assertion from
  `/var/lib/snapd/assertions/` requires filesystem access that is blocked
  by `strict` confinement without the super-privileged `snapd-control`
  interface (which requires Snap Store approval).
- In a production deployment, consider publishing the snap to a Brand
  Store with an approved `snap-declaration` that grants `snapd-control`.
- The fail-open policy (agent starts if proxy is unreachable) is a
  deliberate design decision for availability. Change to fail-closed
  (`exit 1` on unreachable proxy) for higher security requirements.

---

## Credits

- Original snap: [MatinatorX](https://github.com/MatinatorX/meshagent-ubuntucore)
- MeshCentral: [Ylian Saint-Hilaire](https://meshcentral.com/info/)
- Fork maintainer: Beatriz Faria <beatrizfaria@ipb.pt>