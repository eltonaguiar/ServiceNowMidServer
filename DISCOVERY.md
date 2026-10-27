# Running Discovery with your ARM64 MID Server

Discovery in ServiceNow is **instance-driven**: the *instance* tells a **validated MID Server**
to scan target IPs, using **Discovery *credentials*** (which are separate from the MID login).
Your MID only needs to be **Up + Validated + capable** and able to **reach the targets**.

> Two different things, don't mix them:
> - **MID user** (`mid.server`, `mid.server2`) — authenticates the **MID → instance**. Set during setup.
> - **Discovery credentials** — how the **MID logs into your target machines** (SSH / WMI / SNMP).
>   Configured under *Discovery → Credentials*.

---

## 0. Prerequisites

1. **Discovery plugin active** — *System Definition → Plugins* → search **Discovery** (`com.snc.discovery`).
   ⚠️ Personal/dev instances (e.g. `dev####`) may **not** expose Discovery or may be limited; a full
   dev/prod instance is best for real scans.
2. **MID Up + Validated + capable** — *MID Server → Servers* → your MID (e.g. `gx10-mid`). Confirm:
   - **Status: Up**, **Validated: Yes**
   - **Capabilities** includes `All` or `Discovery`
3. **Discovery credentials** — *Discovery → Credentials* → **New**, matching your target OS:
   - **Linux**: SSH username + password (or private key) + sudo password
   - **Windows**: Domain/Workgroup admin (WMI)
   - **Network devices**: SNMP community
   These are encrypted in the instance and used by the MID to log into targets.
4. **Network reachability** — the MID must reach target IPs **outbound**: SSH 22, WMI 135/445/5985,
   SNMP 161, ICMP. Our MID runs in Docker on the GX10; Docker bridge/NAT gives outbound LAN access.
   If targets aren't reachable, run the container with `--network host` (see Troubleshooting).

---

## 1. Fastest test — Quick Discovery (one IP / small range)

*Discovery → Quick Discovery* (a.k.a. *Quick Discover*):
- **Discover**: `192.168.1.10` (single) or `192.168.1.1-254` (range) or a subnet
- **MID Server**: choose `gx10-mid` (or the *All* cluster)
- **Credentials**: pick the SSH/WMI/SNMP credential for those targets
- Click **Discover**

Watch *Discovery → Discovery Logs / Status* (In Progress → Complete). Great for proving the MID
can reach and authenticate to a target before you build schedules.

---

## 2. Repeatable — Discovery Schedule

*Discovery → Discovery Schedules → New*:
- **Name**: e.g. `LAN sweep`
- **Discover**: IP range(s) / subnet, or a CI / Service
- **MID Server**: `gx10-mid` (or cluster)
- **Credentials / Discovery behaviors**: attach the credential(s)
- **Run**: set a schedule, or leave manual
- Save → on the record use **Related Links → Discover / Execute Now** to run immediately

Monitor: **Discovery Status** / **Discovery Logs** on the schedule. Results land in the **CMDB**
(e.g. `cmdb_ci_linux_server`) and **Device History**.

---

## 3. What success looks like
- Discovery Status: **Complete** (or errors listing the reason).
- New CIs appear in the CMDB with relationships.
- **Device History** shows per-target results.
- MID log shows probe activity:
  ```bash
  docker exec sn-mid_mid1 sh -c 'tail -f /opt/agent/logs/agent0.log.0'
  ```
  (use `sn-mid` for the mid.server2 instance)

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| Discovery stuck **Ready**, never runs | No validated MID selected; MID not Up/Validated; MID lacks Discovery capability. |
| **No credential** / auth failures on targets | Missing/wrong **Discovery Credential** (not the MID user). Add at *Discovery → Credentials* and test. |
| **Could not connect / timeout** to a target | MID can't reach the IP (firewall/route). Test from the MID container: `docker exec sn-mid_mid1 sh -c 'nc -vz <ip> 22'`. If the target is on the host's LAN and NAT blocks it, re-run the container with `--network host`. |
| **"Could not decrypt file discovery whitelist"** / **"Unable to load key store"** | Keystore mismatch — see `APPENDIX.md` troubleshooting; run `setup-mid-fast.sh` (it clears a stale keystore). |
| Personal/dev instance: **no Discovery menu** | Discovery is a separate plugin/license; personal instances may not include it. Use a full dev instance. |

---

## Quick reference — do I even need Discovery?
- **Now**, the MID just needs to be **Up + Validated** to receive work (including Discovery once licensed).
- Discovery requires the plugin + target credentials + a schedule/Quick Discovery. The MID itself is
  the *agent* that performs the scan and reports back to the instance.
