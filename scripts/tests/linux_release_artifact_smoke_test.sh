#!/usr/bin/env bash
#
# Structural test suite for scripts/linux_release_artifact_smoke.sh (issue #98).
#
# The gate is only worth committing if its assertions can actually go red. This
# suite proves that twice over, and the two halves are deliberately independent:
#
#   1. SCENARIOS break the *artifact or the environment* and require one specific
#      named assertion to fail. This proves each assertion is sensitive to the
#      failure mode it claims to catch.
#
#   2. MUTATIONS break the *assertion itself* -- inverting a comparison, so the
#      gate fails on a perfectly good artifact -- and require the same named
#      assertion to fail. This proves the assertion is load-bearing rather than
#      dead code that a refactor could quietly delete. A mutation that does not
#      change the file, or that changes it but leaves the run green, is a test
#      FAILURE, never a skip: a mutation suite that skips quietly reports
#      coverage it does not have.
#
# The X server, the image tools and dpkg are all replaced with fakes on a PATH
# farm, so the suite needs no X server, no ImageMagick and no root. The window
# and window-query fixtures are the REAL output recorded from xwininfo 1.1.7
# against this app's actual GTK window, including the toolkit's 10x10 offscreen
# helper windows, so the probe is tested against the shape it meets in CI rather
# than against an idealised one.
#
#   The fake AppImage stands in for the AppImage *runtime*: it implements
#   `--appimage-extract` (the one behaviour the gate depends on) and otherwise
#   behaves like a long-lived X client that can be told to die, crash, or print
#   a crash signature. It cannot be a real AppImage -- a real one is an ELF
#   object, and a test double that is a real ELF cannot also be a script that
#   misbehaves on demand. The real AppImage is exercised by the end-to-end run
#   documented in the issue report, not here.

set -uo pipefail

# LINUX_GATE_REPO_ROOT exists so a trimmed copy of this suite can be run from a
# scratch directory while still pointing at the real gate. Nothing else sets it.
REPO_ROOT="${LINUX_GATE_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GATE="${REPO_ROOT}/scripts/linux_release_artifact_smoke.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/linux-gate-test.XXXXXXXX")"
FARM="${WORK}/bin"
LAST_OUT=""
MUTANT_PATH=""
# Where make_good_artifacts put the artifacts most recently, copied into each
# run's artifact directory by run_gate. Unset on purpose until a fixture is
# built: a run with no artifact source is a harness bug, and run_gate exits 2
# rather than quietly gating an empty directory.
ARTIFACT_SRC=""
LAST_STATUS=0
PASS_COUNT=0
FAIL_COUNT=0
MUTATION_COUNT=0
MUTATION_APPLIED=0
SCENARIO_COUNT=0
FAILED_NAMES=()

cleanup() {
  reap_strays
  rm -rf "${WORK}"
}
# The gate launches the app with `setsid --wait`, so the app sits in its own
# session and is NOT killed when the gate process itself dies -- that is the
# whole point of `kill_tree`, but a gate that was killed mid-run (or a mutant
# that hangs and gets `timeout`-ed) leaves the fake app spinning in
# `while :; do sleep 0.2; done` forever. Without this reaper one interrupted run
# leaks a busy-looping process per leg, and after a dozen runs the machine is
# the bottleneck rather than the suite. Only processes whose command line names
# THIS run's scratch tree are touched.
reap_strays() {
  local pids
  pids="$(pgrep -f "${WORK}" 2>/dev/null || true)"
  if [[ -n "${pids}" ]]; then
    # shellcheck disable=SC2086
    kill -9 ${pids} 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok %d - %s\n' "$((PASS_COUNT + FAIL_COUNT))" "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_NAMES+=("$1")
  printf 'not ok %d - %s\n' "$((PASS_COUNT + FAIL_COUNT))" "$1"
  if [[ -n "${LAST_OUT}" ]]; then
    printf '%s\n' "${LAST_OUT}" | sed 's/^/    | /'
  fi
}

check() {
  local desc="$1" cond="$2"
  if [[ "${cond}" == "1" ]]; then
    pass "${desc}"
  else
    fail "${desc}"
  fi
}

# ---------------------------------------------------------------------------
# The PATH farm
# ---------------------------------------------------------------------------
#
# A farm is a directory of symlinks to the real coreutils plus hand-written fakes
# for everything X11, ImageMagick or dpkg. Building it by symlink (rather than
# prepending the farm to the real PATH) is what makes "the tool is missing" a
# testable condition: a tool is absent from the farm exactly when the test
# deletes it, with no chance of the real one being found by accident.
# awk, basename and setsid are in this list because the gate calls them: `awk`
# parses xwininfo output, `basename` names the artifacts, and `setsid --wait` is
# what gives the launch its own process group and a real exit status. A farm that
# omitted them would fail the gate on its own tooling rather than on the artifact
# under test, which would make every scenario meaningless.
FARM_CORE_TOOLS=(
  awk basename bash cat chmod cp cut date dirname env find grep head mkdir
  mktemp mv od readlink rm sed setsid sha256sum sleep sort stat tail tr uname
  wc
)

make_fake() {
  local name="$1"
  printf '#!/usr/bin/env bash\n# fake %s (linux artifact gate test suite)\nexit 0\n' "${name}" \
    >"${FARM}/${name}"
  chmod +x "${FARM}/${name}"
}

# `xvfb-run` re-executes the gate with the guard set and a DISPLAY, exactly as the
# real one does, and records the server arguments so a test can assert the screen
# geometry the gate asked for. It deliberately does NOT start an X server: every
# X query in the suite is served by the fake xwininfo.
build_farm() {
  rm -rf "${FARM}"
  mkdir -p "${FARM}"
  local t
  for t in "${FARM_CORE_TOOLS[@]}"; do
    local real
    real="$(command -v "${t}" 2>/dev/null || true)"
    if [[ -n "${real}" ]]; then
      ln -sf "${real}" "${FARM}/${t}"
    fi
  done
  ln -sf "$(command -v bash)" "${FARM}/sh"

  make_fake Xvfb
  make_fake xauth

  cat >"${FARM}/xvfb-run" <<'FAKE_EOF'
#!/usr/bin/env bash
# fake xvfb-run: re-exec the command with the guard variable and a DISPLAY set,
# recording the requested server arguments for the suite to assert on.
#
# The gate invokes it as
#   xvfb-run <opts> env LINUX_SMOKE_UNDER_XVFB=1 <script> <args...>
# so the command to run starts at the FIRST `env` in the argument list and
# everything from there on is handed to `exec` verbatim. Skipping past `env`
# (which is what the first version of this fake did) execs
# `LINUX_SMOKE_UNDER_XVFB=1` as a command name, so every run died 127 with
# "exec: LINUX_SMOKE_UNDER_XVFB=1: not found" and every scenario looked like a
# genuine red.
set -uo pipefail
out="${FAKE_XVFB_ARGS_FILE:-/dev/null}"
: >"${out}"
printf '%s\n' "$@" >>"${out}"
args=("$@")
start=-1
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[i]}" == "env" ]]; then
    start=${i}
    break
  fi
done
if ((start < 0)) || ((start + 1 >= ${#args[@]})); then
  echo "fake xvfb-run: no 'env NAME=value cmd' command found in: $*" >&2
  exit 64
fi
rest=("${args[@]:start}")
export DISPLAY="${FAKE_XVFB_DISPLAY:-:99}"
export LINUX_SMOKE_UNDER_XVFB=1
exec "${rest[@]}"
FAKE_EOF
  chmod +x "${FARM}/xvfb-run"

  cat >"${FARM}/xwininfo" <<'FAKE_EOF'
#!/usr/bin/env bash
# fake xwininfo. Serves recorded real output, switchable by env so a scenario can
# present the failure mode it needs to exercise.
#
# The good tree below is in xwininfo's own `xwininfo -root -tree` shape: a
# header block, an indented `N children:` line, and one line per window reading
#
#   <indent>0x<id> "<name>": (<class>)  <W>x<H><X><Y>  <ax><ay>
#
# where each coordinate is printed with C's `%+d` -- a sign is ALWAYS present, and
# a negative coordinate therefore prints as `-100`, not as `+-100`. That detail
# is load-bearing: an earlier version of this fixture wrote `+-100+-100`, which
# the gate's parser rejects outright (it accepts `[-+][0-9]+`, one sign then
# digits), so the line was silently SKIPPED and the tree held one window fewer
# than it appeared to.
#
# It is NOT byte-for-byte output captured from a real runner: no xwininfo binary
# exists on the machine this suite was written on. The shape above is
# reconstructed from the format xwininfo documents, and what is verified here is
# that the gate parses it. A reviewer with a real `xwininfo` should diff this
# against one `xwininfo -root -tree` from a live Flutter/GTK window.
set -uo pipefail
root_w="${FAKE_XWININFO_ROOT_W:-1280}"
root_h="${FAKE_XWININFO_ROOT_H:-800}"
root_mode="${FAKE_XWININFO_ROOT_MODE:-good}"
tree_mode="${FAKE_XWININFO_TREE_MODE:-good}"
id_mode="${FAKE_XWININFO_ID_MODE:-good}"
id_x="${FAKE_XWININFO_ID_X:-0}"
id_y="${FAKE_XWININFO_ID_Y:-0}"
id_w="${FAKE_XWININFO_ID_W:-1280}"
id_h="${FAKE_XWININFO_ID_H:-720}"
map_state="IsViewable"
# The good tree, as a function, because `xwininfo -id` has to answer about the
# window it was ASKED about. It used to answer the same canned 1280x720+0+0 for
# every id, which quietly neutralised part of the suite: in the
# `window-area-floor` mutation probe_window correctly selected the 10x10 helper
# window, `xwininfo -id` then reported that window as 1280x720 at the origin,
# and the gate rendered and passed. A fixture that contradicts the thing it
# stands in for is worse than no fixture at all.
good_tree() {
  cat <<'TREE'
xwininfo: Window id: 0x3a7 (the root window) (has no name)

  Root window id: 0x3a7 (the root window) (has no name)
  Parent window id: 0x0 (none)
     5 children:
     0x20001e "com.privategallery.desktop": ()  10x10-100-100  -100-100
     0x200012 (has no name): ()  1x1-1-1  -1-1
     0x200005 "Private Gallery": ("com.privategallery.desktop" "Com.privategallery.desktop")  1280x720+0+0  +0+0
        1 child:
        0x200006 (has no name): ()  1x1-1-1  -1-1
     0x20000b (has no name): ()  1x1-100-100  -100-100
     0x200001 "com.privategallery.desktop": ("com.privategallery.desktop" "Com.privategallery.desktop")  10x10+10+10  +10+10

TREE
}
# Geometry of one id, read from the same tree line the probe read, so the two
# invocations can never disagree. Prints nothing for an id that is not in the
# tree, which the gate then reports as unreadable geometry.
geometry_for_id() {
  local want="$1" line w h x y
  line="$(good_tree | grep -E "^[[:space:]]+${want}[[:space:]]" || true)"
  [[ -n "${line}" ]] || return 1
  if [[ "${line}" =~ ([0-9]+)x([0-9]+)([-+][0-9]+)([-+][0-9]+)[[:space:]] ]]; then
    w="${BASH_REMATCH[1]}"
    h="${BASH_REMATCH[2]}"
    # `${v#+\+}` is the wrong way to drop a sign. Inside a `${v#pattern}` the
    # `\+` is an escaped `+`, so `+\+` is a TWO-character pattern (`++`) and
    # matches nothing. The coordinate came back as `+0`, the gate then built a
    # crop geometry of `1280x720++0++0`, and every string downstream of it was
    # garbage. `${v#+}` is the one-character pattern that actually strips the
    # sign; a leading `-` is left alone, because that is the coordinate.
    x="${BASH_REMATCH[3]#+}"
    y="${BASH_REMATCH[4]#+}"
    printf '%s %s %s %s' "${w}" "${h}" "${x}" "${y}"
  fi
}
# Deliberately NOT handled here: `broken` must not exit before the argument
# dispatch below. It used to, which made `xwininfo -version` and `xwininfo -root`
# fail as well, so the "the per-window query fails" scenario reported
# `root_geometry` -- a real assertion going red for a reason that had nothing to
# do with what the scenario was built to break. Only the `-id` invocation is
# allowed to be broken.
case "${id_mode}" in
  unmapped) map_state="IsUnmapped" ;;
esac
case "${1:-}" in
  -version)
    echo "xwininfo Version: 1.1.7 (fake)"
    exit 0
    ;;
  -id)
    if [[ "${id_mode}" == "broken" ]]; then
      echo "xwininfo: unable to find window '${2:-}'" >&2
      exit 1
    fi
    # Answer about the window that was asked for, not about a canned one.
    if [[ "${id_mode}" != "forced" ]]; then
      if ! geom="$(geometry_for_id "${2:-0x0}")" || [[ -z "${geom}" ]]; then
        echo "xwininfo: unable to find window '${2:-}'" >&2
        exit 1
      fi
      read -r id_w id_h id_x id_y <<<"${geom}"
    fi
    printf 'xwininfo: Window id: %s "Private Gallery"\n\n' "${2:-0x0}"
    if [[ "${id_mode}" != "no-geometry" ]]; then
      printf '  Absolute upper-left X:  %s\n' "${id_x}"
      printf '  Absolute upper-left Y:  %s\n' "${id_y}"
      printf '  Relative upper-left X:  %s\n' "${id_x}"
      printf '  Relative upper-left Y:  %s\n' "${id_y}"
      printf '  Width: %s\n' "${id_w}"
      printf '  Height: %s\n' "${id_h}"
    fi
    printf '  Depth: 24\n  Visual Class: TrueColor\n  Class: InputOutput\n'
    printf '  Map State: %s\n  Override Redirect State: no\n' "${map_state}"
    exit 0
    ;;
  -root)
    if [[ "${2:-}" == "-tree" ]]; then
      case "${tree_mode}" in
        broken)
          echo "xwininfo: unable to open display" >&2
          exit 1
          ;;
        empty)
          printf 'xwininfo: Window id: 0x1a1 (the root window) (has no name)\n\n'
          printf '  Root window id: 0x1a1 (the root window) (has no name)\n'
          printf '  Parent window id: 0x0 (none)\n     0 children:\n'
          exit 0
          ;;
        small)
          # A real window that is far below the 20%% area floor: the app is up
          # but not presenting anything usable.
          printf 'xwininfo: Window id: 0x1a1 (the root window) (has no name)\n\n'
          printf '  Root window id: 0x1a1 (the root window) (has no name)\n'
          printf '  Parent window id: 0x0 (none)\n     1 child:\n'
          printf '     0x200005 "Private Gallery": ("com.privategallery.desktop" "Com.privategallery.desktop")  100x100+0+0  +0+0\n'
          exit 0
          ;;
        good|*)
          good_tree
          exit 0
          ;;
      esac
    fi
    printf 'xwininfo: Window id: 0x1a1 (the root window) (has no name)\n\n'
    printf '  Absolute upper-left X:  0\n  Absolute upper-left Y:  0\n'
    printf '  Relative upper-left X:  0\n  Relative upper-left Y:  0\n'
    # root_mode=no-geometry answers successfully with no Width/Height at all,
    # which is the case root_geometry exists to catch: the area floor is
    # relative to the root, so a root that reports no size cannot be compared
    # against anything.
    if [[ "${root_mode}" != "no-geometry" ]]; then
      printf '  Width: %s\n  Height: %s\n' "${root_w}" "${root_h}"
    fi
    printf '  Depth: 24\n'
    printf '  Visual Class: TrueColor\n  Class: InputOutput\n  Map State: IsViewable\n'
    exit 0
    ;;
  *)
    echo "fake xwininfo: unsupported arguments: $*" >&2
    exit 2
    ;;
