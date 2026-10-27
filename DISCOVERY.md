# Running Discovery with your ARM64 MID Server

Discovery in ServiceNow is **instance-driven**: the *instance* tells a **validated MID Server**
to scan target IPs, using **Discovery *credentials*** (which are separate from the MID login).
Your MID only needs to be **Up + Validated + capable** and able to **reach the targets**.

> Two different things, don't mix them:
> - **MID user** (`mid.server`, `mid.server2`) — authenticates the **MID → instance**. Set during setup.
> - **Discovery credentials** — how the **MID logs into your target machines** (SSH / WMI / SNMP).
>   Configured under *Discovery → Credentials*.

---

## ⚠️ First: activate the Discovery plugin

Network **Discovery** is the **ITOM Discovery** product (plugin `com.snc.discovery`).
It may or may not be **installed** on your instance — that is a separate question from
entitlement.

**Good news: PDIs *are* allowed to install it.** The "Pricing: Paid" label you see in the
plugin record is irrelevant on a PDI — PDIs are isolated personal dev sandboxes, so
installing a paid plugin there is free and does not create a compliance/licensing
obligation. Rule of thumb: *if the plugin offers an Install button, you may install it*
(the exceptions are capabilities PDIs genuinely can't run, e.g. some GenAI features).

### Activate it (needs an `admin` login)

Two equivalent routes:

1. **Classic plugin list** (most reliable, works on every release) — open
   `https://<instance>.service-now.com/sys_plugins_list.do?sysparm_query=nameLIKEDiscovery`
   and click the **Discovery** record. The form header shows **Status: Active/Inactive**; an
   inactive plugin shows an **Activate** link.
2. **Plugin/store card** — *All → System Definition → Plugins* (or the "Plugins for your
   instance" card page), filter for `discovery`, click the **Discovery** card → **Activate plugin**.

> ⚠️ `https://<instance>.service-now.com/now/app-manager/home/plugin/id/com.snc.discovery/details`
> returns **"Plugin details not found"** on some releases (verified on Australia `dev296154`).
> That is **not** an error with your instance or a failed activation — `com.snc.discovery` is a
> legacy unscoped plugin, so it does not always appear in the store app-manager. Use route 1.

Activation is not instant (often 10–40 min on a PDI). If it fails with a *store entitlement*
or *activation failed* error, just retry — that is a known PDI flake, not a "you're not
allowed" message.

**Which plugin card to click.** Filtering the plugin/store list for `Discovery` on a PDI
`dev####` instance typically shows two cards:

| Card | Do this |
|---|---|
| **Discovery** | ✅ **This is the one.** Click **Activate plugin**. Drives Discovery schedules, probes, MID jobs. |
| **File Based Discovery** | Optional add-on — discovers *installed software products* via file signatures on Windows/Unix. Not needed to scan hosts; add later if you want software inventory. |

**Not** the right plugin: *ITOM Metric Management*, *Operational Intelligence*, *Health Log
Analytics*, *Event Management* (the ITOM AIOps suite). Those are metrics/events/monitoring —
they add no Discovery schedules and give the MID no Discovery work.

### Verify it actually installed

- The application navigator gains **Discovery** (*Discovery Schedules*, *Discovery Status*,
  *Quick Discovery*) and **Discovery Definition**.
- **Activation is progressive — the menus lag the tables.** ServiceNow creates the ~130
  Discovery tables first and adds the navigation modules near the end. Measured on
  `dev296154`: 30 min in, 114 `discovery*` tables existed but only *Credentials* /
  *Discovery Probes Trackers* modules were present, and **no** *Discovery Schedules* module.
  Check whether the install is still running (admin, browser or REST):

  ```
  https://<instance>.service-now.com/api/now/table/sys_progress_worker?sysparm_query=name=PluginManagerWorker&sysparm_fields=name,state,sys_updated_on
  ```

  `"state":"running"` ⇒ wait. `"state":"complete"` ⇒ reload the nav (hard refresh) and the
  Discovery menu will be there.
- **No-terminal check (admin, browser session auth)** — paste this into the browser while logged
  in as `admin`; it returns JSON with the plugin state:

  ```
  https://<instance>.service-now.com/api/now/table/sys_plugins?sysparm_query=idLIKEcom.snc.discovery&sysparm_fields=id,name,active
  ```

  `"active":"true"` ⇒ activated. `"active":"false"` ⇒ still inactive, go click Activate.
- `https://<instance>.service-now.com/discovery_schedule_list.do` loads a list instead of
  redirecting / 404ing.
- Unauthenticated probes are useless here (everything redirects to `session_timeout.do`), so
  use a REST check with any authenticated user instead — a **missing** table returns HTTP 400
  `"Invalid table discovery_schedule"`, whereas an **existing** table returns 200 or a 403 ACL
  error:

  ```bash
  curl -s -u "<user>:<pass>" -H 'Accept: application/json' \
    "https://<instance>.service-now.com/api/now/table/discovery_schedule?sysparm_limit=1" \
    -w '\n[http %{http_code}]\n'
  ```

  Verified on `dev296154` (2026-10-27): **Discovery IS installed** after activation —
  `discovery_schedule` (label *Discovery Schedule*), `discovery_status`, `discovery_range`
  (label *Discovery Range Set*, 1 default record), `discovery_device_history`, plus the nav
  modules *Discovery Probes Trackers*, *Discovery Log*, *Traffic Based Discovery* and
  *Credentials*. Before activation `discovery_schedule` returned `400 Invalid table`.
  Base-adjacent tables (`discovery_credentials`, `discovery_classy`, `discovery_range`) exist
  **even without** the plugin, so they are *not* evidence on their own.

> **Different product, do not confuse:** *System Security → Data Discovery (Classic) → All Data
> Patterns* is the **data-anonymization / data-pattern** tool (privacy/GDPR). It is **not**
> network Discovery and cannot scan devices.
>
> Until the plugin is installed the MID is perfectly healthy but has **nothing to do** for
> Discovery — it can still be used for integrations, credentials, and scheduled jobs.

Everything below applies **once the plugin is installed**.

---

## 0. Prerequisites

1. **Discovery plugin installed + active** — *System Definition → Plugins* → **Discovery**
   (`com.snc.discovery`). On a PDI this is a free install (see the section above). If the
   plugin isn't there yet, nothing below will work — there is no Discovery menu, no
   schedules, and the MID has no Discovery work to poll for.
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
| MID shows **Status: Down** but `docker ps` says **Up** | A UI **Restart MID** killed a *wrapper-less* MID (`Wrapper-less MID Server cannot be automatically restarted. Shutting down.`). Modern containers run `mid-supervisor.sh` and self-heal; otherwise `docker restart sn-mid`. Details in `APPENDIX.md`. |
| Personal/dev instance: **no Discovery menu** | The plugin isn't installed yet — it is *not* a licensing block. Install `com.snc.discovery` as an admin (see the section at the top); retry on store errors. |

---

## Quick reference — do I even need Discovery?
- **Now**, the MID just needs to be **Up + Validated** to receive work. Discovery work only exists
  after the `com.snc.discovery` plugin is installed.
- Discovery requires the plugin + target credentials + a schedule/Quick Discovery. The MID itself is
  the *agent* that performs the scan and reports back to the instance.
- Order of operations: **install plugin → MID Up/Validated → target credentials → Quick Discovery
  (one IP) → schedule (range)**.
