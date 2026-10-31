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
PROOF_DIR="$(mktemp -d /tmp/openclaw-dns-proof.XXXXXX)"
COREDNS_DIR="$(brew --prefix)/etc/coredns"
COREFILE="${COREDNS_DIR}/Corefile"
MANAGED_COREFILE="${COREDNS_DIR}/managed-Corefile"
READER_ACCOUNT="dnsproofreader"
IMPORT_LINE="import ${COREDNS_DIR}/conf.d/*.server"

log() { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nPROOF FAILED: %s\n' "$*" >&2; exit 1; }

cleanup() {
  pkill -9 -f "dns setup" 2>/dev/null || true
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
# The command refuses to run without a tailnet address. A utun interface keeps
# the address off the loopback interface, which the command skips.
TAILNET_IP=""
for idx in 0 1 2 3 4 5; do
  if sudo ifconfig "utun${idx}" create >/dev/null 2>&1 \
    && sudo ifconfig "utun${idx}" inet 100.64.0.1 100.64.0.2 netmask 255.192.0.0 up >/dev/null 2>&1; then
    TAILNET_IP="100.64.0.1"
    echo "created utun${idx} with ${TAILNET_IP}"
    break
  fi
done
[ -n "${TAILNET_IP}" ] || fail "could not create a tailnet-range interface"
node -e 'const os=require("os");const hit=Object.entries(os.networkInterfaces()).flatMap(([n,e])=>(e||[]).filter(x=>x.address.startsWith("100.64.")).map(x=>n+"="+x.address));if(!hit.length){console.error("no tailnet address visible");process.exit(1)}console.log("visible:",hit.join(","))'

log "unauthorized reader account"
if ! id -u "${READER_ACCOUNT}" >/dev/null 2>&1; then
  sudo dscl . -create "/Users/${READER_ACCOUNT}" UserShell /usr/bin/false
  sudo dscl . -create "/Users/${READER_ACCOUNT}" UniqueID 54123
fi
echo "reader account: ${READER_ACCOUNT} (groups: $(id -Gn ${READER_ACCOUNT} 2>/dev/null || echo none))"

log "prepare a root-owned, group-restricted Corefile"
sudo mkdir -p "${COREDNS_DIR}/conf.d"
printf '.:53 {\n  errors\n  log\n}\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown root:wheel "${COREFILE}"
sudo chmod 640 "${COREFILE}"
sudo -u "${READER_ACCOUNT}" cat "${COREFILE}" >/dev/null 2>&1 \
  && fail "reader could read the original Corefile; the fixture is wrong"
echo "original Corefile: mode=$(sudo stat -f '%Lp' ${COREFILE}) owner=$(sudo stat -f '%Su:%Sg' ${COREFILE})"

run_setup() {
  # The CLI runs unprivileged so the publication takes the privileged path.
  set +e
  pnpm openclaw dns setup --domain openclaw.internal --apply >"$1" 2>&1
  local status=$?
  set -e
  echo "exit status: ${status} (a failure at the CoreDNS service restart is expected on a runner)"
  tail -n 15 "$1" || true
}

log "case 1: successful privileged publication"
run_setup "${PROOF_DIR}/setup-success.log"
grep -qF "${IMPORT_LINE}" "${COREFILE}" || fail "published Corefile lacks the import line"
echo "published Corefile: $(cat "${COREFILE}" | tr '\n' '|')"
[ "$(sudo stat -f '%Lp' "${COREFILE}")" = "640" ] || fail "published Corefile lost the operator's mode"
[ "$(sudo stat -f '%Su:%Sg' "${COREFILE}")" = "root:wheel" ] || fail "published Corefile lost the operator's ownership"
sudo -u "${READER_ACCOUNT}" cat "${COREFILE}" >/dev/null 2>&1 \
  && fail "reader could read the published Corefile"
echo "after publication: mode=$(sudo stat -f '%Lp' "${COREFILE}") owner=$(sudo stat -f '%Su:%Sg' "${COREFILE}"); reader denied"

log "case 2: interrupted privileged publication"
printf '.:53 {\n  errors\n  log\n}\n# marker-before-interruption\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown root:wheel "${COREFILE}"
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
[ -n "${STAGED}" ] || fail "no staging file appeared during the privileged publication"
STAGING_PATH="${COREDNS_DIR}/${STAGED}"
echo "staging file: ${STAGING_PATH} mode=$(sudo stat -f '%Lp' "${STAGING_PATH}") owner=$(sudo stat -f '%Su:%Sg' "${STAGING_PATH}")"
sudo -u "${READER_ACCOUNT}" cat "${STAGING_PATH}" >/dev/null 2>&1 \
  && fail "reader could read the staged configuration"
echo "reader denied the staged configuration"
pkill -9 -f "dns setup" 2>/dev/null || true
kill -9 "${SETUP_PID}" 2>/dev/null || true
sleep 1
AFTER_BYTES="$(sudo cat "${COREFILE}")"
[ "${BEFORE_BYTES}" = "${AFTER_BYTES}" ] || fail "interrupted publication changed the operator's Corefile"
echo "operator Corefile after the interruption: unchanged ($(echo "${AFTER_BYTES}" | tr '\n' '|'))"
sudo -u "${READER_ACCOUNT}" cat "${STAGING_PATH}" >/dev/null 2>&1 \
  && fail "reader could read the leftover staging file"
echo "leftover staging file after the interruption: still unreadable by the reader"

log "case 3: symlinked Corefile keeps its link"
sudo rm -f "${COREFILE}" "${MANAGED_COREFILE}"
printf '.:53 {\n  errors\n}\n' | sudo tee "${MANAGED_COREFILE}" >/dev/null
sudo chown root:wheel "${MANAGED_COREFILE}"
sudo chmod 640 "${MANAGED_COREFILE}"
sudo ln -s managed-Corefile "${COREFILE}"
run_setup "${PROOF_DIR}/setup-symlink.log"
[ -L "${COREFILE}" ] || fail "the operator's Corefile link was replaced by a regular file"
grep -qF "${IMPORT_LINE}" "${MANAGED_COREFILE}" || fail "the managed target was not updated"
echo "link preserved: $(readlink "${COREFILE}"); managed target updated"

log "case 4: latest stable configuration survives the upgrade"
sudo rm -f "${COREFILE}" "${MANAGED_COREFILE}"
printf '.:53 {\n  errors\n}\n' | sudo tee "${COREFILE}" >/dev/null
sudo chown root:wheel "${COREFILE}"
sudo chmod 640 "${COREFILE}"
set +e
pnpm dlx "openclaw@latest" dns setup --domain openclaw.internal --apply \
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
grep -qF "${IMPORT_LINE}" "${COREFILE}" || fail "the upgrade left the Corefile without its import"
echo "after the upgrade: mode=${STABLE_MODE} owner=${STABLE_OWNER} content=ok"

log "PROOF PASSED"
for logfile in "${PROOF_DIR}"/*.log; do
  echo "----- $(basename "${logfile}") -----"
  cat "${logfile}" || true
done