esac
FAKE_EOF
  chmod +x "${FARM}/xwininfo"

  cat >"${FARM}/import" <<'FAKE_EOF'
#!/usr/bin/env bash
# fake import: writes a stand-in PNG where the real one would write a capture.
set -uo pipefail
out=""
for a in "$@"; do
  case "${a}" in
    png:*) out="${a#png:}" ;;
  esac
done
if [[ -z "${out}" ]]; then
  echo "fake import: no png: output target in: $*" >&2
  exit 2
fi
if [[ -n "${FAKE_IMPORT_SINK_FILE:-}" ]]; then
  printf 'capture %s\n' "$*" >>"${FAKE_IMPORT_SINK_FILE}"
fi
# Deliberately small but non-empty: the gate's own size check is what this stands
# in for, and a zero-byte file is exactly what it must reject.
printf 'fake-capture\n' >"${out}"
exit 0
FAKE_EOF
  chmod +x "${FARM}/import"

  cat >"${FARM}/convert" <<'FAKE_EOF'
#!/usr/bin/env bash
# fake convert. Renders the metric self-check images and answers the colour-count
# and crop operations the gate performs. FAKE_CONVERT_COLOURS can be set to a
# number (a blank frame), to "garbage" (a metric that is not answering), or left
# alone (a normal app frame).
set -uo pipefail
last="${!#}"
case "${last}" in
  info:)
    # A `-format %k info:` query: convert <input> -format %k info:. The input is
    # the FIRST non-option argument, not the last. Taking the last one picks up
    # `%k` itself, so the fixture name never matched and every self-check read
    # FAKE_CONVERT_COLOURS (500) instead of its known-exact 1 and 2 -- which is
    # why every run of the suite stopped at metric_selfcheck_colours.
    input=""
    for a in "$@"; do
      case "${a}" in
        -*) continue ;;
        info:) continue ;;
      esac
      input="${a}"
      break
    done
    base="$(basename "${input}")"
    case "${base}" in
      solid.png) echo 1 ;;
      two-hue.png) echo 2 ;;
      *) echo "${FAKE_CONVERT_COLOURS:-500}" ;;
    esac
    exit 0
    ;;
esac
out="${last#png:}"
printf 'fake-image\n' >"${out}"
exit 0
FAKE_EOF
  chmod +x "${FARM}/convert"

  cat >"${FARM}/compare" <<'FAKE_EOF'
#!/usr/bin/env bash
# fake compare. Prints an AE pixel count on stderr and exits 1 when the images
# differ, like the real one. A self-comparison must report 0, two different
# images must report a positive count, and the settle captures report
# FAKE_COMPARE_SETTLE_DIFF (0 by default: a settled screen).
set -uo pipefail
files=()
for a in "$@"; do
  case "${a}" in
    -metric | null:) ;;
    *) files+=("${a}") ;;
  esac
done
a="${files[0]:-}"
b="${files[1]:-}"
if [[ -n "${FAKE_COMPARE_GARBAGE:-}" ]]; then
  echo "compare: image widths or heights differ" >&2
  exit 1
fi
# FAKE_COMPARE_SETTLE_GARBAGE breaks ONLY the settle comparison, so the two
# self-check comparisons (same image, and two known-different images) still
# answer. A globally-broken compare is caught by metric_selfcheck_settle first,
# which is the correct fail-closed ordering and is asserted separately.
if [[ -n "${FAKE_COMPARE_SETTLE_GARBAGE:-}" ]] \
  && [[ "${a}" == *-settle-* || "${b}" == *-settle-* ]]; then
  echo "compare: image widths or heights differ" >&2
  exit 1
fi
if [[ "${a}" == "${b}" ]]; then
  echo 0 >&2
  exit 0
fi
if [[ "${a}" == *-settle-* || "${b}" == *-settle-* ]]; then
  echo "${FAKE_COMPARE_SETTLE_DIFF:-0}" >&2
  exit 1
fi
echo 32 >&2
exit 1
FAKE_EOF
  chmod +x "${FARM}/compare"

  # `dpkg-deb` unpacks from a template tree the scenario built, and answers
  # control-field queries from a control file. `-x` and `-f` are the only two
  # invocations the gate makes.
  cat >"${FARM}/dpkg-deb" <<'FAKE_EOF'
#!/usr/bin/env bash
# fake dpkg-deb: unpacks a prepared template tree, and answers -f from a control
# file. FAKE_DEB_TEMPLATE / FAKE_DEB_CONTROL say where the prepared data is.
set -uo pipefail
mode="${1:-}"
case "${mode}" in
  -x)
    root="${3:?}"
    if [[ -n "${FAKE_DEB_X_FAIL:-}" ]]; then
      echo "dpkg-deb: error: control archive has bad magic" >&2
      exit 2
    fi
    # Same rule as the AppImage fake, for the same reason: a real dpkg-deb
    # refuses a .deb whose ar/tar tail has been cut, and a fake that did not
    # would make the zero-byte negative test prove nothing about the gate.
    archive="${2:?}"
    want="$(awk '$1 == "deb" { print $2 }' "${FAKE_FULL_SIZES:-/nonexistent}" 2>/dev/null || true)"
    if [[ -n "${want}" && -r "${archive}" ]] && (( $(wc -c <"${archive}") < want )); then
      echo "dpkg-deb: error: control archive has bad magic" >&2
      exit 2
    fi
    template="${FAKE_DEB_TEMPLATE:?FAKE_DEB_TEMPLATE is not set}"
    mkdir -p "${root}"
    cp -R "${template}/." "${root}/"
    exit 0
    ;;
  -f)
    field="${3:?}"
    control="${FAKE_DEB_CONTROL:?FAKE_DEB_CONTROL is not set}"
    if [[ ! -f "${control}" ]]; then
      echo "dpkg-deb: error: no control file" >&2
      exit 2
    fi
    if [[ -n "${FAKE_DEB_F_MISSING:-}" ]]; then
      echo "dpkg-deb: error: no such package" >&2
      exit 2
    fi
    sed -n "s/^${field}:[[:space:]]*//p" "${control}"
    exit 0
    ;;
  *)
    echo "fake dpkg-deb: unsupported arguments: $*" >&2
    exit 2
    ;;
esac
FAKE_EOF
  chmod +x "${FARM}/dpkg-deb"

  # `bsdtar` is the documented fallback extractor, so the suite exercises that
  # path too rather than leaving it unrun.
  cat >"${FARM}/bsdtar" <<'FAKE_EOF'
#!/usr/bin/env bash
# fake bsdtar: enough of libarchive to stand in for the gate's fallback path.
set -uo pipefail
template="${FAKE_DEB_TEMPLATE:?}"
control="${FAKE_DEB_CONTROL:?}"
case "${1:-}" in
  -xf)
    dir=""
    member=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -C) dir="$2"; shift 2 ;;
        -*) shift ;;
        *) member="$1"; shift ;;
      esac
    done
    if [[ -n "${member}" && "${member}" == control.tar.* ]]; then
      mkdir -p "${dir}/${member}"
      cp -f "${control}" "${dir}/${member}/control"
      exit 0
    fi
    if [[ -n "${dir}" ]]; then
      mkdir -p "${dir}"
      cp -R "${template}/." "${dir}/"
    fi
    exit 0
    ;;
  -tf)
    printf 'debian-binary\ncontrol.tar.gz\ndata.tar.xz\n'
    exit 0
    ;;
  -xOf)
    # Print the control member's ./control to stdout.
    cat "${control}"
    exit 0
    ;;
  *)
    echo "fake bsdtar: unsupported arguments: $*" >&2
    exit 2
    ;;
esac
FAKE_EOF
  chmod +x "${FARM}/bsdtar"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
#
# The payload templates mirror what the `linux` job in release.yml assembles. The
# engine binary is a copy of a real ELF object, because the gate asserts the
# payload binary really is an ELF and a text placeholder would not be a valid
# fixture for that assertion.
EL_FIXTURE=""
WRONG_ARCH_FIXTURE=""
make_elf_fixture() {
  EL_FIXTURE="${WORK}/elf-fixture"
  # `command -v true` prints the BUILTIN's name ("true"), not a path, so `cp`
  # then looked for a file called `true` in the current directory and every ELF
  # fixture in the suite silently came out missing -- which in turn made every
  # payload look as if it had no engine binary. `type -P` returns the path of a
  # real file, so that is what is resolved here. `env` is the fallback.
  local src
  src="$(type -P true 2>/dev/null || type -P env 2>/dev/null || true)"
  if [[ -z "${src}" || ! -f "${src}" ]]; then
    printf 'FATAL: no on-disk ELF binary found to use as the fixture (tried `type -P true` and `type -P env`)\n' >&2
    exit 2
  fi
  cp -f "${src}" "${EL_FIXTURE}"
  chmod +x "${EL_FIXTURE}"
  local magic
  magic="$(od -An -tx1 -N4 "${EL_FIXTURE}" | tr -d ' \n')"
  if [[ "${magic}" != "7f454c46" ]]; then
    printf 'FATAL: the ELF fixture is not an ELF object (leading bytes %s)\n' "${magic:-none}" >&2
    exit 2
  fi
  # A valid ELF for the WRONG architecture, for the assertion that the bytes are
  # the ones this runner can launch. It is derived from the real fixture by
  # patching only e_machine (header bytes 18-19 -- bytes 16-17 are e_type and
  # come first, which is the mistake the first version of the gate's own check
  # made) to 0xb7 = 183 = EM_AARCH64, so it is a genuine ELF64 LSB object that
  # simply is not x86-64. Handing the gate a text placeholder instead would
  # prove nothing: the magic assertion would catch it first and the architecture
  # assertion would never be reached.
  WRONG_ARCH_FIXTURE="${WORK}/elf-fixture-aarch64"
  cp -f "${EL_FIXTURE}" "${WRONG_ARCH_FIXTURE}"
  chmod +x "${WRONG_ARCH_FIXTURE}"
  printf '\xb7\x00' | dd of="${WRONG_ARCH_FIXTURE}" bs=1 seek=18 conv=notrunc 2>/dev/null
  local got
  got="$(od -An -tx1 -N20 "${WRONG_ARCH_FIXTURE}" | tr -d ' \n')"
  # The good fixture is asserted too, or a silently-wrong EL_FIXTURE would make
  # both architecture scenarios green for the wrong reason.
  local base
  base="$(od -An -tx1 -N20 "${EL_FIXTURE}" | tr -d ' \n')"
  if [[ "${base:0:8}" != "7f454c46" || "${base:8:2}" != "02" || "${base:10:2}" != "01" || "${base:36:4}" != "3e00" ]]; then
    printf 'FATAL: the ELF fixture is not a little-endian 64-bit x86-64 ELF (header is %s)\n' "${base:-none}" >&2
    exit 2
  fi
  if [[ "${got:0:8}" != "7f454c46" || "${got:8:2}" != "02" || "${got:10:2}" != "01" || "${got:36:4}" != "b700" ]]; then
    printf 'FATAL: could not build the wrong-arch ELF fixture (header is %s)\n' "${got:-none}" >&2
    exit 2
  fi
}

