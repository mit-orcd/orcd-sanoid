#!/usr/bin/env bash
# Install Sanoid and Syncoid on a RHEL-family server.
#
# Follows sanoid/INSTALL.md, section "RHEL/CentOS/AlmaLinux":
#   prerequisites (EPEL, CodeReady Builder / PowerTools / CRB, Perl modules,
#   lzop, mbuffer, mhash, pv), copy of the executables and config files,
#   sanoid.service, sanoid-prune.service, sanoid.timer (every 15 minutes),
#   then systemctl enable.
#
# INSTALL.md lists every distro variant as consecutive commands. Running them
# all on one host fails, so this script enables only the builder repo and EPEL
# method that match the machine it is running on.
#
# Run this on the RHEL, CentOS Stream, AlmaLinux, or Rocky Linux server:
#
#   sudo ./install-sanoid-rhel.sh
#
# ./sanoid is not part of this repository. If that directory is missing,
# this script clones https://github.com/jimsalterjrs/sanoid.git into it.
# An existing checkout is fetched. Either way the latest stable v* tag is
# checked out (same step as INSTALL.md). check-sanoid-compat.sh then
# compares that tree with the template sanoid.conf in this directory.
# The template is not stored inside sanoid/, so the refresh does not
# replace it.
#
# Installed names match the manual INSTALL.md procedure:
#   /usr/local/sbin/{sanoid,syncoid,findoid,sleepymutex}
#   /etc/sanoid/sanoid.conf
#   /etc/sanoid/sanoid.defaults.conf
#   /etc/sanoid/sanoid.example.conf
#   sanoid.service, sanoid-prune.service, sanoid.timer
# sanoid-config and sanoid-discover.timer are added beside those units.
# They do not replace them.
#
# A missing /etc/sanoid/sanoid.conf is created empty, then sanoid-config fills
# it from zfs list. A new dataset such as data1/xyz or data1/xyz/abc is given
# template_production and com.sun:auto-snapshot=true. Pool roots are omitted.
# A dataset whose property is false stays out. A non-empty
# sanoid.conf that sanoid-config did not write is left unchanged until
# `sanoid-config sync --force`. sanoid.service will not run while sanoid.conf
# is empty (ConditionFileNotEmpty).

set -euo pipefail

UPSTREAM_URL="https://github.com/jimsalterjrs/sanoid.git"
SBIN_DIR="/usr/local/sbin"
CONF_DIR="/etc/sanoid"
UNIT_DIR="/etc/systemd/system"

SOURCE_DIR=""
GIT_REF=""
CHECK_ONLY=0
ORIG_ARGS=("$@")
SCRIPT_DIR=""

log() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install-sanoid-rhel.sh [--ref REF] [--source DIR] [--check DIR]

Install sanoid on the RHEL-family server where this script is run.
The ./sanoid checkout is refreshed to the latest stable v* tag first.
See the header comment and sanoid/INSTALL.md (RHEL/CentOS/AlmaLinux).

  --ref REF      Tag or branch to check out. Default: latest stable v* tag.
  --source DIR   Use this Sanoid tree instead of refreshing ./sanoid.
                 The compatibility check still runs.
  --check DIR    Run only the compatibility check against this Sanoid tree
                 and the sanoid.conf template in this directory, then exit.
  -h, --help     Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || die "--source requires a directory"
      SOURCE_DIR=$2
      shift 2
      ;;
    --clone)
      warn "--clone is not needed; ./sanoid is refreshed to the latest stable tag"
      shift
      ;;
    --check)
      [[ $# -ge 2 ]] || die "--check requires a Sanoid source directory"
      CHECK_ONLY=1
      SOURCE_DIR=$2
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || die "--ref requires a tag or branch"
      GIT_REF=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (try --help)"
      ;;
  esac
done

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  "${SCRIPT_DIR}/check-sanoid-compat.sh" "${SOURCE_DIR}" "${SCRIPT_DIR}/sanoid.conf"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Run this script as root."
  exec sudo -- "$0" "${ORIG_ARGS[@]}"
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

[[ "$(uname -s)" == "Linux" ]] || die "Run this script on the RHEL server, not on $(uname -s)."
[[ -r /etc/os-release ]] || die "/etc/os-release is missing; this does not look like a systemd Linux host."

# shellcheck disable=SC1091
source /etc/os-release
ID=${ID:-}
VERSION_ID=${VERSION_ID:-}
MAJOR=${VERSION_ID%%.*}
CPU=$(uname -m)

case "${ID}" in
  rhel|centos|almalinux|rocky) ;;
  *)
    die "Unsupported distribution '${ID:-unknown}'. This script covers the INSTALL.md RHEL/CentOS/AlmaLinux path (RHEL, CentOS Stream, AlmaLinux, Rocky Linux)."
    ;;
