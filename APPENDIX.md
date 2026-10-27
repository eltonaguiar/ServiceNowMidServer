# Appendix — Real-World ARM64 Bring-Up Notes (2026-10-27)

This appendix documents an actual end-to-end bring-up of the MID Server on ARM64,
including the problems hit when **reusing an existing install** and running
**non-interactively**, and the exact fixes. Read this alongside the main README if
you are re-running setup, reusing a machine that had a prior MID, or automating it.

## Environment
- **Host:** NVIDIA GX10 (GB10 Grace Blackwell), `aarch64`, Ubuntu 24.04.5 LTS
- **Instance:** `dev296154.service-now.com` (Australia patch3 — build `australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106`)
- **MID name:** `gx10-mid` · **MID user:** `mid.server` (role `mid_server` present)
- **Docker:** server `29.6.2`; the operator is in the `docker` group (docker ops require **no sudo**)

## Outcome (verified)
Container `sn-mid` running on image `moers/mid-server:latest`. `agent0.log` shows:
```
Successfully connected to instance:
MID Server is connected to instance host: dev296154.service-now.com using IPversion: IPV4
AutoUpgrade.run(), MID server Operational State=UP
```
…and **0** `UnrecoverableKeyException` after the keystore fix below.

**ServiceNow confirms: `gx10-mid` → Status: Up, Validated: Yes.**

## Fast setup (recommended) — `quickstart.sh` + `setup-mid-fast.sh`
Two helpers make bring-up fast and password-safe:
- **`quickstart.sh`** — prompts for host / user / password (hidden) / name, then runs the setup. The password never touches disk or shell history.
- **`setup-mid-fast.sh`** — **sudo-free, idempotent**. On a **fresh instance** it downloads the ~478 MB payload once; on a **re-run / already-installed** machine it detects the agent already in the `mid_data` volume and **skips the download (starts in seconds)**. It also auto-clears a stale keystore after regenerating `config.xml`, which prevents the "Unable to load keystore" trap.

```bash
./quickstart.sh        # interactive, recommended
# or non-interactive:
export SN_HOST=acme.service-now.com MID_USER=mid.server MID_NAME=gx10-mid
read -rsp "pw: " MID_PASS; export MID_PASS
./setup-mid-fast.sh
```
No host `sudo` required for users in the `docker` group — volume file ops run **inside Docker as root** (`docker run --rm --user root -v mid_data:/…`).

## What was already installed (no reinstall needed)
- Docker image `moers/mid-server:latest` present.
- Volume **`mid_data`**: full agent already present (673 jars in `lib/`, `extlib/`, `config.xml`, …).
- Volume **`mid_jdk17`**: native **JDK 17** already present.

⇒ The 478 MB MID-core payload did **not** need re-downloading; only the **config
(rotated password)** and the **keystore** needed refreshing. Prefer the fast-relaunch
path (below) when the agent is already in the volume.

---

## Issues encountered and fixes

### 1) Script "echoes instead of running"
**Symptom:** `./setup-mid-arm64.sh` prints text and exits without doing work.
**Cause:** mandatory env-var guards at the top of the script:
```bash
: "${SN_HOST:?Set SN_HOST first: export SN_HOST=\"YOUR_INSTANCE.service-now.com\"}"
: "${MID_USER:?Set MID_USER first: ...}"
: "${MID_PASS:?Set MID_PASS first: ...}"
```
`${VAR:?message}` prints the message and **exits immediately** if the variable is
unset **or empty**. (Also, the `cat setup-mid-arm64.sh` line prints the whole script —
that is the "review before running" step, not execution — and the "HOW TO USE" exports
are commented out, so copying them does nothing.)
**Fix:** export the four variables in the **same shell** first:
```bash
export SN_HOST="your-instance.service-now.com"   # no https://, no trailing slash
export MID_USER="mid.server"
read -rsp "MID password: " MID_PASS; echo        # hidden; avoids shell history
export MID_NAME="gx10-mid"                        # optional, defaults to <hostname>-mid
./setup-mid-arm64.sh
```
Notes: empty string still triggers `:?`; `sudo ./setup...` drops these env vars — don't.

