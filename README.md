<img width="1348" height="128" alt="image" src="https://github.com/user-attachments/assets/df6bbc88-c6fe-48de-9ea3-2570e9a77e08" />

# ServiceNow MID Server on ARM64 (NVIDIA GX10 / Grace Blackwell)

> **Run a ServiceNow MID Server (Management, Instrumentation, and Discovery) — including the current Australia release — on an ARM64 machine, even though ServiceNow does not publish a single ARM64 download.**

![MID Up and Validated](https://github.com/user-attachments/assets/df6bbc88-c6fe-48de-9ea3-2570e9a77e08)

**Proof it works:** the screenshot above shows `gx10-mid` in ServiceNow with **Status: Up**, **Validated: Yes**, and **Version: australia-02-11-2026_patch3-05-25-2026** — the exact current release.

Tested end-to-end on an **NVIDIA DGX Spark / GX10** (GB10 Grace Blackwell, `aarch64`, Ubuntu 24.04.5 LTS) against an **Australia patch3** instance.

---

## 📌 TL;DR — Long Story Short

**The problem:** ServiceNow only makes MID Server downloads for Intel/AMD computers (`x86-64`). If your computer is ARM (like the NVIDIA GX10, a Raspberry Pi, or Apple Silicon), the normal installer simply won't run. *(ELI5: it's like being handed a left-handed glove when you're right-handed — it just doesn't fit.)*

**The fix in one paragraph:** A MID Server is really just a Java program. Java programs can run on *any* processor — so we skip the parts that are locked to Intel chips (the "wrapper" and the bundled Java), install a proper ARM version of Java, drop in ServiceNow's official Australia MID files, and start it ourselves with a few special flags. No fake/chip-translating needed — it runs natively at full speed.

**The 5 things that were broken and how we fixed each:**

| # | What was wrong (ELI5) | The fix |
|---|------------------------|---------|
| 1 | The installer is Intel-only, your chip is ARM | Skip the installer, use the Java files directly |
| 2 | The ready-made image is an older release (Zurich), your instance wants Australia | Manually swap in the official Australia files |
| 3 | The image ships Java 11, but modern MID needs Java 17 | Install a native ARM Java 17 |
| 4 | The "starter" program that normally boots MID is Intel-only | Skip it — start MID directly with `java` |
| 5 | Java 17 blocks two things MID needs | Add 2 special launch flags |

