#!/bin/bash
# Deploy imrnes-homepage from the artifact CI built.
#
# Runs as root on imrnes, invoked ONLY through /usr/local/bin/gh-actions-homepage,
# which is a forced command: the CI key cannot run anything else on this host.
#
# The release is unpacked beside the live one and swapped by symlink, so a failed
# start leaves the previous release serving. There is no `git pull` here on
# purpose — the host has no repository for this app, and a deploy that needs one
# is a deploy that can be edited by hand on the box.

set -euo pipefail

APP=/opt/imrnes-homepage
RELEASES=$APP/releases
CURRENT=$APP/current
UNIT=imrnes-homepage
UPLOAD=/opt/imrnes-homepage/upload/homepage-payload.tar.gz
KEEP=3

say() { printf '%s\n' "$*"; }

say "── pre-flight ──"
[ -f "$UPLOAD" ] || { say "FATAL: no payload at $UPLOAD"; exit 1; }
# A truncated upload is the failure this catches: tar would fail halfway through
# unpacking and leave a half-release that still looks like a directory.
tar -tzf "$UPLOAD" >/dev/null || { say "FATAL: payload is not a readable tarball"; exit 1; }

SHA=$(sha256sum "$UPLOAD" | cut -c1-12)
RELEASE=$RELEASES/$SHA

say "payload  : $(du -h "$UPLOAD" | cut -f1) sha=$SHA"
say "release  : $RELEASE"

say "── unpack ──"
mkdir -p "$RELEASES"
# Unpack to a staging name and rename at the end, so an interrupted unpack is
# never mistaken for a finished release.
STAGING=$RELEASES/.staging-$$
rm -rf "$STAGING"
mkdir -p "$STAGING"
tar -xzf "$UPLOAD" -C "$STAGING"

[ -f "$STAGING/.next/BUILD_ID" ] || { say "FATAL: payload has no .next/BUILD_ID"; exit 1; }
[ -d "$STAGING/node_modules" ] || { say "FATAL: payload has no node_modules"; exit 1; }

rm -rf "$RELEASE"
mv "$STAGING" "$RELEASE"
chown -R imrnes-homepage:imrnes-homepage "$RELEASE"

PREVIOUS=$(readlink -f "$CURRENT" 2>/dev/null || true)
say "previous : ${PREVIOUS:-none}"

say "── swap ──"
ln -sfn "$RELEASE" "$CURRENT"

say "── restart ──"
systemctl restart "$UNIT"

# Block on the observable state rather than on systemd's word for it: the unit
# reports active the moment the process is forked, which is before Next has
# bound the port.
for _ in $(seq 1 40); do
  if systemctl is-active --quiet "$UNIT" \
     && curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:3200/ 2>/dev/null; then
    say "site answered on 127.0.0.1:3200"
    break
  fi
  sleep 1
done

if ! systemctl is-active --quiet "$UNIT"; then
  say "FAIL: $UNIT is not active"
  journalctl -u "$UNIT" -n 30 --no-pager | tail -30
  # Put the previous release back: leaving the host on a release that does not
  # start is worse than leaving it one commit behind.
  if [ -n "$PREVIOUS" ] && [ -d "$PREVIOUS" ]; then
    say "rolling back to $PREVIOUS"
    ln -sfn "$PREVIOUS" "$CURRENT"
    systemctl restart "$UNIT"
  fi
  exit 1
fi

if ! curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:3200/ 2>/dev/null; then
  say "FAIL: $UNIT is active but nothing answers on 3200"
  journalctl -u "$UNIT" -n 30 --no-pager | tail -30
  exit 1
fi

say "── prune ──"
# Keep the last few releases so a rollback is possible without a re-download.
ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  say "removing $old"
  rm -rf "$old"
done

rm -f "$UPLOAD"

say "── result ──"
systemctl is-active "$UNIT"
say "deployed build $(cat "$CURRENT/.next/BUILD_ID")"
say "OK"
