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
    MOCK_MOUNTINFO_TARGET=""
    MOCK_FSTYPE="ext4"
    export TEST_FSTAB CALL_LOG MOCK_TARGETS MOCK_UMOUNT_FAIL MOCK_MOUNTINFO_TARGET MOCK_FSTYPE
    cat > "$TEST_FSTAB" <<EOF
# Keep this comment
UUID=$UUID  $MOUNTPOINT  ext4  defaults,noatime  0  2
UUID=other-uuid  /mnt/other  ext4  defaults  0  2
EOF
    cp "$TEST_FSTAB" "$CASE_DIR/original"
}

run_mocked() (
    # El script toma FSTAB de DISCOFACIL_FSTAB al cargarse, así que ambas
    # variables deben estar definidas ANTES del source.
    export DISCOFACIL_TEST=1
    export DISCOFACIL_FSTAB="$TEST_FSTAB"
    source "$SCRIPT"
    require_root() { :; }
    blkid() {
        # resolve_device usa `blkid -t UUID=... -o device`; cmd_mount usa -s TYPE.
        case " $* " in
            *" -s TYPE "*) printf '%s\n' "${MOCK_FSTYPE:-ext4}" ;;
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
    mkdir() {
        printf 'mkdir' >> "$CALL_LOG"
        printf ' %s' "$@" >> "$CALL_LOG"
        printf '\n' >> "$CALL_LOG"
    }
    mount() {
        printf 'mount' >> "$CALL_LOG"
        printf ' %s' "$@" >> "$CALL_LOG"
        printf '\n' >> "$CALL_LOG"
    }
    mount.ntfs-3g() { :; }
    awk() {
        # Redirige SOLO la lectura de /proc/self/mountinfo a un fichero controlado;
        # cualquier otra llamada delega en el awk real. Propaga el código de salida.
        local args=("$@")
        local n=${#args[@]}
        if [[ "$n" -ge 1 && "${args[$((n-1))]}" == "/proc/self/mountinfo" ]]; then
            local mi rc=0
            mi="$(mktemp)"
            printf '1 0 0:1 / / rw - rootfs rootfs rw\n' > "$mi"
            [[ -n "${MOCK_MOUNTINFO_TARGET:-}" ]] \
                && printf '1 0 0:2 / %s rw - ext4 /dev/mock-disk rw\n' "$MOCK_MOUNTINFO_TARGET" >> "$mi"
            command awk "${args[@]:0:$((n-1))}" "$mi" || rc=$?
            rm -f "$mi"
            return "$rc"
        fi
        command awk "$@"
    }

    case "$TEST_OPERATION" in
        unmount) cmd_unmount "$UUID" "$TEST_EXPECTED" ;;
        disable) cmd_disable "$UUID" "$TEST_EXPECTED" ;;
        mount)   cmd_mount "$UUID" "$TEST_EXPECTED" ;;
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

real_backup_path() {
    local backup
    while IFS= read -r backup; do
        # Ignora los backups falsos del test (fstab.discofacil-bak.aaaaaaaN) y
        # busca uno cuyo contenido coincida con el original.
        if [[ "$(basename "$backup")" != fstab.discofacil-bak.aaaaaaa* ]] \
            && cmp -s "$CASE_DIR/original" "$backup"; then
            printf '%s\n' "$backup"
            return 0
        fi
    done < <(find "$CASE_DIR" -maxdepth 1 -name 'fstab.discofacil-bak.*' -print)
    return 1
}

assert_backup_matches_original() {
    local backup
    backup="$(real_backup_path)" && [[ -n "$backup" ]]
}

backup_count() {
    local n=0 f
    for f in "$TEST_FSTAB".discofacil-bak.????????; do
        [[ -e "$f" ]] && n=$((n + 1))
    done
    printf '%d' "$n"
}

