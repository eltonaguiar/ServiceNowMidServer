# Appendix — MID Server on Windows 11 (and why Discovery needs it)

> ## ⚠️ NOT OFFICIALLY SUPPORTED — this is a learning workaround
>
> ServiceNow's MID Server platform matrix lists **Windows Server** editions
> (2016 / 2019 / 2022 and later), not Windows client. **Windows 10/11 desktop is not a
> supported MID Server host**, so everything in this appendix is an *unsupported* path that
> happens to work: use it to learn/experiment with Discovery, not for production.
>
> Two visible symptoms of that unsupported status, both hit while writing this:
> - the **MSI installer refuses Windows 11** outright ("minimum version" gate) — hence the ZIP path;
> - the agent is built and validated against server editions, so quirks like
>   `host_name = host.docker.internal` appear.
>
> *(Could not re-verify the live matrix on 2026-10-28: the ServiceNow docs and KB pages
> redirect to a login. Check your instance's MID Server system requirements before relying on
> the exact version list.)*
>
> **Supported alternatives**
> | Option | Status |
> |---|---|
> | Windows **Server** VM (Hyper-V / Azure EC2) registered as a MID | ✅ supported |
> | Windows Server running directly on hardware | ✅ supported |
> | Linux MID (this repo, ARM64 or x64) for Linux/SNMP | ✅ supported |
> | **Windows 11 client as MID** | ❌ unsupported — works, documented here as a lab workaround |

> **This appendix is Windows-specific.** The main guides (`README.md`, `DISCOVERY.md`,
> `APPENDIX.md`) cover the **Linux/ARM64 container** MID Server built by this repo.
> Everything below is the *other* path: a native Windows MID Server on a Windows 11 desktop,
> which is required if you want to discover Windows targets.
>
> Verified end-to-end on 2026-10-28 against `dev296154.service-now.com` (Australia,
> Windows 11 Pro 10.0.26300): a `cmdb_ci_computer` CI was created with 5,398 software
> packages, 474 processes, 9 NICs and 8 disks.

---

## 0. Why you need a Windows MID at all

Windows discovery uses **WMI**, executed by `WMIRunner`/ScriptRunner **locally on the MID**.
That runner is a Windows binary, so a Linux MID cannot do it — no credential, firewall or
capability change fixes that:

```
Warning [Windows Classify / WMIRunner]  MID Server isn't Windows, unable to run ScriptRunner
Info    [Windows Classify / WMIRunner]  Active, couldn't classify: No WMI connection, now finished
```