# make_appimage_template <dir> [opt=value ...]
#   desktop_exec   value for Exec= in the shipped desktop entry
#   omit           a payload path to leave out
#   not_exec       a payload path to leave non-executable
#   not_elf        replace private_gallery_app with a non-ELF file
#   wrong_arch     replace private_gallery_app with a valid ELF64 LSB object
#                  whose e_machine is EM_AARCH64
make_appimage_template() {
  local dir="$1"
  shift
  local desktop_exec="photo-organizer"
  local omit="" not_exec="" not_elf="" wrong_arch=""
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "${k}" in
      desktop_exec) desktop_exec="${v}" ;;
      omit) omit="${v}" ;;
      not_exec) not_exec="${v}" ;;
      not_elf) not_elf="1" ;;
      wrong_arch) wrong_arch="1" ;;
      *) printf 'unknown fixture option: %s\n' "${k}" >&2; exit 2 ;;
    esac
  done
  rm -rf "${dir}"
  mkdir -p "${dir}/ml_sidecar"
  if [[ -z "${omit}" || "${omit}" != "AppRun" ]]; then
    printf '#!/usr/bin/env bash\nexit 0\n' >"${dir}/AppRun"
  fi
  if [[ -z "${omit}" || "${omit}" != "private_gallery_app" ]]; then
    if [[ -n "${not_elf}" ]]; then
      # Executable on purpose: the ELF check must be reachable, so the fixture
      # has to fail THAT assertion and not the preceding exec-bit one. Leaving
      # the text file non-executable made this scenario report
      # appimage_not_executable, which is a different assertion.
      printf 'not an elf\n' >"${dir}/private_gallery_app"
      chmod +x "${dir}/private_gallery_app"
    elif [[ -n "${wrong_arch}" ]]; then
      cp -f "${WRONG_ARCH_FIXTURE}" "${dir}/private_gallery_app"
      chmod +x "${dir}/private_gallery_app"
    else
      cp -f "${EL_FIXTURE}" "${dir}/private_gallery_app"
    fi
  fi
  if [[ -z "${omit}" || "${omit}" != "galleryd" ]]; then
    cp -f "${EL_FIXTURE}" "${dir}/galleryd"
  fi
  if [[ -z "${omit}" || "${omit}" != "ml_sidecar/private_gallery_ml_sidecar.py" ]]; then
    printf '#!/usr/bin/env python3\n' >"${dir}/ml_sidecar/private_gallery_ml_sidecar.py"
  fi
  if [[ -z "${omit}" || "${omit}" != "photo-organizer.desktop" ]]; then
    {
      printf '[Desktop Entry]\n'
      printf 'Name=Photo Organizer\n'
      printf 'Exec=%s\n' "${desktop_exec}"
      printf 'Icon=photo-organizer\n'
      printf 'Type=Application\n'
      printf 'Categories=Graphics;Photography;\n'
      printf 'Terminal=false\n'
    } >"${dir}/photo-organizer.desktop"
  fi
  chmod +x "${dir}/AppRun" 2>/dev/null || true
  if [[ "${not_exec}" == "galleryd" ]]; then
    chmod -x "${dir}/galleryd"
  fi
  return 0
}

# make_deb_template <dir> [opt=value ...]
#   omit / not_exec / link_target / not_elf / deb_exec / icon
make_deb_template() {
  local dir="$1"
  shift
  local omit="" not_exec="" not_elf="" wrong_arch=""
  local link_target="/opt/photo-organizer/AppRun"
  local deb_exec="/opt/photo-organizer/AppRun" icon="photo-organizer"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    case "${k}" in
      omit) omit="${v}" ;;
      not_exec) not_exec="${v}" ;;
      not_elf) not_elf="1" ;;
      link_target) link_target="${v}" ;;
      deb_exec) deb_exec="${v}" ;;
      icon) icon="${v}" ;;
      wrong_arch) wrong_arch="1" ;;
      *) printf 'unknown fixture option: %s\n' "${k}" >&2; exit 2 ;;
    esac
  done
  rm -rf "${dir}"
  mkdir -p "${dir}/opt/photo-organizer/ml_sidecar" \
    "${dir}/usr/share/applications" \
    "${dir}/usr/share/icons/hicolor/512x512/apps" \
    "${dir}/usr/bin"
  if [[ -z "${omit}" || "${omit}" != "opt/photo-organizer/AppRun" ]]; then
    # The same fake application the AppImage leg launches, so one behaviour
    # setting drives both legs.
    write_fake_app "${dir}/opt/photo-organizer/AppRun"
  fi
  if [[ -z "${omit}" || "${omit}" != "opt/photo-organizer/private_gallery_app" ]]; then
    if [[ -n "${not_elf}" ]]; then
      printf 'not an elf\n' >"${dir}/opt/photo-organizer/private_gallery_app"
    elif [[ -n "${wrong_arch}" ]]; then
      cp -f "${WRONG_ARCH_FIXTURE}" "${dir}/opt/photo-organizer/private_gallery_app"
    else
      cp -f "${EL_FIXTURE}" "${dir}/opt/photo-organizer/private_gallery_app"
    fi
    chmod +x "${dir}/opt/photo-organizer/private_gallery_app"
  fi
  if [[ -z "${omit}" || "${omit}" != "opt/photo-organizer/galleryd" ]]; then
    cp -f "${EL_FIXTURE}" "${dir}/opt/photo-organizer/galleryd"
    chmod +x "${dir}/opt/photo-organizer/galleryd"
  fi
  if [[ -z "${omit}" || "${omit}" != "opt/photo-organizer/ml_sidecar/private_gallery_ml_sidecar.py" ]]; then
    printf '#!/usr/bin/env python3\n' \
      >"${dir}/opt/photo-organizer/ml_sidecar/private_gallery_ml_sidecar.py"
  fi
  if [[ -z "${omit}" || "${omit}" != "usr/share/applications/photo-organizer.desktop" ]]; then
    {
      printf '[Desktop Entry]\n'
      printf 'Name=Photo Organizer\n'
      printf 'Exec=%s\n' "${deb_exec}"
      printf 'Icon=%s\n' "${icon}"
      printf 'Type=Application\n'
      printf 'Categories=Graphics;Photography;\n'
    } >"${dir}/usr/share/applications/photo-organizer.desktop"
  fi
  if [[ -z "${omit}" || "${omit}" != "usr/share/icons/hicolor/512x512/apps/photo-organizer.png" ]]; then
    printf 'fake-png\n' >"${dir}/usr/share/icons/hicolor/512x512/apps/photo-organizer.png"
  fi
  if [[ "${link_target}" == "none" ]]; then
    rm -f "${dir}/usr/bin/photo-organizer"
  else
    ln -sfn "${link_target}" "${dir}/usr/bin/photo-organizer"
  fi
  if [[ -n "${not_exec}" && "${not_exec}" == "opt/photo-organizer/AppRun" ]]; then
    chmod -x "${dir}/opt/photo-organizer/AppRun"
  fi
  if [[ -n "${not_exec}" && "${not_exec}" == "opt/photo-organizer/galleryd" ]]; then
    chmod -x "${dir}/opt/photo-organizer/galleryd"
  fi
  if [[ -n "${not_exec}" && "${not_exec}" == "opt/photo-organizer/private_gallery_app" ]]; then
    chmod -x "${dir}/opt/photo-organizer/private_gallery_app"
  fi
  return 0
}

# make_control <path> [omit-field]
# `omit-field` names a control field to leave out entirely, which is how the
# "the .deb has no Version" scenario is built. The path is passed in and every
# caller already holds it, so nothing is exported from here.
make_control() {
  local path="$1"
  shift
  local omit="${1:-}"
  {
    printf 'Package: photo-organizer\n'
    if [[ "${omit}" != "Version" ]]; then
      printf 'Version: 0.1.7\n'
    fi
    if [[ "${omit}" != "Architecture" ]]; then
      printf 'Architecture: amd64\n'
    fi
    printf 'Maintainer: Photo Organizer <noreply@example.com>\n'
    printf 'Description: Local-first, private-by-default photo and video library\n'
  } >"${path}"
}

# The fake application runtime. It is used for BOTH legs: the `.AppImage` file
# itself and the `.deb`'s `/opt/photo-organizer/AppRun`. They have to be the same
# program or the deb leg is untestable -- it used to be a two-line
# `#!/usr/bin/env bash / exit 0` stub, so every deb leg reported
# `app_exited_during_launch` and every deb-leg assertion (teardown status, Dart
# soft-fail, crash signature) was exercised by the appimage leg alone.
#
# `FAKE_APPIMAGE_TEMPLATE` says what to materialise for `--appimage-extract`;
# `FAKE_APP_BEHAVIOUR` says how the launch should end.
#
#   ok                 run until told to stop (the passing case)
#   exit-immediately   die before drawing anything
#   die-late           draw a frame, then die
#   crash-on-term      die with a non-signal status when SIGTERMed
#   crash-log          print a native crash signature on stdout
#   panic-log          write a Rust panic into galleryd.log
#   dart-error         print a Dart "Unhandled exception" (soft: must NOT fail)
#   no-start-line      start without printing anything at all
write_fake_app() {
  local dest="$1"
  cat >"${dest}" <<'APP_EOF'
#!/usr/bin/env bash
# fake application runtime for the linux artifact gate test suite.
set -uo pipefail
# The behaviour arrives in a FILE next to this script, not in the environment.
# The gate launches the app under `env -i` with an explicit allow-list, which is
# right for a release gate -- it must not hand the artifact the CI environment
# -- but it means a test double can never be steered by an exported variable.
# Every scenario that set FAKE_APP_BEHAVIOUR was therefore running the `ok` app:
# five "the app dies / the app crashes" scenarios saw a green run and the suite
# recorded them as reds. Reading a sibling file is how a fixture the gate cannot
# see still gets to decide what the app does.
behaviour="${FAKE_APP_BEHAVIOUR:-ok}"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _here="."
if [[ -r "${_here}/fake-behaviour" ]]; then
  behaviour="$(tr -d '[:space:]' <"${_here}/fake-behaviour")"
fi
if [[ "${1:-}" == "--appimage-extract" ]]; then
  template="${FAKE_APPIMAGE_TEMPLATE:?FAKE_APPIMAGE_TEMPLATE is not set}"
  if [[ -n "${FAKE_APPIMAGE_EXTRACT_FAIL:-}" ]]; then
    echo "Cannot mount AppImage, please check your FUSE setup." >&2
    exit 1
  fi
  # Truncation is fatal to a real AppImage: the squashfs image is the tail of
  # the file, so cutting it makes the mount fail. A fake that happily unpacks a
  # cut file would make "the archive is whole" untestable, and the negative test
  # that cuts the tail would be measuring the harness instead of the gate. The
  # archive path is not an argument -- the gate invokes this with
  # `--appimage-extract` and no path -- so it is this script's own path.
  _self="${BASH_SOURCE[0]}"
  _want="$(awk '$1 == "appimage" { print $2 }' "${FAKE_FULL_SIZES:-/nonexistent}" 2>/dev/null || true)"
  if [[ -n "${_want}" && -n "${_self}" && -r "${_self}" ]] \
    && (( $(wc -c <"${_self}") < _want )); then
    echo "Cannot mount AppImage: the squashfs image is truncated." >&2
    exit 1
  fi
  mkdir -p squashfs-root
  cp -R "${template}/." squashfs-root/
  exit 0
fi
if [[ "${behaviour}" == "no-start-line" ]]; then
  trap 'exit 0' TERM
  while :; do sleep 0.2; done
fi
echo "fake-app: started (behaviour=${behaviour})"
case "${behaviour}" in
  exit-immediately) exit 3 ;;
  crash-log) echo "terminate called after throwing an instance of 'std::runtime_error'" ;;
  dart-error) echo "Unhandled exception: SecretService not available" ;;
