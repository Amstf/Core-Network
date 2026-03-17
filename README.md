# OAI 5G Core Network — Network Slicing Deployment

A deployment of the OAI 5G Core configured for network slicing experiments. The stack runs as a Docker Compose deployment with two independent network slices, each with a dedicated SMF and UPF pair.

> **Before starting the core network**, provision the LXC container environment by following [`src/README.md`](src/README.md).

---

## Table of Contents

1. [Repository Layout](#1-repository-layout)
2. [Prerequisites](#2-prerequisites)
3. [Configuration Overview](#3-configuration-overview)
4. [Running the Core Network — `start_cn.sh`](#4-running-the-core-network--start_cnsh)
5. [Network Interface Summary](#5-network-interface-summary)
6. [Sources](#6-sources)

---

## 1. Repository Layout

```
Core-Network/
├── src/                              # LXC container lifecycle scripts — see src/README.md
│   ├── setup_container/
│   ├── Export_container/
│   └── setup_Github/
└── oai-cn5g/
    ├── docker-compose-slicing.yaml   # Core network stack (two slices, dedicated SMF+UPF per slice)
    ├── start_cn.sh                   # Main launch script
    ├── conf/                         # NF configuration files (AMF, SMF, UPF, NSSF, ...)
    ├── database/                     # MySQL seed data (UE subscriptions and authentication)
    ├── healthscripts/                # Container health check scripts
    └── extdn-iperf-logs/             # iperf log output from the external DN container
```

---

## 2. Prerequisites

The following must be installed and operational on the host before running the core network:

- **Docker** and **Docker Compose**
- **LXC** — required only for Colosseum deployment; refer to [`src/README.md`](src/README.md)

---

## 3. Configuration Overview

### 3.1 `docker-compose-slicing.yaml` — Service Definitions

Defines all core NF containers, fixed IP assignments, and inter-service dependencies. All containers are attached to the `demo-oai-public-net` bridge network (`192.168.70.128/26`).

#### Container IP Reference

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

---

### 3.2 `conf/` — NF Configuration Files

Per-NF configuration files consumed at container startup. Includes AMF, SMF, UPF, NSSF, and slice-specific parameters.

Default S-NSSAIs:

| SST | SD | Purpose |
|-----|----|---------|
| 1 | `0xFFFFFF` | Default slice |
| 1 | `0x000002` | Secondary slice |

---

### 3.3 `database/oai_db.sql` — Subscriber Database

SQL dump loaded at startup by the `mysql` container. Contains UE entries: IMSI, authentication keys, DNN assignment, and slice subscription.

---

## 4. Running the Core Network — `start_cn.sh`

### Usage

```bash
cd oai-cn5g
./start_cn.sh -m <rfsim|usrp>
```

The `-m` flag selects the network interface for UPF tunnel injection:

| Mode | Interface | When to use |
|------|-----------|-------------|
| `rfsim` | `eth0` | Local deployment inside an LXC container (RF simulation) |
| `usrp` | `tun0` | Colosseum deployment with real RF (USRP hardware) |

> `tun0` is the tunnel interface used by the UPF to carry user-plane traffic on Colosseum. UPF gateways must be bound to this interface rather than `eth0` in that environment.

### Execution Steps

---

**[1/4] Recreate the Docker bridge network**

Removes any existing `demo-oai-public-net` instance and recreates it:

```
Subnet:  192.168.70.128/26
Gateway: 192.168.70.129
```

---

**[2/4] Tear down any previous deployment**

```bash
docker-compose -f docker-compose-slicing.yaml down
```

---

**[3/4] Start all core network services**

```bash
docker-compose -f docker-compose-slicing.yaml up -d
```

Brings up all NF containers in detached mode.

---

**[4/4] Inject UPF tunnel addresses**

After a short delay, assigns tunnel addresses on the selected interface inside each UPF container:

| Container | Tunnel Address |
|-----------|---------------|
| `oai-upf-slice1` | `12.1.1.1/24` |
| `oai-upf-slice2` | `12.1.2.1/24` |

> This step can fail silently if the UPF containers are not yet ready. If UEs fail to obtain an IP address, verify with:
> ```bash
> docker exec oai-upf-slice1 ip addr show <interface>
> ```

### Verify

```bash
docker ps -a
```

> If containers exit shortly after starting, inspect logs with `docker logs <container-name>`.

---

## 5. Network Interface Summary

| Mode | UPF Interface | Used for |
|------|--------------|----------|
| `rfsim` | `eth0` | LXC bridge network; UPF tunnel and inter-NF traffic |
| `usrp` (Colosseum) | `tun0` | Colosseum user-plane tunnel (GTP-U) |

All NFs communicate over the `demo-oai-public-net` bridge (`192.168.70.128/26`). The gNB connects to the AMF at `192.168.70.132` over the same network.

### External Data Network Routing

`oai-ext-dn` applies the following static routes at startup, enabling end-to-end connectivity for iperf tests:

```
12.1.1.0/24 via 192.168.70.134   # → UPF Slice 1
12.1.2.0/24 via 192.168.70.141   # → UPF Slice 2
```

---

## 6. Sources

**Repository**
- [wineslab/ORANSlice](https://github.com/wineslab/ORANSlice/tree/main/oai_cn) — upstream 5G core baseline, built on the OpenAirInterface [oai-cn5g](https://gitlab.eurecom.fr/oai/cn5g) stack

