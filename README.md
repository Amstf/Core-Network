# OAI CN5G — Network Slicing

A deployment of the OAI 5G Core configured for network slicing experiments, along with automation scripts for LXC container lifecycle management on the [Colosseum](https://experiments.colosseum.net/) testbed. The repository includes the core network stack, slice-specific configuration files, and tooling for container provisioning and export.

---

## Repository Structure

```
oai-cn5g/
├── docker-compose-slicing.yaml   # Core network stack (two slices, dedicated SMF+UPF per slice)
├── start_cn.sh                   # Start/restart the core network
├── conf/                         # Slice configuration files (SMF, UPF, AMF, NSSF, ...)
├── database/                     # MySQL seed data (UE subscriptions and authentication)
├── healthscripts/                # Container health check scripts
└── extdn-iperf-logs/             # iperf log output from the external DN container

src/
├── setup_container/              # Scripts to download, import, and prepare an LXC container
├── Export_container/             # Scripts to snapshot and upload a container to Colosseum
└── setup_Github/                 # SSH key generation helper for GitHub access
```

---

## 1. Core Network

The core runs as a Docker Compose stack (`docker-compose-slicing.yaml`) with two independent network slices, each with a dedicated SMF and UPF pair. All containers share a single Docker bridge network (`demo-oai-public-net`, subnet `192.168.70.128/26`).

### Container IP Reference

| Container | IP | Role |
|---|---|---|
| `oai-nrf` | `192.168.70.130` | Network Repository Function |
| `mysql` | `192.168.70.131` | UE subscription database |
| `oai-amf` | `192.168.70.132` | Access and Mobility Management |
| `oai-smf-slice1` | `192.168.70.133` | Session Management — Slice 1 |
| `oai-upf-slice1` | `192.168.70.134` | User Plane — Slice 1 (DNN `oai`, UE subnet `12.1.1.0/24`) |
| `oai-ext-dn` | `192.168.70.135` | External data network (iperf server) |
| `oai-udr` | `192.168.70.136` | Unified Data Repository |
| `oai-udm` | `192.168.70.137` | Unified Data Management |
| `oai-ausf` | `192.168.70.138` | Authentication Server |
| `oai-nssf` | `192.168.70.139` | Network Slice Selection |
| `oai-smf-slice2` | `192.168.70.140` | Session Management — Slice 2 |
| `oai-upf-slice2` | `192.168.70.141` | User Plane — Slice 2 (DNN `oai2`, UE subnet `12.1.2.0/24`) |

> These IPs are fixed in `docker-compose-slicing.yaml`. The gNB configuration must point to `oai-amf` at `192.168.70.132`.

### Starting the Core

```bash
cd oai-cn5g
./start_cn.sh -m [rfsim|usrp]
```

The `-m` flag selects the network interface based on the deployment environment:

| Mode | Interface | When to use |
|---|---|---|
| `rfsim` | `eth0` | Local deployment inside an LXC container (RF simulation) |
| `usrp` | `tun0` | Colosseum deployment with real RF (USRP hardware) |

> `tun0` is the tunnel interface used by the UPF to carry user-plane traffic. On Colosseum, UPF gateways must be bound to this interface rather than `eth0`.

```bash
# Local / rfsim
./start_cn.sh -m rfsim

# Colosseum / USRP
./start_cn.sh -m usrp
```

`start_cn.sh` executes the following steps:

1. Recreates the `demo-oai-public-net` Docker bridge network, removing any existing instance
2. Tears down any previous Compose deployment via `docker-compose down`
3. Starts all services in detached mode via `docker-compose up -d`
4. Waits 5 seconds, then injects UPF gateway IPs on the selected interface via `docker exec`:
   - `oai-upf-slice1` → `12.1.1.1/24`
   - `oai-upf-slice2` → `12.1.2.1/24`

> **Note:** The `docker exec` step can fail silently if the UPF containers are not yet ready. If UEs fail to obtain an IP address, verify with: `docker exec oai-upf-slice1 ip addr show <interface>`

To check container status:

```bash
docker ps -a
```

> If containers exit shortly after starting, inspect logs with `docker logs <container-name>`.

### External Data Network Routing

`oai-ext-dn` adds the following static routes at startup, enabling end-to-end data path connectivity for iperf tests:

```
12.1.1.0/24 via 192.168.70.134   # → UPF Slice 1
12.1.2.0/24 via 192.168.70.141   # → UPF Slice 2
```

---

## 2. Colosseum / LXC Setup Scripts

The core network is deployed inside an LXC container on the Colosseum testbed. The scripts in `src/` automate the full container lifecycle from image download to a ready-to-run environment.

> LXC must be configured on the host before using these scripts. For installation and setup instructions, refer to `<add-your-lxc-setup-doc-here>`.

---

### Pre-step — GitHub SSH Key Setup (one-time)

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

### Container Setup — `setup_core_container.sh`

Downloads, imports, configures, and fully prepares the LXC container:

```bash
cd src/setup_container
./setup_core_container.sh <image-name.tar.gz> [alias] [container-name] [remote-user] [ssh-key-path]
```

Example:

```bash
./setup_core_container.sh oai-core.tar.gz core-image core-container myuser ~/.ssh/github-keys
```

The script executes the following steps in order:

1. **Download** the LXC image from Colosseum via `download_image.sh`
2. **Import and launch** the container via `import_and_launch.sh`
3. **Configure container networking** via `set_lxc_network.sh`
4. **Apply a static IP to `eth0`** — reads the current DHCP lease, installs `netplan.io`, and writes a persistent static configuration at `/etc/netplan/60-static-eth0.yaml` (DNS: `8.8.8.8` / `1.1.1.1`)
5. **Push SSH key** into the container, add `github.com` to known hosts, and verify GitHub authentication *(only if an SSH key path is provided)*
6. **Clone the core repository** and pre-pull all Docker images via `docker-compose pull` inside the container

> If a Colosseum image is not available, a `base.tar.gz` can be requested from the repository maintainers.

---

### Exporting a Container — `export_and_upload.sh`

To snapshot a prepared container, remove private SSH keys from inside the container, and upload it back to Colosseum:

```bash
cd src/Export_container
./export_and_upload.sh <container-name> [image-alias] [ssh-key-path-inside-container] [remote-user]
```

Example:

```bash
./export_and_upload.sh core-container core-image "/root/.ssh/github-keys /root/.ssh/github-keys.pub" myuser
```

The script performs the following operations:

- Removes the specified SSH key files from inside the container
- Stops the container if running
- Exports it as a `.tar.gz` archive
- Uploads the archive to `/share/nas/<team>/images` on Colosseum

---

## Source

Based on [wineslab/ORANSlice — oai_cn](https://github.com/wineslab/ORANSlice/tree/main/oai_cn).