esac
if [[ -n "${PRIVATE_GALLERY_RUNTIME_ROOT:-}" ]]; then
  mkdir -p "${PRIVATE_GALLERY_RUNTIME_ROOT}"
  case "${behaviour}" in
    panic-log) echo "thread 'galleryd' panicked at src/main.rs:42:5" \
      >"${PRIVATE_GALLERY_RUNTIME_ROOT}/galleryd.log" ;;
  esac
fi
if [[ "${behaviour}" == "crash-on-term" ]]; then
  trap 'exit 42' TERM
fi
if [[ "${behaviour}" == "die-late" ]]; then
  # The MAIN process has to exit, not a subshell. `(sleep 1; exit 9) &` only
  # ended the background job, so the app stayed up for the whole leg and the
  # "died after the first frame" assertion was unreachable: the gate correctly
  # reported the launch as a pass. The trap re-raises SIGTERM on the main shell
  # after a delay, so the status is a signal-class exit and `kill -0` on the
  # `setsid --wait` parent stops succeeding partway through prove_render.
  trap 'exit 9' TERM
  (sleep 1; kill -TERM $$) &
fi
while :; do sleep 0.2; done
APP_EOF
  chmod +x "${dest}"
}

# ---------------------------------------------------------------------------
# Running the gate
# ---------------------------------------------------------------------------
#
# Every run gets its own artifact dir, evidence dir and scratch, and a fast,
# fully-passing set of tunables. `LINUX_SMOKE_NAME` distinguishes the runs so
# their evidence does not collide.
run_gate() {
  local tag="$1"
  shift
  local gate="$1"
  shift
  local artdir="${WORK}/art-${tag}"
  local evdir="${WORK}/ev-${tag}"
  rm -rf "${artdir}" "${evdir}"
  mkdir -p "${artdir}" "${evdir}"
  # The artifact directory has to be POPULATED. It used to be created empty,
  # because make_good_artifacts writes into its own `${dir}/out` and nothing ever
  # copied from there: every run stopped at `artifact_discovery` and reported
  # "no *.AppImage". That is worse than a broken test -- a scenario asserts a
  # specific tag, an empty artifact directory trips a different one, and the
  # suite reports "wrong assertion red" for all of them while the mutations that
  # happen to target artifact_discovery pass for entirely the wrong reason.
  if [[ ! -d "${ARTIFACT_SRC}" ]]; then
    printf 'FATAL: run_gate %s has no artifact source (ARTIFACT_SRC=%s is not a directory)\n' \
      "${tag}" "${ARTIFACT_SRC:-<unset>}" >&2
    exit 2
  fi
  cp -R "${ARTIFACT_SRC}/." "${artdir}/"
  # A hard per-run wall clock. Without it a single mutant can hang the entire
  # suite: inverting `if ! kill -0 "${APP_PID}"` makes the gate call
  # `collect_wait_status` while the app is still alive, and that blocks in
  # `wait` on a live process forever. A hang is the worst outcome available
  # here -- it reads as "the suite is working hard" and reports nothing.
  LAST_OUT="$(timeout -k 5 "${TEST_GATE_TIMEOUT:-180}" env -i \
    PATH="${FARM}" \
    HOME="${WORK}" \
    TMPDIR="${WORK}" \
    LINUX_SMOKE_NAME="${tag}" \
    LINUX_SMOKE_EVIDENCE_DIR="${evdir}" \
    LINUX_SMOKE_SETTLE_SECONDS="${TEST_SETTLE_SECONDS:-0}" \
    LINUX_SMOKE_TEARDOWN_GRACE_SECONDS=0 \
    LINUX_SMOKE_POLL_SECONDS="${TEST_POLL:-0}" \
    LINUX_SMOKE_LAUNCH_TIMEOUT="${TEST_LAUNCH_TIMEOUT:-8}" \
    LINUX_SMOKE_RENDER_TIMEOUT="${TEST_RENDER_TIMEOUT:-6}" \
    FAKE_XVFB_ARGS_FILE="${WORK}/xvfb-args-${tag}.txt" \
    FAKE_XWININFO_TREE_MODE="${TEST_TREE_MODE:-good}" \
    FAKE_XWININFO_ID_MODE="${TEST_ID_MODE:-good}" \
    FAKE_XWININFO_ID_X="${TEST_ID_X:-0}" \
    FAKE_XWININFO_ID_Y="${TEST_ID_Y:-0}" \
    FAKE_XWININFO_ROOT_W="${TEST_ROOT_W:-1280}" \
    FAKE_XWININFO_ROOT_H="${TEST_ROOT_H:-800}" \
    FAKE_XWININFO_ROOT_MODE="${TEST_ROOT_MODE:-good}" \
    FAKE_CONVERT_COLOURS="${TEST_COLOURS:-500}" \
    FAKE_COMPARE_SETTLE_DIFF="${TEST_SETTLE_DIFF:-0}" \
    FAKE_COMPARE_GARBAGE="${TEST_COMPARE_GARBAGE:-}" \
    FAKE_COMPARE_SETTLE_GARBAGE="${TEST_COMPARE_SETTLE_GARBAGE:-}" \
    FAKE_DEB_TEMPLATE="${TEST_DEB_TEMPLATE:-}" \
    FAKE_DEB_CONTROL="${TEST_DEB_CONTROL:-}" \
    FAKE_DEB_X_FAIL="${TEST_DEB_X_FAIL:-}" \
    FAKE_DEB_F_MISSING="${TEST_DEB_F_MISSING:-}" \
    FAKE_APPIMAGE_TEMPLATE="${TEST_APPIMAGE_TEMPLATE:-}" \
    FAKE_APPIMAGE_EXTRACT_FAIL="${TEST_APPIMAGE_EXTRACT_FAIL:-}" \
    FAKE_FULL_SIZES="${artdir}/fake-full-sizes" \
    FAKE_APP_BEHAVIOUR="${TEST_APP_BEHAVIOUR:-ok}" \
    FAKE_IMPORT_SINK_FILE="${TEST_IMPORT_SINK:-}" \
    "${gate}" "${artdir}" 2>&1)"
  LAST_STATUS=$?
  reap_strays
  return 0
}

# Builds a complete, valid pair of artifacts. `behaviour` is the fake app's
# behaviour and it is written INTO THE FIXTURE, in the two places the two legs
# actually execute the app from:
#
#   * next to the .AppImage inside the artifact directory, because the gate runs
#     the AppImage in place, and
#   * next to the .deb's `AppRun`, because the gate extracts the payload and
#     runs `AppRun` from the extracted tree.
#
# It cannot travel in the environment: the gate launches the app under `env -i`.
make_good_artifacts() {
  local dir="$1"
  local behaviour="${2:-ok}"
  make_appimage_template "${dir}/appimage-payload"
  make_deb_template "${dir}/deb-payload"
  make_control "${dir}/control" ""
  mkdir -p "${dir}/out"
  ARTIFACT_SRC="${dir}/out"
  write_fake_app "${dir}/out/photo-organizer-linux-x86_64-v0.1.7.AppImage"
  printf '%s' "${behaviour}" >"${dir}/out/fake-behaviour"
  printf '%s' "${behaviour}" >"${dir}/deb-payload/opt/photo-organizer/fake-behaviour"
  # A real AppImage is tens of megabytes; the size floor is asserted, so the
  # double has to be over it.
  dd if=/dev/zero bs=1024 count=1200 >>"${dir}/out/photo-organizer-linux-x86_64-v0.1.7.AppImage" 2>/dev/null
  printf 'fake deb payload\n' >"${dir}/out/photo-organizer_0.1.7_amd64.deb"
  # Both archives' pristine sizes, recorded here while they are whole. The two
  # extractor fakes compare the file they were handed against these, so a
  # truncated artifact fails the way a truncated artifact fails in production.
  # Without the file, the fakes unpack anything -- including an empty file -- and
  # the two truncation scenarios below would assert that the harness is lenient
  # rather than that the gate is not.
  {
    printf 'appimage %s\n' \
      "$(wc -c <"${dir}/out/photo-organizer-linux-x86_64-v0.1.7.AppImage")"
    printf 'deb %s\n' "$(wc -c <"${dir}/out/photo-organizer_0.1.7_amd64.deb")"
  } >"${dir}/out/fake-full-sizes"
  TEST_APPIMAGE_TEMPLATE="${dir}/appimage-payload"
  TEST_DEB_TEMPLATE="${dir}/deb-payload"
  TEST_DEB_CONTROL="${dir}/control"
  TEST_APP_BEHAVIOUR="${behaviour}"
}

# ---------------------------------------------------------------------------
# Assertions on a run
# ---------------------------------------------------------------------------
assert_green() {
  local desc="$1"
  if [[ "${LAST_STATUS}" -eq 0 ]]; then
    pass "${desc}"
  elif [[ "${LAST_STATUS}" -eq 124 || "${LAST_STATUS}" -eq 137 ]]; then
    # `timeout` reports 124 (or 137 with -k). A timed-out run is not a red
    # assertion, and counting it as "the gate failed" would let a hanging gate
    # masquerade as a passing detection test.
    fail "${desc} (the gate run TIMED OUT after ${TEST_GATE_TIMEOUT:-180}s instead of exiting 0)"
  else
    fail "${desc} (expected exit 0, got ${LAST_STATUS})"
  fi
}

assert_red() {
  local desc="$1" tag="$2"
  if [[ "${LAST_STATUS}" -eq 0 ]]; then
    fail "${desc} (expected a failure, got exit 0)"
    return 0
  fi
  if [[ "${LAST_STATUS}" -eq 124 || "${LAST_STATUS}" -eq 137 ]]; then
    fail "${desc} (the gate run TIMED OUT after ${TEST_GATE_TIMEOUT:-180}s; a hang is not a detection)"
    return 0
  fi
  if printf '%s\n' "${LAST_OUT}" | grep -q "FAIL assertion=${tag}:"; then
    pass "${desc}"
  else
    fail "${desc} (exit ${LAST_STATUS} but no 'FAIL assertion=${tag}:' line; assertions reported: $(printf '%s\n' "${LAST_OUT}" | sed -n 's/.*FAIL assertion=\([a-z_]*\):.*/\1/p' | tr '\n' ' '))"
  fi
}

# The evidence directory a run wrote to. Derived from the tag rather than by
# searching for a summary file: `dirname ""` is "." , so a run that produced no
# summary made every evidence assertion grep "." -- which is how a missing
# summary could silently satisfy an evidence check against some unrelated file.
evidence_dir_for() {
  printf '%s' "${WORK}/ev-$1"
}

assert_evidence_contains() {
  local desc="$1" needle="$2" tag="$3"
  local evdir
  evdir="$(evidence_dir_for "${tag}")"
  if [[ ! -d "${evdir}" ]]; then
    fail "${desc} (no evidence directory for ${tag})"
    return 0
  fi
  if ! compgen -G "${evdir}/*" >/dev/null; then
    fail "${desc} (the evidence directory for ${tag} is empty)"
    return 0
  fi
  if grep -qR -I \
    --include='*.txt' --include='*.log' \
    -- "${needle}" "${evdir}" 2>/dev/null; then
    pass "${desc}"
  else
    fail "${desc} (evidence in ${evdir} does not contain '${needle}')"
  fi
}