assert_no_backup() {
    ! compgen -G "$TEST_FSTAB.discofacil-bak.*" >/dev/null
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

# El backup debe quedar con la fecha de creación: cp -a copiaría la del fstab,
# y el prune ordena por fecha de modificación.
new_case
touch -d "2020-01-01" "$TEST_FSTAB"
cp -p "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
real_backup="$(real_backup_path)"
[[ -n "$real_backup" ]]
(( $(date +%s) - $(stat -c %Y "$real_backup") < 120 ))
pass "el backup conserva la fecha de creación, no la del fstab original"

# (a) En éxito, prune conserva los 5 backups más recientes y borra los antiguos.
# Los backups con otros nombres (ajenos) no se tocan nunca, ni siquiera
# fstab.bak.aaaaaaaa, que coincide con el patrón antiguo de 8 caracteres.
new_case
for i in 1 2 3 4 5 6 7; do
    touch -d "2026-01-0$i" "$CASE_DIR/fstab.discofacil-bak.aaaaaaa$i"
done
touch -d "2026-01-01" "$CASE_DIR/fstab.discofacil-bak.manual"
for foreign in fstab.bak.20260101 fstab.bak.original fstab.bak.aaaaaaaa; do
    touch -d "2019-01-01" "$CASE_DIR/$foreign"
done
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
[[ "$(backup_count)" -eq 5 ]]
[[ ! -e "$CASE_DIR/fstab.discofacil-bak.aaaaaaa1" ]]
[[ ! -e "$CASE_DIR/fstab.discofacil-bak.aaaaaaa2" ]]
[[ ! -e "$CASE_DIR/fstab.discofacil-bak.aaaaaaa3" ]]
[[ -e "$CASE_DIR/fstab.discofacil-bak.aaaaaaa4" ]]
[[ -e "$CASE_DIR/fstab.discofacil-bak.aaaaaaa5" ]]
[[ -e "$CASE_DIR/fstab.discofacil-bak.aaaaaaa6" ]]
[[ -e "$CASE_DIR/fstab.discofacil-bak.aaaaaaa7" ]]
[[ -e "$CASE_DIR/fstab.discofacil-bak.manual" ]]
[[ -e "$CASE_DIR/fstab.bak.20260101" ]]
[[ -e "$CASE_DIR/fstab.bak.original" ]]
[[ -e "$CASE_DIR/fstab.bak.aaaaaaaa" ]]
assert_backup_matches_original
pass "prune conserva 5 backups, borra los antiguos y respeta ajenos"

# (b) Si la operación falla, prune NO se ejecuta y no borra ningún backup.
new_case
for i in 1 2 3 4 5 6 7; do
    touch -d "2026-01-0$i" "$CASE_DIR/fstab.discofacil-bak.aaaaaaa$i"
done
touch -d "2026-01-01" "$CASE_DIR/fstab.discofacil-bak.manual"
TEST_OPERATION=disable TEST_EXPECTED="$MOUNTPOINT" MOCK_UMOUNT_FAIL=1
export TEST_OPERATION TEST_EXPECTED MOCK_UMOUNT_FAIL
if run_mocked >/dev/null 2>&1; then exit 1; fi
for i in 1 2 3 4 5 6 7; do
    [[ -e "$CASE_DIR/fstab.discofacil-bak.aaaaaaa$i" ]]
done
[[ -e "$CASE_DIR/fstab.discofacil-bak.manual" ]]
[[ "$(backup_count)" -eq 8 ]]
pass "en fallo no se ejecuta prune y se conservan todos los backups"

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

# --- --mount: rechazos que no deben tocar fstab ni crear backup ---

# (a) El disco ya está montado en otro sitio.
new_case
MOCK_TARGETS="/mnt/ya-montado"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export MOCK_TARGETS TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
assert_no_backup
pass "--mount aborta si el disco ya está montado (ya montado en)"

# (b) fstab ya usa el destino, con otro UUID.
new_case
MOCK_TARGETS=""
printf 'UUID=otro %s ext4 defaults 0 2\n' "$MOUNTPOINT" > "$TEST_FSTAB"
cp "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export MOCK_TARGETS TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
assert_no_backup
pass "--mount aborta si fstab ya usa el destino (fstab ya usa)"

# (c) fstab ya tiene una entrada para el UUID, con otro destino.
new_case
MOCK_TARGETS=""
printf 'UUID=%s /mnt/otro-destino ext4 defaults 0 2\n' "$UUID" > "$TEST_FSTAB"
cp "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export MOCK_TARGETS TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
assert_no_backup
pass "--mount aborta si fstab ya tiene una entrada para el UUID"

# (d) Destino de traversal.
new_case
TEST_OPERATION=mount TEST_EXPECTED="/mnt/../tmp"
export TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
assert_no_backup
pass "--mount aborta con destino de traversal"

# (f) El destino ya está montado según /proc/self/mountinfo.
new_case
MOCK_TARGETS=""
MOCK_MOUNTINFO_TARGET="$MOUNTPOINT"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export MOCK_TARGETS MOCK_MOUNTINFO_TARGET TEST_OPERATION TEST_EXPECTED
if run_mocked >/dev/null 2>&1; then exit 1; fi
assert_unchanged
assert_no_calls
assert_no_backup
pass "--mount aborta si el destino ya está montado (ya hay algo montado en)"

# --- --mount: camino de éxito (mocks; no se monta nada real) ---

# (2a) ext4
new_case
MOCK_TARGETS=""; MOCK_MOUNTINFO_TARGET=""; MOCK_FSTYPE="ext4"
export MOCK_TARGETS MOCK_MOUNTINFO_TARGET MOCK_FSTYPE
unset SUDO_UID SUDO_GID 2>/dev/null || true
printf '# limpio\n' > "$TEST_FSTAB"; cp "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
grep -Fx "UUID=$UUID $MOUNTPOINT ext4 defaults,noatime,nofail,x-systemd.device-timeout=5s 0 2" "$TEST_FSTAB" >/dev/null
assert_backup_matches_original
grep -Fx "mount -- $MOUNTPOINT" "$CALL_LOG" >/dev/null
grep -Fx 'systemctl daemon-reload' "$CALL_LOG" >/dev/null
pass "mount ext4: línea y backup correctos"

# (2b) xfs
new_case
MOCK_TARGETS=""; MOCK_MOUNTINFO_TARGET=""; MOCK_FSTYPE="xfs"
export MOCK_TARGETS MOCK_MOUNTINFO_TARGET MOCK_FSTYPE
printf '# limpio\n' > "$TEST_FSTAB"; cp "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
grep -Fx "UUID=$UUID $MOUNTPOINT xfs defaults,noatime,nofail,x-systemd.device-timeout=5s 0 0" "$TEST_FSTAB" >/dev/null
assert_backup_matches_original
grep -Fx "mount -- $MOUNTPOINT" "$CALL_LOG" >/dev/null
grep -Fx 'systemctl daemon-reload' "$CALL_LOG" >/dev/null
pass "mount xfs: línea y backup correctos"

# (2c) ntfs con SUDO_UID/GID
new_case
MOCK_TARGETS=""; MOCK_MOUNTINFO_TARGET=""; MOCK_FSTYPE="ntfs"
export MOCK_TARGETS MOCK_MOUNTINFO_TARGET MOCK_FSTYPE
export SUDO_UID=1000 SUDO_GID=1000
printf '# limpio\n' > "$TEST_FSTAB"; cp "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
grep -Fx "UUID=$UUID $MOUNTPOINT ntfs-3g defaults,noatime,nofail,x-systemd.device-timeout=5s,uid=1000,gid=1000 0 0" "$TEST_FSTAB" >/dev/null
assert_backup_matches_original
grep -Fx "mount -- $MOUNTPOINT" "$CALL_LOG" >/dev/null
grep -Fx 'systemctl daemon-reload' "$CALL_LOG" >/dev/null
pass "mount ntfs con SUDO_UID: añade uid/gid"

# (2d) ntfs sin SUDO_UID
new_case
MOCK_TARGETS=""; MOCK_MOUNTINFO_TARGET=""; MOCK_FSTYPE="ntfs"
export MOCK_TARGETS MOCK_MOUNTINFO_TARGET MOCK_FSTYPE
unset SUDO_UID SUDO_GID 2>/dev/null || true
printf '# limpio\n' > "$TEST_FSTAB"; cp "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
grep -Fx "UUID=$UUID $MOUNTPOINT ntfs-3g defaults,noatime,nofail,x-systemd.device-timeout=5s 0 0" "$TEST_FSTAB" >/dev/null
! grep -F 'uid=' "$TEST_FSTAB"
! grep -F 'gid=' "$TEST_FSTAB"
assert_backup_matches_original
grep -Fx "mount -- $MOUNTPOINT" "$CALL_LOG" >/dev/null
grep -Fx 'systemctl daemon-reload' "$CALL_LOG" >/dev/null
pass "mount ntfs sin SUDO_UID: no añade uid/gid"

# (2e) fstab sin salto de línea final
new_case
MOCK_TARGETS=""; MOCK_MOUNTINFO_TARGET=""; MOCK_FSTYPE="ext4"
export MOCK_TARGETS MOCK_MOUNTINFO_TARGET MOCK_FSTYPE
unset SUDO_UID SUDO_GID 2>/dev/null || true
printf '# sin salto final' > "$TEST_FSTAB"; cp "$TEST_FSTAB" "$CASE_DIR/original"
TEST_OPERATION=mount TEST_EXPECTED="$MOUNTPOINT"
export TEST_OPERATION TEST_EXPECTED
run_mocked >/dev/null
grep -Fx '# sin salto final' "$TEST_FSTAB" >/dev/null
grep -Fx "UUID=$UUID $MOUNTPOINT ext4 defaults,noatime,nofail,x-systemd.device-timeout=5s 0 2" "$TEST_FSTAB" >/dev/null
assert_backup_matches_original
grep -Fx "mount -- $MOUNTPOINT" "$CALL_LOG" >/dev/null
grep -Fx 'systemctl daemon-reload' "$CALL_LOG" >/dev/null
pass "mount con fstab sin salto final: entrada en su propia línea"

# La compuerta de pruebas: sin DISCOFACIL_TEST=1 se ignora DISCOFACIL_FSTAB.
got="$(env -u DISCOFACIL_TEST DISCOFACIL_FSTAB=/tmp/no-debe-usarse \
    bash -c 'source "$1"; printf "%s" "$FSTAB"' _ "$SCRIPT" 2>/dev/null)"
[[ "$got" == "/etc/fstab" ]]
pass "sin DISCOFACIL_TEST=1 se ignora DISCOFACIL_FSTAB"

got="$(DISCOFACIL_TEST=1 DISCOFACIL_FSTAB=/tmp/fstab-de-prueba \
    bash -c 'source "$1"; printf "%s" "$FSTAB"' _ "$SCRIPT" 2>/dev/null)"
[[ "$got" == "/tmp/fstab-de-prueba" ]]
pass "con DISCOFACIL_TEST=1 se respeta DISCOFACIL_FSTAB"

printf 'Resultado: %d pruebas correctas. Solo se usaron archivos y comandos temporales/simulados.\n' "$tests"
