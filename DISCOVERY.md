# Installing and Running Discovery

Everything about getting **ITOM Discovery** working on a ServiceNow instance and driving it with
the ARM64 MID Server from this repo: install the plugin → verify it → connect a MID → scan hosts.

Discovery is **instance-driven**: the *instance* instructs a **validated MID Server** to scan
target IPs, authenticating with **Discovery credentials** (separate from the MID login). The MID
only needs to be **Up + Validated + capable** and able to **reach the targets**.

> **Do not mix these up**
> - **MID user** (`mid.server`) — authenticates the **MID → instance**. Set during setup.
> - **Discovery credentials** — how the **MID logs into targets** (SSH / WMI / SNMP).
>   Configured under *Discovery → Credentials*.

**Order of operations** (each step blocks the next):

1. Install the `com.snc.discovery` plugin → 2. MID **Up + Validated** → 3. target **credentials**
→ 4. **Quick Discovery** on one host → 5. **Discovery Schedule** for ranges.

---

## 1. Before you install

| Requirement | Why |
|---|---|
| `admin` on the instance | Plugin activation needs an admin login. |
| A PDI or dev instance | PDIs **may** install paid plugins free of charge — the "Pricing: Paid" label is irrelevant there (PDIs are isolated sandboxes). Rule of thumb: *if it offers an Install button, you may install it.* |
| ~30–90 min of patience | PDI plugin activations are slow and occasionally fail-then-retry. |
| MID already running | Not required for the install itself, but you'll want it for step 6+. See `README.md` / `quickstart.sh`. |

---

## 2. Install the plugin

Two equivalent routes — both need `admin`:

1. **PDI console** (developer.servicenow.com → *Manage my instance*) → plugin/store list →
   filter `discovery` → **Discovery** card → **Activate plugin**.
2. **From the instance** —
   `https://<instance>.service-now.com/sys_plugins_list.do?sysparm_query=nameLIKEDiscovery`
   → open the **Discovery** record → header shows **Status**; an inactive record has an
   **Activate** link.

### Which card / plugin id

| Card | Verdict |
|---|---|
| **Discovery** (`com.snc.discovery`) | ✅ **This one.** Creates Discovery Schedules/Status, probes, MID jobs. |
| **File Based Discovery** | Optional. Discovers *installed software products* via file signatures. Not needed to scan hosts. |
| *ITOM Metric Management*, *Operational Intelligence*, *Health Log Analytics*, *Event Management* | ❌ Not needed. These are the ITOM **AIOps** suite (metrics/events). They create **no** Discovery schedules and give the MID no Discovery work. |

**Demo data:** choose **without demo data** if offered. It keeps the CMDB clean — otherwise you
get phantom CIs and pre-built schedules that muddy your first test.

> ⚠️ `https://<instance>.service-now.com/now/app-manager/home/plugin/id/com.snc.discovery/details`
> returns **"Plugin details not found"** on some releases (verified on Australia `dev296154`).
> That is **not** an instance problem — `com.snc.discovery` is a legacy unscoped plugin and does
> not always appear in the store app-manager. Use route 2 above.

---

## 3. Monitor the install (three sources, three different meanings)

This is where people get lost. The console, the worker row, and the plugin log each answer a
different question.

| Source | What it actually tells you | Gotcha |
|---|---|---|
| **"Activating Plugin…"** badge on developer.servicenow.com | That a store-side request exists / the last known state | **Stale by minutes.** Keeps showing "Activating…" after the job has finished — including after a *successful* run. Not live telemetry. |
| `sys_progress_worker` (`PluginManagerWorker`) | Live progress: `Loaded 703 of 1,634 files` | The row is **deleted when the job ends**. Empty list = *finished*, not *running*. It also does not say **which** plugin is being installed. |
| `sys_plugin_log` | The durable record: which plugin, every file loaded, and the outcome | Only written once the instance actually starts pulling the payload. Empty = still **queued**. |

### Poll it

Instance-side, as admin:

- `https://<instance>.service-now.com/sys_progress_worker_list.do?sysparm_query=state%3Drunning`
- `https://<instance>.service-now.com/sys_plugin_log_list.do` (newest first, filter
  `plugin = com.snc.discovery`)

Or with the helper in this repo (read-only, sudo-free):

```bash
SN_HOST=dev296154.service-now.com SN_USER=admin ./watch-plugin-install.sh com.snc.discovery
```

It prints worker progress plus the newest plugin-log line every 20 s and exits when the log says
`Plugin activated/upgraded successfuly` or `... failed`. `--interval N` / `--timeout N` adjust
pacing; `SN_PASS` can be supplied via env or it will prompt.

### How to read it

- **No worker row + no log line for your plugin** → the request is still queued store-side. Wait.
- **Worker row with `Loaded N of M files`** → running. Leave it alone; do **not** click Activate again.
- **`Plugin activated/upgraded successfuly`** in `sys_plugin_log` → done.
- **`Plugin activated/upgraded failed`** → see §5.