# ---------------------------------------------------------------------------
# Mutation runner
# ---------------------------------------------------------------------------
#
# Copies the gate, applies the sed expressions, and FAILS if any of them did not
# change the file. "The mutation did not apply" means the suite is testing a
# string that no longer exists, which is a silent loss of coverage, so it is
# reported as a failure and never skipped.
#
# `MUTANT_PATH` and `MUTATION_APPLIED` are globals rather than a printed path on
# purpose. The first version of this function printed the mutant's path and read
# it back with `dest="$(apply_mutation ...)"`, which runs the function in a
# SUBSHELL: every assignment it made -- including `MUTATION_APPLIED=1` -- was
# thrown away when the substitution ended. The caller then saw the initial 0 and
# reported "the mutation did not apply, so nothing was proven" for all 40+
# mutations, i.e. the suite reported zero coverage while looking busy.
#
# "Did the mutation apply" is decided by comparing the file's digest before and
# after `sed -i`, not by grepping for the expression. A grep can succeed on a
# string the substitution would never match (the expression is a sed BRE, not the
# literal text), and a sed that exits 0 without changing anything is common --
# both produce a mutation that measures nothing and reports as a pass.
file_digest() {
  sha256sum "$1" | cut -d' ' -f1
}

apply_mutation() {
  local name="$1"
  shift
  MUTANT_PATH="${WORK}/mutants/${name}.sh"
  mkdir -p "${WORK}/mutants"
  cp -f "${GATE}" "${MUTANT_PATH}"
  chmod +x "${MUTANT_PATH}"
  MUTATION_APPLIED=1
  local expr before after
  for expr in "$@"; do
    before="$(file_digest "${MUTANT_PATH}")"
    if ! sed -i "${expr}" "${MUTANT_PATH}" 2>/dev/null; then
      MUTATION_APPLIED=0
      printf '    mutation "%s": sed rejected the expression: %s\n' "${name}" "${expr}" >&2
      continue
    fi
    after="$(file_digest "${MUTANT_PATH}")"
    if [[ "${before}" == "${after}" ]]; then
      MUTATION_APPLIED=0
      printf '    mutation "%s": sed made no change, so it would prove nothing: %s\n' \
        "${name}" "${expr}" >&2
    fi
  done
  if [[ "${MUTATION_APPLIED}" -eq 1 ]]; then
    MUTATION_COUNT=$((MUTATION_COUNT + 1))
  fi
}

# A mutation test: the mutated gate must go red on a GOOD artifact, and it must go
# red for the specific assertion the mutation targets.
mutation_test() {
  local name="$1" tag="$2"
  shift 2
  apply_mutation "${name}" "$@"
  if [[ "${MUTATION_APPLIED}" -ne 1 ]]; then
    fail "mutation ${name}: the mutation did not apply, so nothing was proven"
    return 0
  fi
  bash -n "${MUTANT_PATH}" 2>/dev/null || {
    fail "mutation ${name}: the mutated gate is not valid bash"
    return 0
  }
  run_gate "mut-${name}" "${MUTANT_PATH}"
  assert_red "mutation ${name}: inverted assertion turns a good artifact red as ${tag}" "${tag}"
}

# A scenario test: the UNMUTATED gate must go red on a broken input, naming the
# assertion that is supposed to catch it.
scenario_test() {
  local name="$1" tag="$2"
  SCENARIO_COUNT=$((SCENARIO_COUNT + 1))
  run_gate "sc-${name}" "${GATE}"
  assert_red "scenario ${name}: broken input is caught as ${tag}" "${tag}"
}

# A mutation that only BITES on broken input.
#
# Assertions like the launch deadline, the render deadline, or "the extractor
# failed" are unreachable while the artifact is good -- the code path is never
# entered -- so a mutation on a good artifact cannot fire, and pretending
# otherwise is how you get a mutation table that proves nothing. The proof that
# such a check is load-bearing is that DISABLING it makes the broken input stop
# being reported as `${tag}`.
#
# The pristine broken run is repeated here on purpose. If the fixture has
# drifted so that it no longer produces `tag`, this fails before the mutation is
# applied, instead of reporting a green mutation against a run that never had
# the property to begin with.
mutation_on_broken() {
  local name="$1" tag="$2"
  shift 2
  run_gate "sc-mut-${name}-pristine" "${GATE}"
  if [[ "${LAST_STATUS}" -eq 0 ]] \
    || ! printf '%s\n' "${LAST_OUT}" | grep -q "FAIL assertion=${tag}:"; then
    fail "mutation ${name}: the pristine run on the broken input did not report ${tag}, so there is nothing for the mutation to prove"
    return 0
  fi
  apply_mutation "${name}" "$@"
  if [[ "${MUTATION_APPLIED}" -ne 1 ]]; then
    fail "mutation ${name}: the mutation did not apply, so nothing was proven"
    return 0
  fi
  bash -n "${MUTANT_PATH}" 2>/dev/null || {
    fail "mutation ${name}: the mutated gate is not valid bash"
    return 0
  }
  run_gate "mut-${name}" "${MUTANT_PATH}"
  if printf '%s\n' "${LAST_OUT}" | grep -q "FAIL assertion=${tag}:"; then
    fail "mutation ${name}: the broken input is STILL reported as ${tag} after the check was disabled, so that check is not what detected it"
  else
    pass "mutation ${name}: disabling the ${tag} check removes ${tag} from the broken-input run (mutant exit ${LAST_STATUS})"
    MUTATION_COUNT=$((MUTATION_COUNT + 1))
  fi
}

# A mutation on a RECORDED value rather than on a verdict.
#
# Some of this gate's checks are warnings by design -- the AppImage's bare
# `Exec=` name is recorded in the summary and the run stays green on purpose,
# because it is a real packaging defect that is out of scope for this issue.
# For those, "the gate goes red" is not available as a proof. What IS available,
# and is still a real proof, is that the recorded value MOVES when the check that
# produces it is disabled: `appimage_desktop_exec_resolves=no` has to become
# `yes`. Both directions are asserted, so a mutation that fails to apply -- or a
# value that was a hard-coded string rather than a computed one -- cannot pass.
mutation_flips_evidence() {
  local name="$1" before="$2" after="$3"
  shift 3
  local evdir
  run_gate "mut-${name}-pristine" "${GATE}"
  evdir="$(evidence_dir_for "mut-${name}-pristine")"
  if ! grep -qR -I --include='*.txt' --include='*.log' -- "${before}" "${evdir}" 2>/dev/null; then
    fail "mutation ${name}: the pristine run did not record '${before}', so there is nothing for the mutation to move"
    return 0
  fi
  apply_mutation "${name}" "$@"
  if [[ "${MUTATION_APPLIED}" -ne 1 ]]; then
    fail "mutation ${name}: the mutation did not apply, so nothing was proven"
    return 0
  fi
  bash -n "${MUTANT_PATH}" 2>/dev/null || {
    fail "mutation ${name}: the mutated gate is not valid bash"
    return 0
  }
  run_gate "mut-${name}" "${MUTANT_PATH}"
  evdir="$(evidence_dir_for "mut-${name}")"
  if grep -qR -I --include='*.txt' --include='*.log' -- "${after}" "${evdir}" 2>/dev/null; then
    pass "mutation ${name}: disabling the check moves the recorded value from '${before}' to '${after}'"
    MUTATION_COUNT=$((MUTATION_COUNT + 1))
  else
    fail "mutation ${name}: the mutated run did not record '${after}', so the recorded value is not produced by the check this mutation disabled"
  fi
}

reset_env() {
  unset TEST_POLL TEST_LAUNCH_TIMEOUT TEST_RENDER_TIMEOUT TEST_TREE_MODE \
    TEST_ID_MODE TEST_ID_X TEST_ID_Y TEST_ROOT_W TEST_ROOT_H TEST_ROOT_MODE \
    TEST_COLOURS \
    TEST_SETTLE_DIFF TEST_COMPARE_GARBAGE TEST_COMPARE_SETTLE_GARBAGE \
    TEST_DEB_TEMPLATE TEST_DEB_CONTROL \
    TEST_DEB_X_FAIL TEST_DEB_F_MISSING TEST_APPIMAGE_TEMPLATE \
    TEST_APPIMAGE_EXTRACT_FAIL TEST_APP_BEHAVIOUR TEST_IMPORT_SINK \
    TEST_GATE_TIMEOUT TEST_SETTLE_SECONDS 2>/dev/null || true
  unset FAKE_XWININFO_TREE_MODE FAKE_XWININFO_ID_MODE 2>/dev/null || true
  build_farm
  unset LINUX_SMOKE_UNDER_XVFB DISPLAY 2>/dev/null || true
  # Cleared so a run that follows a reset without building a fixture first fails
  # loudly instead of gating a stale artifact directory from an earlier scenario.
  ARTIFACT_SRC=""
}

printf '# %s\n' "linux_release_artifact_smoke.sh structural suite (issue #98)"
printf '# gate: %s\n' "${GATE}"

# ---------------------------------------------------------------------------
# 0. The gate is well formed
# ---------------------------------------------------------------------------
reset_env
make_elf_fixture

bash -n "${GATE}" 2>/dev/null
check "the gate parses as bash" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning "${GATE}" >/dev/null 2>&1
  check "the gate is shellcheck-clean at --severity=warning" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"
else
  printf '# shellcheck not available; skipping the lint assertion (not a pass)\n'
fi

# ---------------------------------------------------------------------------
# 1. The happy path
# ---------------------------------------------------------------------------
make_good_artifacts "${WORK}/good" ok
run_gate happy "${GATE}"
assert_green "a well-formed AppImage + .deb pair passes both legs"
assert_evidence_contains "evidence records the appimage window geometry" \
  "appimage_window_geometry=1280x720+0+0" happy
assert_evidence_contains "evidence records the deb leg completing" \
  "result=pass" happy
assert_evidence_contains "evidence records the recorded distinct-colour count" \
  "appimage_colours=500" happy
assert_evidence_contains "the AppImage's bare-name desktop Exec is reported as unresolved" \
  "appimage_desktop_exec_resolves=no" happy
# Asserted against the recorded xvfb-run ARGUMENTS, not against the evidence
# directory. The evidence directory contains `xvfb_server_args=-screen 0
# 1280x800x24 ...` because the gate records the string it *intends* to pass, so
# grepping the evidence for it matched the gate's own constant and would have
# gone green even if the gate passed something else to xvfb-run entirely. The
# fake xvfb-run writes the argv it was actually handed, one token per line, and
# the gate passes the whole `--server-args=...` value as ONE token -- so the
# needle is that single token, matched as a fixed string.
if grep -qxF -- '--server-args=-screen 0 1280x800x24 -nolisten tcp' \
  "${WORK}/xvfb-args-happy.txt" 2>/dev/null; then
  pass "the gate asked Xvfb for the 1280x800x24 screen it asserts against"
else
  fail "the gate asked Xvfb for the 1280x800x24 screen it asserts against (recorded args: $(tr '\n' ' ' <"${WORK}/xvfb-args-happy.txt" 2>/dev/null))"
fi

# The screenshots must be named so a human (or a dashboard) can tell which
# platform and which leg each one came from.
missing=""
for f in linux-smoke-happy-appimage-root.png linux-smoke-happy-appimage-window.png \
  linux-smoke-happy-deb-root.png linux-smoke-happy-deb-window.png; do
  [[ -s "${WORK}/ev-happy/${f}" ]] || missing="${missing} ${f}"
done
check "both legs leave named root and window screenshots as evidence${missing:+ (missing:${missing})}" \
  "$([[ -z "${missing}" ]] && echo 1 || echo 0)"

# A second run must not depend on state left by the first: "cold" is the claim, so
# it is tested by running twice into the same place and requiring the same result.
run_gate happy2 "${GATE}"
assert_green "the gate is re-runnable: a second cold launch also passes"

# ---------------------------------------------------------------------------
# 2. Scenarios: a broken input must be caught by the assertion that claims it
# ---------------------------------------------------------------------------
reset_env
make_good_artifacts "${WORK}/s1" exit-immediately
scenario_test "app-dies-at-launch" app_exited_during_launch

reset_env
make_good_artifacts "${WORK}/s2" die-late
TEST_LAUNCH_TIMEOUT=8
# The app has to be alive when the render finishes and dead by the survival
# check that immediately follows it -- a window of a couple of milliseconds. A
# pure timer cannot be aimed at that, and this scenario was flaky for exactly
# that reason: it passed or failed depending on how fast the machine happened to
# be, which is not a test.
#
# `LINUX_SMOKE_SETTLE_SECONDS=3` is what makes it deterministic, and it is not
# padding. The stability loop sleeps once per attempt, and it has NO liveness
# check inside it -- by design, because the survival check belongs after the
# stability proof, not inside it. So a three-second settle sleep is a
# three-second window in which the app's own one-second self-kill lands with the
# render already succeeded. The app is guaranteed to die during the sleep and
# guaranteed to still have been alive for the render: the two facts are separated
# by seconds, not by microseconds. The stability verdict is unaffected (a settled
# screen diffs to 0 however long you wait) and the assertion that fires is the
# one this scenario is about.
TEST_SETTLE_SECONDS=3
scenario_test "app-dies-after-first-frame" app_exited_after_first_frame

