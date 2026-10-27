#!/bin/bash
# mid-supervisor.sh — relaunches the MID JVM whenever it exits.
#
# WHY THIS EXISTS
# ---------------
# This container runs the MID "wrapper-less" (we exec `com.service_now.mid.Main
# start` directly instead of through ServiceNow's service wrapper, because the
# wrapper is x86-only and we are on ARM64).
#
# A wrapper-less MID cannot honour a restart request. When the instance sends
# `restartService` / `restart` (i.e. somebody clicks "Restart MID" in the UI, or
# a config change asks for a restart), the JVM logs:
#
#   [RestartHandler] Wrapper-less MID Server cannot be automatically restarted.
#   Shutting down. MANUALLY START THE MID SERVER TO CONTINUE
#
# ...and then exits. Nothing brings it back, so the instance shows Status: Down
# while `docker ps` still reports the container as "Up" (only `tail` is alive).
#
# This supervisor turns that into a self-healing restart: the JVM is relaunched
# a few seconds after any exit.
#
# Tuning: MID_RESTART_DELAY (seconds, default 10), MID_MAX_FAST_RESTARTS before
# the delay degrades to a 60s back-off (protects against a crash loop).
set -u

cd /opt/agent || exit 1
LOG=/opt/agent/logs/console.log
mkdir -p /opt/agent/logs
: "${OPENS:=}"
: "${MID_XMX:=1024m}"
: "${MID_RESTART_DELAY:=10}"

say() { printf '[supervisor] %s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

say "=== supervisor started (restart delay ${MID_RESTART_DELAY}s) ==="
fast=0
while true; do
  rm -f /opt/agent/work/mid.pid
  started=$(date +%s)
  say "starting MID JVM"
  # shellcheck disable=SC2086
  /opt/jdk17/bin/java -Xmx"$MID_XMX" -Djava.security.manager=allow $OPENS \
    -classpath 'lib/*:extlib/*' com.service_now.mid.Main start >>"$LOG" 2>&1
  rc=$?
  ran=$(( $(date +%s) - started ))

  if [ "$ran" -lt 60 ]; then
    fast=$(( fast + 1 ))
  else
    fast=0
  fi

  if [ "$fast" -ge 3 ]; then
    delay=60
    say "MID exited rc=$rc after ${ran}s (fast-crash x$fast) — backing off ${delay}s"
  else
    delay="$MID_RESTART_DELAY"
    say "MID exited rc=$rc after ${ran}s — relaunching in ${delay}s"
  fi
  sleep "$delay"
done
