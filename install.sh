#!/bin/sh
# RadiusOne installer bootstrap (ARCHITECTURE.md §13.1).
# All-in-one production install (ADR 0019): OS check, prerequisites, then the
# `radiusone install` CLI (Python standard library only) does the rest.
#
# Online (no token, ADR 0023; it asks for the domain and the network):
#   curl -fsSL https://github.com/sharis1999/radiusone-releases/releases/latest/download/install.sh | sudo sh
# Offline: sudo sh install.sh --bundle /path/to/releases   (from an unpacked bundle)
# Usage:   sh install.sh [--check-only] [--force-unsupported] [radiusone install options]
set -eu

R1_PREFIX="${R1_PREFIX:-/opt/radiusone}"
R1_OS_RELEASE="${R1_OS_RELEASE:-/etc/os-release}"

banner() {
    cat <<BANNER
===========================================================
  RadiusOne installer
  Designed & developed by Sardar Haris
===========================================================
BANNER
}

die() {
    # die <what failed> <exact fix>
    printf 'ERROR: %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf 'FIX:   %s\n' "$2" >&2
    exit 1
}

# Sets OS_ID, OS_LIKE, OS_VERSION, OS_FAMILY, OS_SUPPORT (supported|eol|untested|unknown)
detect_os() {
    [ -r "$R1_OS_RELEASE" ] || die "cannot read $R1_OS_RELEASE" "RadiusOne needs a systemd-based Linux with /etc/os-release"
    # shellcheck disable=SC1090
    OS_ID=$(. "$R1_OS_RELEASE"; printf '%s' "${ID:-unknown}")
    OS_LIKE=$(. "$R1_OS_RELEASE"; printf '%s' "${ID_LIKE:-}")
    OS_VERSION=$(. "$R1_OS_RELEASE"; printf '%s' "${VERSION_ID:-0}")
    OS_MAJOR=${OS_VERSION%%.*}

    case " $OS_ID $OS_LIKE " in
        *" debian "*|*" ubuntu "*) OS_FAMILY=debian ;;
        *" rhel "*|*" fedora "*|*" centos "*) OS_FAMILY=redhat ;;
        *) OS_FAMILY=unknown ;;
    esac

    OS_SUPPORT=unknown
    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION" in
                22.04|24.04) OS_SUPPORT=supported ;;
                *) if [ "$OS_MAJOR" -lt 22 ]; then OS_SUPPORT=eol; else OS_SUPPORT=untested; fi ;;
            esac ;;
        debian)
            case "$OS_MAJOR" in
                12|13) OS_SUPPORT=supported ;;
                *) if [ "$OS_MAJOR" -lt 12 ]; then OS_SUPPORT=eol; else OS_SUPPORT=untested; fi ;;
            esac ;;
        rocky|almalinux)
            case "$OS_MAJOR" in
                9) OS_SUPPORT=supported ;;
                *) if [ "$OS_MAJOR" -lt 9 ]; then OS_SUPPORT=eol; else OS_SUPPORT=untested; fi ;;
            esac ;;
        centos|rhel)
            if [ "$OS_MAJOR" -lt 9 ]; then OS_SUPPORT=eol; else OS_SUPPORT=untested; fi ;;
    esac
}

check_support() {
    case "$OS_SUPPORT" in
        supported) return 0 ;;
        eol)
            die "$OS_ID $OS_VERSION is end-of-life and not supported" \
                "use Ubuntu 22.04/24.04, Debian 12/13 or Rocky/AlmaLinux 9" ;;
        untested|unknown)
            if [ "$FORCE_UNSUPPORTED" = 1 ]; then
                printf 'WARNING: %s %s is not in the tested matrix; continuing because of --force-unsupported\n' "$OS_ID" "$OS_VERSION" >&2
                return 0
            fi
            die "$OS_ID $OS_VERSION is not in the supported matrix (D11)" \
                "use a supported distro, or re-run with --force-unsupported (logged)" ;;
    esac
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "the installer must run as root" "sudo sh install.sh $*"
}

