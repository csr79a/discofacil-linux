#!/usr/bin/env bash
#
# tests/test_btrfs_subvol.sh
#
# Qué verifica:
#   Que `montar_disco.sh --list` NO ofrece el disco raíz cuando un subvolumen
#   Btrfs está montado en una ruta de sistema como /.snapshots (el bug de
#   MOUNTPOINT singular de lsblk con Btrfs y subvolúmenes).
#
# Cómo se ejecuta:
#   sudo bash tests/test_btrfs_subvol.sh
#
# Qué necesita:
#   - root (sudo): usa losetup y unshare -m.
#   - btrfs-progs (mkfs.btrfs, btrfs). Si no está, skip con código 77.
#   - NO toca /.snapshots real: monta dentro de `unshare -m`.
#   - Incluye un control positivo (sin /.snapshots el disco SÍ debe aparecer) y
#     usa un shim de lsblk que presenta los bucles como "part".
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
    command -v mkfs.btrfs >/dev/null 2>&1 || skip "falta btrfs-progs (mkfs.btrfs)"
    command -v btrfs >/dev/null 2>&1 || skip "falta btrfs-progs (btrfs)"
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "requiere root: ejecuta con sudo"
    exec unshare -m bash "$SCRIPT_PATH" --inside
fi

# ---- A partir de aquí: dentro del namespace de montaje ----

IMG="$(mktemp /tmp/btrfs_subvol.XXXXXX.img)"
FSTAB_FAKE="/tmp/btrfs_subvol_fstab.fake"
FSTAB_ORIG="/tmp/btrfs_subvol_fstab.orig"
TOP="/tmp/btrfs_root"
SYS="/tmp/btrfs_system"
SNAP="/.snapshots"
SHIM_DIR="/tmp/shim_lsblk_btrfs"
DEV=""
SNAP_CREADO=0

cleanup() {
    set +e
    umount "$SNAP" 2>/dev/null || true
    umount "$SYS" 2>/dev/null || true
    umount "$TOP" 2>/dev/null || true
    [[ -n "$DEV" ]] && losetup -d "$DEV" 2>/dev/null || true
    rm -f "$IMG" "$FSTAB_FAKE" "$FSTAB_ORIG" "$FSTAB_FAKE".discofacil-bak.* 2>/dev/null || true
    rm -rf "$SHIM_DIR" 2>/dev/null || true
    rmdir "$SYS" "$TOP" 2>/dev/null || true
    # Sólo borrar /.snapshots si lo creamos nosotros (puede existir de antes).
    if [[ "$SNAP_CREADO" -eq 1 ]]; then rmdir "$SNAP" 2>/dev/null || true; fi
}
trap cleanup EXIT

echo "[info] imagen: $IMG  subvolumen raíz -> $SYS  subvol snap -> $SNAP"

truncate -s 256M "$IMG"
mkfs.btrfs -q -f "$IMG"
DEV="$(losetup -f --show "$IMG")"
udevadm settle 2>/dev/null || true
UUID="$(blkid -s UUID -o value "$DEV")"
[[ -n "$UUID" ]] || fail "no se pudo obtener el UUID de $DEV"

mkdir -p "$TOP"
mount "$DEV" "$TOP"
btrfs subvolume create "$TOP/@" >/dev/null
btrfs subvolume create "$TOP/@snap" >/dev/null
umount "$TOP"

mkdir -p "$SYS"
mount -o subvol=@ "$DEV" "$SYS"

if [[ ! -e "$SNAP" ]]; then
    mkdir -p "$SNAP"
    SNAP_CREADO=1
fi
mount -o subvol=@snap "$DEV" "$SNAP"

echo "--- montajes del dispositivo ---"
findmnt -n -o SOURCE,TARGET "$DEV" || true

cp -a /etc/fstab "$FSTAB_ORIG"
cp -a "$FSTAB_ORIG" "$FSTAB_FAKE"

# Shim: lsblk presenta los dispositivos de bucle como "part" para que el filtro
# TYPE de --list los vea. Todo lo demás (findmnt, blkid, montajes) es real.
mkdir -p "$SHIM_DIR"
REAL_LSBLK="$(command -v lsblk)"
cat > "$SHIM_DIR/lsblk" <<SHIM
#!/bin/sh
"$REAL_LSBLK" "\$@" | sed 's/TYPE="loop"/TYPE="part"/'
SHIM
chmod +x "$SHIM_DIR/lsblk"

list_out() {
    PATH="$SHIM_DIR:$PATH" DISCOFACIL_TEST=1 DISCOFACIL_FSTAB="$FSTAB_FAKE" \
        bash "$SCRIPT_UNDER_TEST" --list 2>&1
}

# Control positivo: solo @ montado fuera de rutas de sistema -> debe aparecer.
umount "$SNAP"
CTRL_OUT="$(list_out)"
grep -qF "$UUID" <<<"$CTRL_OUT" \
    || fail "control: el Btrfs debería aparecer sin /.snapshots; la prueba no ve el bucle"

# Caso real: con @snap en /.snapshots -> debe quedar excluido.
mount -o subvol=@snap "$DEV" "$SNAP"
OUT="$(list_out)"
printf '%s\n' "$OUT"
if grep -qF "$UUID" <<<"$OUT"; then
    fail "el UUID del Btrfs ($UUID) aparece en --list con /.snapshots montado"
fi

ok "Btrfs excluido de --list con /.snapshots (y visible sin él: control positivo)"
exit 0