*(Don't worry if that table means nothing yet — each row is explained in plain English further down.)*

**Want the fast version?** Jump to [Quick Start](#-quick-start-run-these-commands).

---

## Table of Contents

- [📌 TL;DR — Long Story Short](#-tldr--long-story-short)
- [Quick Start — Run These Commands](#quick-start--run-these-commands)
- [What You Need To Edit (The 4 Settings)](#what-you-need-to-edit-the-4-settings)
- [Why This Is Hard](#why-this-is-hard)
- [The Incompatible Versions We Worked Around](#the-incompatible-versions-we-worked-around)
- [How The Solution Works (The Clever Bit)](#how-the-solution-works-the-clever-bit)
- [Step-by-Step Guide (Manual Method)](#step-by-step-guide-manual-method)
- [Verify It Worked (incl. when to check ServiceNow)](#verify-it-worked)
- [Troubleshooting — Every Error We Hit](#troubleshooting--every-error-we-hit)
- [Operations — Restart, Logs, Teardown](#operations--restart-logs-teardown)
- [Running Discovery (use your MID)](DISCOVERY.md) — includes **how to check whether the
  Discovery plugin is even installed** (`./check-discovery.sh`) and how to activate it on a PDI
- [Appendix — Real-World Bring-Up Notes (2026-10-27)](APPENDIX.md)
- [Contributing & License](#contributing--license)

---

## 🚀 Quick Start — Run These Commands

**Run these commands one at a time, in order.** First you tell the script who you are (the 4 settings below), then you run the setup script.

> 🔁 **Instance refreshed or replaced (old one gone)?** Do **not** reinstall: the agent,
> JDK and volumes are instance-agnostic. Run `./repoint-mid.sh` with the new host/user/password
> — ~75 s, sudo-free, keeps your existing install (see the appendix for the runbook).
>
> ⚡ **Fastest path (recommended):** just run `./quickstart.sh` and answer 4 prompts — it uses
> `setup-mid-fast.sh`, which is **sudo-free** (no host `sudo`/password needed for `docker`-group users),
> **idempotent**, **skips the ~478 MB download when the agent is already installed** (starts in seconds
> on a re-run), and auto-fixes the "Unable to load keystore" trap. See [APPENDIX.md](APPENDIX.md).
> The manual steps below still work and use the original `setup-mid-arm64.sh`.

### Step 1 — Tell it your details


Copy-paste these four lines and **change the values** to match your own ServiceNow setup:

```bash
export SN_HOST="YOUR_INSTANCE.service-now.com"   # <-- your instance web address
export MID_USER="mid.server"                     # <-- your MID username
export MID_PASS='***PASSWORDHERE***'             # <-- your MID password (keep the quotes)
export MID_NAME="gx10-mid"                       # <-- a name you choose for this MID
```

> ⚠️ **Keep the single quotes around the password.** If your password contains `&`, `!`, `#` or similar, the quotes are what stop your shell from mangling it.

### Step 2 — Download and run the setup script

```bash
curl -fsSL https://raw.githubusercontent.com/eltonaguiar/ServiceNowMidServer/main/setup-mid-arm64.sh -o setup-mid-arm64.sh
# Optional but recommended: review the script before running it
cat setup-mid-arm64.sh
chmod +x setup-mid-arm64.sh
./setup-mid-arm64.sh
```

> 🔒 **Security note:** this downloads from the `main` branch, which can change. For a pinned, immutable copy, download a specific commit by replacing `main` with a full commit SHA in the URL (find SHAs under the repo's *Commits* page), then verify the file contents with `cat` before running. Never commit your real password anywhere — the `export` lines above live only in your terminal session.

### Step 3 — Watch it start

```bash
docker logs -f sn-mid
```

Press `Ctrl+C` to stop watching (the MID keeps running).

**Within ~60 seconds you should see:**

```
User mid.server has all necessary roles
Successfully connected to instance: YOUR_INSTANCE.service-now.com
Build tag: glide-australia-02-11-2026__patch3-05-25-2026
```

Then in ServiceNow go to **MID Server → MID Servers** and your MID should show **Status: Up**. ✅

> **Don't have `curl`?** Use `wget -O setup-mid-arm64.sh <the-url>` instead. Or just clone the repo (`git clone https://github.com/eltonaguiar/ServiceNowMidServer.git`) and run `./setup-mid-arm64.sh` from inside it.

---

## What You Need To Edit (The 4 Settings)

If you only read one section, read this one. The script has **4 settings you must change** — everything else is already tuned and you can leave it alone.

| Setting | What it is | Example | Where to find it |
|---------|-----------|---------|------------------|
| `SN_HOST` | Your instance's web address | `dev213089.service-now.com` | It's whatever you type into the browser to reach ServiceNow. Include the full address. |
| `MID_USER` | The ServiceNow login the MID will use | `mid.server` | A dedicated machine-user in **User Administration → Users**, with the **`mid_server`** role. |
| `MID_PASS` | That user's password | `'***PASSWORDHERE***'` | The password for the user above. **Keep it in quotes.** |
| `MID_NAME` | A friendly name for this MID (you pick it) | `gx10-mid` | Make it up! It's just what appears in the MID Server list. |

**ELI5:** think of these as the four things the MID needs to introduce itself to ServiceNow — *which server do I talk to* (`SN_HOST`), *who am I* (`MID_USER`), *prove it* (`MID_PASS`), and *what should people call me* (`MID_NAME`).

### Optional settings (rarely needed)

Only change these if your instance is **not** on the Australia release we tested:

| Setting | Default | When to change |
|---------|---------|----------------|
| `MID_BUILD` | `australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106` | Your instance runs a different release. Get your exact build tag from your instance's `stats.do` page or **MID Server → Downloads**. |
| `MID_DATE` | `2026/06/12` | The date folder of your build (matches the pattern above). |

```bash
export MID_BUILD="your-release-tag-here"
export MID_DATE="2026/06/12"
```

### ✏️ Editing an already-running setup

The script reads settings **only at run time**. To change something later, edit the `export` lines in Step 1 and re-run Step 2 (the script is safe to re-run — it keeps your existing registration).

### Security note

⚠️ **Never commit your password to git.** The `export` lines above are meant to be run in *your* terminal, not saved into a file you push. The repo's script uses `***PASSWORDHERE***` as a placeholder on purpose.

---

## Why This Is Hard

ServiceNow **does not ship an ARM64 MID Server.** Not as a `.deb`, not as an `.rpm`, not as a ZIP, not as a Docker image. Every official download is `x86-64` (Intel/AMD) only. *(ELI5: imagine buying a game that only comes out for PlayStation when you own an Xbox — there's simply no disc made for your console.)*

On an ARM64 machine the failure modes stack up:

1. **The official `.deb` refuses to install.**
   ```
   dpkg: package architecture (amd64) does not match system (arm64)
   ```
   Forcing it with `--force-architecture` unpacks Intel binaries that then can't execute. *(ELI5: you can force the disc into the slot, but the console still can't read it.)*

2. **There's no ARM64 alternative hidden on the download server.** We probed the CDN for `…arm64.deb`, `…aarch64.deb`, `…ARM64.deb` — all `404`. It genuinely doesn't exist.

3. **The community multi-arch image is the wrong release *and* the wrong Java.** [`moers/mid-server`](https://hub.docker.com/r/moers/mid-server) does have an `arm64` version, but it's pinned to an older release (**Zurich**) and bundles **Java 11**.

4. **The "starter" program is Intel-only.** The image ships `wrapper-linux-x86-64` — there's no ARM equivalent, so the normal start command dies instantly.

5. **MID can't upgrade itself.** Its auto-upgrade downloads a ~480 MB file and fails with *"The size of uncompressed files is too big or too many entries in the zip file."*

So you can't install it, can't run the packaged image as-is, and can't let it fix itself. Here's how we got a native, current-release, ARM64 MID running anyway.

> **SECTION SUMMARY:** There is no official ARM64 MID. Every "easy" path (installer, ready-made image, self-upgrade) fails for a different reason. The rest of this guide works around all three.

---

## The Incompatible Versions We Worked Around

This is the heart of the problem: **five separate version/architecture mismatches**, each failing differently. Knowing which one you've hit saves hours of guessing.

| # | Mismatch | What the error looks like | The fix |
|---|----------|---------------------------|---------|
| 1 | **CPU type**: `arm64` machine vs `x86-64` downloads | `dpkg: package architecture (amd64) does not match system (arm64)` | Don't install the `.deb`. Run the Java files directly (they work on any chip). |
| 2 | **MID release**: image is `Zurich` (rel 28), instance is `Australia` (rel 29) | Instance shows `Upgrade Failed`; MID tries and fails to self-upgrade | Manually overlay the **Australia** MID files (they're pure Java — arch-independent). |
| 3 | **Java version**: image has **Java 11** (class 55), MID needs **Java 17** (class 61) | `UnsupportedClassVersionError: ... class file version 61.0 ... only recognizes up to 55.0` | Install a real **ARM64 JDK 17** and launch with it. |
| 4 | **Starter program**: only an `x86-64` wrapper exists | `Unable to locate ... wrapper-linux-arm-64` | **Skip the wrapper** — start `com.service_now.mid.Main` directly with `java`. |
| 5 | **Java 17 rules**: MID uses APIs Java 17 now restricts | `InaccessibleObjectException: ... does not "opens java.nio"` | Add `--add-opens=...` flags **plus** `-Djava.security.manager=allow`. |

**ELI5 for the whole table:** the MID is like a box of parts. The *instructions* (Java code) are universal, but three of the *parts* were made for a different machine (Intel), one part is an old version (Java 11), and the new machine has stricter safety rules (Java 17). We kept the universal instructions, swapped the incompatible parts, and followed the new rules.

> **SECTION SUMMARY — the 5 mismatches in one line each:** 1. **Chip type** → skip the installer, use Java files · 2. **Release name** → swap Zurich files for Australia files · 3. **Java 11 vs 17** → install ARM Java 17 · 4. **Intel-only starter** → start with `java` directly · 5. **Java 17 safety rules** → add 2 launch flags.
>
> Plus two non-version traps: **passwords with `&` must be XML-encoded** in `config.xml` (and sed-escaped when inserting), and the MID runs as **uid 999 (not 1000)** — get the ownership wrong and it can't write its own logs.

---

## How The Solution Works (The Clever Bit)

**The key insight:** a MID Server is just a Java program. The actual MID files (`lib/*.jar`) are pure, chip-independent code. The only things that are chip-specific are:

- the **wrapper** binary (just a start/stop helper — we skip it), and
- the **bundled Java** (we replace it with a native ARM one).

*(ELI5: the engine is universal — only the spark plugs and the battery were the wrong size. Swap those two and the car runs.)*

So the recipe is:

1. Start from the community `arm64` image **only** for its folder layout and config template.
2. Install a native **ARM64 JDK 17**.
3. Download ServiceNow's official **Australia MID files** (pure Java).
4. **Unzip it yourself** (bypassing MID's own size limit) and overlay it.
5. Build a valid `config.xml` with an **XML-encoded** password.
6. Start MID **directly with `java`** (skipping the Intel wrapper), using the required flags.

**Result:** a native ARM64 MID running the exact Australia build your instance expects — no emulation, full speed.

> **SECTION SUMMARY:** We keep the universal Java code, replace the two Intel-only pieces (wrapper → skipped, Java → ARM version), add two Java 17 flags, and start it ourselves. That's the whole trick.

---

## Step-by-Step Guide (Manual Method)

*Prefer to understand what the script does, or need to debug? Run these by hand. If you just want it working, use the [Quick Start](#-quick-start-run-these-commands) instead.*

### Prerequisites

- ARM64 (`aarch64` — check with `uname -m`) Linux with Docker installed
- `sudo` access
- The following command-line tools: `unzip`, `wget`, `rsync` (all standard on Ubuntu; install missing ones with `apt install unzip wget rsync`)
- A ServiceNow **MID server user** with the `mid_server` role
- Outbound HTTPS to your instance **and** to `install.service-now.com`

Confirm your machine is ARM:

```bash
uname -m            # must print: aarch64  (Debian/Ubuntu also: dpkg --print-architecture → arm64)
```

### Step 1 — Pull the base image and create volumes

Volumes are Docker's permanent storage — they keep your config and Java between restarts.

```bash
docker pull --platform linux/arm64 moers/mid-server:latest
docker volume create mid_data
docker volume create mid_jdk17
```

### Step 2 — Install a native ARM64 JDK 17

The bundled Java is 11 (too old). Australia needs **≥ 17.0.10**. We use Corretto 17 for `aarch64`.

```bash
docker run --rm --platform linux/arm64 --user root \
  -v mid_jdk17:/opt/jdk17 \
  --entrypoint /bin/bash moers/mid-server:latest \
  -c 'wget -q https://corretto.aws/downloads/latest/amazon-corretto-17-aarch64-linux-jdk.tar.gz -O /tmp/jdk.tar.gz \
   && mkdir -p /opt/jdk17 \
   && tar -xzf /tmp/jdk.tar.gz -C /opt/jdk17 --strip-components=1 \
   && rm -f /tmp/jdk.tar.gz \
   && chown -R 999:999 /opt/jdk17 \
   && /opt/jdk17/bin/java -version'
```

Last line should print `openjdk version "17.0.x"`.

> **Why 17 and not 21?** 17 works. If your instance's patch requires 21, swap in `amazon-corretto-21-aarch64-linux-jdk.tar.gz` — everything else stays the same.

### Step 3 — Download the official Australia MID files

Get your build tag from your instance's `stats.do` page (**MID buildstamp** line). Ours: `australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106`.

```bash
MID_BUILD="australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106"
MID_DATE="2026/06/12"

wget -O /tmp/mid-core.zip \
  "https://install.service-now.com/glide/distribution/builds/package/app-signed/mid-core/${MID_DATE}/mid-core.${MID_BUILD}.universal.universal.zip"
```

> **Tip:** If you're unsure of the URL, the MID's own `agent0.log.0` prints the exact `mid-core…universal.zip` URL right before it fails the auto-upgrade. Copy it from there.

### Step 4 — Unzip to staging (with system unzip)

We use **system `unzip`**, not MID's Java unzipper — that's how we beat the *"too big or too many entries"* limit.

```bash
rm -rf /tmp/mid_au && mkdir -p /tmp/mid_au
unzip -q /tmp/mid-core.zip -d /tmp/mid_au

# Verify it's Australia (release 29):
unzip -p /tmp/mid_au/agent/lib/mid-acc-commons.jar META-INF/MANIFEST.MF | grep Implementation-Version
# Expect: Implementation-Version: 29.xxxxx
```

### Step 5 — Overlay the Australia files onto the live volume

Stop any running container first. We keep your existing `config.xml` (it holds your credentials and registration) and fix ownership to **uid 999**.

```bash
docker rm -f sn-mid 2>/dev/null

# Resolve the volume path dynamically (works on any Docker data-root / rootless setups)
V=$(docker volume inspect mid_data --format '{{.Mountpoint}}')

# Backup existing config only if this is NOT a fresh install
if [ -f "$V/config.xml" ]; then
  sudo cp "$V/config.xml" /tmp/config_backup.xml
fi
sudo rsync -a --exclude 'config.xml' --exclude 'logs/' /tmp/mid_au/agent/ "$V/"
if [ -f /tmp/config_backup.xml ]; then
  sudo cp /tmp/config_backup.xml "$V/config.xml"
fi
sudo chown -R 999:999 "$V"
```

> ⚠️ **`chown -R 999:999`, NOT `1000:1000`.** The MID user inside the container is **uid 999**. Getting this wrong is the #1 cause of the mysterious `AccessDeniedException` crash.

### Step 6 — Build a valid `config.xml` (first run only)

Skip this if you already have a registered MID (Step 5 kept yours). For a **fresh** setup:

```bash
docker run --rm --platform linux/arm64 --user root \
  -v mid_data:/opt/agent \
  -e SN_HOST_NAME="YOUR_INSTANCE.service-now.com" \
  -e USER_NAME="mid.server" \
  -e PASSWORD='***PASSWORDHERE***' \
  -e MIDNAME="gx10-mid" \
  --entrypoint /bin/bash moers/mid-server:latest \    -c 'cd /opt/agent; ENC_PW=$(printf %s "$PASSWORD" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g"); SED_PW=$(printf %s "$ENC_PW" | sed "s/[\\\\&|]/\\\\&/g"); cp /opt/config.xml /opt/agent/config.xml; sed -i "s|https://YOUR_INSTANCE.service-now.com|https://${SN_HOST_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_USER_NAME_HERE|${USER_NAME}|g" config.xml; sed -i "s|YOUR_INSTANCE_PASSWORD_HERE|${SED_PW}|g" config.xml; sed -i "s|YOUR_MIDSERVER_NAME_GOES_HERE|${MIDNAME}|g" config.xml; chown 999:999 config.xml'
```

> **Why the double `sed` on the password?** The first converts special characters into safe XML (`&` → `&amp;`). The second (`SED_PW`) escapes `&`, `|`, `\` *for sed's replacement syntax itself* — without it, sed treats `&` as "the matched text" and corrupts the value (password `A&B` would land in config.xml as `AYOUR_INSTANCE_PASSWORD_HEREamp;B`). Skip both and a password like `a&b` produces invalid XML → you get a confusing `401` even though the password is correct.
>
> **Do NOT add a `mid.pinned.version` parameter.** Pinning forces MID back to an older release and restarts the failed-upgrade loop.

### Step 7 — Launch the MID (direct Java, wrapper bypassed)

The launch that works. Note: **no wrapper**, direct `java … Main start`, backgrounded, container stays alive tailing the log.

```bash
docker rm -f sn-mid 2>/dev/null

docker run -d --name sn-mid \
  --platform linux/arm64 --restart unless-stopped --user root \
  -v mid_data:/opt/agent -v mid_jdk17:/opt/jdk17 \
  --entrypoint /bin/bash moers/mid-server:latest \
  -c "cd /opt/agent; rm -f /opt/agent/work/mid.pid; OPENS='--add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/javax.crypto=ALL-UNNAMED --add-opens=java.base/sun.security.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED'; su mid -s /bin/bash -c \"cd /opt/agent && nohup /opt/jdk17/bin/java -Xmx1024m -Djava.security.manager=allow \$OPENS -classpath 'lib/*:extlib/*' com.service_now.mid.Main start >/opt/agent/logs/console.log 2>&1 &\"; exec tail -F /opt/agent/logs/agent0.log.0 /opt/agent/logs/console.log"
```

**Why each flag matters (ELI5 in brackets):**

| Flag | Reason |
|------|--------|
| `-Djava.security.manager=allow` | Australia's code calls `System.setSecurityManager`. Java 17 blocks it by default → without this the JVM aborts. *(ELI5: the new house has a stricter alarm system — we need to tell it "yes, this is allowed".)* |
| `--add-opens=java.base/java.nio=ALL-UNNAMED` (+13 more) | MID's Apache Ignite looks inside Java's internals. Java 17's module system locks those rooms → `InaccessibleObjectException` without these. *(ELI5: give the program keys to the locked cabinets it needs.)* |

> ⚠️ **Java-version ceiling:** `-Djava.security.manager=allow` works on **JDK 17 and 21**, but Java has deprecated the Security Manager for removal — on newer JDKs (24+) this flag no longer enables it. Stick to JDK 17/21 for MID until ServiceNow ships a release designed for post-removal JDKs. If a future MID release drops the `setSecurityManager` call, the flag becomes a harmless no-op.
| `-classpath "lib/*:extlib/*"` | Loads all MID files. |
| `com.service_now.mid.Main start` | The real MID entrypoint (normally called *by* the wrapper — we call it ourselves). |
| `nohup … &` + `tail -F` | `Main start` forks a child and the parent exits. Without backgrounding + tailing, Docker thinks the container finished and restart-loops it. *(ELI5: keep a babysitter in the room so the container knows the job isn't done.)* |

> **SECTION SUMMARY (manual method):** install ARM Java 17 → download Australia files → unzip yourself → overlay while keeping `config.xml` → fix ownership to **999** → launch with `java` + the flags. That's it.

---

## Verify It Worked

### ✅ When to check ServiceNow (and what you'll see)

**Where:** In ServiceNow go to **MID Server → MID Servers** (the `ecc_agent` list) and find your `MID_NAME`.

**When to check:**

| When | What to expect | If it's not there yet |
|------|----------------|------------------------|
| **Right after starting** (first ~60s) | The MID authenticates, then the record appears/updates. Watch `docker logs -f sn-mid` — the handshake prints `Successfully connected to instance` when ready. | Wait. On a **fresh** setup the record doesn't exist until first successful registration. |
| **~1–2 min after launch** | **Status: Up** — this is the moment it's actually working. | Status `Starting`/`Down` → give it another minute, then check `docker logs --tail 50 sn-mid`. |
| **After clicking Validate** | **Validated: Yes** confirms the instance-side handshake (this is the state in the screenshot at the top of this README). | `Validating` forever → check for a stale **MID Server Issue** row (see Troubleshooting). |
| **Any time later** | Status stays `Up`, **Version** shows your release (`australia-…`), **Last refreshed** ticks with each heartbeat. | Status flipped to `Down` → container likely exited: `docker ps` + `docker logs --tail 50 sn-mid`. |

**Where the other places to look:**

- **MID Server → MID Server Issues** — one-off errors (e.g. the stale *"Aborting MID Server upgrade"* row from a pre-fix attempt; safe to close/delete once Status is Up)
- **`ecc_agent` record itself** — fields: `status`, `version`, `last refreshed`, `validated`
- **Instance stats** — browse to `https://YOUR_INSTANCE/stats.do` to see the expected `MID buildstamp` your instance wants

> **SECTION SUMMARY:** check **MID Server → MID Servers** about **2 minutes after launch**. You want three green signals: **Status: Up**, **Validated: Yes**, **Version: australia-…**. Before that, use `docker logs -f sn-mid` — the log tells you the moment the handshake completes.

```bash
# Container up and Java alive
docker ps -a --filter name=sn-mid
docker exec sn-mid bash -c "ps aux | grep 'Main start' | grep -v grep | grep -v defunct | wc -l"   # expect >= 1

# MID reports Australia build and connected cleanly
docker exec sn-mid bash -c "tail -100 /opt/agent/logs/agent0.log.0" | \
  grep -iE "Build tag|all necessary roles|Successfully connected|MID buildstamp"
```

Expected:

```
User mid.server has all necessary roles
Successfully connected to instance: YOUR_INSTANCE.service-now.com
Build tag: glide-australia-02-11-2026__patch3-05-25-2026
MID buildstamp: australia-02-11-2026__patch3-05-25-2026_06-12-2026_1106
```

**The easiest check** — in ServiceNow go to **MID Server → MID Servers**. Your MID should show **Status: Up** and **Validated: Yes** (that's what the screenshot at the top of this README shows). Click **Validate** to re-confirm.

Or check from the command line:

```bash
curl -s --user "mid.server:***PASSWORDHERE***" \
  "https://YOUR_INSTANCE.service-now.com/api/now/table/ecc_agent?sysparm_query=name%3Dgx10-mid&sysparm_fields=name,status"
```

> **SECTION SUMMARY:** you're looking for three things — Java process alive, log lines saying *"all necessary roles"* + *"Successfully connected"*, and **Status: Up** in the ServiceNow UI.

---

## Troubleshooting — Every Error We Hit

Each is a real error from building this, with the fix.

### `UnsupportedClassVersionError: ... class file version 61.0 ... up to 55.0`

**Cause:** Running with the bundled **Java 11** (max class 55). MID needs **Java 17** (class 61).
**Fix:** Install ARM64 JDK 17 (Step 2) and launch with `/opt/jdk17/bin/java`.

### `Unable to locate ... wrapper-linux-arm-64`

**Cause:** The Tanuki starter is x86-only; `mid.sh start` can't run on ARM.
**Fix:** Bypass it — start `com.service_now.mid.Main` directly with `java`. The `WrapperManager: ERROR - Unable to load the Wrapper's native library` warning you'll see is **non-fatal** (ELI5: it's a warning that a helper tool is missing, but we don't need that helper).

### `InaccessibleObjectException: ... does not "opens java.nio"`

**Cause:** MID's Apache Ignite reflects into Java internals; Java 17 blocks it.
**Fix:** Add the full `--add-opens=…` set.

### JVM starts then dies; log shows `System::setSecurityManager has been called` then terminates

**Cause:** Australia calls `System.setSecurityManager`, which Java 17 refuses unless allowed. (Zurich didn't call it — this is an **Australia-specific** requirement.)
**Fix:** Add `-Djava.security.manager=allow`.

### Auto-upgrade fails: `The size of uncompressed files is too big or too many entries in the zip file`

**Cause:** MID's built-in Java unzipper has a size/entry limit the ~480 MB Australia package exceeds.
**Fix:** Don't let it self-upgrade. Download the zip and unzip it **yourself** with system `unzip`, then overlay (Steps 3–5).

### `401 Unauthorized` / `User Not Authenticated` even though the password looks right

**Check in order:**
1. **Password contains `&` and wasn't XML-encoded** in `config.xml`. Encode `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&quot;`.
2. **The ServiceNow user has "password needs reset" enabled** — this blocks API/SOAP login entirely. Turn it off in the `sys_user` record. *(We hit this one!)*
3. Wrong password, or the user lacks the `mid_server` role.

Test your credentials directly (no MID involved):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  --user "mid.server:***PASSWORDHERE***" \
  "https://YOUR_INSTANCE.service-now.com/api/now/table/sys_user?sysparm_limit=1"
# HTTP 200 = good, HTTP 401 = bad credentials / role / reset-flag
```

### `AccessDeniedException: logs/agent1.log.0.lck` (or can't write FileHandlerReport.txt)

**Cause:** MID runs as `mid` (**uid 999**). If you overlaid files as root and/or `chown`'d to `1000:1000`, it can't write its own logs.
**Fix:** `sudo chown -R 999:999 /var/lib/docker/volumes/mid_data/_data`

### Container keeps restarting; `docker logs` shows nothing useful

**Cause:** `Main start` forks and the parent exits → Docker thinks the container finished.
**Fix:** Background `java` with `nohup … &` and `exec tail -F` the log (Step 7).

### Instance shows `Upgrade Failed` and empty Version

**Cause:** A prior failed self-upgrade left the `ecc_agent` record stuck.
**Fix:** Clear it, then restart:

```bash
curl -s --user "mid.server:***PASSWORDHERE***" -X PUT \
  -H "Content-Type: application/json" -d '{"status":"Down"}' \
  "https://YOUR_INSTANCE.service-now.com/api/now/table/ecc_agent/<SYS_ID>?sysparm_fields=status"
docker restart sn-mid
```

A leftover **MID Server Issue** row (e.g. *"Aborting MID Server upgrade due to pre-upgrade check failure"*) from before the fix is **stale** — safe to close/delete. It won't recur once versions match.

> **SECTION SUMMARY (troubleshooting):** 90% of problems are one of four things — **wrong Java version**, **Intel-only wrapper**, **missing Java 17 flags**, or **a credential/permission issue** (reset-flag, `&` in password, or uid 999 ownership). Find your error above and apply its one-line fix.

---

## Operations — Restart, Logs, Teardown

```bash
docker restart sn-mid                                   # restart (re-registers)
docker logs -f sn-mid                                   # follow logs
docker exec sn-mid bash -c "tail -f /opt/agent/logs/agent0.log.0"   # MID's own log
docker stop sn-mid                                      # stop

# Tear down completely (removes volumes = lose MID registration)
docker rm -f sn-mid
docker volume rm mid_data mid_jdk17
```

**Persistence:** `mid_data` holds your `config.xml` (credentials + registration) and `mid_jdk17` holds Java. Both survive `docker rm`, so you can remove and re-run the same `docker run` command without re-registering.

---

## Summary of the Hack

| Component | Official | What we did |
|-----------|----------|-------------|
| CPU package (`.deb`/`.rpm`) | x86-64 only | Skipped — run the Java files directly |
| Java runtime | Bundled x86 JRE / Java 11 | Native **ARM64 Corretto JDK 17** |
| Service wrapper | x86-64 Tanuki binary | **Bypassed** — direct `java … Main start` |
| MID release | Instance is Australia (29) | Manually overlaid **Australia** files |
| JVM flags | Defaults | `--add-opens` (×14) + `-Djava.security.manager=allow` |
| **Result** | **Won't install on ARM64** | **Native ARM64 MID, Australia build, Up & Validated** ✅ |

---

## Contributing & License

Found a fix for a new release, another ARM64 platform quirk, or a script improvement? Open an **issue** or **PR** — especially welcome:

- Verified steps for releases after Australia (update `MID_BUILD`/`MID_DATE` and confirm the release-check logic)
- Experience on other ARM64 hardware (Graviton, Raspberry Pi 5, Apple Silicon VMs)
- Docker Compose / rootless-Docker variants of the launch command

**License:** MIT — see [LICENSE](LICENSE). Use at your own risk; this is a community workaround for an unsupported configuration (ServiceNow does not officially support ARM64 MID Servers).

---

## Credits & References

- Community base image: [`moers/mid-server`](https://hub.docker.com/r/moers/mid-server) (multi-arch; used for layout + config template only)
- ARM64 JDK: [Amazon Corretto](https://corretto.aws/) for `aarch64`
- ServiceNow MID docs: [Build MID Server Docker image for Linux](https://www.servicenow.com/docs/r/servicenow-platform/mid-server/mid-build-docker-linux.html)

Built and verified on the NVIDIA GX10 (GB10 Grace Blackwell). No x86 emulation — fully native ARM64.