### 2) `sudo` password blocks non-interactive / automated runs
The script's `SUDO()` helper performs **host** file operations on the docker volume
mountpoint (`/var/lib/docker/volumes/mid_data/_data`), which needs root. Where `sudo`
requires a password, automation blocks at the prompt.
**Fix:** do those volume file operations **through Docker (root-in-container)** instead of
host sudo — no sudo needed for users in the `docker` group. Replaced the host-sudo block with:
```bash
# overlay agent files (example)
docker run --rm -v mid_data:/dest -v /tmp/mid_au/agent:/src:ro \
  --entrypoint /bin/bash moers/mid-server:latest \
  -c "mkdir -p /dest && cp -a /src/. /dest/"
# ownership
docker run --rm -v mid_data:/v --entrypoint /bin/bash moers/mid-server:latest \
  -c "chown -R 999:999 /v"
```
(config.xml generation already runs in a container with `--user root`.)

### 3) 478 MB payload download interrupted → unzip failure
**Symptom:** `unzip: cannot find or open /tmp/mid-core.zip`.
**Cause:** the MID core payload is ~478 MB (`install.service-now.com`); large and slow, and
when downloads contend or the file is removed the unzip step fails.
**Fix:** when the agent is already in the `mid_data` volume (re-run / prior install),
**skip download + unzip + overlay** and use the fast-relaunch path (Section below).

### 4) Keystore mismatch after regenerating `config.xml` → "Unable to load keystore"
**Symptom:** `agent0.log` shows
```
java.security.UnrecoverableKeyException: failed to decrypt safe contents entry:
  javax.crypto.BadPaddingException ...  (bad key used during decryption)
MID server is not yet validated.
```
and the UI/greps may report *"Unable to load key store, MID server will not be able to function."*
**Cause:** regenerating `config.xml` produces a **new keystore password**, but the **stale**
keystore from the prior install (`/opt/agent/security/agent_keystore` + `security_backup/` copies)
was encrypted with the **old** password → decryption fails → MID never validates.
**Fix:** delete the stale keystore so the MID regenerates one matching the new config, then restart:
```bash
docker exec sn-mid sh -c 'rm -f /opt/agent/security/agent_keystore /opt/agent/security_backup/agent_keystore.*'
docker restart sn-mid
```
After this: **0** `UnrecoverableKeyException`, connected, `Operational State=UP`.

### 5) Rotated MID password
The MID password was rotated on the instance. `config.xml` was regenerated with the new
value (read from a **local secrets file into an env var — never echoed to logs**). The MID
authenticated successfully on the next start.

---