reset_env
make_good_artifacts "${WORK}/s3" crash-log
scenario_test "native-crash-signature" crash_signature

reset_env
make_good_artifacts "${WORK}/s4" panic-log
scenario_test "rust-panic-in-galleryd" crash_signature

reset_env
make_good_artifacts "${WORK}/s5" crash-on-term
scenario_test "app-dies-with-a-signal-class-status-at-teardown" app_crashed_at_teardown

reset_env
make_good_artifacts "${WORK}/s6" no-start-line
TEST_TREE_MODE=empty
TEST_LAUNCH_TIMEOUT=3
TEST_POLL=1
scenario_test "no-window-ever" launch_timeout

reset_env
make_good_artifacts "${WORK}/s7" ok
TEST_TREE_MODE=small
TEST_LAUNCH_TIMEOUT=3
TEST_POLL=1
scenario_test "window-present-but-tiny" window_area_too_small

reset_env
make_good_artifacts "${WORK}/s8" ok
TEST_ID_MODE=unmapped
scenario_test "window-not-viewable" window_not_visible

reset_env
make_good_artifacts "${WORK}/s9" ok
TEST_ID_MODE=broken
scenario_test "window-query-fails" window_geometry_unreadable

reset_env
make_good_artifacts "${WORK}/s10" ok
TEST_ID_MODE=no-geometry
scenario_test "window-query-returns-no-geometry" window_geometry_unreadable

reset_env
make_good_artifacts "${WORK}/s11" ok
TEST_TREE_MODE=broken
scenario_test "xwininfo-itself-is-broken" window_probe_failed

# A root query that answers but reports no geometry. This has to be its own
# fake mode: making the whole of `xwininfo -root` fail also breaks
# `xwininfo -version`, which the gate reads for the evidence summary, and the
# run then reports root_geometry for the wrong reason (a claim the test made by
# accident until the two modes were split).
reset_env
make_good_artifacts "${WORK}/s11b" ok
TEST_ROOT_MODE=no-geometry
scenario_test "root-query-returns-no-geometry" root_geometry

reset_env
make_good_artifacts "${WORK}/s12" ok
# `id_mode=forced` is required, not decorative. The fake `xwininfo -id` answers
# about the window it was asked about by looking the id up in the same tree the
# probe read, so a TEST_ID_X/TEST_ID_Y override is IGNORED unless the forced mode
# is selected. Without it this scenario silently tested nothing: the forced
# position was discarded, the window came back at the origin, and the run stayed
# green.
TEST_ID_MODE=forced
TEST_ID_X=10000
TEST_ID_Y=10000
scenario_test "window-mostly-offscreen" window_offscreen

reset_env
make_good_artifacts "${WORK}/s13" ok
TEST_COLOURS=1
TEST_RENDER_TIMEOUT=2
TEST_POLL=1
scenario_test "blank-frame" render_not_complex

reset_env
make_good_artifacts "${WORK}/s14" ok
TEST_COLOURS=garbage
scenario_test "colour-metric-returns-garbage" render_colour_probe_failed

reset_env
make_good_artifacts "${WORK}/s15" ok
TEST_SETTLE_DIFF=500
scenario_test "screen-never-settles" render_unsettled

# A diff metric that stops answering, but only for the settle comparison: the
# gate's self-check runs first and a globally-broken `compare` is caught THERE
# (asserted separately as s41). This scenario exists to prove the render-time
# guard -- `pixel_diff` returning non-numeric is a failure, not "0 differing
# pixels" -- actually fires, which a globally-broken tool could never reach.
reset_env
make_good_artifacts "${WORK}/s16" ok
TEST_COMPARE_SETTLE_GARBAGE=1
scenario_test "diff-metric-returns-garbage-at-render-time" render_unsettled

# And the global case, asserted as what it really is: the self-check catching it.
reset_env
make_good_artifacts "${WORK}/s16b" ok
TEST_COMPARE_GARBAGE=1
scenario_test "diff-metric-returns-garbage-everywhere" metric_selfcheck_settle

# A root far larger than the window: the area floor is relative to the root, so
# this is the same assertion the "too small window" scenario reaches by a
# different route. It is kept because it proves the floor is computed against the
# REPORTED root rather than against the window.
reset_env
make_good_artifacts "${WORK}/s17" ok
TEST_ROOT_W=4000
TEST_ROOT_H=4000
scenario_test "window-too-small-for-a-larger-root" window_area_too_small

reset_env
make_good_artifacts "${WORK}/s18" ok
TEST_APPIMAGE_EXTRACT_FAIL=1
scenario_test "appimage-payload-cannot-be-extracted" appimage_payload_extract

# The AppImage is too small to be one.
reset_env
make_good_artifacts "${WORK}/s19" ok
: >"${WORK}/s19/out/photo-organizer-linux-x86_64-v0.1.7.AppImage"
TEST_APPIMAGE_TEMPLATE="${WORK}/s19/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s19/deb-payload"
TEST_DEB_CONTROL="${WORK}/s19/control"
scenario_test "appimage-too-small" appimage_size

# Truncated, but still comfortably over the 1 MiB size floor, so `appimage_size`
# cannot be what catches it. What has to catch it is the extractor: the squashfs
# image is the tail of the file, so a cut artifact does not mount.
reset_env
make_good_artifacts "${WORK}/s19b" ok
truncate -s 1100000 "${WORK}/s19b/out/photo-organizer-linux-x86_64-v0.1.7.AppImage"
scenario_test "appimage-truncated-but-still-oversized" appimage_payload_extract

# The payload is missing the engine binary.
reset_env
make_good_artifacts "${WORK}/s20" ok
make_appimage_template "${WORK}/s20/appimage-payload" omit=private_gallery_app
TEST_APPIMAGE_TEMPLATE="${WORK}/s20/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s20/deb-payload"
TEST_DEB_CONTROL="${WORK}/s20/control"
scenario_test "appimage-payload-missing-engine" appimage_layout_missing

# The payload binary is not an ELF at all (truncated, LFS pointer, text mangled).
reset_env
make_good_artifacts "${WORK}/s21" ok
make_appimage_template "${WORK}/s21/appimage-payload" not_elf=1
TEST_APPIMAGE_TEMPLATE="${WORK}/s21/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s21/deb-payload"
TEST_DEB_CONTROL="${WORK}/s21/control"
scenario_test "appimage-payload-not-an-elf" appimage_payload_not_elf

# A valid ELF that is not this architecture. Reached only because require_elf
# reads e_machine, not just the magic: with the magic alone this artifact was a
# pass, and it is exactly the artifact the runner cannot execute.
reset_env
make_good_artifacts "${WORK}/s21b" ok
make_appimage_template "${WORK}/s21b/appimage-payload" wrong_arch=1
scenario_test "appimage-payload-is-the-wrong-architecture" appimage_payload_not_elf

reset_env
make_good_artifacts "${WORK}/s22" ok
# not_elf makes private_gallery_app a text file AND leaves it non-executable
# (the fixture copies it without chmod +x). The layout check runs before the
# exec-bit check, so this scenario reports the ELF defect, not the permission
# one.
make_deb_template "${WORK}/s22/deb-payload" not_elf=1
TEST_APPIMAGE_TEMPLATE="${WORK}/s22/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s22/deb-payload"
TEST_DEB_CONTROL="${WORK}/s22/control"
scenario_test "deb-engine-not-an-elf" deb_binary_not_elf

# The same wrong-architecture defect on the .deb leg.
reset_env
make_good_artifacts "${WORK}/s22c" ok
make_deb_template "${WORK}/s22c/deb-payload" wrong_arch=1
TEST_APPIMAGE_TEMPLATE="${WORK}/s22c/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s22c/deb-payload"
TEST_DEB_CONTROL="${WORK}/s22c/control"
scenario_test "deb-engine-is-the-wrong-architecture" deb_binary_not_elf

# The exec-bit check on its own: a present, ELF, but non-executable engine binary.
reset_env
make_good_artifacts "${WORK}/s22b" ok
make_deb_template "${WORK}/s22b/deb-payload" not_exec=opt/photo-organizer/private_gallery_app
TEST_APPIMAGE_TEMPLATE="${WORK}/s22b/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s22b/deb-payload"
TEST_DEB_CONTROL="${WORK}/s22b/control"
scenario_test "deb-engine-not-executable" deb_not_executable

reset_env
make_good_artifacts "${WORK}/s23" ok
make_deb_template "${WORK}/s23/deb-payload" omit=opt/photo-organizer/galleryd
TEST_APPIMAGE_TEMPLATE="${WORK}/s23/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s23/deb-payload"
TEST_DEB_CONTROL="${WORK}/s23/control"
scenario_test "deb-missing-daemon" deb_layout_missing

reset_env
make_good_artifacts "${WORK}/s24" ok
make_deb_template "${WORK}/s24/deb-payload" not_exec=opt/photo-organizer/AppRun
TEST_APPIMAGE_TEMPLATE="${WORK}/s24/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s24/deb-payload"
TEST_DEB_CONTROL="${WORK}/s24/control"
scenario_test "deb-apprun-not-executable" deb_not_executable

reset_env
make_good_artifacts "${WORK}/s25" ok
make_deb_template "${WORK}/s25/deb-payload" link_target=/opt/photo-organizer/does-not-exist
TEST_APPIMAGE_TEMPLATE="${WORK}/s25/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s25/deb-payload"
TEST_DEB_CONTROL="${WORK}/s25/control"
scenario_test "deb-usr-bin-symlink-dangles" deb_symlink_invalid

reset_env
make_good_artifacts "${WORK}/s26" ok
make_deb_template "${WORK}/s26/deb-payload" link_target=opt/photo-organizer/AppRun
TEST_APPIMAGE_TEMPLATE="${WORK}/s26/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s26/deb-payload"
TEST_DEB_CONTROL="${WORK}/s26/control"
scenario_test "deb-usr-bin-symlink-is-relative" deb_symlink_invalid

reset_env
make_good_artifacts "${WORK}/s27" ok
make_deb_template "${WORK}/s27/deb-payload" link_target=none
TEST_APPIMAGE_TEMPLATE="${WORK}/s27/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s27/deb-payload"
TEST_DEB_CONTROL="${WORK}/s27/control"
scenario_test "deb-usr-bin-symlink-missing" deb_symlink_missing

reset_env
make_good_artifacts "${WORK}/s28" ok
make_deb_template "${WORK}/s28/deb-payload" deb_exec=photo-organizer
TEST_APPIMAGE_TEMPLATE="${WORK}/s28/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s28/deb-payload"
TEST_DEB_CONTROL="${WORK}/s28/control"
scenario_test "deb-desktop-exec-is-a-bare-name" deb_exec_unresolvable

reset_env
make_good_artifacts "${WORK}/s29" ok
make_deb_template "${WORK}/s29/deb-payload" deb_exec=/opt/photo-organizer/NotHere
TEST_APPIMAGE_TEMPLATE="${WORK}/s29/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s29/deb-payload"
TEST_DEB_CONTROL="${WORK}/s29/control"
scenario_test "deb-desktop-exec-points-nowhere" deb_exec_unresolvable

reset_env
make_good_artifacts "${WORK}/s30" ok
make_deb_template "${WORK}/s30/deb-payload" icon=photo-organizer-other
TEST_APPIMAGE_TEMPLATE="${WORK}/s30/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s30/deb-payload"
TEST_DEB_CONTROL="${WORK}/s30/control"
scenario_test "deb-desktop-icon-not-installed" deb_icon_missing

reset_env
make_good_artifacts "${WORK}/s31" ok
make_control "${WORK}/s31/control" Version
TEST_APPIMAGE_TEMPLATE="${WORK}/s31/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/s31/deb-payload"
TEST_DEB_CONTROL="${WORK}/s31/control"
scenario_test "deb-control-missing-version" deb_control_missing

reset_env
make_good_artifacts "${WORK}/s32" ok
TEST_DEB_X_FAIL=1
scenario_test "deb-cannot-be-unpacked" deb_extract_failed

# A zero-byte .deb is the other truncation, and the one a real dpkg-deb rejects
# outright. Asserted separately from the injected-extractor-failure above: that
# one proves the gate reacts to an extractor that says no, this one proves the
# gate is fed an artifact that any extractor must say no to.
reset_env
make_good_artifacts "${WORK}/s32b" ok
: >"${WORK}/s32b/out/photo-organizer_0.1.7_amd64.deb"
scenario_test "deb-truncated-to-zero-bytes" deb_extract_failed

