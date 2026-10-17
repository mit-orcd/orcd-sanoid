# orcd-sanoid

Install [Sanoid](https://github.com/jimsalterjrs/sanoid) on a RHEL-family ZFS host and keep `/etc/sanoid/sanoid.conf` aligned with the datasets on that host.

The `sanoid/` directory is not stored in this repository. `install-sanoid-rhel.sh` clones `https://github.com/jimsalterjrs/sanoid.git` there when the directory is missing, fetches it when it already exists, and checks out the latest stable `v*` tag. The snapshot policy in this repository's `sanoid.conf` stays outside that checkout, so the refresh does not replace it.

## Install

On the storage host, as root:

```sh
git clone https://github.com/mit-orcd/orcd-sanoid.git
cd orcd-sanoid
./install-sanoid-rhel.sh
```

The script enables the matching EPEL and CodeReady Builder repository, installs the Perl modules Sanoid needs, clones upstream Sanoid if `./sanoid` is absent, runs `check-sanoid-compat.sh`, and installs:

| Path | Role |
| --- | --- |
| `/usr/local/sbin/sanoid`, `syncoid`, `findoid`, `sleepymutex` | Upstream programs |
| `/usr/local/sbin/sanoid-config` | Dataset discovery and per-dataset maintenance |
| `/etc/sanoid/sanoid.conf` | Generated dataset list |
| `/etc/sanoid/sanoid.conf.template` | Copy of this repo's `sanoid.conf` |
| `/etc/sanoid/sanoid-discover.conf` | Which pools and datasets are included. Left in place on reinstall |
| `/etc/sanoid/sanoid-overrides.conf` | Per-dataset exceptions. Left in place on reinstall |
| `sanoid.service`, `sanoid-prune.service`, `sanoid.timer` | Upstream units. Snapshots every 15 minutes |
| `sanoid-discover.service`, `sanoid-discover.timer` | Rewrites `sanoid.conf` one minute before each snapshot run |

`sanoid.timer` stays on `*:0/15`. `sanoid-discover.timer` runs at `:14`, `:29`, `:44`, and `:59`.

Useful install options:

```sh
./install-sanoid-rhel.sh --ref v2.3.0
./install-sanoid-rhel.sh --source /path/to/sanoid
./install-sanoid-rhel.sh --check /path/to/sanoid
```

`--source` skips the fetch and still runs the compatibility check. `--check` runs only that check.

## Discovery

`sanoid-discover.service` runs `sanoid-config sync`. For each new filesystem or volume such as `data1/xyz` or `data1/xyz/abc` it sets `com.sun:auto-snapshot=true` and adds:

```
[data1/xyz]
	use_template = production

[data1/xyz/abc]
	use_template = production
```

The pool root `data1` is omitted. A snapshot of the pool does not include its children.

These datasets are left out:

- `com.sun:auto-snapshot=false`, including after `sanoid-config disable`
- names matched by `exclude` in `/etc/sanoid/sanoid-discover.conf`
- pools outside the optional `pools=` list
- datasets marked with `sanoid-config ignore`

`depth=all` is the default, so nested datasets are included. `depth=children` keeps only the direct child of each pool.

A `sanoid.conf` that was written by hand is not replaced until `sanoid-config sync --force`.

## Snapshot policy

Uniform retention lives in `[template_production]` in `sanoid.conf`:

```
frequently = 0
hourly = 3
daily = 1
weekly = 0
monthly = 0
yearly = 0
autosnap = yes
autoprune = yes
```

Change every dataset from one place:

```sh
sanoid-config template set hourly=4 daily=2
```

A later run of `install-sanoid-rhel.sh` copies `sanoid.conf` over `/etc/sanoid/sanoid.conf.template`. Edit the copy in this repository when the new counts should survive a reinstall.

Override one dataset:

```sh
sanoid-config set data1/edboyden hourly=6 daily=7
sanoid-config set data1/orcd use_template=backup
sanoid-config disable data1/scratch
sanoid-config ignore data1/scratch
sanoid-config list
```

## Files

| File | Role |
| --- | --- |
| `install-sanoid-rhel.sh` | Install and update on RHEL, CentOS Stream, AlmaLinux, or Rocky Linux 8+ |
| `sanoid-config` | Build `sanoid.conf` from `zfs list` and edit overrides |
| `sanoid.conf` | Master template, including `[template_production]` |
| `sanoid-discover.conf` | Default discovery policy installed on first install |
| `check-sanoid-compat.sh` | Confirm the upstream tree still matches this template |
| `tests/sanoid-config.sh` | Behavior tests. The compatibility check uses a local `./sanoid` checkout |

Run the tests from this directory:

```sh
bash tests/sanoid-config.sh
```