---

## 4. Verify it worked

Authoritative order (stop at the first one that fails):

**a. The plugin record is active.** `v_plugin` is readable by admin over REST (unlike
`sys_plugins`, which needs the `maint` role and returns `403 Failed API level ACL Validation`):

```
https://<instance>.service-now.com/api/now/table/v_plugin?sysparm_query=idLIKEdiscovery&sysparm_fields=id,name,active,version
```

`com.snc.discovery` must be present and active. Also check `com.snc.itom.discovery.license` — it
must be **active** too.

**b. The install ended cleanly.** Newest `sys_plugin_log` line for `com.snc.discovery` reads
`Plugin activated/upgraded successfuly`.

**c. The menus exist.** Hard-refresh (`Ctrl+Shift+R`) and look for
**Discovery → Discovery Schedules / Discovery Status / Quick Discovery** and
**Discovery Definition**. Before a successful install you'll only see stray modules
(*Credentials*, *Discovery Probes Trackers*, *Traffic Based Discovery*).

**d. The pages open.** `https://<instance>.service-now.com/discovery_schedule_list.do` loads a list.

> ### ⚠️ Table existence is NOT proof of installation
> Measured the hard way on `dev296154` (2026-10-27):
> - `discovery_status` and `discovery_range` are **base-platform** tables shipped with the
>   instance build (created `2026-06-12`) — they exist with no plugin at all.
> - A **failed** `com.snc.sa.metric` (ITOM AIOps) activation still created **~69 `discovery*`
>   tables** before ending in `Plugin activated/upgraded failed`.
> - During that window `discovery_schedule` flipped from `400 Invalid table` to `403`, which
>   looks exactly like a successful install.
>
> Only `v_plugin` + a `successfuly` log line are conclusive.

> **Different product, do not confuse:** *System Security → Data Discovery (Classic) → All Data
> Patterns* is the **data-anonymization / data-pattern** tool (privacy/GDPR). It is **not**
> network Discovery and cannot scan devices.

---

## 5. If the install fails

1. **Read the last log lines** — *Plugin log* filtered to your plugin, or
   `watch-plugin-install.sh`. Install logs are verbose and name the exact file/step that broke;
   `Loading update: <app>/if/<other-app>/update/<file>.xml` immediately before a failure is a
   strong hint at a dependency conflict.
2. **Expect a free retry.** PDIs frequently fail once on the store handshake and then succeed on
   the automatic retry. Observed on `dev296154`: `failed` at 23:23:00 → retry auto-started
   23:26:02 → `successfuly` at 23:27:14 (the retry is much faster because the payload is cached).
3. **Do not click Activate repeatedly** while a job is queued or running — you stack duplicate
   requests and make the store status harder to clear.
4. **Timebox:** if ~15–20 min pass with *no* worker row and *no* new log line, the request was
   dropped — click **Activate plugin** once more.
5. **If it keeps failing:** log fully out of developer.servicenow.com and back in (the console
   caches status per session); retry a **small** plugin first (e.g. *File Based Discovery*) to
   prove the store pipeline is healthy, then retry Discovery. Last resorts: a support case quoting
   instance + plugin + exact failure timestamp, or release/restore the PDI (destroys data).

---

## 6. Prerequisites for actually scanning

1. **MID Up + Validated** — *MID Server → Servers* → your MID (e.g. `gx10-mid`):
   **Status: Up**, **Validated: Yes**, **Capabilities** includes `All` or `Discovery`.
   The MID picks up new capabilities automatically after the plugin installs — no restart needed.
2. **Discovery credentials** — *Discovery → Credentials → New*, matching the target OS:
   - **Linux**: SSH username + password (or private key) + optional sudo password
   - **Windows**: Domain/Workgroup admin (WMI) — **needs a Windows MID Server, see the warning below**
   - **Network devices**: SNMP community

   These are separate from the MID user. A wrong or missing credential is the #1 cause of
   "no results".

> ### ⚠️ Windows targets cannot be discovered by a Linux MID Server
> Measured on `dev296154` (2026-10-28): a Windows host with 135/445/5985 open, WMI firewall
> rules enabled and `LocalAccountTokenFilterPolicy=1` still fails, because `Windows - Classify`
> is a **WMI probe** (`discovery_probes_wmi`) executed by WMIRunner locally on the MID:
>
> ```
> Warning  [Windows Classify / WMIRunner]  MID Server isn't Windows, unable to run ScriptRunner
> Info     [Windows Classify / WMIRunner]  Active, couldn't classify: No WMI connection, now finished
> ```
>
> WMI discovery requires a **Windows** MID Server. With a Linux/ARM64 MID you can discover
> Linux/Unix and SNMP devices only; add a Windows MID alongside it for Windows hosts. Treating
> a Windows box as *Unix* over OpenSSH is not a workaround — the classify step is WMI-only.
3. **Network reachability** — the MID must reach targets **outbound**: SSH 22, WMI 135/445/5985,
   SNMP 161, ICMP. In this repo the MID runs in Docker; bridge/NAT gives outbound LAN access.
   Check from inside the container before blaming ServiceNow:

   ```bash
   docker exec sn-mid sh -c 'timeout 4 bash -c "echo > /dev/tcp/192.168.2.52/22" && echo REACHABLE'
   ```

   If inbound access is needed, re-run the container with `--network host`.

