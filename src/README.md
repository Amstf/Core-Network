# Colosseum / LXC Container Setup

Scripts for automating the full LXC container lifecycle when deploying the OAI 5G Core Network on the [Colosseum](https://www.colosseum.net) wireless network emulator, or on any LXC-capable host. The tooling covers base image acquisition, container initialization, network configuration, and Docker image retrieval.

> After setup, refer to **[`../README.md`](../README.md)** for instructions on running the 5G Core Network.

---

## Directory Structure

```
src/
├── setup_container/              # Scripts to download, import, and prepare an LXC container
│   ├── setup_core_container.sh       # Main orchestration script
│   ├── download_image.sh             # Downloads the base image from Colosseum storage
│   ├── import_and_launch.sh          # Imports the image into LXC and starts the container
│   └── set_lxc_network.sh            # Configures network inside the container
├── Export_container/             # Scripts to snapshot and upload a container to Colosseum
│   ├── export_container.sh           # Exports the running container as a .tar.gz image
│   ├── upload_image.sh               # Uploads the exported image to Colosseum storage
│   └── export_and_upload.sh          # Runs export then upload in one step
└── setup_Github/                 # SSH key generation helper for GitHub access
    └── generate_github_keys.sh
```

---

## Prerequisites

LXC must be configured on the host before using these scripts. For installation and setup instructions, refer to `<add-your-lxc-setup-doc-here>`.

---

## Pre-step — GitHub SSH Key Setup (one-time)

Before running the container setup script, generate and register an SSH key for GitHub access.

**1. Run the key generator:**
```bash
cd src/setup_Github
./generate_github_keys.sh
```
When prompted, enter a GitHub username, email, target directory (default: `~/.ssh`), and an optional passphrase. The script prints the public key on completion.

**2. Add the public key to GitHub:**
- Go to [https://github.com/settings/keys](https://github.com/settings/keys)
- Click **New SSH key** and paste the printed key.

**3. Verify authentication:**
```bash
ssh -i ~/.ssh/github-keys -T git@github.com
```
Expected output:
```
Hi <your-username>! You've successfully authenticated, but GitHub does not provide shell access.
```

---

## Setting Up the Container — `setup_core_container.sh`

`setup_core_container.sh` automates the full pipeline from a base LXC image to a ready-to-run 5G Core Network environment. Run it from the `src/setup_container/` directory.

### Usage

```bash
cd src/setup_container
./setup_core_container.sh \
    <image-name.tar.gz> \
    [alias] \
    [container-name] \
    [remote-user] \
    [ssh-key-path]
```

| Argument | Required | Description |
|----------|----------|-------------|
| `image-name.tar.gz` | yes | Filename of the base LXC image on Colosseum storage |
| `alias` | no | LXC image alias — defaults to filename without `.tar.gz` |
| `container-name` | no | LXC container name — defaults to `<alias>-cont` |
| `remote-user` | no | Colosseum username — defaults to `alimustapha` |
| `ssh-key-path` | no | Path to the GitHub SSH private key (host-side) to copy into the container |

### Example

```bash
./setup_core_container.sh base-2204.tar.gz core-image core-cont myuser ~/.ssh/github-keys
```

### Execution Steps

The script runs **5 sequential steps**.

---

**[1/5] Download the image** — `download_image.sh`

Downloads the base LXC image from the Colosseum shared NAS, proxied through the Colosseum gateway. If the image is already present locally, this step is skipped. The image is saved under `./images/`.

---

**[2/5] Import and launch the container** — `import_and_launch.sh`

Imports the downloaded image into LXC under the given alias, then initializes and starts a container from it using the `bigpool` storage pool. Both steps are idempotent — if the image alias or container already exists, they are skipped.

---

**[3/5] Configure the network** — `set_lxc_network.sh`

Attaches the `lxdbr1` bridge to the container's `eth0` interface, brings it up, and obtains a DHCP lease. Converts the DHCP address to a static assignment via `netplan`, writing a persistent configuration to `/etc/netplan/60-static-eth0.yaml`. Writes a static DNS configuration to prevent DHCP from overwriting `/etc/resolv.conf`. Verifies internet connectivity before exiting.

---

**[4/5] Push SSH key** *(only if `ssh-key-path` is provided)*

Copies the GitHub SSH key pair into `/root/.ssh/` inside the container as `id_rsa` / `id_rsa.pub`, sets correct permissions, adds `github.com` to known hosts, and runs an authentication test.

---

**[5/5] Clone repository and pull Docker images** — runs entirely inside the container

- Clones the `OAI-CORE-Network` repository from GitHub into `/root/OAI-CORE-Network/`
- Pre-pulls all Docker images defined in `docker-compose-slicing.yaml` via `docker-compose pull`

All images are available inside the container and ready for use via `start_cn.sh`.

---

## Exporting a Container — `Export_container/`

A working container can be snapshotted and pushed back to Colosseum storage for reuse or sharing.

| Script | Description |
|--------|-------------|
| `export_container.sh` | Stops the container, publishes it as an LXC image, and exports it to `~/myimages/<alias>.tar.gz`. Optionally removes a private SSH key from inside the image before export to avoid credential leakage. |
| `upload_image.sh` | Uploads the exported `.tar.gz` to the Colosseum shared NAS via the gateway jump host. |
| `export_and_upload.sh` | Runs export then upload in one step. |

### Usage

```bash
cd src/Export_container

# Export only
./export_container.sh <container-name> [image-alias] [ssh-key-path-inside-container]

# Export and upload in one step
./export_and_upload.sh <container-name> [image-alias] [ssh-key-path-inside-container] [remote-user]
```