reset_env
make_good_artifacts "${WORK}/s33" ok
rm -f "${FARM}/dpkg-deb" "${FARM}/bsdtar"
scenario_test "no-way-to-unpack-a-deb" deb_extract_failed

# The bsdtar fallback path must be exercised, not just written.
reset_env
make_good_artifacts "${WORK}/s34" ok
rm -f "${FARM}/dpkg-deb"
run_gate s34 "${GATE}"
assert_green "the bsdtar fallback extractor is used when dpkg-deb is absent"
assert_evidence_contains "the fallback extractor is named in the evidence" \
  "deb_extractor=bsdtar" s34

reset_env
make_good_artifacts "${WORK}/s35" ok
rm -f "${FARM}/xwininfo"
scenario_test "xwininfo-missing" required_tool

reset_env
make_good_artifacts "${WORK}/s36" ok
rm -f "${FARM}/xauth"
scenario_test "xauth-missing" xvfb_tooling

reset_env
make_good_artifacts "${WORK}/s37" ok
rm -f "${FARM}/xvfb-run"
scenario_test "xvfb-run-missing" xvfb_tooling

reset_env
make_good_artifacts "${WORK}/s38" ok
rm -f "${FARM}/import" "${FARM}/convert" "${FARM}/compare"
scenario_test "imagemagick-missing" imagemagick_tooling

# A Dart error on a headless runner must NOT be a gate failure, or the gate would
# fail for reasons that have nothing to do with the artifact.
reset_env
make_good_artifacts "${WORK}/s39" dart-error
run_gate s39 "${GATE}"
assert_green "a Dart 'Unhandled exception' is recorded but does not fail the gate"
assert_evidence_contains "the Dart error is captured as evidence" \
  "Unhandled exception" s39

# The metric self-check must fire when the tool is not answering, rather than
# letting a dead metric tool produce a silent pass.
reset_env
make_good_artifacts "${WORK}/s40" ok
cat >"${FARM}/convert" <<'DEAD_EOF'
#!/usr/bin/env bash
# A convert that produces no files and prints nothing: every count is empty.
exit 0
DEAD_EOF
chmod +x "${FARM}/convert"
scenario_test "imagemagick-counts-nothing" metric_selfcheck_colours

reset_env
make_good_artifacts "${WORK}/s41" ok
cat >"${FARM}/compare" <<'DEAD_EOF'
#!/usr/bin/env bash
# A compare that prints nothing at all: every diff count is empty.
exit 0
DEAD_EOF
chmod +x "${FARM}/compare"
scenario_test "imagemagick-diffs-nothing" metric_selfcheck_settle

# Exactly one of each artifact, and both required.
reset_env
make_good_artifacts "${WORK}/s42" ok
rm -f "${WORK}/s42/out/"*.AppImage
scenario_test "appimage-missing" artifact_discovery

reset_env
make_good_artifacts "${WORK}/s43" ok
rm -f "${WORK}/s43/out/"*.deb
scenario_test "deb-missing" artifact_discovery

reset_env
make_good_artifacts "${WORK}/s44" ok
cp -f "${WORK}/s44/out/photo-organizer-linux-x86_64-v0.1.7.AppImage" \
  "${WORK}/s44/out/second.AppImage"
scenario_test "two-appimages" artifact_discovery

# A non-integer threshold must be a usage error, never a silently-zero one.
reset_env
make_good_artifacts "${WORK}/s45" ok
LAST_OUT="$(env -i PATH="${FARM}" HOME="${WORK}" TMPDIR="${WORK}" \
  LINUX_SMOKE_NAME=s45 LINUX_SMOKE_EVIDENCE_DIR="${WORK}/ev-s45" \
  LINUX_SMOKE_MIN_COLOURS=lots \
  "${GATE}" "${WORK}/s45/out" 2>&1)"
LAST_STATUS=$?
check "a non-integer threshold is rejected as a usage error, not read as 0" \
  "$([[ ${LAST_STATUS} -eq 2 ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 3. Mutations: an inverted assertion must go red on a GOOD artifact
# ---------------------------------------------------------------------------
# Each mutation flips one comparison so the gate fails on a well-formed artifact.
# If the mutated gate stays green, the assertion was dead code.

MUT_GOOD_DIR="${WORK}/mutgood"
make_good_artifacts "${MUT_GOOD_DIR}" ok

mut() {
  local name="$1" tag="$2"
  shift 2
  local dir
  dir="${WORK}/mut-run-${name}"
  make_good_artifacts "${dir}" ok
  TEST_APPIMAGE_TEMPLATE="${dir}/appimage-payload"
  TEST_DEB_TEMPLATE="${dir}/deb-payload"
  TEST_DEB_CONTROL="${dir}/control"
  mutation_test "${name}" "${tag}" "$@"
}

reset_env
mut "appimage-size" appimage_size \
  's/if ((appimage_size < 1048576)); then/if ((appimage_size < 999999999)); then/'

reset_env
mut "appimage-exec-bit" appimage_executable_bit \
  's/if \[\[ ! -x "${APPIMAGE_RUN}" \]\]; then/if [[ -x "${APPIMAGE_RUN}" ]]; then/'

reset_env
mut "appimage-payload-dir" appimage_payload_extract \
  's/if \[\[ ! -d "${PAYLOAD}" \]\]; then/if [[ -d "${PAYLOAD}" ]]; then/'

reset_env
mut "appimage-layout" appimage_layout_missing \
  's|^  "galleryd" \\$|  "galleryd-not-really" \\|'

reset_env
mut "appimage-payload-exec" appimage_not_executable \
  's|if \[\[ ! -x "${PAYLOAD}/${required_rel}" \]\]; then|if [[ -x "${PAYLOAD}/${required_rel}" ]]; then|'

reset_env
mut "appimage-payload-elf" appimage_payload_not_elf \
  's/if \[\[ "${magic}" != "7f454c46" \]\]; then/if [[ "${magic}" == "7f454c46" ]]; then/'

reset_env
# The architecture half of require_elf, which the magic half cannot reach: the
# mutant still rejects non-ELF files and still rejects wrong EI_CLASS, so if this
# only bites because of the fixture rather than the mutation the suite would show
# it immediately.
mut "engine-architecture" appimage_payload_not_elf \
  's/if \[\[ "${machine}" != "3e00" \]\]; then/if [[ "${machine}" == "3e00" ]]; then/'

reset_env
# The hard `appimage_desktop_exec_unresolvable` failure is only reached when the
# desktop entry names an ABSOLUTE path that is not in the payload. The good
# fixture carries the repo's real bare `Exec=photo-organizer`, which is the
# recorded packaging warning, not this failure -- so the fixture is rebuilt with
# a broken absolute Exec and the `-x` test is then disabled to show that it is
# what caught it.
make_good_artifacts "${WORK}/mut-appimage-desktop-exec-abs" ok
make_appimage_template "${WORK}/mut-appimage-desktop-exec-abs/appimage-payload" \
  desktop_exec=/opt/photo-organizer/does-not-exist
TEST_APPIMAGE_TEMPLATE="${WORK}/mut-appimage-desktop-exec-abs/appimage-payload"
mutation_on_broken "appimage-desktop-exec-abs" appimage_desktop_exec_unresolvable \
  's/if \[\[ -x "${PAYLOAD}${appimage_desktop_exec}" \]\]; then/if [[ -n "${appimage_desktop_exec}" ]]; then/'

reset_env
# The bare-name case is a RECORDED warning, not a verdict, so it is proven by
# showing the recorded value moves. It is proven in the "resolves" direction
# because that is the only one available: the recorded failure text is a
# constant, so forcing the check false on the DEFAULT fixture just re-records
# the same "no". Here the fixture's bare `Exec=AppRun` genuinely resolves, the
# pristine run records `yes`, and disabling the `-x` test turns that into `no`.
# With the `resolves=no` assertion on the happy run, both recorded values are
# then proven computed rather than hard-coded.
make_good_artifacts "${WORK}/mut-appimage-desktop-exec-warn" ok
make_appimage_template "${WORK}/mut-appimage-desktop-exec-warn/appimage-payload" \
  desktop_exec=AppRun
TEST_APPIMAGE_TEMPLATE="${WORK}/mut-appimage-desktop-exec-warn/appimage-payload"
TEST_DEB_TEMPLATE="${WORK}/mut-appimage-desktop-exec-warn/deb-payload"
TEST_DEB_CONTROL="${WORK}/mut-appimage-desktop-exec-warn/control"
mutation_flips_evidence "appimage-desktop-exec-warn" \
  "appimage_desktop_exec_resolves=yes" "appimage_desktop_exec_resolves=no" \
  's%if \[\[ -x "${PAYLOAD}/${appimage_desktop_exec}" || -x "${PAYLOAD}/usr/bin/${appimage_desktop_exec}" \]\]; then%if false; then%'

reset_env
mut "artifact-discovery-appimage" artifact_discovery \
  's/if ((\${#APPIMAGES\[@\]} == 0)); then/if ((\${#APPIMAGES[@]} > 0)); then/'

reset_env
mut "artifact-discovery-deb" artifact_discovery \
  's/if ((\${#DEBS\[@\]} == 0)); then/if ((\${#DEBS[@]} > 0)); then/'

reset_env
# Raise the size floor above every window in the good fixture, so the probe sees
# top-level windows and rejects all of them. This is the assertion's real
# question -- "are the windows we found big enough to be the app?" -- and the
# replacement is load-bearing in a way the old expression was not: the previous
# `((area >= min_area))` -> `((area < min_area))` swap made the probe select the
# 10x10 helper window instead, which is `window_offscreen`, a different
# assertion. `window_too_small`'s reachability is also covered directly by the
# `window-present-but-tiny` scenario.
mut "window-area-floor" window_area_too_small \
  's/min_area=$((ROOT_W \* ROOT_H \* LINUX_SMOKE_MIN_WINDOW_PERCENT \/ 100))/min_area=$((ROOT_W * ROOT_H * 999))/'

reset_env
mut "window-map-state" window_not_visible \
  's/if \[\[ "${state}" != "IsViewable" \]\]; then/if [[ "${state}" == "IsViewable" ]]; then/'

reset_env
mut "window-offscreen" window_offscreen \
  's/if ((visible < ROOT_W \* ROOT_H \* LINUX_SMOKE_MIN_WINDOW_PERCENT \/ 100)); then/if ((visible > ROOT_W * ROOT_H * LINUX_SMOKE_MIN_WINDOW_PERCENT \/ 100)); then/'

reset_env
mut "window-probe-broken" window_probe_failed \
  's/if ! out="$(xwininfo -root -tree 2>&1)"; then/if out="$(xwininfo -root -tree 2>\&1)"; then/'

reset_env
mut "window-query-broken" window_geometry_unreadable \
  's/if ! out="$(xwininfo -id "${id}" 2>&1)"; then/if out="$(xwininfo -id "${id}" 2>\&1)"; then/'

reset_env
mut "render-colour-floor" render_not_complex \
  's/if ((colours >= LINUX_SMOKE_MIN_COLOURS)); then/if ((colours < LINUX_SMOKE_MIN_COLOURS)); then/'

reset_env
# Deliberately `&& false`, NOT the obvious-looking `-s` -> `-n` swap.
# `capture_root` ends in a POSITIVE check -- the capture must be a non-empty
# file -- and the fake `import` really does write one, so swapping `-s` for `-n`
# leaves the run exactly as green as it was. That "mutation" would have passed
# for the wrong reason and taught us nothing. The question actually worth asking
# is whether the render verdict DEPENDS on this check at all, and only forcing it
# false answers that.
mut "render-capture" render_capture_failed \
  's/^  \[\[ -s "${out_png}" \]\]$/  [[ -n "${out_png}x" ]] \&\& false/'

reset_env
mut "render-settle-bound" render_unsettled \
  's/if ((diff <= LINUX_SMOKE_MAX_UNSETTLED_PIXELS)); then/if ((diff > LINUX_SMOKE_MAX_UNSETTLED_PIXELS)); then/'

reset_env
mut "render-colour-garbage" render_colour_probe_failed \
  's/if \[\[ ! "${n}" =~ \^\[0-9\]+\$ \]\]; then/if [[ ! "${n}" =~ ^never-ever$ ]]; then/'

reset_env
mut "app-exits-at-launch" app_exited_during_launch \
  's/^    if ! kill -0 "${APP_PID}" 2>\/dev\/null; then$/    if kill -0 "${APP_PID}" 2>\/dev\/null; then/'

