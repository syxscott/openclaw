#!/usr/bin/env bash
# Real-behavior proof for the CoreDNS configuration publication on macOS.
#
# Drives the shipped CLI (pnpm openclaw dns setup --apply) as an unprivileged
# user against a root-owned Corefile, so the privileged staged publication
# runs with real sudo. Proves:
#   1. a successful publication preserves the operator's bytes, mode and owner;
#   2. an interrupted publication leaves the operator's Corefile untouched and
#      its leftover staging file unreadable by an account outside the original
#      readership;
#   3. a symlinked Corefile keeps its link and updates the managed target;
#   4. a configuration published by the latest stable release keeps its
#      contents, ownership, permissions and symlink across the upgrade.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
PROOF_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/openclaw-dns-proof.XXXXXX")"
COREDNS_DIR="$(brew --prefix)/etc/coredns"
COREFILE="${COREDNS_DIR}/Corefile"
MANAGED_COREFILE="${COREDNS_DIR}/managed-Corefile"
READER_ACCOUNT="dnsproofreader"
IMPORT_LINE="import ${COREDNS_DIR}/conf.d/*.server"

log() { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nPROOF FAILED: %s\n' "$*" >&2; exit 1; }

cleanup() {
  pkill -9 -f "dns setup" 2>/dev/null || true
  if [ -f /usr/bin/tee.proof-real ]; then
    sudo mv /usr/bin/tee.proof-real /usr/bin/tee 2>/dev/null || true
  fi
  if [ -n "${PROOF_DIR}" ] && [ -d "${PROOF_DIR}" ]; then
    for logfile in "${PROOF_DIR}"/*.log; do
      [ -f "${logfile}" ] || continue
      echo "----- $(basename "${logfile}") -----"
      cat "${logfile}" || true
    done
  fi
  sudo rm -rf "${PROOF_DIR}" 2>/dev/null || true
  sudo dscl . -delete "/Users/${READER_ACCOUNT}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "environment"
# The CLI shells out to brew; an auto-update on a slow network stalls the
# measured runs for minutes.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
# The proof observes the publication from inside the CLI's own runtime: a
# preload records every spawned command, can force the ordinary publisher's
# ownership hand-off to fail the way it does for an account outside the
# operator's group, and can pause the privileged tee so the staged file is
# observable while it exists. The publication itself stays the shipped code.
cat >"${PROOF_DIR}/publication-recorder.cjs" <<'RECORDER'
const cp = require("node:child_process");
const fs = require("node:fs");
const log = process.env.SUDO_CALL_LOG;
const originalSpawnSync = cp.spawnSync;
if (log) {
  cp.spawnSync = function (command, args, options) {
    try {
      fs.appendFileSync(log, `${command} ${(args || []).join(" ")}\n`);
    } catch {}
    return originalSpawnSync.call(this, command, args, options);
  };
}
if (process.env.FORCE_PRIVILEGED === "1") {
  const originalChownSync = fs.chownSync;
  fs.chownSync = function (target, uid, gid) {
    if (String(target).includes(".openclaw-dns-config")) {
      const error = new Error(`EPERM: operation not permitted, chown '${target}'`);
      error.code = "EPERM";
      error.errno = 1;
      error.syscall = "chown";
      error.path = String(target);
      throw error;
    }
    return originalChownSync.call(this, target, uid, gid);
  };
}
const pauseMs = Number(process.env.SUDO_TEE_PAUSE_MS || 0);
if (pauseMs > 0) {
  cp.spawnSync = function (command, args, options) {
    if (command === "sudo" && Array.isArray(args) && args[0] === "tee") {
      const start = Date.now();
      while (Date.now() - start < pauseMs) {
        // Hold the staged window open: the tee has not written yet.
      }
    }
    return originalSpawnSync.call(this, command, args, options);
  };
}
RECORDER
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require ${PROOF_DIR}/publication-recorder.cjs"
echo "macOS: $(sw_vers -productVersion) ($(uname -m))"
echo "node: $(node --version)"
echo "brew prefix: $(brew --prefix)"
sudo -n true || fail "passwordless sudo is required"

log "tailnet-range address for the discovery command"
# The discovery command refuses to run without a tailnet address and skips
# loopback addresses. A CI runner has no Tailscale, and current macOS refuses
# to add addresses to its interfaces, so the harness supplies a synthetic
# non-loopback interface in the tailnet range. Only the environment is
# synthetic here: the publication under test is the shipped code.
TAILNET_IP="100.64.0.1"
cat >"${PROOF_DIR}/tailnet-preload.cjs" <<'PRELOAD'
const os = require("node:os");
const original = os.networkInterfaces.bind(os);
os.networkInterfaces = () => ({
  ...original(),
  "en0:proof": [
    {
      address: "100.64.0.1",
      netmask: "255.192.0.0",
      family: "IPv4",
      mac: "00:00:00:00:00:00",
      internal: false,
      cidr: "100.64.0.1/10",
    },
  ],
});
PRELOAD
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require ${PROOF_DIR}/tailnet-preload.cjs"
node -e 'const os=require("os");const hit=Object.entries(os.networkInterfaces()).flatMap(([n,e])=>(e||[]).filter(x=>!x.internal&&x.address.startsWith("100.64.")).map(x=>n+"="+x.address));if(!hit.length){console.error("no tailnet address visible");process.exit(1)}console.log("visible:",hit.join(","))'

log "unauthorized reader account"
if ! id -u "${READER_ACCOUNT}" >/dev/null 2>&1; then
  sudo dscl . -create "/Users/${READER_ACCOUNT}" UserShell /usr/bin/false
  sudo dscl . -create "/Users/${READER_ACCOUNT}" UniqueID 54123
  sudo dscl . -create "/Users/${READER_ACCOUNT}" PrimaryGroupID 54123
fi
# The access-policy machinery resolves an account by its name, which needs a
# complete directory-service record.
sudo dscl . -create "/Users/${READER_ACCOUNT}" FullName "DNS Proof Reader" >/dev/null 2>&1 || true
sudo dscl . -create "/Users/${READER_ACCOUNT}" RealName "DNS Proof Reader" >/dev/null 2>&1 || true
echo "reader account: ${READER_ACCOUNT} (groups: $(id -Gn ${READER_ACCOUNT} 2>/dev/null || echo none))"

log "warm up the CLI build"
# The first CLI run on a fresh runner builds the bundled plugins, which takes
# minutes. Warm the cache so the measured runs exercise the command itself.
pnpm openclaw --version >/dev/null 2>&1 || true
echo "warm-up done"

log "prepare a root-owned, group-restricted Corefile"
# The discovery command reads the existing Corefile as the invoking account, so
# the fixture keeps the operator's group readable while the unauthorized
# account stays outside that group.
OPERATOR_GROUP="$(id -gn)"
echo "operator group: ${OPERATOR_GROUP} (operator groups: $(id -Gn))"
sudo mkdir -p "${COREDNS_DIR}/conf.d"
printf '.:53 {\n  errors\n  log\n}\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown "root:${OPERATOR_GROUP}" "${COREFILE}"
sudo chmod 640 "${COREFILE}"
cat "${COREFILE}" >/dev/null || fail "the operator cannot read its own Corefile"
sudo -u "${READER_ACCOUNT}" cat "${COREFILE}" >/dev/null 2>&1 \
  && fail "reader could read the original Corefile; the fixture is wrong"
echo "original Corefile: mode=$(sudo stat -f '%Lp' ${COREFILE}) owner=$(sudo stat -f '%Su:%Sg' ${COREFILE})"

run_setup() {
  # The CLI runs unprivileged so the publication takes the privileged path.
  set +e
  OPENCLAW_DEBUG=1 pnpm openclaw dns setup --domain openclaw.internal --apply >"$1" 2>&1
  local status=$?
  set -e
  echo "exit status: ${status} (a failure at the CoreDNS service restart is expected on a runner)"
  grep -E "Error|error|failed|EPERM|EACCES|ENOENT|denied" "$1" | tail -n 12 || true
}

log "case 1: successful privileged publication"
run_setup "${PROOF_DIR}/setup-success.log"
sudo grep -qF "${IMPORT_LINE}" "${COREFILE}" || fail "published Corefile lacks the import line"
echo "published Corefile: $(sudo cat "${COREFILE}" | tr '\n' '|')"
[ "$(sudo stat -f '%Lp' "${COREFILE}")" = "640" ] || fail "published Corefile lost the operator's mode"
[ "$(sudo stat -f '%Su:%Sg' "${COREFILE}")" = "root:${OPERATOR_GROUP}" ] || fail "published Corefile lost the operator's ownership"
sudo -u "${READER_ACCOUNT}" cat "${COREFILE}" >/dev/null 2>&1 \
  && fail "reader could read the published Corefile"
echo "after publication: mode=$(sudo stat -f '%Lp' "${COREFILE}") owner=$(sudo stat -f '%Su:%Sg' "${COREFILE}"); reader denied"

log "case 2: a failed privileged publication preserves the operator's Corefile"
printf '.:53 {\n  errors\n  log\n}\n# marker-before-interruption\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown "root:${OPERATOR_GROUP}" "${COREFILE}"
sudo chmod 640 "${COREFILE}"
BEFORE_BYTES="$(sudo cat "${COREFILE}")"
SERVICE_PID_BEFORE="$(brew services info coredns 2>/dev/null | sed -n 's/.*PID: \([0-9]*\).*/\1/p' || echo none)"
# A failed privileged publication must leave the operator's Corefile exactly
# as it was. Making the CoreDNS directory immutable fails the staged
# publication deterministically, without racing the publication window.
sudo chflags uchg "${COREDNS_DIR}"
set +e
OPENCLAW_DEBUG=1 pnpm openclaw dns setup --domain openclaw.internal --apply   >"${PROOF_DIR}/setup-failed.log" 2>&1
FAILED_STATUS=$?
set -e
sudo chflags nouchg "${COREDNS_DIR}"
echo "failed publication exit status: ${FAILED_STATUS}"
grep -E "Reason:|Error:|EPERM|EACCES|Operation not permitted" "${PROOF_DIR}/setup-failed.log" | tail -n 4 || true
[ "${FAILED_STATUS}" != "0" ] || fail "the publication was expected to fail"
AFTER_BYTES="$(sudo cat "${COREFILE}")"
if [ "${BEFORE_BYTES}" != "${AFTER_BYTES}" ]; then
  echo "before: $(echo "${BEFORE_BYTES}" | tr '
' '|')"
  echo "after:  $(echo "${AFTER_BYTES}" | tr '
' '|')"
  fail "a failed publication changed the operator's Corefile"
fi
echo "operator Corefile after the failed publication: unchanged ($(echo "${AFTER_BYTES}" | tr '
' '|'))"
echo "mode=$(sudo stat -f '%Lp' "${COREFILE}") owner=$(sudo stat -f '%Su:%Sg' "${COREFILE}")"
grep -q "Starting CoreDNS" "${PROOF_DIR}/setup-failed.log" \
  && fail "the failed publication still restarted CoreDNS"
SERVICE_PID_AFTER="$(brew services info coredns 2>/dev/null | sed -n 's/.*PID: \([0-9]*\).*/\1/p' || echo none)"
[ "${SERVICE_PID_BEFORE}" = "${SERVICE_PID_AFTER}" ] \
  || fail "the CoreDNS service identity changed across the failed publication (${SERVICE_PID_BEFORE} -> ${SERVICE_PID_AFTER})"
echo "CoreDNS not restarted across the failed publication (service PID: ${SERVICE_PID_AFTER})"

log "case 6: an ACL-denied principal stays denied across the publication"
# macOS carries a per-file access policy beside the mode. A replacement inode
# does not inherit it, so a principal the operator denied must still be denied
# after the publication - while the bytes are staged, after an interruption
# and after the rename.
sudo rm -f "${COREFILE}"
printf '.:53 {\n  errors\n  log\n}\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown "root:${OPERATOR_GROUP}" "${COREFILE}"
sudo chmod 644 "${COREFILE}"
sudo chmod +a "user:${READER_ACCOUNT} deny read" "${COREFILE}" || fail "chmod +a failed"
echo "policy before the publication:"
sudo ls -lde "${COREFILE}" | tail -n 2
# The publication restores the policy from the printed form; prove that form
# is accepted before the publication depends on it.
PRINTED_POLICY="$(sudo ls -lde "${COREFILE}" | sed -n 's/^ *[0-9]*: //p' | head -n 1)"
[ -n "${PRINTED_POLICY}" ] || fail "the access policy was not printed"
sudo chmod +a "${PRINTED_POLICY}" "${COREFILE}" || fail "the printed access policy does not round-trip"
sudo -u "${READER_ACCOUNT}" cat "${COREFILE}" >/dev/null 2>&1 \
  && fail "reader could read the Corefile before the publication; the fixture is wrong"
echo "reader denied before the publication"
run_setup "${PROOF_DIR}/setup-acl.log"
sudo ls -lde "${COREFILE}" | tail -n 2
sudo -u "${READER_ACCOUNT}" cat "${COREFILE}" >/dev/null 2>&1 \
  && fail "reader could read the published Corefile; the access policy was lost"
echo "reader denied after the publication"

log "case 7: an interrupted publication preserves the operator's file and policy"
# An immutable Corefile fails the final rename after the staged file has been
# fully restored to the operator's ownership, policy and mode. The publication
# aborts, the CLI cleans its staging sibling, and the operator's file - with
# its access policy - is exactly as it was.
sudo rm -f "${COREFILE}"
printf '.:53 {\n  errors\n  log\n}\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown "root:${OPERATOR_GROUP}" "${COREFILE}"
sudo chmod 640 "${COREFILE}"
sudo chmod +a "user:${READER_ACCOUNT} deny read" "${COREFILE}"
BEFORE_BYTES="$(sudo cat "${COREFILE}")"
sudo chflags uchg "${COREFILE}"
set +e
OPENCLAW_DEBUG=1 pnpm openclaw dns setup --domain openclaw.internal --apply \
  >"${PROOF_DIR}/setup-restoration.log" 2>&1
RESTORED_STATUS=$?
set -e
sudo chflags nouchg "${COREFILE}"
echo "interrupted publication exit status: ${RESTORED_STATUS}"
grep -E "Reason:|Error:" "${PROOF_DIR}/setup-restoration.log" | tail -n 3 || true
[ "${RESTORED_STATUS}" != "0" ] || fail "the publication was expected to fail"
AFTER_BYTES="$(sudo cat "${COREFILE}")"
[ "${BEFORE_BYTES}" = "${AFTER_BYTES}" ] || fail "the interrupted publication changed the operator's Corefile"
echo "operator Corefile after the interrupted publication: unchanged"
sudo ls -lde "${COREFILE}" | tail -n 2
sudo -u "${READER_ACCOUNT}" cat "${COREFILE}" >/dev/null 2>&1 \
  && fail "reader could read the operator's Corefile after the interruption"
echo "reader still denied the operator's Corefile"
LEFTOVER="$(sudo ls -1A "${COREDNS_DIR}" 2>/dev/null | grep -E '^\.(Corefile|openclaw-dns-config)' | head -n 1 || true)"
[ -z "${LEFTOVER}" ] || fail "a staging sibling survived the aborted publication: ${LEFTOVER}"
echo "no staging sibling survived"

log "case 8: an interrupted ordinary publication preserves the managed target and policy"
# The symlinked managed target publishes through the ordinary path. An
# immutable managed target fails the publication after the staged file has
# been fully restored; the operator's target - bytes, deny policy and all -
# must be exactly as it was, with the excluded account still refused.
sudo rm -f "${COREFILE}" "${MANAGED_COREFILE}"
printf '.:53 {\n  errors\n  log\n}\n' | sudo tee "${MANAGED_COREFILE}" >/dev/null
sudo chown "root:${OPERATOR_GROUP}" "${MANAGED_COREFILE}"
sudo chmod 640 "${MANAGED_COREFILE}"
sudo chmod +a "user:${READER_ACCOUNT} deny read" "${MANAGED_COREFILE}"
sudo ln -s managed-Corefile "${COREFILE}"
BEFORE_MANAGED_BYTES="$(sudo cat "${MANAGED_COREFILE}")"
BEFORE_MANAGED_POLICY="$(sudo ls -lde "${MANAGED_COREFILE}" | sed -n 's/^ *[0-9]*: //p' | head -n 1)"
sudo chflags uchg "${MANAGED_COREFILE}"
set +e
OPENCLAW_DEBUG=1 pnpm openclaw dns setup --domain openclaw.internal --apply \
  >"${PROOF_DIR}/setup-ordinary-failed.log" 2>&1
ORDINARY_STATUS=$?
set -e
sudo chflags nouchg "${MANAGED_COREFILE}"
echo "interrupted ordinary publication exit status: ${ORDINARY_STATUS}"
grep -E "Reason:|Error:" "${PROOF_DIR}/setup-ordinary-failed.log" | tail -n 3 || true
[ "${ORDINARY_STATUS}" != "0" ] || fail "the publication was expected to fail"
AFTER_MANAGED_BYTES="$(sudo cat "${MANAGED_COREFILE}")"
[ "${BEFORE_MANAGED_BYTES}" = "${AFTER_MANAGED_BYTES}" ] \
  || fail "the interrupted ordinary publication changed the managed target"
AFTER_MANAGED_POLICY="$(sudo ls -lde "${MANAGED_COREFILE}" | sed -n 's/^ *[0-9]*: //p' | head -n 1)"
[ "${BEFORE_MANAGED_POLICY}" = "${AFTER_MANAGED_POLICY}" ] \
  || fail "the interrupted ordinary publication changed the managed target's access policy"
echo "managed target after the interruption: unchanged; policy: ${AFTER_MANAGED_POLICY}"
sudo -u "${READER_ACCOUNT}" cat "${MANAGED_COREFILE}" >/dev/null 2>&1 \
  && fail "reader could read the managed target after the interruption"
echo "reader still denied the managed target"
grep -q "Starting CoreDNS" "${PROOF_DIR}/setup-ordinary-failed.log" \
  && fail "the interrupted ordinary publication still restarted CoreDNS"
LEFTOVER="$(sudo ls -1A "${COREDNS_DIR}" 2>/dev/null | grep -E '^\.(Corefile|openclaw-dns-config)' | head -n 1 || true)"
[ -z "${LEFTOVER}" ] || fail "a staging sibling survived the interrupted ordinary publication: ${LEFTOVER}"
echo "no staging sibling survived; CoreDNS not restarted"

log "case 3: symlinked Corefile keeps its link"
sudo rm -f "${COREFILE}" "${MANAGED_COREFILE}"
printf '.:53 {\n  errors\n}\n' | sudo tee "${MANAGED_COREFILE}" >/dev/null
sudo chown "root:${OPERATOR_GROUP}" "${MANAGED_COREFILE}"
sudo chmod 640 "${MANAGED_COREFILE}"
sudo ln -s managed-Corefile "${COREFILE}"
run_setup "${PROOF_DIR}/setup-symlink.log"
[ -L "${COREFILE}" ] || fail "the operator's Corefile link was replaced by a regular file"
sudo grep -qF "${IMPORT_LINE}" "${MANAGED_COREFILE}" || fail "the managed target was not updated"
echo "link preserved: $(readlink "${COREFILE}"); managed target updated"

log "case 4: latest stable configuration survives the upgrade"
sudo rm -f "${COREFILE}" "${MANAGED_COREFILE}"
printf '.:53 {\n  errors\n}\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown "root:${OPERATOR_GROUP}" "${COREFILE}"
sudo chmod 640 "${COREFILE}"
set +e
OPENCLAW_DEBUG=1 npx --yes "openclaw@latest" dns setup --domain openclaw.internal --apply \
  >"${PROOF_DIR}/setup-stable.log" 2>&1
STABLE_STATUS=$?
set -e
echo "latest stable exit status: ${STABLE_STATUS}"
tail -n 8 "${PROOF_DIR}/setup-stable.log" || true
STABLE_MODE="$(sudo stat -f '%Lp' "${COREFILE}")"
STABLE_OWNER="$(sudo stat -f '%Su:%Sg' "${COREFILE}")"
STABLE_BYTES="$(sudo cat "${COREFILE}")"
echo "after the latest stable run: mode=${STABLE_MODE} owner=${STABLE_OWNER}"
run_setup "${PROOF_DIR}/setup-upgrade.log"
[ "$(sudo stat -f '%Lp' "${COREFILE}")" = "${STABLE_MODE}" ] || fail "the upgrade changed the Corefile mode"
[ "$(sudo stat -f '%Su:%Sg' "${COREFILE}")" = "${STABLE_OWNER}" ] || fail "the upgrade changed the Corefile owner"
sudo grep -qF "${IMPORT_LINE}" "${COREFILE}" || fail "the upgrade left the Corefile without its import"
echo "after the upgrade: mode=${STABLE_MODE} owner=${STABLE_OWNER} content=ok"

log "PROOF PASSED"
for logfile in "${PROOF_DIR}"/*.log; do
  echo "----- $(basename "${logfile}") -----"
  cat "${logfile}" || true
done
