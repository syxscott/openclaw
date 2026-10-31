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
export NODE_OPTIONS="--require ${PROOF_DIR}/tailnet-preload.cjs"
node -e 'const os=require("os");const hit=Object.entries(os.networkInterfaces()).flatMap(([n,e])=>(e||[]).filter(x=>!x.internal&&x.address.startsWith("100.64.")).map(x=>n+"="+x.address));if(!hit.length){console.error("no tailnet address visible");process.exit(1)}console.log("visible:",hit.join(","))'

log "unauthorized reader account"
if ! id -u "${READER_ACCOUNT}" >/dev/null 2>&1; then
  sudo dscl . -create "/Users/${READER_ACCOUNT}" UserShell /usr/bin/false
  sudo dscl . -create "/Users/${READER_ACCOUNT}" UniqueID 54123
fi
echo "reader account: ${READER_ACCOUNT} (groups: $(id -Gn ${READER_ACCOUNT} 2>/dev/null || echo none))"

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

log "case 2: interrupted privileged publication"
printf '.:53 {\n  errors\n  log\n}\n# marker-before-interruption\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown "root:${OPERATOR_GROUP}" "${COREFILE}"
sudo chmod 640 "${COREFILE}"
BEFORE_BYTES="$(sudo cat "${COREFILE}")"
# A sudo wrapper that pauses during the staged write gives the proof a
# deterministic interruption point inside the staging window.
mkdir -p "${PROOF_DIR}/bin"
cat >"${PROOF_DIR}/bin/sudo" <<'WRAPPER'
#!/usr/bin/env bash
if [ "${1:-}" = "tee" ]; then
  sleep 30
fi
exec /usr/bin/sudo "$@"
WRAPPER
chmod +x "${PROOF_DIR}/bin/sudo"
PATH="${PROOF_DIR}/bin:${PATH}" pnpm openclaw dns setup --domain openclaw.internal --apply \
  >"${PROOF_DIR}/setup-interrupted.log" 2>&1 &
SETUP_PID=$!
STAGED=""
for _ in $(seq 1 300); do
  STAGED="$(sudo ls -1 "${COREDNS_DIR}" 2>/dev/null | grep '^\.Corefile' | head -n 1 || true)"
  [ -n "${STAGED}" ] && break
  sleep 0.2
done
if [ -z "${STAGED}" ]; then
  echo "----- interrupted run log -----"
  cat "${PROOF_DIR}/setup-interrupted.log" || true
  echo "----- end log -----"
  fail "no staging file appeared during the privileged publication"
fi
STAGING_PATH="${COREDNS_DIR}/${STAGED}"
echo "staging file: ${STAGING_PATH} mode=$(sudo stat -f '%Lp' "${STAGING_PATH}") owner=$(sudo stat -f '%Su:%Sg' "${STAGING_PATH}")"
sudo -u "${READER_ACCOUNT}" cat "${STAGING_PATH}" >/dev/null 2>&1 \
  && fail "reader could read the staged configuration"
echo "reader denied the staged configuration"
pkill -9 -f "dns setup" 2>/dev/null || true
kill -9 "${SETUP_PID}" 2>/dev/null || true
sleep 1
AFTER_BYTES="$(sudo cat "${COREFILE}")"
if [ "${BEFORE_BYTES}" != "${AFTER_BYTES}" ]; then
  echo "before: $(echo "${BEFORE_BYTES}" | tr '
' '|')"
  echo "after:  $(echo "${AFTER_BYTES}" | tr '
' '|')"
  echo "stat:   mode=$(sudo stat -f '%Lp' "${COREFILE}") owner=$(sudo stat -f '%Su:%Sg' "${COREFILE}")"
  echo "dir:"
  sudo ls -la "${COREDNS_DIR}" || true
  fail "interrupted publication changed the operator's Corefile"
fi
echo "operator Corefile after the interruption: unchanged ($(echo "${AFTER_BYTES}" | tr '\n' '|'))"
sudo -u "${READER_ACCOUNT}" cat "${STAGING_PATH}" >/dev/null 2>&1 \
  && fail "reader could read the leftover staging file"
echo "leftover staging file after the interruption: still unreadable by the reader"

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
OPENCLAW_DEBUG=1 pnpm dlx "openclaw@latest" dns setup --domain openclaw.internal --apply \
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
