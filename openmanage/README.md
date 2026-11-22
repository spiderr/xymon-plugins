# openmanage — Dell PowerEdge hardware check for Xymon

Client-side ext script. Reports the **`hardware`** column.

**Version 1.0.4** — full rewrite for thorough, readable Dell PowerEdge reporting.

## What it checks

| Area | Source | Notes |
|------|--------|--------|
| Chassis (fans, memory, PSU, temps, …) | `omreport chassis` | Drill-down on non-Ok components |
| iDRAC DNS | `omreport chassis remoteaccess` | FQDN must resolve to iDRAC IP |
| Controllers + battery | `omreport storage` | All controllers |
| Virtual disks | OMSA + perccli | State machine; **Resynching ≠ rebuild** |
| Physical disks | OMSA + perccli | Colour by **State** / predictive failure, not third-party `Non-Critical` Status noise |
| Enclosures | OMSA | Backplane Critical when members fail |
| Topology, CC/rebuild ops, media errors | **perccli/storcli** if available | Preferred RAID detail |

### Colour rules (worst wins)

| Condition | Colour |
|-----------|--------|
| Failed / offline / missing PD, predictive failure, degraded VD (`Pdgd`/`Dgrd`), critical enclosure | **red** |
| Rebuild, consistency check, resync, battery learning/charging | **yellow** |
| All clear | **green** |
| omreport missing / unreadable states | **purple** |

Third-party disks often show OMSA `Status: Non-Critical` while `State: Online` — those are **not** alarmed.

## Requirements

- Dell OMSA (`omreport` under `/opt/dell/srvadmin/bin/`)
- bash, standard Xymon client env (`XYMONHOME`, `XYMON`, `XYMSRV`/`XYMONDISP`, `MACHINE`)
- **Optional but recommended:** `perccli64` (or storcli). The `xymon` user usually cannot open the controller — append to the **same** file as other xymon sudos:

```
# /etc/sudoers.d/xymon  (not a separate drop-in)
xymon ALL=NOPASSWD: /opt/MegaRAID/perccli/perccli64
xymon ALL=NOPASSWD: /opt/MegaRAID/perccli/perccli
```

Snippet for copy/paste: `sudoers.xymon-perccli.snippet`. Without perccli, the check still runs on OMSA alone and notes that RAID CLI is missing.

## Installation

```bash
cp openmanage.sh $XYMONCLIENTHOME/ext/
chmod 755 $XYMONCLIENTHOME/ext/openmanage.sh
```

`clientlaunch` snippet (e.g. `/etc/xymon-client/client.d/openmanage.cfg`):

```
[openmanage]
    ENVFILE /etc/xymon-client/xymonclient.cfg
    CMD $XYMONCLIENTHOME/ext/openmanage.sh
    LOGFILE $XYMONSERVERLOGS/openmanage.log
    INTERVAL 15m
```

### Dry run (no Xymon send)

```bash
DRY_RUN=1 XYMONHOME=/usr/share/xymon-client XYMONTMP=/dev/shm \
  MACHINE=$(hostname -f) ./openmanage.sh | less
```

## Long-running task ETA

Consistency check, rebuild, BGI, replace-member progress includes an **ETA** when the client has at least two samples.

- **State file** (client only, not Xymon server / spacey):  
  `$XYMONHOME/tmp/openmanage-tasks.state` (or `/var/tmp`, `$XYMONTMP`, … first writable)  
  Override with `OPENMANAGE_STATE_FILE=/path/to/file`.
- Each line: `key|epoch|percent|label` (up to 6 samples per key).
- Rate = oldest→newest kept sample; ETA = remaining percent / rate.
- First run after a new job: `ETA pending`; next interval (e.g. 15m) produces an estimate.
- Finished jobs: state file cleared when no tasks are active.

## Physical disk init / erase / FORMAT progress

Yellow when any of these are active on a PD:

| Source | What | Progress |
|--------|------|----------|
| `perccli … show initialization` | PD clear / init | % + ETA string from perccli |
| `perccli … show erase` | Secure erase | % + ETA from perccli |
| `openmanage-pd-sense` (optional) | SCSI **FORMAT UNIT** in progress | % from REQUEST SENSE |

perccli alone does **not** report low-level FORMAT UNIT. The sense helper is an **extreme-case** add-on (extra binary + sudo) — **not** deployed fleet-wide.

Canonical procedure, source links, and when to use the helper:

→ **`~/sysadmin/docs/dell-hardware.md`** (section *PI-formatted disk* / MegaRAID passthrough)

Helper source in this directory: `openmanage-pd-sense.c` (build only if needed).

## Report layout

1. **SUMMARY** — `&red` / `&yellow` lines with the actionable facts (slot, SN, CC vs rebuild)
2. Host / OMSA identity (model, service tag)
3. Chassis rollup
4. iDRAC DNS
5. Controllers + battery (table)
6. Virtual disks (table)
7. Physical disks (compact table: ID, State, Status, Pred, media, product, serial)
8. Enclosures
9. Full OMSA detail **only for problem PDs**
10. Full perccli controller summary + VD detail + problem PD `show all` (when CLI available)

## History

| Ver | Notes |
|-----|--------|
| 1.0.4 | PD init/erase (perccli) + SCSI FORMAT progress via `openmanage-pd-sense` → yellow + % |
| 1.0.3 | ETA for CC/rebuild/BGI via client state file (`openmanage-tasks.state`) |
| 1.0.2 | perccli discovery requires Controller Count &gt; 0 (xymon must use `sudo -n`); UGood disks yellow |
| 1.0.1 | Discovery avoids slow `/c0 show`; perccli model field fix; enclosure raise dedupe |
| 1.0.0 | Rewrite: always-on storage inventory, perccli optional, correct CC vs rebuild, PD State-based alerts |
| 0.58 | Local patch: Storage case + unconditional vdisk check (insufficient — missed failed PDs when chassis had no Storage line) |
| 0.57 | iDRAC DNS |
| 0.56 | Batteries, wider chassis grep |
| 0.55 | Upstream Smith-Sweeney / spiderr lineage |

## License

Original 0.5x header: Copyright (C) 2002 Regents of the University of California (research/non-profit terms in older headers).  
1.0.x operational rewrite for this environment; treat as internal ops tooling.