esac

[[ "${MAJOR}" =~ ^[0-9]+$ ]] || die "Could not parse a major version from VERSION_ID='${VERSION_ID}'."
if [[ "${MAJOR}" -lt 8 ]]; then
  die "RHEL ${MAJOR} is not supported. INSTALL.md targets RHEL/CentOS/Alma 8 and newer."
fi
if [[ "${MAJOR}" -gt 10 ]]; then
  warn "RHEL ${MAJOR} was not in INSTALL.md when this script was written. Using the RHEL ${MAJOR} CodeReady Builder / CRB names."
fi

command -v dnf >/dev/null 2>&1 || die "dnf is required."

dnf_config_set_enabled() {
  local repo=$1
  local help

  help=$(dnf config-manager --help 2>&1 || true)
  if [[ "${help}" == *"No such command"* ]]; then
    log "Installing dnf-plugins-core so repositories can be enabled"
    dnf install -y dnf-plugins-core
    help=$(dnf config-manager --help 2>&1 || true)
  fi

  if [[ "${help}" == *"--set-enabled"* ]]; then
    dnf config-manager --set-enabled "${repo}"
  else
    dnf config-manager setopt "${repo}.enabled=1"
  fi
}

repo_ids() {
  dnf repolist --all | awk 'NR > 1 && $1 != "" { print $1 }'
}

repo_exists() {
  local id=$1
  local ids
  ids=$(repo_ids)
  awk -v id="${id}" '$0 == id { found = 1 } END { exit !found }' <<< "${ids}"
}

enable_named_repo() {
  local id
  for id in "$@"; do
    if repo_exists "${id}"; then
      log "Enabling ${id}"
      dnf_config_set_enabled "${id}"
      return 0
    fi
  done
  return 1
}

enable_builder_repo() {
  local ids found

  if [[ "${ID}" == "rhel" ]]; then
    local repo="codeready-builder-for-rhel-${MAJOR}-${CPU}-rpms"
    if command -v subscription-manager >/dev/null 2>&1 && subscription-manager identity >/dev/null 2>&1; then
      log "Enabling CodeReady Builder (${repo})"
      if subscription-manager repos --enable "${repo}"; then
        return 0
      fi
      warn "subscription-manager could not enable ${repo}; looking for an RHUI CodeReady repository"
    else
      log "subscription-manager is not registered; looking for a CodeReady Builder repo in dnf"
    fi

    ids=$(repo_ids)
    found=$(awk -v major="${MAJOR}" '$0 ~ "^codeready-builder-for-rhel-" major "-" { print; exit }' <<< "${ids}")
    if [[ -n "${found}" ]]; then
      log "Enabling ${found}"
      dnf_config_set_enabled "${found}"
      return 0
    fi
    die "No CodeReady Builder repository found for RHEL ${MAJOR}. Register the host with subscription-manager, or enable the RHUI codeready-builder repo, then re-run."
  fi

  if [[ "${MAJOR}" -eq 8 ]]; then
    enable_named_repo powertools PowerTools \
      || die "Could not find the PowerTools repository (powertools / PowerTools)."
    return 0
  fi

  enable_named_repo crb \
    || die "Could not find the CRB repository. On AlmaLinux/Rocky/CentOS ${MAJOR} it is named crb."
}