## Fast relaunch (no payload download) — `mid_fast.sh`
Use when the agent is already present in `mid_data` and you only need to (re)apply the
password and relaunch. Reads credentials from a local file; never prints the password.
```bash
#!/usr/bin/env bash
set -euo pipefail
F="$HOME/dbpasses.txt"
SN_HOST="$(grep -m1 -oE 'https?://[^ ]+' "$F" | sed -E 's#^https?://##; s#/.*$##')"
MID_USER="mid.server"
MID_PASS="$(sed -n '2p' "$F")"
MID_NAME="gx10-mid"; BASE_IMG="moers/mid-server:latest"
AGENT_VOL="mid_data"; JDK_VOL="mid_jdk17"; CONTAINER="sn-mid"; MID_XMX="1024m"

# 1) regenerate config.xml with current password (XML-encoding handled inside container)
docker run --rm --platform linux/arm64 --user root -v "$AGENT_VOL":/opt/agent \
  -e SN_HOST_NAME="$SN_HOST" -e USER_NAME="$MID_USER" -e PASSWORD="$MID_PASS" -e MIDNAME="$MID_NAME" \
  --entrypoint /bin/bash "$BASE_IMG" \
  -c 'cd /opt/agent; ENC_PW=$(printf %s "$PASSWORD" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g"); SED_PW=$(printf %s "$ENC_PW" | sed "s/[\\\\&|]/\\\\&/g"); cp /opt/config.xml /opt/agent/config.xml; sed -i "s|https://YOUR_INSTANCE.service-now.com|https://${SN_HOST_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_USER_NAME_HERE|${USER_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_PASSWORD_HERE|${SED_PW}|g" config.xml; sed -i "s|YOUR_MIDSERVER_NAME_GOES_HERE|${MIDNAME}|g" config.xml; chown 999:999 config.xml'

# 2) ownership
docker run --rm -v "$AGENT_VOL":/v --entrypoint /bin/bash "$BASE_IMG" -c "chown -R 999:999 /v"

# 3) clear stale keystore so it regenerates against the new config, then relaunch
docker rm -f "$CONTAINER" 2>/dev/null || true
docker run -d --name "$CONTAINER" --platform linux/arm64 --restart unless-stopped --user root \
  -v "$AGENT_VOL":/opt/agent -v "$JDK_VOL":/opt/jdk17 --entrypoint /bin/bash "$BASE_IMG" \
  -c "cd /opt/agent; rm -f /opt/agent/security/agent_keystore /opt/agent/work/mid.pid; OPENS='--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/javax.crypto=ALL-UNNAMED --add-opens=java.base/sun.security.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED'; su mid -s /bin/bash -c \"cd /opt/agent && nohup /opt/jdk17/bin/java -Xmx${MID_XMX} -Djava.security.manager=allow \$OPENS -classpath 'lib/*:extlib/*' com.service_now.mid.Main start >/opt/agent/logs/console.log 2>&1 &\"; exec tail -F /opt/agent/logs/agent0.log.0 /opt/agent/logs/console.log"

# 4) wait for connect
for _ in $(seq 1 60); do sleep 2;
  docker logs --tail 200 "$CONTAINER" 2>&1 | grep -q "Successfully connected to instance" && { echo CONNECTED; break; }
done
```

## Verify
```bash
docker ps --filter name=^sn-mid$ --format '{{.Status}}'
docker exec sn-mid sh -c 'grep -iE "Successfully connected to instance|Operational State" /opt/agent/logs/agent0.log.0 | tail'
docker exec sn-mid sh -c 'tail -120 /opt/agent/logs/agent0.log.0 | grep -c UnrecoverableKeyException'   # expect 0
```
Then in ServiceNow: **MID Server → Servers → `gx10-mid`** (Status: Up; Validated: Yes once the
instance-side handshake completes).

## Troubleshooting: 401 "User Not Authenticated" / "cannot be authenticated"
If `agent0.log` shows `HTTP/1.1 401 Unauthorized … User Not Authenticated` and
`Could not authenticate user '<mid user>'`, the MID's credentials don't match the
instance. In ServiceNow (User Administration → Users → the MID user), confirm:
1. The user **exists** and is **Active**.
2. It has the **`mid_server`** role (plus the SOAP roles).
3. **Not** "Locked out"; "**Password needs reset**" is **unchecked**.
4. **Set the password, then CLICK SAVE on the user form.** ⚠️ **This is the usual culprit** —
   generating/typing a new password without clicking **Save** leaves the old (or blank)
   password in place, so the MID keeps getting 401 even though the script used the value
   you typed. Re-run the setup after saving.
5. Re-run `./setup-mid-fast.sh` (or `./quickstart.sh`) with that exact password.

## ⚠️ "Restart MID" in the UI kills a wrapper-less MID (fixed by `mid-supervisor.sh`)

**Symptom:** you click **Related Links → Restart MID** on the MID Server record (or change
something that requests a restart). Afterwards the instance shows **Status: Down**, but
`docker ps` still says the container is **Up**. `agent0.log` ends with:

```
[RestartHandler] Wrapper-less MID Server cannot be automatically restarted.
Shutting down. MANUALLY START THE MID SERVER TO CONTINUE
[MIDServerState] MID Server stopped
```

**Why:** this container runs the MID *wrapper-less* — we exec
`com.service_now.mid.Main start` directly, because ServiceNow's service wrapper is x86-only
and this host is ARM64. A restart request therefore terminates the JVM and there is no
wrapper to bring it back. Only `tail` is left running inside the container, which is why
Docker reports "Up".