| MID OS | Windows targets (WMI) | Linux/Unix targets (SSH) | SNMP |
|---|---|---|---|
| **Linux** (this repo's container) | ❌ | ✅ | ✅ |
| **Windows** | ✅ | ✅ (SSH probes are plain Java) | ✅ |

So: keep the ARM64 container for Linux/SNMP, add a Windows MID for Windows hosts — two MIDs on
one instance is a normal, supported pattern. (Alternative: run *only* a Windows MID if you can
tolerate it being offline whenever that desktop is off.)

---

## 1. The MSI refuses to install on Windows 11

`ServiceNowMIDServer.msi` is gated on a minimum OS version. On Windows 11 client it stops with a
"requires a minimum version" message and offers no override. That gate is **not a bug you can
argue with** — Windows 11 simply isn't in the supported MID platform list (see the banner above).

**Workaround (unsupported, lab use): use the ZIP package.** It has no OS gate and produces the
same MID.

*All → MID Server → Downloads* (`/mid_server_download.do`) → **Windows 64-bit (.zip)** →
unzip to a short path, e.g. `C:\ServiceNow\MID`.

The ZIP bundles its own JRE — **no Java install needed**.

---

## 2. ZIP layout — there is no `wrapper\` folder in current builds

```
C:\ServiceNow\MID\
    agent\        <- config.xml, start.bat, logs\, security\
    ...
```

`agent\start.bat` (run **elevated**) installs *and* starts the Windows service via the wrapper:

```
wrapperm | ServiceNow MID Server service installed.
wrapperm | ServiceNow MID Server service started.
```

Service name is **`snc_mid`**, StartType `Automatic`:

```powershell
Get-Service *MID*      # midisrv (leftover from the MSI attempt, Manual) + snc_mid (the real one)
Start-Service snc_mid
```

> There is **no `wrapper\InstallMidService.bat`** in this package — don't hunt for it. If you ever
> see a stray `midisrv` service, it came from the MSI; remove it with `sc.exe delete midisrv`.

---

## 3. `config.xml` — the four parameters, and the XML traps

```xml
<parameter name="url" value="https://dev296154.service-now.com/"/>
<parameter name="mid.instance.username" value="mid.server2"/>
<parameter name="mid.instance.password" value="...escaped..."/>
<parameter name="name" value="win11-mid"/>
```

Rules that cost real time here:

| Trap | Symptom | Rule |
|---|---|---|
| `url` without scheme | MID never contacts the instance | must be `https://host/` — **not** `host/` |
| `&` `<` `>` in the password | `SAXParseException: The reference to entity "xyz" must end with the ';' delimiter` → `config.xml may be malformed` → `NullPointerException` → MID exits | escape them: `&amp;` `&lt;` `&gt;` |
| Single vs double quotes | — | Changing the delimiter does **not** legalise `&`/`<`; escaping is mandatory in attributes |
| `secure="true"` | — | Just a marker; the plaintext *still* must be XML-escaped |
| Dots in `name` | odd behaviour | use `win11-mid`, not `mid.server2` (that's a username) |
| leftover `keypairs.mid_id` | identity mismatch on a fresh agent | delete that line |

**Validate the file before every restart** (turns a 5-minute cycle into one second):

```powershell
[xml](Get-Content C:\ServiceNow\MID\agent\config.xml -Raw) | Out-Null; "XML OK"
```

### Escaping helper (bash/macOS/Linux)
```bash
printf '%s' "$RAW_PASSWORD" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
```
### Escaping helper (Windows PowerShell)
```powershell
$raw -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
```

---

## 4. MID passwords: the UI is the only way (REST silently fails)

Verified on this PDI:

| Attempt | Result |
|---|---|
| `PATCH /api/now/table/sys_user/<id>` with `user_password` | reports `200`, record updates — **login still 401** |
| `POST /api/now/table/sys_user` creating a user with `user_password` | `201` created, roles assigned — **login still 401** |
| UI *Users → user → Set Password* → **Update** | **works** |

The table API writes the password **unhashed**, so authentication fails while everything looks
fine. Don't debug config yet — debug the credential first.

If the *Set Password* dialog only offers **Generate**, that's fine: **copy the generated value it
displays** (don't just close the dialog) and use that.

### Verify the credential *before* touching config
This is exactly the endpoint the MID uses at startup:

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" -u "mid.server2:THE_PASSWORD" `
  -H 'Content-Type: text/xml' -H 'SOAPAction: "http://www.service-now.com/GetMIDInfo#execute"' `
  --data '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:m="http://www.service-now.com"><SOAP-ENV:Body><m:execute><roles>mid_server</roles></m:execute></SOAP-ENV:Body></SOAP-ENV:Envelope>' `
  "https://dev296154.service-now.com/GetMIDInfo.do?SOAP"
```

- `200` → credential good, safe to put in `config.xml`
- `401` → wrong password; fix in the UI and retest

> Bash note: `!` in a password triggers history expansion (`!]ObSC...: event not found`). Run the
> command in PowerShell, or `set +H` first, or single-quote the password.

Note the table REST API returns `401` for **all** MID users regardless of password correctness —
that endpoint is not a valid credential test. Always use `/GetMIDInfo.do?SOAP`.

---

## 5. Restart procedure (after any config or password change)

```powershell
Stop-Service snc_mid
Remove-Item C:\ServiceNow\MID\agent\security\agent_keystore* -Force -ErrorAction SilentlyContinue
Start-Service snc_mid
Get-Content C:\ServiceNow\MID\agent\logs\agent0.log.0 -Tail 30
```

Deleting the keystore matters: it caches the (possibly old) credential and produces
`Unable to load keystore` / decryption errors if left behind.

Healthy sequence:
```
Setting basic authentication with user mid.server2
Keystore file security\agent_keystore not found. Creating new keystore file.
Welcome to the ServiceNow MID Server
... Successfully connected to instance
```

---

## 6. Validation — a MID that isn't validated is invisible to Discovery

Discovery only selects MIDs with **Status = Up** *and* **Validated = Yes** *and* a matching
capability. `validated: validating` for more than a minute is abnormal.

```
win11-mid   status=Up   validated=validating   capabilities: ALL      <- stuck
win11-mid   status=Up   validated=true         capabilities: ALL, WMI, Nmap, ...   <- good
```

Unstick it: restart the service, or on the MID record use **Related Links → Validate** (re-runs the
validation suite). Capabilities such as `WMI` / `Nmap` are published *by* validation, so an empty
capability list usually means validation never finished.

Cosmetic oddity: `host_name` may show **`host.docker.internal`** — Docker Desktop injects that
into the Windows `hosts` file. Harmless.

---

## 7. Preparing a Windows target

Ports (checked from the MID's network):
```
135 OPEN   (RPC endpoint mapper — WMI entry point)
445 OPEN   (SMB)
5985       optional (WinRM, enables PowerShell-based probes)
3389       irrelevant for discovery
```

On the target, in an **elevated** PowerShell:

```powershell
# allow WMI through the firewall (135 + dynamic RPC ports)
netsh advfirewall firewall set rule group="Windows Management Instrumentation (WMI)" new enable=Yes

# local (non-domain) admin accounts are token-filtered over the network by default
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f

# optional: WinRM (needs 5985). Enable-PSRemoting refuses if any NIC is "Public":
#   Set-NetConnectionProfile -InterfaceAlias "<alias>" -NetworkCategory Private
#   or add the rule manually:
netsh advfirewall firewall add rule name="WinRM 5985" dir=in action=allow protocol=TCP localport=5985 profile=private,public
```

Credential in ServiceNow: *Discovery → Credentials → New* → **Windows Credentials**, user
`.\localadmin` (or `MACHINE\user`), must be a **local administrator**. No credential *alias* is
needed — the probes match by type + "Applies to".

---

## 8. Two MIDs, one instance — routing

| MID | OS | Serves |
|---|---|---|
| `gx10-mid` | Linux/ARM64 container | Linux/Unix (SSH), SNMP, network devices |
| `win11-mid` | Windows 11 desktop | Windows (WMI), and anything SSH too |

- Pick the MID explicitly on a Quick Discovery / schedule, **or**
- put both in a **MID Server cluster** and let the instance route by OS/capability.
- One MID **user** may back several MIDs (rotation then affects all of them — plan accordingly).

Result of the reference run:

```
gx10-c9b9        Linux Ubuntu 24.04.5   4,731 pkgs   (gx10-mid)
desktop-081g9oh  Windows 11 Pro 26300   5,398 pkgs   (win11-mid)
```

Volume warning: each Linux host adds ~4.7k `cmdb_ci_spkg` rows, each Windows host ~5.4k. Scanning a
whole `/24` can add tens of thousands of rows — scope schedules accordingly.

---

## 9. Quick checklist

1. `[xml](Get-Content ...config.xml -Raw)` → **XML OK**
2. `curl.exe ... /GetMIDInfo.do?SOAP` → **200**
3. `Start-Service snc_mid` → `Get-Service snc_mid` = Running
4. Log → `Successfully connected to instance`
5. Instance → *MID Server → Servers* → **Up + Validated: Yes**, capabilities include `WMI`
6. *Quick Discovery* → target IP → **MID = the Windows MID** → credential `.\localadmin`
7. *Discovery → CIs* → `cmdb_ci_computer` appears
