#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/montar_disco.sh"
UUID="12345678-abcd-4321-abcd-1234567890ab"
MOUNTPOINT="/mnt/discofacil-test"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

tests=0

new_case() {
    CASE_DIR="$(mktemp -d "$TMP_ROOT/case.XXXXXXXX")"
    TEST_FSTAB="$CASE_DIR/fstab"
    CALL_LOG="$CASE_DIR/calls"
    : > "$CALL_LOG"
    MOCK_TARGETS="$MOUNTPOINT"
    MOCK_UMOUNT_FAIL=0
    export TEST_FSTAB CALL_LOG MOCK_TARGETS MOCK_UMOUNT_FAIL
    cat > "$TEST_FSTAB" <<EOF
# Keep this comment
UUID=$UUID  $MOUNTPOINT  ext4  defaults,noatime  0  2
UUID=other-uuid  /mnt/other  ext4  defaults  0  2
EOF
    cp "$TEST_FSTAB" "$CASE_DIR/original"
}

run_mocked() (
    # El script toma FSTAB de DISCOFACIL_FSTAB al cargarse, así que debe
    # definirse ANTES del source.
    DISCOFACIL_FSTAB="$TEST_FSTAB"
    source "$SCRIPT"
    require_root() { :; }
    blkid() {
        # resolve_device usa `blkid -t UUID=... -o device`; el mock debe cubrir -t.
        case " $* " in
            *" -t "*|*" -U "*) printf '/dev/mock-disk\n' ;;
            *) return 2 ;;
        esac
    }
    findmnt() {
        # Sin --source (p. ej. la comprobación de salud de load_mount_targets)
        # siempre hay montajes; con --source, devolver MOCK_TARGETS o rc=1.
        case " $* " in
            *" --source "*)
                if [[ -n "${MOCK_TARGETS:-}" ]]; then
                    printf '%s\n' "$MOCK_TARGETS"
                    return 0
                fi
                return 1
                ;;
            *)
                printf '/\n'
                return 0
                ;;
        esac
    }
    umount() {
        printf 'umount' >> "$CALL_LOG"
        printf ' %s' "$@" >> "$CALL_LOG"
        printf '\n' >> "$CALL_LOG"
        [[ "$MOCK_UMOUNT_FAIL" != "1" ]]
    }
    systemctl() {
        printf 'systemctl' >> "$CALL_LOG"
        printf ' %s' "$@" >> "$CALL_LOG"
        printf '\n' >> "$CALL_LOG"
    }

    case "$TEST_OPERATION" in
        unmount) cmd_unmount "$UUID" "$TEST_EXPECTED" ;;
        disable) cmd_disable "$UUID" "$TEST_EXPECTED" ;;
        *) return 2 ;;
    esac
)

assert() {
    if ! "$@"; then
        printf 'FALLO: %s\n' "$*" >&2
        exit 1
    fi
}

assert_unchanged() {
    cmp -s "$CASE_DIR/original" "$TEST_FSTAB"
}

assert_no_calls() {
    [[ ! -s "$CALL_LOG" ]]
}

assert_backup_matches_original() {
    local backup
    backup="$(find "$CASE_DIR" -maxdepth 1 -name 'fstab.bak.*' -print -quit)"
    [[ -n "$backup" ]] && cmp -s "$CASE_DIR/original" "$backup"
}

pass() {
    tests=$((tests + 1))
    printf 'OK %d - %s\n' "$tests" "$1"
}

# Desmontar ahora nunca toca fstab ni crea backups.
new_case
TEST_OPERATION=unmount TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
assert_unchanged
[[ "$(cat "$CALL_LOG")" == "umount -- $MOUNTPOINT" ]]
pass "unmount no modifica fstab y no usa opciones de fuerza"

# Un desmontaje ocupado debe abortar antes de eliminar la entrada persistente.
new_case
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT" MOCK_UMOUNT_FAIL=1
export TEST_OPERATION TEST_EXPECTED MOCK_UMOUNT_FAIL
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_backup_matches_original
! grep -q 'systemctl' "$CALL_LOG"
pass "si umount falla, conserva fstab"

# Más de un punto activo: aborta antes de umount y antes de cambiar fstab.
new_case
MOCK_TARGETS="$MOUNTPOINT
/mnt/otro-punto"
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT"
export MOCK_TARGETS TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
pass "varios puntos activos abortan sin efectos"

# Entradas duplicadas para el UUID son ambiguas.
new_case
printf 'UUID=%s  %s  ext4  defaults  0  2\n' "$UUID" "$MOUNTPOINT" >> "$TEST_FSTAB"
cp "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
pass "entradas fstab duplicadas abortan sin efectos"

# Un punto de fstab distinto del esperado se conserva intacto.
new_case
TEST_OPERATION=disable TEST_EXPECTED="/mnt/otro"
export TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
pass "punto fstab inesperado aborta sin efectos"

# Un punto activo distinto del configurado tampoco se desmonta.
new_case
MOCK_TARGETS="/mnt/otro"
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT"
export MOCK_TARGETS TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
pass "punto activo inesperado aborta sin efectos"

# En éxito elimina solo la línea del UUID exacto y conserva el backup.
new_case
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
grep -Fx '# Keep this comment' "$TEST_FSTAB" >/dev/null
grep -Fx 'UUID=other-uuid  /mnt/other  ext4  defaults  0  2' "$TEST_FSTAB" >/dev/null
! grep -F "$UUID" "$TEST_FSTAB"
assert_backup_matches_original
grep -Fx "umount -- $MOUNTPOINT" "$CALL_LOG" >/dev/null
grep -Fx 'systemctl daemon-reload' "$CALL_LOG" >/dev/null
pass "éxito elimina solo la entrada seleccionada y conserva backup"

# Si ya estaba desmontado, se puede quitar la entrada persistente sin umount.
new_case
MOCK_TARGETS=""
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT"
export MOCK_TARGETS TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
! grep -F "$UUID" "$TEST_FSTAB"
! grep -q '^umount ' "$CALL_LOG"
assert_backup_matches_original
pass "entrada persistente se elimina también si ya estaba desmontado"

# Rutas de traversal se rechazan sin alterar fstab ni invocar umount.
new_case
TEST_OPERATION=disable TEST_EXPECTED="/mnt/../tmp"
export TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
pass "ruta con traversal aborta sin efectos"

printf 'Resultado: %d pruebas correctas. Solo se usaron archivos y comandos temporales/simulados.\n' "$tests"