enable_epel() {
  if [[ "${ID}" == "rhel" ]]; then
    if rpm -q epel-release >/dev/null 2>&1; then
      log "epel-release is already installed"
      return 0
    fi
    log "Installing EPEL ${MAJOR} from Fedora (RHEL has no epel-release package in its own repos)"
    dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${MAJOR}.noarch.rpm"
    return 0
  fi

  log "Installing epel-release"
  if ! dnf install -y epel-release; then
    if repo_exists extras; then
      log "Enabling extras and retrying epel-release"
      dnf_config_set_enabled extras
      dnf install -y epel-release
    else
      die "epel-release is not available. Enable the distribution extras repository and re-run."
    fi
  fi

  if [[ "${ID}" == "centos" && "${MAJOR}" -eq 9 ]]; then
    dnf install -y epel-next-release || warn "epel-next-release was not installed; continuing with EPEL only"
  fi
}

install_packages() {
  local required=(git perl perl-Config-IniFiles perl-Capture-Tiny lzop mbuffer pv)
  local optional=(perl-Data-Dumper perl-Getopt-Long mhash gzip openssh-clients)
  local package

  log "Installing Sanoid dependencies"
  if dnf install -y "${required[@]}" "${optional[@]}"; then
    return 0
  fi

  warn "The full INSTALL.md package list did not install in one transaction. Installing required packages, then each optional package on its own."
  dnf install -y "${required[@]}"
  for package in "${optional[@]}"; do
    dnf install -y "${package}" || warn "Package ${package} is not in the enabled repositories; continuing"
  done
}

ensure_perl_modules() {
  local module
  local -a missing=()

  for module in Config::IniFiles Capture::Tiny Data::Dumper Getopt::Long; do
    if ! perl -M"${module}" -e 'exit 0' >/dev/null 2>&1; then
      missing+=("${module}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "Perl modules are present: Config::IniFiles Capture::Tiny Data::Dumper Getopt::Long"
    return 0
  fi

  warn "Missing Perl modules after the dnf install: ${missing[*]}"
  log "Installing the missing modules from CPAN, which is the fallback in INSTALL.md"
  if ! command -v cpanm >/dev/null 2>&1; then
    dnf install -y perl-App-cpanminus || dnf install -y perl-CPAN
  fi

  if command -v cpanm >/dev/null 2>&1; then
    cpanm --notest "${missing[@]}"
  else
    PERL_MM_USE_DEFAULT=1 perl -MCPAN -e 'for my $m (@ARGV) { CPAN::Shell->notest("install", $m) }' -- "${missing[@]}"
  fi

  for module in "${missing[@]}"; do
    perl -M"${module}" -e 'exit 0' >/dev/null 2>&1 || die "Perl module ${module} is still not loadable."
  done
}

# git refuses to read a checkout root does not own unless this path is marked
# safe. -c does not change the user's git config.
git_sanoid() {
  local dest=$1
  shift
  git -C "${dest}" -c "safe.directory=${dest}" "$@"
}

# Print the remote name to fetch. A copied tree often has no origin remote;
# add the upstream URL in that case. A remote that points somewhere else is
# left alone and the install stops.
sanoid_fetch_remote() {
  local dest=$1
  local url name

  url=$(git_sanoid "${dest}" config --get remote.origin.url 2>/dev/null || true)
  if [[ -n "${url}" ]]; then
    case "${url}" in
      *jimsalterjrs/sanoid*)
        printf '%s\n' origin
        return 0
        ;;
      *)
        die "${dest} origin is '${url}', not ${UPSTREAM_URL}. Pass --source to use a different tree."
        ;;
    esac
  fi

  name=$(git_sanoid "${dest}" remote -v | awk '$2 ~ /jimsalterjrs\/sanoid(\.git)?$/ { print $1; exit }')
  if [[ -n "${name}" ]]; then
    printf '%s\n' "${name}"
    return 0
  fi

  # stderr: this function's stdout is the remote name.
  printf '==> No upstream remote in %s; adding origin %s\n' "${dest}" "${UPSTREAM_URL}" >&2
  git_sanoid "${dest}" remote add origin "${UPSTREAM_URL}"
  printf '%s\n' origin
}