**Fix (as of this version):** the container now launches `mid-supervisor.sh`, which
relaunches the JVM whenever it exits (10 s delay, backing off to 60 s after 3 fast crashes).
A UI "Restart MID" is now a real restart. Verified: killing the JVM (`rc=143`) produced
`[supervisor] … MID exited rc=143 after 39s — relaunching in 10s` → `starting MID JVM`, and
the instance went back to **Up**.

**Manual recovery (old containers / no supervisor):**

```bash
docker restart sn-mid          # NOT "Restart MID" in the UI
docker ps --format '{{.Names}}\t{{.Status}}'
docker exec sn-mid sh -c 'pgrep -af service_now.mid.Main'    # must show the java process
```

**Checking whether the MID JVM is alive (not just the container):**

```bash
docker exec sn-mid sh -c 'pgrep -af service_now.mid.Main' || echo "JVM DEAD - container is a shell only"
docker exec sn-mid sh -c 'grep "\[supervisor\]" /opt/agent/logs/console.log | tail -5'
```

## Running multiple MIDs on one host (e.g. `mid.server` + `mid.server2`)
Each MID = its own agent volume + container + MID name (they connect outbound :443, so
no port clash). The scripts accept overrides so a 2nd instance doesn't overwrite the 1st:
```bash
# 1st MID (defaults): user mid.server, name gx10-mid, volume mid_data, container sn-mid
export SN_HOST=dev296154.service-now.com MID_USER=mid.server MID_NAME=gx10-mid
read -rsp "pw: " MID_PASS; export MID_PASS; bash ./setup-mid-fast.sh

# 2nd MID: separate volume+container+name; agent is fast-copied from mid_data (no re-download)
AGENT_VOL=mid_data2 CONTAINER=sn-mid2 SEED_VOL=mid_data \
  SN_HOST=dev296154.service-now.com MID_USER=mid.server2 MID_NAME=gx10-mid.server2 \
  bash ./setup-mid-fast.sh
```
Result: two MID Server records (`gx10-mid` and `gx10-mid.server2`), each validating
independently. A single user can also back multiple MIDs — separate users just give you
independent password rotation and audit.

> ⚠️ Note: `quickstart.sh` uses the **default** volume/container, so running it twice with
> different users **replaces** the first MID. To keep two at once, use the `AGENT_VOL`/
> `CONTAINER`/`SEED_VOL` overrides shown above (or pass them in the environment before
> `./quickstart.sh`).

## Security notes
- Secrets were read from a local file into env vars and **never echoed**; prefer `read -rsp`
  so the password never touches shell history or process args.
- Treat any password pasted into a chat or shell as compromised and rotate it.

## Credit
- Original ARM64 approach + `setup-mid-arm64.sh`: prior agents (see README).
- This bring-up + troubleshooting notes (env guards, sudo-free volume ops, skip-payload
  fast path, keystore regeneration): GHCopilot + peer agents (opencode / freebuff), 2026-10-27.

---

## Re-pointing an existing MID onto a refreshed / replaced instance — `repoint-mid.sh` (2026-10-27, freebuff)

The same session also packaged the *"our instance was refreshed, the old one is gone"*
case as a script, because re-installing for that is wasted effort — the ARM64 JDK, the
MID jars and the volumes are instance-agnostic; only `config.xml`, the registration ids
and the keystore are tied to an instance.

```bash
export SN_HOST="dev123456.service-now.com"   # the NEW instance
export MID_USER="mid.server"
export MID_PASS='***PASSWORDHERE***'         # keep the quotes
export MID_NAME="gx10-mid"
./repoint-mid.sh                             # ~75 s, no sudo, no re-download, no reinstall
```

When to use which script:

| Situation | Script |
|---|---|
| First time on this machine (no agent in `mid_data`) | `quickstart.sh` / `setup-mid-fast.sh` |
| Agent already installed, **same** instance, just bounced | `docker restart sn-mid` (or `setup-mid-fast.sh` fast-relaunch path) |
| Agent already installed, **new/refreshed** instance | **`repoint-mid.sh`** |