---

## 7. Fastest test — Quick Discovery (one host)

*Discovery → Quick Discovery*:

- **Discover**: `192.168.2.52` (single host — start here, not with a /24)
- **MID Server**: `gx10-mid` (or the *All* cluster)
- **Credentials**: the SSH/WMI/SNMP credential for that target
- **Discover**

Watch *Discovery → Discovery Status / Discovery Logs* (In Progress → Complete). This proves the
MID can reach and authenticate to a target before you build schedules.

---

## 8. Repeatable — Discovery Schedule

*Discovery → Discovery Schedules → New*:

- **Name**: e.g. `LAN sweep`
- **Discover**: IP range(s)/subnet, or a CI / Service
- **MID Server**: `gx10-mid` (or cluster)
- **Credentials / Discovery behaviors**: attach the credential(s)
- **Run**: schedule it, or leave manual
- Save → **Related Links → Discover / Execute Now** to run immediately

Results land in the **CMDB** (`cmdb_ci_linux_server`, …), **Device History**, and the schedule's
**Discovery Logs**.

---

## 9. What success looks like

- **Discovery Status: Complete** (or errors that name a real cause).
- New CIs in the CMDB with relationships; **Device History** shows per-target results.
- MID log shows probe activity:

  ```bash
  docker exec sn-mid sh -c 'tail -f /opt/agent/logs/agent0.log.0'
  ```

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Console stuck on **"Activating Plugin…"** but nothing is running | Stale store badge (see §3). Confirm with `sys_progress_worker` (empty = finished) and `sys_plugin_log`. Press **Refresh**; the badge usually clears. |
| `Plugin activated/upgraded failed` | §5 — read the log line, expect an automatic retry, avoid repeat clicks. |
| Discovery tables exist but **no menu** | Not proof of install (§4) — usually debris from a different or failed plugin. Check `v_plugin`. |
| Discovery stuck **Ready**, never runs | No validated MID selected; MID not Up/Validated; MID lacks the Discovery capability. |
| **No credential / auth failures** on targets | Missing or wrong **Discovery Credential** (not the MID user). |
| **Timeout / could not connect** | MID can't reach the IP — test from the container (see §6.3). |
| **Windows target: `MID Server isn't Windows, unable to run ScriptRunner`** | WMI probes are Windows-MID only. Ports 135/445/5985 open, correct local-admin credential and `LocalAccountTokenFilterPolicy=1` are **not enough** on a Linux MID — deploy a Windows MID Server for Windows hosts (see §6.2). |
| **"Could not decrypt file discovery whitelist"** / **"Unable to load key store"** | Keystore mismatch — see `APPENDIX.md`; `setup-mid-fast.sh` clears a stale keystore. |
| MID **Status: Down** while `docker ps` says **Up** | A UI **Restart MID** killed a *wrapper-less* MID. Modern containers run `mid-supervisor.sh` and self-heal; otherwise `docker restart sn-mid`. See `APPENDIX.md`. |

---

## Appendix — measured timeline (`dev296154`, 2026-10-27, UTC)

Kept as evidence for the claims above:

| Time | Event |
|---|---|
| 22:55 | `discovery_schedule` → `400 Invalid table` (Discovery genuinely absent) |
| 23:02:28 | `PluginManagerWorker` created for **`com.snc.sa.metric`** (ITOM AIOps, *not* Discovery) |
| 23:05 / 23:16 | UI **Restart MID** → `Wrapper-less MID Server cannot be automatically restarted. Shutting down.` → MID Down while the container stayed "Up" |
| 23:19 | 114 `discovery*` tables existed (debris) while `v_plugin` had **no** `com.snc.discovery` record |
| 23:23:00 | `com.snc.sa.metric` → **`Plugin activated/upgraded failed`** |
| 23:26:02 | automatic retry starts (`Loaded 703 of 1,634 files`) |
| 23:27:14 | `com.snc.sa.metric` → **`Plugin activated/upgraded successfuly`** |
| — | `com.snc.discovery` still absent (`v_plugin` has no record, license inactive) |

Lessons baked into this doc: the console badge lags; the worker row disappears on completion;
`sys_plugins` needs `maint` (use `v_plugin`); table creation ≠ installation; and a wrapper-less
MID does not survive a UI restart.