refresh_sanoid_repo() {
  local dest="${SCRIPT_DIR}/sanoid"
  local remote ref latest git_err

  command -v git >/dev/null 2>&1 || die "git is required to refresh ${UPSTREAM_URL}."
  export GIT_TERMINAL_PROMPT=0
  git_err=$(mktemp)

  if [[ -d "${dest}/.git" || -f "${dest}/.git" ]]; then
    if ! git_sanoid "${dest}" rev-parse --is-inside-work-tree >/dev/null 2>"${git_err}"; then
      warn "${dest} is not a usable Git checkout: $(tr '\n' ' ' < "${git_err}")"
      warn "Replacing it with a clone of ${UPSTREAM_URL}."
      rm -rf "${dest}"
      git clone "${UPSTREAM_URL}" "${dest}"
    else
      remote=$(sanoid_fetch_remote "${dest}")
      log "Refreshing ${dest} from ${remote}"
      git_sanoid "${dest}" fetch --tags "${remote}"
    fi
  elif [[ ! -e "${dest}" ]]; then
    log "Cloning ${UPSTREAM_URL} into ${dest}"
    git clone "${UPSTREAM_URL}" "${dest}"
  else
    rm -f "${git_err}"
    die "${dest} exists and is not a git checkout. Move it aside, or pass --source."
  fi

  if [[ -n "${GIT_REF}" ]]; then
    ref=${GIT_REF}
  else
    # Version-sort, so v2.10.0 is newer than v2.9.0. INSTALL.md's
    # "git tag | grep ^v | tail -n 1" follows the order tags were created.
    latest=$(git_sanoid "${dest}" tag -l 'v*' --sort=v:refname | awk 'END { print }')
    [[ -n "${latest}" ]] || die "No v* tags found in ${dest}."
    ref=${latest}
    git_sanoid "${dest}" rev-parse -q --verify "refs/tags/${ref}" >/dev/null \
      || die "${ref} is not a tag in ${dest}."
    log "Latest stable tag is ${ref}"
  fi

  log "Checking out ${ref}"
  git_sanoid "${dest}" checkout --force --detach "${ref}"
  rm -f "${git_err}"
  SOURCE_DIR=${dest}
}

install_files() {
  local src=$1
  local bin

  for bin in sanoid syncoid findoid sleepymutex sanoid.defaults.conf sanoid.conf; do
    [[ -f "${src}/${bin}" ]] || die "Source tree is incomplete, missing ${src}/${bin}"
  done

  log "Installing executables to ${SBIN_DIR}"
  install -d -m 0755 "${SBIN_DIR}" "${CONF_DIR}"
  install -m 0755 \
    "${src}/sanoid" \
    "${src}/syncoid" \
    "${src}/findoid" \
    "${src}/sleepymutex" \
    "${SBIN_DIR}/"

  log "Installing ${CONF_DIR}/sanoid.defaults.conf and sanoid.example.conf"
  install -m 0644 "${src}/sanoid.defaults.conf" "${CONF_DIR}/sanoid.defaults.conf"
  install -m 0644 "${src}/sanoid.conf" "${CONF_DIR}/sanoid.example.conf"

  if [[ ! -e "${CONF_DIR}/sanoid.conf" ]]; then
    touch "${CONF_DIR}/sanoid.conf"
    chmod 0644 "${CONF_DIR}/sanoid.conf"
    log "Created empty ${CONF_DIR}/sanoid.conf (sanoid-config will fill it from zfs list)"
  else
    log "Leaving existing ${CONF_DIR}/sanoid.conf unchanged until sanoid-config sync"
  fi
}