What it does, in order: (1) credential pre-check via
`/api/now/table/sys_user` — **401 stops it in ~2 s with the exact reason**
(200 = ok, 403 = authenticated but no REST role); (2) rewrites `config.xml`
(url + user + XML-escaped password) and, **only when the instance actually changed**,
blanks `mid_sys_id` / `keypairs.mid_id` so the MID registers fresh instead of binding the
dead instance's record; (3) clears stale keystore / `work/remote.properties` / cache;
(4) recreates the container with the same direct-`java` launch; (5) polls until
`Successfully connected to instance:` appears, then prints the build tag.

**Nothing has to be created by hand in ServiceNow.** The MID creates its own `ecc_agent`
record on first contact (Status: Up, then Validated: Yes). What *must* exist on the
instance is the **user** (`mid.server`, role `mid_server`) — the MID cannot create its own
login, and a wrong/missing one is the `SOAP 401` trap.

### Extra failure modes found while scripting the re-point (beyond those above)

| Symptom | Cause | Fix |
|---|---|---|
| `File: /opt/agent/config.xml may be malformed, load operation returned null` | the write-back ran `docker run -i … -c 'cat > config.xml'` **without a stdin redirect** → empty file | always redirect stdin (`… < config.new.xml`) and **read the file back** to confirm it contains the new host |
| broken `…/>/>` tags, then the same "malformed" error | rebuilding the whole `<parameter …/>` element instead of replacing its **value** | replace the value only, and `xml.dom.minidom.parse()` the result before the MID ever reads it |
| `&` in the password breaks the config | password inserted raw | XML-escape `& < > "` (`&` → `&amp;`, …). A `secure="true"` plain-text value is accepted and re-encrypted by the MID on startup |
| the wrong parameter got edited | `name="mid.instance.password"` appears **twice** — once live, once in an XML comment showing the CyberArk format | replace only the **first** match (`count=1`) |
| container keeps vanishing mid-startup | another concurrent run of `setup-mid-arm64.sh`/`setup-mid-fast.sh` (both start with `docker rm -f sn-mid`) | check `docker events --since 10m`; re-run the script — it is idempotent and preserves the registration |
| `Unable to load key store, MID server will not able to function` | keystore missing **on that one startup** | normal once: the next lines are `Keystore file security/agent_keystore not found. Creating new keystore file.` → `Updated public key, new certificate`. Only investigate if it repeats every boot |

Verification that closed it out on `dev296154` (2026-10-27):

```
INFO (StartupSequencer) [UserConfigTest:74] User mid.server has all necessary roles
INFO (StartupSequencer) [InstanceConnectivityTest:36] Successfully connected to instance:
INFO (StartupSequencer) [InstanceConnectivityTest:41]  Build tag: glide-australia-02-11-2026__patch3-05-25-2026
INFO (AutoUpgrade:267) Installed packages are up-to-date.
```

```bash
curl -s -u "$MID_USER:$MID_PASS" \
  "https://$SN_HOST/api/now/table/ecc_agent?sysparm_fields=name,status,last_refreshed&sysparm_query=nameLIKEgx10"
# {"result":[{"name":"gx10-mid","status":"Up","last_refreshed":"2026-10-27 22:48:29"}]}
```

> Bonus: `repoint-mid.sh` doubles as the recovery procedure for a MID whose keystore or
> registration is corrupt, and it is safe to run repeatedly.

---

## Two MIDs, one instance: name collision + "encryption keys do not match" (2026-10-27, freebuff)

Symptom: the instance showed **two** MID records — `gx10-mid` and `gx10-mid.server2` — endpoints
flapping between `Up`/`Down`, `Validated: validating` never settling, plus these MID errors:

```
Unable to load key store, MID server will not able to function
Could not decrypt file discovery whitelist after sync
MID Server encryption keys do not match and are no longer valid.
  To restore proper functionality, invalidate and re-validate the MID Server.
```

Cause, in order:
1. **Two agents each ran a setup script.** Every run of `setup-mid-arm64.sh` / `setup-mid-fast.sh`
   begins with `docker rm -f sn-mid`, and the fast path also clears the keystore. So the MID
   restarted repeatedly with a **new keypair** each time.
2. **The MID name was taken.** When the kernel came up while another agent still owned the name,
   ServiceNow assigned **`gx10-mid.server2`** and wrote that name back into `config.xml` — so the
   two containers permanently disagreed about who they were, and each re-registered.