# curl, python3 (3.9+ is enough: the CLI uses only its standard library), openssl, tar.
prerequisites() {
    missing=""
    for c in curl python3 openssl tar gzip; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
    [ -z "$missing" ] && return 0
    echo "Installing:$missing"
    case "$OS_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null \
                    && DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl ca-certificates python3 openssl tar gzip >/dev/null ;;
        redhat) dnf install -y -q curl ca-certificates python3 openssl tar gzip >/dev/null ;;
    esac || die "could not install:$missing" "check internet access / package mirrors and run again"
}

# The installer CLI: next to this script (bundle or source), else the newest release's
# installer.tar.gz: from the public release repository (no token), or with a token from a
# private one.
locate_cli() {
    here=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /nonexistent)
    if [ -d "$here/cli/radiusone_cli" ]; then CLI_DIR="$here/cli"; return 0; fi
    mkdir -p "$R1_PREFIX"
    if [ -z "$TOKEN" ]; then
        url="https://github.com/$REPO/releases/latest/download/installer.tar.gz"
        curl -fsSL --retry 3 -o "$R1_PREFIX/installer.tar.gz" "$url" \
            || die "could not download the installer ($url)" "check internet access / DNS and run again"
        tar -xzf "$R1_PREFIX/installer.tar.gz" -C "$R1_PREFIX" || die "the installer download is damaged" "run again"
        CLI_DIR="$R1_PREFIX/installer/cli"
        return 0
    fi
    R1_TOKEN="$TOKEN" R1_REPO="$REPO" R1_PREFIX="$R1_PREFIX" python3 - <<'PY' || die "could not download the installer from GitHub" "check the token (Contents: read) and internet access"
import json, os, shutil, tarfile, urllib.request, urllib.error
api, repo, tok = "https://api.github.com", os.environ["R1_REPO"], os.environ["R1_TOKEN"]
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
def get(url, accept):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok, "Accept": accept, "User-Agent": "radiusone-installer"})
    try:
        return urllib.request.build_opener(NoRedirect).open(req, timeout=60)
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 307, 308):
            return urllib.request.urlopen(urllib.request.Request(e.headers["Location"], headers={"User-Agent": "radiusone-installer"}), timeout=300)
        raise
rels = json.load(get(api + "/repos/" + repo + "/releases?per_page=10", "application/vnd.github+json"))
rel = next(r for r in rels if not r.get("draft") and any(a["name"] == "installer.tar.gz" for a in r["assets"]))
asset = next(a for a in rel["assets"] if a["name"] == "installer.tar.gz")
out = os.path.join(os.environ["R1_PREFIX"], "installer.tar.gz")
with get(api + "/repos/" + repo + "/releases/assets/" + str(asset["id"]), "application/octet-stream") as r, open(out, "wb") as f:
    shutil.copyfileobj(r, f)
with tarfile.open(out) as t:
    t.extractall(os.environ["R1_PREFIX"])
print("installer of release", rel["tag_name"])
PY
    CLI_DIR="$R1_PREFIX/installer/cli"
}

FORCE_UNSUPPORTED=0
CHECK_ONLY=0
TOKEN="${R1_UPDATE_TOKEN:-}"
REPO="${R1_UPDATE_REPO:-sharis1999/radiusone-releases}"
ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force-unsupported) FORCE_UNSUPPORTED=1; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --token) TOKEN="${2:-}"; ARGS="$ARGS --token $2"; shift 2 ;;
        *) ARGS="$ARGS $1"; shift ;;
    esac
done

banner
detect_os
printf 'Detected: %s %s (family: %s, arch: %s) -> %s\n' \
    "$OS_ID" "$OS_VERSION" "$OS_FAMILY" "$(uname -m)" "$OS_SUPPORT"
check_support
if [ "$CHECK_ONLY" = 1 ]; then
    echo "OS check passed."
    exit 0
fi

need_root
prerequisites
locate_cli
export R1_UPDATE_TOKEN="$TOKEN" R1_UPDATE_REPO="$REPO"
# shellcheck disable=SC2086
PYTHONPATH="$CLI_DIR" exec python3 -m radiusone_cli install $ARGS
