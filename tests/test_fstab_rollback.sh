#!/usr/bin/env bash
#
# tests/test_fstab_rollback.sh
#
# Qué verifica:
#   Que `montar_disco.sh --mount` restaura /etc/fstab desde el backup cuando el
#   montaje falla, y que no deja temporales .rollback.* residuales.
#
# Cómo se ejecuta:
#   sudo bash tests/test_fstab_rollback.sh
#
# Qué necesita:
#   - root (sudo): usa losetup.
#   - util-linux (losetup, blkid, findmnt) y bash.
#   - NO toca /etc/fstab real: usa un FSTAB falso dentro de `unshare -m`.
#
# Devuelve 0 si pasa, 1 si falla, 77 si no se puede ejecutar (skip).
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_DIR/montar_disco.sh"

skip() { printf '[SKIP] %s\n' "$*" >&2; exit 77; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
ok()   { printf '[ OK ] %s\n' "$*"; }

if [[ "${1:-}" != "--inside" ]]; then
    [[ -f "$SCRIPT_UNDER_TEST" ]] || fail "no se encuentra $SCRIPT_UNDER_TEST"
    command -v unshare >/dev/null 2>&1 || skip "falta unshare"
    command -v losetup >/dev/null 2>&1 || skip "falta losetup"
    command -v mkfs.ext4 >/dev/null 2>&1 || skip "falta mkfs.ext4"
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "requiere root: ejecuta con sudo"
    exec unshare -m bash "$SCRIPT_PATH" --inside
fi

# ---- A partir de aquí: dentro del namespace de montaje ----

IMG="$(mktemp /tmp/rollback_test.XXXXXX.img)"
FSTAB_FAKE="/tmp/rollback_fstab.fake"
FSTAB_ORIG="/tmp/rollback_fstab.orig"
MNT="/mnt/rollback_test"
SHIM_DIR="/tmp/shim_mount_rollback"
DEV=""

cleanup() {
    set +e
    umount "$MNT" 2>/dev/null || true
    [[ -n "$DEV" ]] && losetup -d "$DEV" 2>/dev/null || true
    rm -f "$IMG" "$FSTAB_FAKE" "$FSTAB_ORIG" "$FSTAB_FAKE".bak.* "$FSTAB_FAKE".rollback.* 2>/dev/null || true
    rm -rf "$SHIM_DIR" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "[info] imagen: $IMG  fstab falso: $FSTAB_FAKE  punto: $MNT"

truncate -s 64M "$IMG"
mkfs.ext4 -q -F "$IMG"
DEV="$(losetup -f --show "$IMG")"
udevadm settle 2>/dev/null || true
UUID="$(blkid -s UUID -o value "$DEV")"
[[ -n "$UUID" ]] || fail "no se pudo obtener el UUID de $DEV"

cp -a /etc/fstab "$FSTAB_ORIG"
cp -a "$FSTAB_ORIG" "$FSTAB_FAKE"
ORIG_SUM="$(sha256sum "$FSTAB_FAKE" | awk '{print $1}')"

REAL_MOUNT="$(command -v mount)"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/mount" <<SHIM
#!/bin/sh
last=""
for a in "\$@"; do last="\$a"; done
if [ "\$last" = "$MNT" ]; then
    exit 1
fi
exec "$REAL_MOUNT" "\$@"
SHIM
chmod +x "$SHIM_DIR/mount"

mkdir -p "$MNT"

set +e
OUT="$(PATH="$SHIM_DIR:$PATH" DISCOFACIL_TEST=1 DISCOFACIL_FSTAB="$FSTAB_FAKE" bash "$SCRIPT_UNDER_TEST" --mount "$UUID" "$MNT" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"

[[ "$RC" -ne 0 ]] || fail "se esperaba que el montaje fallara, pero la salida fue 0"
grep -q "no se pudo montar $MNT; fstab restaurado desde" <<<"$OUT" \
    || fail "no aparece el mensaje de restauración de fstab"
NEW_SUM="$(sha256sum "$FSTAB_FAKE" | awk '{print $1}')"
[[ "$NEW_SUM" == "$ORIG_SUM" ]] || fail "el fstab falso NO quedó idéntico al original"
if compgen -G "$FSTAB_FAKE.rollback.*" >/dev/null; then
    fail "quedaron temporales .rollback.* residuales"
fi

ok "rollback de fstab correcto (rc=$RC, fstab idéntico, sin residuales)"
exit 0