3. **Keypair rotation without re-validation.** A regenerated keystore means the instance holds keys
   the MID no longer has → the "encryption keys do not match" error, and file-discovery whitelist
   sync fails until the MID is re-validated.

How to tell which container is which:

```bash
docker ps -a --filter ancestor=moers/mid-server:latest --format '{{.Names}} | {{.Status}}'
docker exec sn-mid        sh -c 'grep -o "name=\"name\" value=\"[^\"]*\"" /opt/agent/config.xml'
docker exec sn-mid_mid1   sh -c 'grep -o "name=\"name\" value=\"[^\"]*\"" /opt/agent/config.xml'
docker inspect sn-mid_mid1 --format '{{range .Mounts}}{{.Name}}->{{.Destination}} {{end}}'
```

Fix (one MID, one name, one clean registration):
1. **Stop the duplicate** — `docker stop sn-mid_mid1` (the container that is *not* using `mid_data`).
2. On the keeper, set `name="gx10-mid"`, blank `mid_sys_id` / `keypairs.mid_id`, delete
   `security/agent_keystore` + `work/remote.properties`, then restart:
   `./repoint-mid.sh` does all of this and re-writes the password as **plaintext** so the MID
   can re-encrypt it with the fresh keystore.
   > A config left holding an `ENCv2[...]` password whose keystore was deleted will fail at
   > startup with `DefaultMidServerEncrypter.decrypt` — that is expected; rewrite it as plaintext.
3. **An admin finishes it in the UI** (these steps are ACL-blocked for the MID user — a REST
   `DELETE /api/now/table/ecc_agent/<sys_id>` returns `403 ACL Exception Delete Failed`):
   - *MID Server → MID Servers* → `gx10-mid.server2` → **Delete**.
   - open `gx10-mid` → **Invalidate**, then **Validate** → `Validated: Yes`.
4. Confirm, from the shell:

```bash
curl -s -u "$MID_USER:$MID_PASS" \
 "https://$SN_HOST/api/now/table/ecc_agent?sysparm_fields=name,status,validated,last_refreshed&sysparm_limit=20"
# only ONE record, status Up, last_refreshed ticking
```

Rule of thumb: **never run two MID agents with the same name against one instance**, and don't
re-run a setup script on a healthy MID — every keystore wipe costs you a re-validation cycle.

## Running Discovery on this MID — what the MID can and cannot do

The MID is only the **execution** end: probes/patterns and the Discovery schedule live on the
instance. You cannot "start discovery from the MID". Checklist:

1. **MID side** — the MID must be `Validated: Yes` and advertise the Discovery-related
   capabilities. A healthy container reports, among others:
   `SSH, WMI, SNMP, REST, SOAP, VMware, PowerShell, Kubernetes, AWS, Azure, Ansible, OpenStack,
   Cloud Management, Resolve DNS, ALL` (read them from `ecc_agent_capability`).
2. **Instance side** — Discovery must be installed/entitled. Check by typing `Discovery` in the
   filter navigator; if the menu is missing, an admin activates it under
   *System Definition → Plugins* (`Discovery`). Note: on a non-entitled instance the
   `discovery_*` tables are not reachable to a plain MID user.
3. **Credentials** — *Discovery → Credentials → New*: SSH (Linux/Unix), Windows (WMI),
   SNMPv2c/v3 as needed, then assign them to the schedule.
4. **Schedule** — *Discovery → Discovery Schedules → New*: give it a name, set **MID Server =
   gx10-mid**, add the targets (IP ranges / serverless ranges / a host list), attach the
   credentials, set Run = *On demand*, save, then **Discover now**.
   Results: *Discovery → Status* / ECC Queue, and CIs land in the CMDB.
5. **Networking caveat (important for this install)** — the MID runs with Docker **bridge**
   networking, so it can only reach what is routable from inside the container
   (`172.17.0.0/16` + outbound). To scan a real LAN, recreate the container with
   `--network host` (add it to the `docker run` in `setup-mid-fast.sh` / `repoint-mid.sh`).
   WMI/SSH/SNMP probes are the ones that care.