reset_env
mut "app-exits-after-frame" app_exited_after_first_frame \
  's/^  if ! kill -0 "${APP_PID}" 2>\/dev\/null; then$/  if kill -0 "${APP_PID}" 2>\/dev\/null; then/'

reset_env
# Invert the teardown guard so that a perfectly normal `kill_tree` exit (status
# 143) now fails the gate.
mut "app-teardown-status" app_crashed_at_teardown \
  's/^  if \[\[ "${WAIT_STATUS}" != "143" && "${WAIT_STATUS}" != "137" && "${WAIT_STATUS}" != "0" \]\]; then$/  if true; then/'

reset_env
mut "crash-signature-scan" crash_signature \
  "s/hits=\"\$(grep -Ein \"\${re}\" \"\${file}\" || true)\"/hits=\"\$(grep -Ein '.' \"\${file}\" || true)\"/"

reset_env
# The launch deadline only fires when NO window ever appears, so it is
# unreachable on a good artifact and cannot be proven by a good-artifact
# mutation. It is proven on broken input instead: with the deadline branch
# disabled the empty-tree run does not merely stop reporting launch_timeout, it
# never terminates -- the harness kills it at 10s (exit 124) and the tag is
# gone. `LAUNCH_TIMEOUT=3` keeps the pristine run honest and fast; it has to be
# well under the harness wall clock or the pristine run would itself be killed.
make_good_artifacts "${WORK}/mut-launch-timeout" ok
TEST_TREE_MODE=empty
TEST_LAUNCH_TIMEOUT=3
TEST_POLL=1
TEST_GATE_TIMEOUT=10
mutation_on_broken "launch-timeout" launch_timeout \
  's/if ((SECONDS >= window_deadline)); then/if false; then/'

reset_env
# Same shape, for the render deadline: with a flat frame and the deadline
# disabled the render loop spins forever instead of failing.
make_good_artifacts "${WORK}/mut-render-timeout" ok
TEST_COLOURS=1
TEST_RENDER_TIMEOUT=3
TEST_POLL=1
TEST_GATE_TIMEOUT=10
mutation_on_broken "render-timeout" render_not_complex \
  's/if ((SECONDS >= render_deadline)); then/if false; then/'

reset_env
mut "metric-selfcheck-colours" metric_selfcheck_colours \
  's/if \[\[ "${k_solid}" != "1" || "${k_two}" != "2" \]\]; then/if [[ "${k_solid}" == "1" || "${k_two}" == "2" ]]; then/'

reset_env
mut "metric-selfcheck-settle" metric_selfcheck_settle \
  's/if \[\[ ! "${cross_ae}" =~ \^\[0-9\]+\$ \]\] || ((cross_ae <= 0)); then/if [[ ! "${cross_ae}" =~ ^[0-9]+$ ]] || ((cross_ae >= 0)); then/'

reset_env
mut "required-tool" required_tool \
  's/if ! command -v "$1" >\/dev\/null 2>&1; then/if command -v "$1" >\/dev\/null 2>\&1; then/'

reset_env
mut "xvfb-tooling" xvfb_tooling \
  's/if ! command -v "${t}" >\/dev\/null 2>&1; then/if command -v "${t}" >\/dev\/null 2>\&1; then/'

reset_env
mut "x11-display" x11_display \
  's/if \[\[ -z "${DISPLAY:-}" \]\]; then/if [[ -n "${DISPLAY:-}" ]]; then/'

reset_env
mut "imagemagick-tooling" imagemagick_tooling \
  's/if command -v import >\/dev\/null 2>&1 && command -v convert >\/dev\/null 2>&1 \\/if false \&\& command -v convert >\/dev\/null 2>\&1 \\/' \
  's/elif command -v magick >\/dev\/null 2>&1; then/elif false; then/'

reset_env
mut "root-geometry" root_geometry \
  's/if \[\[ -z "${dims}" \]\]; then/if [[ -n "${dims}" ]]; then/'

reset_env
# `deb_extract_failed` has three producers and a good fixture reaches none of
# them, so a good-artifact mutation is impossible here. The first attempt was
# `if command -v dpkg-deb` -> `if false`, which does not fail the gate at all:
# it just selects the bsdtar fallback, which then SUCCEEDS, and the run stays
# green. The dimension that matters is the one the scenario already covers -- the
# no-extractor-at-all path. What has to be proven here is that a failing
# extractor is FATAL, so the broken input is a .deb that cannot be unpacked and
# the mutation makes the failure branch unreachable: the run then dies later and
# honestly, on `deb_layout_missing`, because the extraction directory is empty.
# That is the load-bearing difference -- swallowing the failure still reddens the
# run, but with a different and much less informative reason.
make_good_artifacts "${WORK}/mut-deb-extractor" ok
TEST_DEB_X_FAIL=1
mutation_on_broken "deb-extractor" deb_extract_failed \
  's/if ! dpkg-deb -x "${DEB}"/if false \&\& dpkg-deb -x "${DEB}"/'

reset_env
mut "deb-layout" deb_layout_missing \
  's|^  "opt/photo-organizer/galleryd" \\$|  "opt/photo-organizer/galleryd-not-really" \\|'

reset_env
mut "deb-binary-elf" deb_binary_not_elf \
  's/require_elf "${DEB_ROOT}\/opt\/photo-organizer\/private_gallery_app" deb_binary_not_elf/require_elf "${DEB_ROOT}\/opt\/photo-organizer\/AppRun" deb_binary_not_elf/'

reset_env
mut "deb-symlink-present" deb_symlink_missing \
  's/if \[\[ ! -L "${DEB_LAUNCHER}" \]\]; then/if [[ -L "${DEB_LAUNCHER}" ]]; then/'

reset_env
mut "deb-symlink-absolute" deb_symlink_invalid \
  's/if \[\[ "${deb_link_target}" != \/\* \]\]; then/if [[ "${deb_link_target}" == \/* ]]; then/'

reset_env
mut "deb-symlink-apprun" deb_symlink_invalid \
  's|if \[\[ "${deb_link_target}" != "/opt/photo-organizer/AppRun" \]\]; then|if [[ "${deb_link_target}" != "/opt/photo-organizer/NeverAppRun" ]]; then|'

reset_env
mut "deb-desktop-entry" deb_desktop_entry_missing \
  's/if \[\[ -z "${deb_exec}" \]\]; then/if [[ -n "${deb_exec}" ]]; then/'

reset_env
mut "deb-desktop-exec" deb_exec_unresolvable \
  's/if \[\[ "${deb_exec}" != \/\* \]\]; then/if [[ "${deb_exec}" == \/* ]]; then/'

reset_env
mut "deb-desktop-exec-target" deb_exec_unresolvable \
  's/if \[\[ ! -x "${DEB_ROOT}${deb_exec}" \]\]; then/if [[ -x "${DEB_ROOT}${deb_exec}" ]]; then/'

reset_env
mut "deb-icon" deb_icon_missing \
  's/&& \[\[ ! -f "${DEB_ROOT}\/usr\/share\/icons\/hicolor\/512x512\/apps\/\${deb_icon_name}.png" \]\]; then/\&\& [[ -f "${DEB_ROOT}\/usr\/share\/icons\/hicolor\/512x512\/apps\/${deb_icon_name}.png" ]]; then/'

reset_env
mut "deb-control-present" deb_control_missing \
  's/if \[\[ -z "${deb_pkg}" || -z "${deb_ver}" || -z "${deb_arch}" \]\]; then/if [[ -n "${deb_pkg}" \&\& -n "${deb_ver}" \&\& -n "${deb_arch}" ]]; then/'

reset_env
mut "deb-control-package" deb_control_invalid \
  's/if \[\[ "${deb_pkg}" != "photo-organizer" \]\]; then/if [[ "${deb_pkg}" == "photo-organizer" ]]; then/'

reset_env
mut "deb-control-arch" deb_control_invalid \
  's/if \[\[ "${deb_arch}" != "amd64" \]\]; then/if [[ "${deb_arch}" == "amd64" ]]; then/'

reset_env
mut "deb-control-version" deb_control_invalid \
  's/if \[\[ ! "${deb_ver}" =~ \^\[0-9\]\[0-9A-Za-z.+~:-\]\*\$ \]\]; then/if [[ ! "${deb_ver}" =~ ^ZZZ$ ]]; then/'

# ---------------------------------------------------------------------------
# 4. The suite's own honesty
# ---------------------------------------------------------------------------
MUT_COUNT_BEFORE_NON_APPLY="${MUTATION_COUNT}"
# A mutation runner that cannot fail is a coverage report that means nothing. Prove
# the harness itself detects a mutation that does not apply.
apply_mutation "deliberately-not-present" \
  's/this-string-does-not-exist-anywhere-in-the-gate/whatever/' >/dev/null 2>&1
if [[ "${MUTATION_APPLIED}" -eq 0 ]]; then
  pass "the mutation runner reports a mutation that did not apply as a failure"
else
  fail "the mutation runner accepted a mutation that did not apply"
fi
# The count must not have been incremented by that deliberate no-op, or the
# headline "mutations applied" number over-reports coverage.
if [[ "${MUTATION_COUNT}" -eq "${MUT_COUNT_BEFORE_NON_APPLY}" ]]; then
  pass "a mutation that did not apply is not counted as coverage"
else
  fail "a mutation that did not apply was counted as coverage (${MUT_COUNT_BEFORE_NON_APPLY} -> ${MUTATION_COUNT})"
fi

# And that a mutation lands ON the assertion it claims to target, rather than
# somewhere else in a 1300-line file.
#
# The previous version sed-mutated the `window_not_visible` comparison and then
# asserted the mutated copy did NOT contain the string `render_not_complex`. It
# could never pass: `render_not_complex` is a real assertion name and appears in
# the gate legitimately. Asserting an unrelated assertion's absence proves
# nothing about attribution.
#
# What is worth proving is that a mutation is LOCALISED: exactly one edit, on the
# line it named. So the diff must be one removed line plus one added line, and
# that line must mention the target.
reset_env
MUT_WRONG="${WORK}/mut-wrong/w.sh"
mkdir -p "${WORK}/mut-wrong"
cp -f "${GATE}" "${MUT_WRONG}"
chmod +x "${MUT_WRONG}"
MUT_WRONG_EXPR='s/if \[\[ "${state}" != "IsViewable" \]\]; then/if [[ "${state}" == "IsViewable" ]]; then/'
if ! sed -i "${MUT_WRONG_EXPR}" "${MUT_WRONG}"; then
  fail "the attribution self-test could not apply its own mutation"
else
  mut_diff_txt="$(diff "${GATE}" "${MUT_WRONG}" || true)"
  mut_diff_lines="$(printf '%s\n' "${mut_diff_txt}" | grep -c '^[<>]' || true)"
  if [[ "${mut_diff_lines}" -eq 2 ]] \
    && printf '%s\n' "${mut_diff_txt}" | grep -q '^[<>].*IsViewable'; then
    pass "a mutation changes exactly the one line of the assertion it names"
  else
    fail "a mutation did not stay on the line it named (diff touched ${mut_diff_lines} lines)"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Usage
# ---------------------------------------------------------------------------
"${GATE}" --help >/dev/null 2>&1
check "--help succeeds" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

"${GATE}" >/dev/null 2>&1
check "no arguments is a usage error" "$([[ $? -eq 2 ]] && echo 1 || echo 0)"

"${GATE}" "${WORK}/definitely-not-here" >/dev/null 2>&1
check "a missing artifact directory is a usage error" "$([[ $? -eq 2 ]] && echo 1 || echo 0)"

# The evidence directory must never be empty, because the workflow uploads it
# with `if-no-files-found: error`; a gate that died before writing anything would
# otherwise look like a gate with nothing to report.
reset_env
make_good_artifacts "${WORK}/s46" ok
rm -f "${FARM}/xwininfo"
run_gate s46 "${GATE}"
evfiles="$(find "${WORK}/ev-s46" -type f 2>/dev/null | wc -l | tr -d ' ')"
check "the evidence directory is non-empty even when the gate fails early" \
  "$([[ "${evfiles}" -gt 0 ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
printf '1..%d\n' "$((PASS_COUNT + FAIL_COUNT))"
printf '# scenarios: %d\n' "${SCENARIO_COUNT}"
printf '# mutations applied and proven load-bearing: %d\n' "${MUTATION_COUNT}"
printf '# assertions: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [[ "${FAIL_COUNT}" -ne 0 ]]; then
  printf '# failing tests:\n'
  for n in "${FAILED_NAMES[@]}"; do
    printf '#   - %s\n' "${n}"
  done
  exit 1
fi
printf '# linux artifact gate suite: all green\n'
exit 0
