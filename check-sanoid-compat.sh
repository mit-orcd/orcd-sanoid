#!/usr/bin/env bash
# Confirm a Sanoid source tree still matches what orcd-sanoid installs.
#
# Run after checking out the latest stable tag, and before copying files
# into /usr/local/sbin and /etc/sanoid. The template is the sanoid.conf in
# this directory, not sanoid/sanoid.conf from upstream.

set -euo pipefail

SKIP_PERL=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: check-sanoid-compat.sh [--skip-perl] UPSTREAM_DIR TEMPLATE

UPSTREAM_DIR is a Sanoid checkout (the sanoid/ directory).
TEMPLATE is orcd-sanoid's sanoid.conf, the file installed as
/etc/sanoid/sanoid.conf.template.

The check fails when upstream no longer provides the programs, defaults
keys, or snapshot flags this repo's units and sanoid-config rely on.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-perl)
      SKIP_PERL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 2 ]] || { usage >&2; exit 1; }
SRC=$1
TEMPLATE=$2
[[ -d "${SRC}" ]] || die "Sanoid source directory does not exist: ${SRC}"
[[ -f "${TEMPLATE}" ]] || die "Template does not exist: ${TEMPLATE}"

require_file() {
  local path="${SRC}/$1"
  [[ -f "${path}" && -s "${path}" ]] || die "Missing or empty ${path}"
}

for name in sanoid syncoid findoid sleepymutex sanoid.defaults.conf sanoid.conf; do
  require_file "${name}"
done

head -n 1 "${SRC}/sanoid" | grep -q perl \
  || die "${SRC}/sanoid does not have a perl shebang."

for flag in --take-snapshots --prune-snapshots; do
  grep -F -q -- "${flag}" "${SRC}/sanoid" \
    || die "${SRC}/sanoid no longer accepts ${flag}, which sanoid.service uses."
done

defaults_version=""
in_version=0
in_default=0
declare -A DEFAULT_KEYS=()
while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ "${line}" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]]; then
    section="${BASH_REMATCH[1]}"
    section="${section#"${section%%[![:space:]]*}"}"
    section="${section%"${section##*[![:space:]]}"}"
    in_version=0
    in_default=0
    [[ "${section}" == "version" ]] && in_version=1
    [[ "${section}" == "template_default" ]] && in_default=1
    continue
  fi
  if [[ "${in_version}" -eq 1 && "${line}" =~ ^[[:space:]]*version[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
    defaults_version="${BASH_REMATCH[1]}"
  fi
  if [[ "${in_default}" -eq 1 && "${line}" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*= ]]; then
    DEFAULT_KEYS["${BASH_REMATCH[1]}"]=1
  fi
done < "${SRC}/sanoid.defaults.conf"

[[ -n "${defaults_version}" ]] || die "${SRC}/sanoid.defaults.conf has no [version] version."
min_version=$(sed -n 's/^my \$MINIMUM_DEFAULTS_VERSION = \([0-9][0-9]*\);/\1/p' "${SRC}/sanoid" | head -n 1)
[[ -n "${min_version}" ]] || die "Could not read MINIMUM_DEFAULTS_VERSION from ${SRC}/sanoid."
if [[ "${defaults_version}" -lt "${min_version}" ]]; then
  die "sanoid.defaults.conf is v${defaults_version}; this Sanoid requires v${min_version} or newer."
fi

for key in use_template autosnap autoprune frequently hourly daily weekly monthly yearly recursive; do
  [[ -v "DEFAULT_KEYS[${key}]" ]] || die "sanoid.defaults.conf [template_default] no longer has '${key}'."
done

found_production=0
in_template=0
template_section=""
while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ "${line}" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]]; then
    section="${BASH_REMATCH[1]}"
    section="${section#"${section%%[![:space:]]*}"}"
    section="${section%"${section##*[![:space:]]}"}"
    in_template=0
    if [[ "${section}" == template_* ]]; then
      in_template=1
      template_section=${section}
      [[ "${section}" == "template_production" ]] && found_production=1
    fi
    continue
  fi
  [[ "${in_template}" -eq 1 ]] || continue
  if [[ "${line}" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*= ]]; then
    key=${BASH_REMATCH[1]}
    [[ -v "DEFAULT_KEYS[${key}]" ]] \
      || die "Template [${template_section}] sets '${key}', which this Sanoid's defaults do not allow."
  fi
done < "${TEMPLATE}"

[[ "${found_production}" -eq 1 ]] || die "Template ${TEMPLATE} has no [template_production] section."

if [[ "${SKIP_PERL}" -eq 0 ]]; then
  command -v perl >/dev/null 2>&1 || die "perl is required to syntax-check ${SRC}/sanoid."
  perl -c "${SRC}/sanoid" >/dev/null
fi

printf 'Sanoid source %s is compatible with %s\n' "${SRC}" "${TEMPLATE}"