install_config_tool() {
  local tool="${SCRIPT_DIR}/sanoid-config"
  local template="${SCRIPT_DIR}/sanoid.conf"
  local discover="${SCRIPT_DIR}/sanoid-discover.conf"

  [[ -f "${tool}" ]] || die "Missing ${tool}"
  [[ -f "${template}" ]] || die "Missing ${template} (the ORCD sanoid template)."
  [[ -f "${discover}" ]] || die "Missing ${discover}"

  log "Installing ${SBIN_DIR}/sanoid-config"
  install -m 0755 "${tool}" "${SBIN_DIR}/sanoid-config"

  # Reinstall refreshes the uniform template from the repository. Per-dataset
  # overrides in sanoid-overrides.conf and sanoid-discover.conf are not touched.
  log "Installing ${CONF_DIR}/sanoid.conf.template"
  install -m 0644 "${template}" "${CONF_DIR}/sanoid.conf.template"

  if [[ ! -e "${CONF_DIR}/sanoid-discover.conf" ]]; then
    install -m 0644 "${discover}" "${CONF_DIR}/sanoid-discover.conf"
    log "Installed ${CONF_DIR}/sanoid-discover.conf"
  else
    log "Leaving existing ${CONF_DIR}/sanoid-discover.conf unchanged"
  fi
}

install_systemd_units() {
  log "Writing ${UNIT_DIR}/sanoid.service"
  cat > "${UNIT_DIR}/sanoid.service" <<'EOF'
[Unit]
Description=Snapshot ZFS Pool
Requires=zfs.target
After=zfs.target
Wants=sanoid-prune.service
Before=sanoid-prune.service
ConditionFileNotEmpty=/etc/sanoid/sanoid.conf

[Service]
Environment=TZ=UTC
Type=oneshot
ExecStart=/usr/local/sbin/sanoid --take-snapshots --verbose
EOF

  log "Writing ${UNIT_DIR}/sanoid-prune.service"
  cat > "${UNIT_DIR}/sanoid-prune.service" <<'EOF'
[Unit]
Description=Cleanup ZFS Pool
Requires=zfs.target
After=zfs.target sanoid.service
ConditionFileNotEmpty=/etc/sanoid/sanoid.conf

[Service]
Environment=TZ=UTC
Type=oneshot
ExecStart=/usr/local/sbin/sanoid --prune-snapshots --verbose

[Install]
WantedBy=sanoid.service
EOF

  log "Writing ${UNIT_DIR}/sanoid.timer"
  cat > "${UNIT_DIR}/sanoid.timer" <<'EOF'
[Unit]
Description=Run Sanoid Every 15 Minutes
Requires=sanoid.service

[Timer]
OnCalendar=*:0/15
Persistent=true

[Install]
WantedBy=timers.target
EOF

  log "Writing ${UNIT_DIR}/sanoid-discover.service"
  cat > "${UNIT_DIR}/sanoid-discover.service" <<'EOF'
[Unit]
Description=Enable snapshots for new ZFS datasets and update sanoid.conf
Requires=zfs.target
After=zfs.target
Before=sanoid.service sanoid-prune.service
ConditionPathExists=/etc/sanoid/sanoid.conf.template

[Service]
Type=oneshot
SyslogIdentifier=sanoid-config
ExecStart=/usr/local/sbin/sanoid-config sync --quiet
EOF

  log "Writing ${UNIT_DIR}/sanoid-discover.timer"
  cat > "${UNIT_DIR}/sanoid-discover.timer" <<'EOF'
[Unit]
Description=Discover ZFS datasets for Sanoid

[Timer]
OnBootSec=30s
OnCalendar=*:14,29,44,59
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  chmod 0644 \
    "${UNIT_DIR}/sanoid.service" \
    "${UNIT_DIR}/sanoid-prune.service" \
    "${UNIT_DIR}/sanoid.timer" \
    "${UNIT_DIR}/sanoid-discover.service" \
    "${UNIT_DIR}/sanoid-discover.timer"
}

