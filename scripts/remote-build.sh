#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; echo "::error::remote-build.sh stopped at line $LINENO: $BASH_COMMAND (exit $rc) | $(df -h /work 2>/dev/null | tail -1)"' ERR

: "${ROM:?}" "${JOBS:?}" "${TARGET:?}" "${RELEASE:?}" "${VARIANT:?}" "${START:?}"
GEN_ARGS="${GEN_ARGS:-}"

LIMIT=$((160 * 60))
ci=/work/ci
export JOBS
export SRC_DIR="/work/src/${ROM}"

SUDO=""
[ "$(id -u)" = 0 ] || SUDO="sudo"

left() { echo $((LIMIT - ($(date +%s) - START))); }

if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: this instance has no apt-get, an Ubuntu/Debian image is needed for the android build" >&2
    exit 2
fi

echo "==> disk"
df -h /work
(mount | grep " /work ") || echo "WARNING: /work is not its own mount, the persistent volume may not be attached here"
swap_gb=74
swap_bytes=$((swap_gb * 1024 * 1024 * 1024))
if [ -f /work/swapfile ] && [ "$(stat -c %s /work/swapfile)" != "$swap_bytes" ]; then
    $SUDO swapoff /work/swapfile || true
    $SUDO rm -f /work/swapfile
fi
if [ ! -f /work/swapfile ]; then
    $SUDO fallocate -l "${swap_gb}G" /work/swapfile
    $SUDO chmod 600 /work/swapfile
    $SUDO mkswap /work/swapfile
fi
$SUDO swapon /work/swapfile || true
trap "$SUDO swapoff /work/swapfile 2>/dev/null || true; sync" EXIT

echo "==> installing packages"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update
$SUDO apt-get install -y git-core git-lfs gnupg flex bison build-essential zip curl zlib1g-dev libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig python3 rsync bc libssl-dev xz-utils openjdk-17-jdk-headless ca-certificates util-linux ccache

$SUDO curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo
$SUDO chmod +x /usr/local/bin/repo
git config --global user.name "gsi-patches"
git config --global user.email "gsi-patches@localhost"
git config --global color.ui false
git lfs install --skip-repo

if [ -d "${SRC_DIR}/.repo" ]; then
    echo "==> resetting the existing tree in ${SRC_DIR}"
    rm -rf "$SRC_DIR"/external/chromium-webview/prebuilt/{arm,arm64,x86,x86_64}
    (cd "$SRC_DIR" && repo forall --ignore-missing -j"$JOBS" -c 'git reset --hard -q "$REPO_LREV" || echo "reset failed in $REPO_PATH"; git clean -fdq || echo "clean failed in $REPO_PATH"') || echo "WARNING: repo forall exited non-zero, continuing so the sync can repair the tree"
else
    echo "==> no existing tree in ${SRC_DIR}, fresh sync"
fi

(
    while sleep 60; do
        echo "[mon] $(date +%T) $(free -m | awk '/^Mem/{printf "mem_used=%sMB avail=%sMB ",$3,$7} /^Swap/{printf "swap_used=%sMB ",$3}')$(df -h /work | awk 'NR==2{printf "disk_avail=%s ",$4}')load=$(cut -d' ' -f1 /proc/loadavg)"
    done
) &
echo "==> syncing sources"
bash "$ci/scripts/sync-sources.sh" "$(case "$ROM" in infinity) echo 1 ;; pixelos) echo 2 ;; lineage) echo 3 ;; esac)"

echo "==> pulling chromium-webview lfs prebuilts"
for a in arm arm64 x86 x86_64; do
    d="$SRC_DIR/external/chromium-webview/prebuilt/$a"
    git -C "$d" config --unset-all filter.lfs.smudge || true
    git -C "$d" config --unset-all filter.lfs.process || true
    git -C "$d" lfs pull
    head -c 2 "$d/webview.apk" | grep -q PK || { echo "ERROR: $d/webview.apk is not a real apk, git-lfs pull failed" >&2; exit 1; }
done

echo "==> applying patches"
SKIP_MISSING=1 KEEP_GOING=1 "$ci/patches-branch/apply-series.sh" "$SRC_DIR"

echo "==> installing signing keys"
keypriv=lineage-priv
[ "$ROM" = infinity ] && keypriv=infinity-priv
mkdir -p "$SRC_DIR/vendor/$keypriv/keys"
cp "$ci"/gsi-keys/keys/* "$SRC_DIR/vendor/$keypriv/keys/"
sed -i "s#vendor/lineage-priv#vendor/$keypriv#g" "$SRC_DIR/vendor/$keypriv/keys/keys.mk"
cp "$ci/gsi-keys/keys/platform.pk8" "$ci/gsi-keys/keys/platform.x509.pem" "$SRC_DIR/treble_app/keys/"

echo "==> building treble_app"
(cd "$SRC_DIR/treble_app" && bash build.sh release)

if [ -z "$GEN_ARGS" ] && [ "$ROM" = lineage ]; then
    GEN_ARGS=lineage
fi
echo "==> generating treble makefiles"
(cd "$SRC_DIR/device/phh/treble" && bash generate.sh $GEN_ARGS)

remaining=$(left)
if [ "$remaining" -le 300 ]; then
    echo "time limit reached before the build could start, rerun to resume" >&2
    exit 124
fi

echo "==> starting the build, deadline in ${remaining}s"
cd "$SRC_DIR"
REPO_TRACE=0 python3 .repo/repo/repo manifest -o - -r > /dev/null
set +e
timeout -s INT -k 120 "${remaining}s" bash -c "source build/envsetup.sh && lunch ${TARGET}-${RELEASE}-${VARIANT} && m -j${JOBS} systemimage"
rc=$?
set -e

if [ "$rc" = 124 ] || [ "$rc" = 130 ] || [ "$rc" = 137 ]; then
    echo "stopped at the 2h40m limit, out/ is kept on /work so a rerun resumes where this stopped" >&2
    exit 124
fi
[ "$rc" = 0 ] || exit "$rc"

outdir="$SRC_DIR/out/target/product/tdgsi_arm64_ab"
[ -s "$outdir/system.img" ] || { echo "ERROR: $outdir/system.img is missing or empty" >&2; exit 1; }

day=$(date +%Y%m%d)
case "$ROM" in
    infinity) name="InfinityX-4.1-UNOFFICIAL-${day}-GSI-arm64_ab.img.xz" ;;
    pixelos)  name="PixelOS-UNOFFICIAL-${day}-GSI-arm64_ab.img.xz" ;;
    *)        name="LineageOS-24.0-UNOFFICIAL-${day}-GSI-arm64_ab.img.xz" ;;
esac

rm -rf /work/artifacts
mkdir -p /work/artifacts
echo "$name" > /work/artifacts/NAME
cd "$outdir"
xz -9e -T0 -k -v -f -c system.img > "/work/artifacts/$name"
ls -lh system.img "/work/artifacts/$name"
[ -s "/work/artifacts/$name" ] || { echo "ERROR: $name is empty" >&2; exit 1; }
