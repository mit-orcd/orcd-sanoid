#!/usr/bin/env bash
# Exercise sanoid-config without a ZFS host. The dataset list is a fixture.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOL=${ROOT}/sanoid-config
WORK=$(mktemp -d)
ETC=${WORK}/etc
LIST=${WORK}/zfs.txt
trap 'rm -rf "${WORK}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  printf '%s\n' "--- stdout ---" "${OUT:-}" "--- stderr ---" "${ERR:-}" >&2
  if [[ -f ${ETC}/sanoid.conf ]]; then
    printf '%s\n' "--- sanoid.conf ---" >&2
    cat "${ETC}/sanoid.conf" >&2
  fi
  exit 1
}

fresh() {
  rm -rf "${ETC}"
  mkdir -p "${ETC}"
  cp "${ROOT}/sanoid.conf" "${ETC}/sanoid.conf.template"
  cp "${ROOT}/sanoid/sanoid.defaults.conf" "${ETC}/sanoid.defaults.conf"
  cp "${ROOT}/sanoid-discover.conf" "${ETC}/sanoid-discover.conf"
}

run() {
  set +e
  OUT=$("${TOOL}" --conf-dir "${ETC}" --from-list "${LIST}" "$@" 2>"${WORK}/err")
  RC=$?
  set -e
  ERR=$(cat "${WORK}/err")
}

assert_rc() {
  local want=$1
  [[ "${RC}" -eq "${want}" ]] || fail "exit ${RC}, wanted ${want}: ${ERR}"
}

