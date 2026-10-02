#!/usr/bin/env bash
#
# tests/test_signal_trap.sh
#
# Qué verifica:
#   Que el trap de SIGINT/SIGTERM de montar_disco.sh restaura /etc/fstab si la
#   señal llega con una modificación en curso (salida 130 y mensaje "SIG<SEÑAL>
#   recibido").
#
# Cómo se ejecuta:
#   sudo bash tests/test_signal_trap.sh
#
# Qué necesita:
#   - root (sudo): usa losetup y unshare -m.
#   - util-linux (losetup, blkid) y bash.
#   - NO toca /etc/fstab real: usa un FSTAB falso dentro de `unshare -m`.
#
# Nota: cada caso tarda ~10 s porque el shim de mount duerme antes de fallar y
# bash difiere el trap hasta que termina el comando en primer plano.
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

IMG="$(mktemp /tmp/trap_test.XXXXXX.img)"
FSTAB_FAKE="/tmp/trap_fstab.fake"
FSTAB_ORIG="/tmp/trap_fstab.orig"
MNT="/mnt/trap_test"
SHIM_DIR="/tmp/shim_mount_trap"
DEV=""

cleanup() {
    set +e
    umount "$MNT" 2>/dev/null || true
    [[ -n "$DEV" ]] && losetup -d "$DEV" 2>/dev/null || true
    rm -f "$IMG" "$FSTAB_FAKE" "$FSTAB_ORIG" "$FSTAB_FAKE".bak.* "$FSTAB_FAKE".sig.* "$FSTAB_FAKE".rollback.* 2>/dev/null || true
    rm -rf "$SHIM_DIR" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

truncate -s 64M "$IMG"
mkfs.ext4 -q -F "$IMG"
DEV="$(losetup -f --show "$IMG")"
udevadm settle 2>/dev/null || true
UUID="$(blkid -s UUID -o value "$DEV")"
[[ -n "$UUID" ]] || fail "no se pudo obtener el UUID de $DEV"

cp -a /etc/fstab "$FSTAB_ORIG"

REAL_MOUNT="$(command -v mount)"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/mount" <<SHIM
#!/bin/sh
last=""
for a in "\$@"; do last="\$a"; done
if [ "\$last" = "$MNT" ]; then
    sleep 10
    exit 1
fi
exec "$REAL_MOUNT" "\$@"
SHIM
chmod +x "$SHIM_DIR/mount"

mkdir -p "$MNT"

run_case() {
    local sig="$1"
    printf '\n--- señal SIG%s ---\n' "$sig"
    cp -a "$FSTAB_ORIG" "$FSTAB_FAKE"
    local orig_sum new_sum rc outf
    orig_sum="$(sha256sum "$FSTAB_FAKE" | awk '{print $1}')"
    outf="$(mktemp)"

    # Se lanza en primer plano (exec) y un ayudante envía la señal a $$; así el
    # SIGINT no queda ignorado por ser un job asíncrono.
    set +e
    PATH="$SHIM_DIR:$PATH" DISCOFACIL_FSTAB="$FSTAB_FAKE" \
        bash -c '
            ( sleep 2; kill -"$4" $$ ) &
            exec bash "$1" --mount "$2" "$3"
        ' _ "$SCRIPT_UNDER_TEST" "$UUID" "$MNT" "$sig" >"$outf" 2>&1
    rc=$?
    set -e

    cat "$outf"

    if [[ "$rc" -ne 130 ]]; then
        rm -f "$outf"; fail "SIG$sig: se esperaba salida 130, fue $rc"
    fi
    if ! grep -q "SIG$sig recibido" "$outf"; then
        rm -f "$outf"; fail "SIG$sig: falta el mensaje 'SIG$sig recibido'"
    fi
    rm -f "$outf"

    new_sum="$(sha256sum "$FSTAB_FAKE" | awk '{print $1}')"
    [[ "$new_sum" == "$orig_sum" ]] || fail "SIG$sig: el fstab falso NO quedó idéntico al original"
    if compgen -G "$FSTAB_FAKE.sig.*" >/dev/null || compgen -G "$FSTAB_FAKE.rollback.*" >/dev/null; then
        fail "SIG$sig: quedaron temporales residuales (.sig.*/.rollback.*)"
    fi
    ok "SIG$sig: trap correcto (rc=$rc, fstab idéntico, sin residuales)"
}

run_case TERM
run_case INT

printf '\n[ OK ] trap de señales verificado (SIGTERM y SIGINT)\n'
exit 0