enable_timer() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required to enable sanoid.timer."
  log "Reloading systemd and enabling sanoid.timer and sanoid-discover.timer"
  systemctl daemon-reload
  systemctl enable sanoid-prune.service
  if "${SBIN_DIR}/sanoid-config" sync --quiet; then
    log "Updated ${CONF_DIR}/sanoid.conf from the ZFS dataset list"
  else
    warn "sanoid-config did not update ${CONF_DIR}/sanoid.conf. sanoid-discover.timer will retry. If that file was edited by hand, keep it or replace it with: sanoid-config sync --force"
  fi
  systemctl enable --now sanoid-discover.timer
  systemctl enable --now sanoid.timer
}

report() {
  local src=$1
  local version="unknown"

  if [[ -f "${src}/VERSION" ]]; then
    version=$(tr -d '[:space:]' < "${src}/VERSION")
  fi

  printf '\nSanoid %s is installed from %s\n' "${version}" "${src}"
  printf '  executables: %s/{sanoid,syncoid,findoid,sleepymutex,sanoid-config}\n' "${SBIN_DIR}"
  printf '  config:      %s/sanoid.conf\n' "${CONF_DIR}"
  printf '  template:    %s/sanoid.conf.template\n' "${CONF_DIR}"
  printf '  discover:    %s/sanoid-discover.conf\n' "${CONF_DIR}"
  printf '  overrides:   %s/sanoid-overrides.conf\n' "${CONF_DIR}"
  printf '  defaults:    %s/sanoid.defaults.conf\n' "${CONF_DIR}"
  printf '  example:     %s/sanoid.example.conf\n' "${CONF_DIR}"
  printf '  timers:      sanoid-discover.timer, then sanoid.timer every 15 minutes\n'
  printf '  one dataset: sanoid-config set DATASET hourly=6 daily=7\n'
  printf '  all datasets: edit [template_production] in %s/sanoid.conf.template\n\n' "${CONF_DIR}"

  if ! command -v zfs >/dev/null 2>&1; then
    warn "The zfs command is not on PATH. Snapshots will fail until OpenZFS is installed."
  fi
  if ! systemctl list-unit-files --no-legend 'zfs.target' 2>/dev/null | awk '$1 == "zfs.target" { found = 1 } END { exit !found }'; then
    warn "zfs.target is not installed. sanoid.service Requires=zfs.target and will not run until OpenZFS is installed."
  fi
  if [[ ! -s "${CONF_DIR}/sanoid.conf" ]]; then
    warn "${CONF_DIR}/sanoid.conf is empty, so sanoid will not take snapshots yet. sanoid-discover.timer fills it from zfs list. Check: journalctl -u sanoid-discover.service"
  elif ! grep -qx '# SANOID-CONFIG-MANAGED' "${CONF_DIR}/sanoid.conf"; then
    warn "${CONF_DIR}/sanoid.conf was not written by sanoid-config, so discovery will not replace it. Use: sanoid-config sync --force"
  fi

  systemctl list-timers sanoid.timer sanoid-discover.timer --all --no-pager || true
}

log "Installing Sanoid on ${NAME:-${ID}} ${VERSION_ID} (${CPU})"
enable_builder_repo
enable_epel
install_packages
ensure_perl_modules
if [[ -n "${SOURCE_DIR}" ]]; then
  [[ -d "${SOURCE_DIR}" ]] || die "Source directory does not exist: ${SOURCE_DIR}"
  log "Using ${SOURCE_DIR} without refreshing the sanoid checkout"
else
  refresh_sanoid_repo
fi
log "Checking ${SOURCE_DIR} against ${SCRIPT_DIR}/sanoid.conf"
"${SCRIPT_DIR}/check-sanoid-compat.sh" "${SOURCE_DIR}" "${SCRIPT_DIR}/sanoid.conf"
install_files "${SOURCE_DIR}"
install_config_tool
install_systemd_units
enable_timer
report "${SOURCE_DIR}"