section_has() {
  local dataset=$1 needle=$2
  awk -v ds="${dataset}" -v needle="${needle}" '
    $0 == "[" ds "]" { inside = 1; next }
    inside && /^\[/ { exit }
    inside && index($0, needle) { found = 1 }
    END { exit !found }
  ' "${ETC}/sanoid.conf"
}

fresh
cat > "${LIST}" <<'EOF'
data1	filesystem	-
data1/edboyden	filesystem	true
data1/hold	filesystem	false
data1/orcd	filesystem	true
EOF

run sync
assert_rc 0
grep -qx '# SANOID-CONFIG-MANAGED' "${ETC}/sanoid.conf" || fail "missing managed marker"
grep -qx '\[data1/edboyden\]' "${ETC}/sanoid.conf" || fail "missing edboyden"
grep -qx '\[data1/orcd\]' "${ETC}/sanoid.conf" || fail "missing orcd"
grep -qx '\[data1\]' "${ETC}/sanoid.conf" && fail "pool root was configured"
grep -qx '\[data1/hold\]' "${ETC}/sanoid.conf" && fail "dataset without auto-snapshot was configured"
grep -qx '\[data1/test\]' "${ETC}/sanoid.conf" && fail "sample dataset was kept"
section_has data1/edboyden $'\tuse_template = production' || fail "edboyden template line"
section_has data1/orcd $'\tuse_template = production' || fail "orcd template line"
section_has data1/edboyden "hourly" && fail "hourly was copied onto the dataset"
awk '
  $0 == "[template_production]" { inside = 1; next }
  inside && /^\[/ { exit }
  inside { print }
' "${ETC}/sanoid.conf" > "${WORK}/prod"
grep -qx $'\thourly = 3' "${WORK}/prod" || fail "template hourly"
grep -qx $'\tdaily = 1' "${WORK}/prod" || fail "template daily"
grep -qx $'\tmonthly = 0' "${WORK}/prod" || fail "template monthly"
grep -qx $'\tweekly = 0' "${WORK}/prod" || fail "template weekly"
grep -qx $'\tyearly = 0' "${WORK}/prod" || fail "template yearly"
grep -qx $'\tfrequently = 0' "${WORK}/prod" || fail "template frequently"
grep -qx $'\tautosnap = yes' "${WORK}/prod" || fail "template autosnap"
grep -qx $'\tautoprune = yes' "${WORK}/prod" || fail "template autoprune"
printf 'ok discovery replaces the sample with edboyden and orcd\n'

cp "${ETC}/sanoid.conf" "${WORK}/first.conf"
run sync --quiet
assert_rc 0
[[ -z "${OUT}" ]] || fail "quiet sync printed: ${OUT}"
cmp -s "${WORK}/first.conf" "${ETC}/sanoid.conf" || fail "second sync changed the file"
printf 'ok sync is quiet and idempotent\n'

rm -f "${ETC}/sanoid.conf"
run sync --dry-run
assert_rc 0
[[ ! -e ${ETC}/sanoid.conf ]] || fail "dry-run created sanoid.conf"
printf '%s\n' "${OUT}" | grep -qx '\[data1/edboyden\]' || fail "dry-run output missing edboyden"
printf 'ok dry-run does not write\n'

printf '[data1/keep]\n\tuse_template = production\n' > "${ETC}/sanoid.conf"
cp "${ETC}/sanoid.conf" "${WORK}/keep.conf"
run sync
assert_rc 2
cmp -s "${WORK}/keep.conf" "${ETC}/sanoid.conf" || fail "hand-written config was changed"
printf '%s\n' "${ERR}" | grep -q -- '--force' || fail "refuse message did not mention --force"
run sync --force
assert_rc 0
grep -qx '\[data1/edboyden\]' "${ETC}/sanoid.conf" || fail "force did not add edboyden"
grep -q '\[data1/keep\]' "${ETC}/sanoid.conf" && fail "force left the hand-written dataset"
printf 'ok hand-written config is kept unless --force\n'

fresh
cat > "${ETC}/sanoid.conf" <<'EOF'
[data1/test]
	use_template = production

[template_production]
	hourly = 48
EOF
run sync
assert_rc 0
grep -qx '\[data1/test\]' "${ETC}/sanoid.conf" && fail "data1/test was not removed"
grep -qx '\[data1/orcd\]' "${ETC}/sanoid.conf" || fail "orcd missing after sample replace"
grep -qx $'\thourly = 3' "${ETC}/sanoid.conf" || fail "sample template was not replaced"
printf 'ok the data1/test sample is replaced\n'

fresh
cat > "${LIST}" <<'EOF'
data1	filesystem	-
data1/edboyden	filesystem	true
data1/edboyden/scratch	filesystem	true
data1/orcd	filesystem	true
data1/images	volume	true
rpool	filesystem	-
rpool/ROOT	filesystem	true
data1/edboyden@autosnap	snapshot	true
EOF
run sync --quiet
assert_rc 0
for ds in data1/edboyden data1/edboyden/scratch data1/orcd data1/images rpool/ROOT; do
  grep -qx "\[${ds}\]" "${ETC}/sanoid.conf" || fail "missing ${ds}"
done
grep -qx '\[data1\]' "${ETC}/sanoid.conf" && fail "pool data1 configured"
grep -qx '\[rpool\]' "${ETC}/sanoid.conf" && fail "pool rpool configured"
grep -q 'autosnap' "${ETC}/sanoid.conf" && grep -q 'data1/edboyden@' "${ETC}/sanoid.conf" && fail "snapshot was configured"
printf 'ok filesystems, volumes, nested datasets; pools and snapshots skipped\n'

cat > "${ETC}/sanoid-discover.conf" <<'EOF'
default_template=production
depth=children
EOF
run sync --quiet
assert_rc 0
grep -qx '\[data1/edboyden/scratch\]' "${ETC}/sanoid.conf" && fail "nested dataset kept at depth=children"
grep -qx '\[data1/edboyden\]' "${ETC}/sanoid.conf" || fail "child missing at depth=children"
grep -qx '\[rpool/ROOT\]' "${ETC}/sanoid.conf" || fail "rpool/ROOT missing at depth=children"
printf 'ok depth=children keeps only direct children\n'

cat > "${ETC}/sanoid-discover.conf" <<'EOF'
default_template=production
depth=all
pools=data1
exclude=data1/edboyden/scratch
EOF
run sync --quiet
assert_rc 0
grep -qx '\[rpool/ROOT\]' "${ETC}/sanoid.conf" && fail "pools= did not drop rpool/ROOT"
grep -qx '\[data1/edboyden/scratch\]' "${ETC}/sanoid.conf" && fail "exclude did not drop scratch"
grep -qx '\[data1/images\]' "${ETC}/sanoid.conf" || fail "volume missing after pools filter"
printf 'ok pools= and exclude=\n'

cp "${ROOT}/sanoid-discover.conf" "${ETC}/sanoid-discover.conf"
run set data1/edboyden hourly=6 daily=2 autosnap=YES
assert_rc 0
section_has data1/edboyden $'\thourly = 6' || fail "override hourly"
section_has data1/edboyden $'\tdaily = 2' || fail "override daily"
section_has data1/edboyden $'\tautosnap = yes' || fail "toggle was not normalized"
section_has data1/orcd "hourly" && fail "override leaked onto orcd"
grep -qx $'\thourly = 3' "${ETC}/sanoid.conf" || fail "template hourly changed by set"
printf 'ok per-dataset overrides\n'

run set data1/orcd use_template=backup
assert_rc 0
section_has data1/orcd $'\tuse_template = backup' || fail "use_template override"
printf 'ok per-dataset template\n'

run set data1 hourly=1
assert_rc 1
printf 'ok pool root cannot be set\n'

run set data1/edboyden notakey=1
assert_rc 1
section_has data1/edboyden "notakey" && fail "invalid key was written"
printf 'ok unknown settings are rejected\n'

run set data1/edboyden hourly=no
assert_rc 1
section_has data1/edboyden $'\thourly = 6' || fail "rejected set changed hourly"
printf 'ok non-numeric retention is rejected\n'

run set data1/edboyden use_template=missing
assert_rc 1
printf 'ok unknown template is rejected\n'

run unset data1/edboyden hourly
assert_rc 0
section_has data1/edboyden "hourly" && fail "hourly override remained"
section_has data1/edboyden $'\tdaily = 2' || fail "daily override was removed"
printf 'ok unset one key\n'

run ignore data1/orcd
assert_rc 0
grep -qx '\[data1/orcd\]' "${ETC}/sanoid.conf" && fail "ignored dataset still configured"
run list
assert_rc 0
printf '%s\n' "${OUT}" | grep -Eq '^ignored[[:space:]]+data1/orcd' || fail "list did not show ignored orcd: ${OUT}"
printf '%s\n' "${OUT}" | grep -Eq '^pool[[:space:]]+data1[[:space:]]' || fail "list did not show pool data1: ${OUT}"
printf 'ok ignore\n'

run unignore data1/orcd
assert_rc 0
section_has data1/orcd $'\tuse_template = backup' || fail "unignore lost the template override"
printf 'ok unignore keeps other overrides\n'

run set data1/future hourly=1
assert_rc 0
grep -q '\[data1/future\]' "${ETC}/sanoid.conf" && fail "absent dataset was written"
run list
printf '%s\n' "${OUT}" | grep -Eq '^absent[[:space:]]+data1/future' || fail "list did not show absent future"
cat > "${LIST}" <<'EOF'
data1	filesystem	-
data1/edboyden	filesystem	true
data1/edboyden/scratch	filesystem	true
data1/orcd	filesystem	true
data1/images	volume	true
data1/future	filesystem	true
rpool	filesystem	-
rpool/ROOT	filesystem	true
EOF
run sync --quiet
assert_rc 0
section_has data1/future $'\thourly = 1' || fail "override did not apply when the dataset appeared"
printf 'ok overrides wait for the dataset to appear\n'

# Drop a dataset and keep its override on disk.
cat > "${LIST}" <<'EOF'
data1	filesystem	-
data1/edboyden	filesystem	true
data1/orcd	filesystem	true
EOF
run sync --quiet
assert_rc 0
grep -qx '\[data1/images\]' "${ETC}/sanoid.conf" && fail "removed volume stayed in sanoid.conf"
grep -q '^\[data1/future\]' "${ETC}/sanoid-overrides.conf" || fail "override file dropped an absent dataset"
printf 'ok removed datasets leave sanoid.conf\n'

cp "${ETC}/sanoid.conf.template" "${WORK}/before-unnamed-template.conf"
run template set hourly=4
assert_rc 1
printf '%s\n' "${ERR}" | grep -q 'production' || fail "unnamed template set did not ask for a name"
cmp -s "${WORK}/before-unnamed-template.conf" "${ETC}/sanoid.conf.template" || fail "unnamed template set wrote the file"
printf 'ok template set requires a template name\n'

run template set production hourly=4
assert_rc 0
awk '
  $0 == "[template_production]" { inside = 1; next }
  inside && /^\[/ { exit }
  inside { print }
' "${ETC}/sanoid.conf.template" > "${WORK}/prod-file"
grep -qx $'\thourly = 4' "${WORK}/prod-file" || fail "template file hourly"
grep -qx $'\thourly = 30' "${ETC}/sanoid.conf.template" || fail "backup template hourly was rewritten"
section_has data1/edboyden $'\tdaily = 2' || fail "template set dropped a dataset override"
awk '
  $0 == "[template_production]" { inside = 1; next }
  inside && /^\[/ { exit }
  inside { print }
' "${ETC}/sanoid.conf" > "${WORK}/prod-live"
grep -qx $'\thourly = 4' "${WORK}/prod-live" || fail "live template hourly"
printf 'ok template set changes every dataset from one place\n'

run template set backup hourly=12
assert_rc 0
awk '
  $0 == "[template_backup]" { inside = 1; next }
  inside && /^\[/ { exit }
  inside { print }
' "${ETC}/sanoid.conf.template" > "${WORK}/backup-file"
grep -qx $'\thourly = 12' "${WORK}/backup-file" || fail "backup hourly was not changed"
awk '
  $0 == "[template_production]" { inside = 1; next }
  inside && /^\[/ { exit }
  inside { print }
' "${ETC}/sanoid.conf.template" > "${WORK}/prod-file"
grep -qx $'\thourly = 4' "${WORK}/prod-file" || fail "production hourly changed with backup"
printf 'ok template set backup leaves production unchanged\n'

cp "${ETC}/sanoid.conf.template" "${WORK}/before-missing-template.conf"
run template set nosuch hourly=1
assert_rc 1
printf '%s\n' "${ERR}" | grep -q 'template_nosuch' || fail "missing template was not named"
cmp -s "${WORK}/before-missing-template.conf" "${ETC}/sanoid.conf.template" || fail "missing template changed the file"
printf 'ok template set does not create a template\n'

run template set production notakey=1
assert_rc 1
printf 'ok template set rejects unknown keys\n'

run template set production recursive=yes
assert_rc 1
printf 'ok recursive is set on a dataset, not the template\n'

cp "${ETC}/sanoid.conf" "${WORK}/before-missing.conf"
run sync --from-list "${WORK}/no-such-list"
assert_rc 1
cmp -s "${WORK}/before-missing.conf" "${ETC}/sanoid.conf" || fail "failed zfs list rewrote sanoid.conf"
printf 'ok a failed dataset list leaves sanoid.conf unchanged\n'

fresh
FAKE=${WORK}/fake-zfs
DB=${WORK}/zfs-db.txt
cat > "${DB}" <<'EOF'
data1	filesystem	-
data1/edboyden	filesystem	true
data1/orcd	filesystem	-
EOF
cat > "${FAKE}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
db=${ZFS_DB:?}
cmd=$1
shift
case "${cmd}" in
  list)
    cat "${db}"
    ;;
  set)
    kv=$1
    ds=$2
    val=${kv#*=}
    tmp=$(mktemp)
    awk -v ds="${ds}" -v val="${val}" 'BEGIN{FS=OFS="\t"} $1==ds {$3=val; found=1} {print} END{if (!found) exit 1}' "${db}" > "${tmp}"
    mv "${tmp}" "${db}"
    ;;
  *)
    printf 'unknown zfs command\n' >&2
    exit 1
    ;;
esac
EOF
chmod +x "${FAKE}"
set +e
OUT=$(ZFS_DB="${DB}" SANOID_ZFS="${FAKE}" "${TOOL}" --conf-dir "${ETC}" enable data1/orcd 2>"${WORK}/err")
RC=$?
set -e
ERR=$(cat "${WORK}/err")
assert_rc 0
grep -qx '\[data1/orcd\]' "${ETC}/sanoid.conf" || fail "enable did not add orcd"
awk -F '\t' '$1=="data1/orcd" { print $3 }' "${DB}" | grep -qx true || fail "property was not set true"
printf 'ok enable sets com.sun:auto-snapshot and syncs\n'

fresh
cat > "${LIST}" <<'EOF'
data1	filesystem	-
data1/xyz	filesystem	-
data1/xyz/abc	filesystem	-
data1/hold	filesystem	false
EOF
run sync --quiet
assert_rc 0
grep -qx '\[data1/xyz\]' "${ETC}/sanoid.conf" || fail "missing xyz"
grep -qx '\[data1/xyz/abc\]' "${ETC}/sanoid.conf" || fail "missing xyz/abc"
section_has data1/xyz $'\tuse_template = production' || fail "xyz template"
section_has data1/xyz/abc $'\tuse_template = production' || fail "xyz/abc template"
grep -qx '\[data1\]' "${ETC}/sanoid.conf" && fail "pool root was configured"
grep -qx '\[data1/hold\]' "${ETC}/sanoid.conf" && fail "disabled dataset was configured"
printf 'ok new datasets use the production template\n'

fresh
cat > "${DB}" <<'EOF'
data1	filesystem	-
data1/xyz	filesystem	-
data1/xyz/abc	filesystem	-
data1/hold	filesystem	false
EOF
set +e
OUT=$(ZFS_DB="${DB}" SANOID_ZFS="${FAKE}" "${TOOL}" --conf-dir "${ETC}" sync --quiet 2>"${WORK}/err")
RC=$?
set -e
ERR=$(cat "${WORK}/err")
assert_rc 0
awk -F '\t' '$1=="data1/xyz" { print $3 }' "${DB}" | grep -qx true || fail "xyz was not enabled"
awk -F '\t' '$1=="data1/xyz/abc" { print $3 }' "${DB}" | grep -qx true || fail "xyz/abc was not enabled"
awk -F '\t' '$1=="data1" { print $3 }' "${DB}" | grep -qx -- '-' || fail "pool root property changed"
awk -F '\t' '$1=="data1/hold" { print $3 }' "${DB}" | grep -qx false || fail "disabled property was changed"
grep -qx '\[data1/xyz\]' "${ETC}/sanoid.conf" || fail "sync did not configure xyz"
grep -qx '\[data1/xyz/abc\]' "${ETC}/sanoid.conf" || fail "sync did not configure xyz/abc"
printf '%s\n' "${OUT}" | grep -q 'set com.sun:auto-snapshot=true on data1/xyz' || fail "enable was not reported"
set +e
OUT=$(ZFS_DB="${DB}" SANOID_ZFS="${FAKE}" "${TOOL}" --conf-dir "${ETC}" disable data1/xyz 2>"${WORK}/err")
RC=$?
set -e
ERR=$(cat "${WORK}/err")
assert_rc 0
awk -F '\t' '$1=="data1/xyz" { print $3 }' "${DB}" | grep -qx false || fail "disable did not set false"
grep -qx '\[data1/xyz\]' "${ETC}/sanoid.conf" && fail "disabled dataset stayed in sanoid.conf"
grep -qx '\[data1/xyz/abc\]' "${ETC}/sanoid.conf" || fail "nested dataset was removed with its parent"
set +e
OUT=$(ZFS_DB="${DB}" SANOID_ZFS="${FAKE}" "${TOOL}" --conf-dir "${ETC}" sync --quiet 2>"${WORK}/err")
RC=$?
set -e
ERR=$(cat "${WORK}/err")
assert_rc 0
[[ -z "${OUT}" ]] || fail "later sync re-enabled a disabled dataset: ${OUT}"
awk -F '\t' '$1=="data1/xyz" { print $3 }' "${DB}" | grep -qx false || fail "later sync cleared the disable"
printf 'ok discover enables new datasets and leaves false alone\n'

bash -n "${TOOL}"
bash -n "${ROOT}/install-sanoid-rhel.sh"
bash -n "${ROOT}/check-sanoid-compat.sh"
"${ROOT}/check-sanoid-compat.sh" --skip-perl "${ROOT}/sanoid" "${ROOT}/sanoid.conf" >/dev/null
bad=${WORK}/bad-template.conf
cp "${ROOT}/sanoid.conf" "${bad}"
printf '\tnot_a_real_setting = 1\n' >> "${bad}"
if "${ROOT}/check-sanoid-compat.sh" --skip-perl "${ROOT}/sanoid" "${bad}" >/dev/null 2>"${WORK}/err"; then
  fail "compat check accepted an unknown template key"
fi
grep -q not_a_real_setting "${WORK}/err" || fail "compat check did not name the unknown key"
grep -q 'sanoid-discover.service' "${ROOT}/install-sanoid-rhel.sh" || fail "install script has no discover service"
grep -q 'check-sanoid-compat.sh' "${ROOT}/install-sanoid-rhel.sh" || fail "install script does not run the compat check"
grep -q 'sanoid-config' "${ROOT}/install-sanoid-rhel.sh" || fail "install script does not install sanoid-config"
grep -qx '\[data1/test\]' "${ROOT}/sanoid.conf" && fail "repo template still has data1/test"
# Upstream unit names stay the ones from the manual install.
grep -q 'ExecStart=/usr/local/sbin/sanoid --take-snapshots --verbose' "${ROOT}/install-sanoid-rhel.sh" || fail "sanoid.service command changed"
grep -q 'Wants=sanoid-discover.service' "${ROOT}/install-sanoid-rhel.sh" && fail "sanoid.service should not depend on the discover unit"
printf 'ok install script syntax\n'

# A copied sanoid/ tree can contain .git without an origin remote. Refresh
# must add the upstream URL instead of stopping.
refresh_funcs=$(sed -n '/^git_sanoid()/,/^}/p; /^sanoid_fetch_remote()/,/^}/p; /^refresh_sanoid_repo()/,/^}/p' "${ROOT}/install-sanoid-rhel.sh")
REAL_GIT=$(command -v git)
GIT_LOG=${WORK}/git.log
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" fetch "* || " $* " == *" clone "* ]]; then
  printf '%s\n' "$*" >> "${GIT_LOG:?}"
  exit 0
fi
exec "${REAL_GIT:?}" "$@"
EOF
chmod +x "${WORK}/bin/git"

init_repo() {
  local repo=$1
  mkdir -p "${repo}"
  "${REAL_GIT}" init -q "${repo}"
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
    "${REAL_GIT}" -C "${repo}" commit -q --allow-empty -m init
  "${REAL_GIT}" -C "${repo}" tag v0.0.test
}

run_refresh() {
  local parent=$1
  : > "${GIT_LOG}"
  (
    set -euo pipefail
    log() { printf '==> %s\n' "$*"; }
    warn() { printf 'WARNING: %s\n' "$*" >&2; }
    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    eval "${refresh_funcs}"
    UPSTREAM_URL="https://github.com/jimsalterjrs/sanoid.git"
    GIT_REF=""
    SCRIPT_DIR=${parent}
    export REAL_GIT GIT_LOG PATH="${WORK}/bin:${PATH}"
    refresh_sanoid_repo
  )
}

parent=${WORK}/refresh-missing
init_repo "${parent}/sanoid"
run_refresh "${parent}"
got=$("${REAL_GIT}" -C "${parent}/sanoid" config --get remote.origin.url)
[[ "${got}" == "https://github.com/jimsalterjrs/sanoid.git" ]] || fail "origin was not added, got '${got}'"
grep -q fetch "${GIT_LOG}" || fail "refresh did not fetch after adding origin"
printf 'ok refresh adds a missing origin remote\n'

parent=${WORK}/refresh-plain
init_repo "${parent}/sanoid"
"${REAL_GIT}" -C "${parent}/sanoid" remote add origin https://github.com/jimsalterjrs/sanoid
run_refresh "${parent}"
got=$("${REAL_GIT}" -C "${parent}/sanoid" config --get remote.origin.url)
[[ "${got}" == "https://github.com/jimsalterjrs/sanoid" ]] || fail "existing origin URL was rewritten: ${got}"
grep -q fetch "${GIT_LOG}" || fail "refresh did not fetch an existing upstream origin"
printf 'ok refresh accepts an origin URL without .git\n'

parent=${WORK}/refresh-other
init_repo "${parent}/sanoid"
"${REAL_GIT}" -C "${parent}/sanoid" remote add origin https://example.com/other.git
set +e
run_refresh "${parent}" >"${WORK}/refresh-other.out" 2>"${WORK}/refresh-other.err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "a non-upstream origin was accepted"
grep -q 'https://example.com/other.git' "${WORK}/refresh-other.err" || fail "error did not show the unexpected origin"
printf 'ok refresh refuses a different origin\n'

printf 'all tests passed\n'
