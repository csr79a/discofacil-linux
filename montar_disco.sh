#!/usr/bin/env bash
#
# montar_disco.sh - Detecta, monta y desmonta discos secundarios.
#
# Uso:
#   montar_disco.sh --list
#       Lista discos candidatos (excluye el disco raíz, /boot y swap)
#       en formato: NAME, FSTYPE, LABEL, UUID, SIZE, MOUNTPOINT, FSTAB_TARGET, FSTAB_COUNT
#       separados por tabulador. FSTAB_TARGET es el destino en fstab si hay
#       exactamente una entrada, y FSTAB_COUNT el número de entradas.
#
#   montar_disco.sh --mount <UUID> <punto_de_montaje>
#       Monta el disco identificado por UUID en el punto indicado
#       y añade la entrada a fstab si no existe ya.
#
#   montar_disco.sh --unmount <UUID> <punto_de_montaje>
#       Desmonta el disco ahora. No lee ni modifica /etc/fstab.
#
#   montar_disco.sh --disable <UUID> <punto_de_montaje>
#       Desmonta el disco (si está montado) y elimina de fstab la entrada
#       exacta que corresponde al UUID y al punto de montaje indicado.

set -euo pipefail

PROG="$(basename "$0")"
# La ruta de fstab se puede sobrescribir solo para las pruebas, con un
# interruptor explícito (DISCOFACIL_TEST=1) y una variable de nombre
# específico del proyecto (DISCOFACIL_FSTAB). No es una barrera de
# seguridad: sudo -E o un env_keep pueden conservar ambas variables.
# Es solo una protección contra colisiones accidentales y un aviso de
# que la ruta de producción es siempre /etc/fstab.
FSTAB="/etc/fstab"
if [[ "${DISCOFACIL_TEST:-}" == "1" && -n "${DISCOFACIL_FSTAB:-}" ]]; then
    FSTAB="$DISCOFACIL_FSTAB"
    printf '[%s] AVISO: modo de pruebas, fstab = %s\n' "$PROG" "$FSTAB" >&2
fi

log()  { printf '[%s] %s\n' "$PROG" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Estado del trap de interrupción: 0 = fstab limpio, 1 = modificación en curso.
FSTAB_DIRTY=0
FSTAB_BACKUP=""

on_interrupt() {
    local sig="$1"
    if [[ "${FSTAB_DIRTY:-0}" -eq 1 && -n "${FSTAB_BACKUP:-}" && -f "$FSTAB_BACKUP" ]]; then
        local tmp
        tmp="$(mktemp "${FSTAB}.sig.XXXXXXXX" 2>/dev/null)" || true
        if [[ -n "$tmp" ]] \
            && cp -a --remove-destination -- "$FSTAB_BACKUP" "$tmp" 2>/dev/null \
            && mv -f -- "$tmp" "$FSTAB" 2>/dev/null; then
            printf '\n[%s] %s recibido; fstab restaurado desde %s\n' "$PROG" "$sig" "$FSTAB_BACKUP" >&2
        else
            rm -f -- "$tmp" 2>/dev/null || true
            printf '\n[%s] %s recibido; no se pudo restaurar fstab, backup en %s\n' "$PROG" "$sig" "$FSTAB_BACKUP" >&2
        fi
    fi
    exit 130
}

trap 'on_interrupt SIGINT' INT
trap 'on_interrupt SIGTERM' TERM
trap 'on_interrupt SIGHUP' HUP

require_root() {
    [[ "$EUID" -eq 0 ]] || die "esta operación requiere sudo/root"
}

validate_uuid() {
    local uuid="$1"
    [[ "$uuid" =~ ^[A-Za-z0-9-]+$ ]] || die "UUID con formato inesperado: $uuid"
}

validate_mountpoint() {
    local mountpoint="$1"
    local canonical

    # Solo se admiten rutas sencillas bajo /mnt. Esto evita traversal,
    # escapes de fstab y destinos que atraviesan enlaces simbólicos.
    [[ "$mountpoint" =~ ^/mnt/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]] \
        || die "punto de montaje inválido; usa una ruta sencilla bajo /mnt/"
    case "$mountpoint" in
        */./*|*/../*|*/.|*/..) die "no se permiten componentes '.' o '..' en el punto de montaje" ;;
    esac

    canonical="$(realpath -m -- "$mountpoint")" \
        || die "no se pudo validar el punto de montaje: $mountpoint"
    [[ "$canonical" == "$mountpoint" && "$canonical" == /mnt/* ]] \
        || die "el punto de montaje no es una ruta canónica dentro de /mnt: $mountpoint"
}

resolve_device() {
    local uuid="$1"
    local -a devices=()
    local line

    # blkid -U devuelve solo el primero si hay UUID duplicados.
    # blkid -t los devuelve todos; rechazamos si hay más de uno.
    while IFS= read -r line; do
        [[ -n "$line" ]] && devices+=("$line")
    done < <(blkid -t "UUID=$uuid" -o device 2>/dev/null || true)

    case "${#devices[@]}" in
        0) die "no se encontró ningún dispositivo con UUID $uuid" ;;
        1) printf '%s\n' "${devices[0]}" ;;
        *) die "hay ${#devices[@]} dispositivos con UUID=$uuid: ${devices[*]}; resuelve la ambigüedad (cambia el UUID de uno) antes de continuar" ;;
    esac
}

fstab_targets_for_uuid() {
    local uuid="$1"
    [[ -r "$FSTAB" ]] || return 0

    awk -v uuid="$uuid" '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "") next
            count = split(line, fields, /[[:space:]]+/)
            if (fields[1] == "UUID=" uuid || fields[1] == "/dev/disk/by-uuid/" uuid) {
                if (count < 2 || fields[2] == "") print "!INVALID"
                else print fields[2]
            }
        }
    ' "$FSTAB"
}

load_mount_targets() {
    local device="$1"
    local output status target
    ACTIVE_TARGETS=()

    # Comprobación de salud: findmnt sin filtro nunca está vacío.
    # Si esto falla, es error real y abortamos.
    if ! findmnt --raw --noheadings --output SOURCE >/dev/null 2>&1; then
        die "findmnt no responde; no se puede determinar el estado de montaje"
    fi

    # Con findmnt funcionando, un rc=1 en la consulta filtrada solo puede ser
    # "sin coincidencias". Cualquier otro código es error.
    if output="$(findmnt --raw --noheadings --source "$device" --output TARGET)"; then
        :
    else
        status=$?
        [[ "$status" -eq 1 ]] || die "findmnt falló al consultar $device"
        output=""
    fi

    if [[ -n "$output" ]]; then
        while IFS= read -r target; do
            [[ -n "$target" ]] && ACTIVE_TARGETS+=("$target")
        done <<< "$output"
    fi
}

create_fstab_backup() {
    local backup
    [[ -f "$FSTAB" && ! -L "$FSTAB" && -r "$FSTAB" && -w "$FSTAB" ]] \
        || die "fstab no es un archivo regular legible y modificable: $FSTAB"

    backup="$(mktemp "${FSTAB}.discofacil-bak.XXXXXXXX")" || die "no se pudo crear un backup de fstab"
    if ! cp -a --remove-destination -- "$FSTAB" "$backup"; then
        rm -f -- "$backup"
        die "no se pudo crear el backup de fstab"
    fi
    # cp -a conserva la fecha de modificación de fstab; el prune ordena por fecha,
    # así que la copia debe llevar la fecha de su creación.
    touch -- "$backup"
    FSTAB_BACKUP="$backup"
    log "backup de fstab creado en: $FSTAB_BACKUP"
}

prune_fstab_backups() {
    # Conserva solo los 2 backups más recientes (/etc/fstab.discofacil-bak.XXXXXXXX).
    # Solo toca ficheros regulares con el patrón exacto de mktemp (8 caracteres)
    # y nunca el backup de la operación en curso. Es best-effort: no falla.
    local keep=2 f
    local -a files=()
    mapfile -t files < <(ls -1t -- "${FSTAB}".discofacil-bak.???????? 2>/dev/null || true)
    (( ${#files[@]} > keep )) || return 0
    for f in "${files[@]:keep}"; do
        if [[ "$f" != "$FSTAB_BACKUP" && -f "$f" && ! -L "$f" ]]; then
            rm -f -- "$f" || true
        fi
    done
    return 0
}

remove_fstab_entry() {
    local uuid="$1"
    local expected_mountpoint="$2"
    local temp

    # No sobrescribir cambios concurrentes hechos después del backup.
    cmp -s -- "$FSTAB" "$FSTAB_BACKUP" \
        || die "fstab cambió durante la operación; no se modificó"

    temp="$(mktemp "${FSTAB}.tmp.XXXXXXXX")" || die "no se pudo preparar la actualización de fstab"
    if ! cp -a --remove-destination -- "$FSTAB" "$temp"; then
        rm -f -- "$temp"
        die "no se pudo preparar la actualización de fstab"
    fi

    if ! awk -v uuid="$uuid" -v target="$expected_mountpoint" '
        /^[[:space:]]*#/ { print; next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "") { print; next }
            count = split(line, fields, /[[:space:]]+/)
            source_match = (fields[1] == "UUID=" uuid || fields[1] == "/dev/disk/by-uuid/" uuid)
            if (source_match) {
                matched++
                if (count < 2 || fields[2] != target) { print; next }
                removed++
                next
            }
            print
        }
        END {
            if (matched != 1 || removed != 1) exit 42
        }
    ' "$FSTAB" > "$temp"; then
        rm -f -- "$temp"
        die "la entrada de fstab cambió o dejó de ser inequívoca; no se modificó"
    fi

    if ! cmp -s -- "$FSTAB" "$FSTAB_BACKUP"; then
        rm -f -- "$temp"
        die "fstab cambió durante la operación; no se modificó"
    fi
    if ! mv -f -- "$temp" "$FSTAB"; then
        rm -f -- "$temp"
        die "no se pudo guardar la actualización de fstab"
    fi
}

cmd_list() {
    # Raíz actual, para poder excluirla de la lista de candidatos
    local root_src
    root_src="$(findmnt -n -o SOURCE /)"

    # Detectar UUIDs que aparecen en más de un dispositivo (Btrfs multidevice)
    local dup_uuids
    dup_uuids="$(lsblk -P -n -o UUID | sed -n 's/^UUID="\(..*\)"$/\1/p' | sort | uniq -d)"
    local SEEN_UUIDS=""

    lsblk -P -o NAME,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINT,TYPE |
    while IFS= read -r line; do
        eval "$line"   # crea NAME= FSTYPE= LABEL= UUID= SIZE= MOUNTPOINT= TYPE=

        # Solo discos y particiones (no mappers LUKS/LVM/RAID, no rom)
        case "${TYPE:-}" in
            disk|part) : ;;
            *) continue ;;
        esac

        # Solo sistemas de archivos soportados
        case "${FSTYPE:-}" in
            ext2|ext3|ext4|btrfs|xfs|ntfs|exfat) : ;;
            *) continue ;;
        esac

        # Btrfs multidevice: mismo UUID en varios dispositivos, excluir todos.
        if [[ "${FSTYPE:-}" == "btrfs" ]] && [[ -n "${UUID:-}" ]] && grep -qxF "$UUID" <<< "$dup_uuids"; then
            continue
        fi

        # Otros FS con UUID repetido (p. ej. disco + partición): mostrar solo uno.
        if [[ -n "${UUID:-}" ]]; then
            if grep -qxF "$UUID" <<< "${SEEN_UUIDS:-}"; then
                continue
            fi
            SEEN_UUIDS="${SEEN_UUIDS:-}${UUID}"$'\n'
        fi

        local dev="/dev/${NAME}"

        # Excluye el disco/partición raíz actual
        [[ "$dev" != "$root_src" ]] || continue

        # Excluye lo que ya está montado en /, /boot, /home, etc.
        # MOUNTPOINT singular puede ser engañoso con Btrfs y subvolúmenes:
        # lsblk solo rellena uno de los puntos, y puede ser cualquiera.
        case "${MOUNTPOINT:-}" in
            "/"|/boot*|/home|/var*|/root|/srv|/.snapshots*) continue ;;
        esac

        # Comprobación adicional con findmnt: si el dispositivo tiene CUALQUIER
        # punto de montaje en rutas de sistema, excluirlo. Cubre Btrfs con
        # subvolúmenes montados fuera de la lista habitual.
        if [[ -n "${UUID:-}" ]] \
            && findmnt -n -o TARGET --source "/dev/$NAME" 2>/dev/null \
                | grep -qE '^(/|/boot|/home|/var|/root|/srv|/\.snapshots)(/.*)?$'; then
            continue
        fi

        local -a fstab_targets=()
        local fstab_target=""
        if [[ -n "${UUID:-}" && -r "$FSTAB" ]]; then
            mapfile -t fstab_targets < <(fstab_targets_for_uuid "$UUID")
            [[ "${#fstab_targets[@]}" -eq 1 ]] && fstab_target="${fstab_targets[0]}"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$NAME" "$FSTYPE" "${LABEL:-}" "${UUID:-}" "$SIZE" \
            "${MOUNTPOINT:-}" "$fstab_target" "${#fstab_targets[@]}"
    done
}

cmd_mount() {
    local uuid="$1"
    local mountpoint="$2"

    require_root

    validate_uuid "$uuid"
    validate_mountpoint "$mountpoint"

    local dev
    dev="$(resolve_device "$uuid")"

    local fstype
    fstype="$(blkid -s TYPE -o value "$dev")" || die "no se pudo determinar el filesystem de $dev"

    case "$fstype" in
        ext4|ext3|ext2|btrfs|xfs) : ;;
        ntfs)
            command -v mount.ntfs-3g >/dev/null 2>&1 || command -v ntfs-3g >/dev/null 2>&1 \
                || die "filesystem NTFS pero no está instalado ntfs-3g"
            fstype="ntfs-3g"
            ;;
        exfat)
            grep -qw exfat /proc/filesystems || modprobe -q exfat 2>/dev/null \
                || command -v mount.exfat >/dev/null 2>&1 \
                || die "sin soporte exFAT (kernel >= 5.7 o exfat-fuse)"
            ;;
        *) die "filesystem '$fstype' no soportado por este script" ;;
    esac

    local pass
    local -a existing_targets=()

    case "$fstype" in
        ext2|ext3|ext4) pass=2 ;;
        *)              pass=0 ;;
    esac

    # Rechazar si el disco ya está montado en algún sitio
    load_mount_targets "$dev"
    [[ "${#ACTIVE_TARGETS[@]}" -eq 0 ]] \
        || die "ya montado en: ${ACTIVE_TARGETS[*]}; desmóntalo antes"

    # Rechazar si el destino ya tiene algo montado (vía /proc/self/mountinfo,
    # sin la ambigüedad de findmnt -M).
    if awk -v mp="$mountpoint" '$5 == mp { found=1 } END { exit !found }' /proc/self/mountinfo; then
        die "ya hay algo montado en $mountpoint"
    fi

    # Rechazar si fstab ya usa ese destino
    awk -v t="$mountpoint" '!/^[[:space:]]*#/ && $2 == t { f = 1 } END { exit !f }' "$FSTAB" \
        && die "fstab ya usa $mountpoint como destino"

    # Rechazar si fstab ya tiene una entrada para ese UUID
    mapfile -t existing_targets < <(fstab_targets_for_uuid "$uuid")
    [[ "${#existing_targets[@]}" -eq 0 ]] \
        || die "fstab ya tiene una entrada para UUID=$uuid; no se modificó nada"

    mkdir -p -- "$mountpoint"
    create_fstab_backup
    FSTAB_DIRTY=1

    # Asegurar salto de línea final antes de añadir
    if [[ -s "$FSTAB" && -n "$(tail -c1 "$FSTAB")" ]]; then
        if ! printf '\n' >> "$FSTAB"; then
            FSTAB_DIRTY=0
            die "no se pudo escribir en fstab; fstab intacto, backup en $FSTAB_BACKUP"
        fi
    fi
    local opts="defaults,noatime,nofail,x-systemd.device-timeout=5s"
    if [[ "$fstype" == "ntfs-3g" || "$fstype" == "exfat" ]] \
        && [[ "${SUDO_UID:-0}" =~ ^[0-9]+$ && "${SUDO_UID:-0}" -ne 0 ]]; then
        opts+=",uid=${SUDO_UID},gid=${SUDO_GID:-$SUDO_UID}"
    fi
    if ! printf 'UUID=%s %s %s %s 0 %s\n' \
        "$uuid" "$mountpoint" "$fstype" "$opts" "$pass" >> "$FSTAB"; then
        local rollback_tmp
        rollback_tmp="$(mktemp "${FSTAB}.rollback.XXXXXXXX" 2>/dev/null)" || true
        if [[ -n "$rollback_tmp" ]] \
            && cp -a --remove-destination -- "$FSTAB_BACKUP" "$rollback_tmp" 2>/dev/null \
            && mv -f -- "$rollback_tmp" "$FSTAB" 2>/dev/null; then
            FSTAB_DIRTY=0
            die "no se pudo escribir en fstab; fstab restaurado desde $FSTAB_BACKUP"
        else
            rm -f -- "$rollback_tmp" 2>/dev/null || true
            die "no se pudo escribir en fstab y falló la restauración; backup en $FSTAB_BACKUP"
        fi
    fi

    systemctl daemon-reload || true
    if ! mount -- "$mountpoint"; then
        # Restauración atómica: temp + mv sobre el mismo directorio.
        # mv dentro del mismo filesystem es rename(2), atómico.
        local rollback_tmp
        rollback_tmp="$(mktemp "${FSTAB}.rollback.XXXXXXXX")" \
            || die "no se pudo montar $mountpoint y no se pudo preparar la restauración; fstab intacto, backup en $FSTAB_BACKUP"
        if ! cp -a --remove-destination -- "$FSTAB_BACKUP" "$rollback_tmp" \
            || ! mv -f -- "$rollback_tmp" "$FSTAB"; then
            rm -f -- "$rollback_tmp" 2>/dev/null || true
            die "no se pudo montar $mountpoint y falló la restauración; fstab sin cambios, backup en $FSTAB_BACKUP"
        fi
        systemctl daemon-reload || true
        die "no se pudo montar $mountpoint; fstab restaurado desde $FSTAB_BACKUP"
    fi
    FSTAB_DIRTY=0
    prune_fstab_backups
    log "montado en $mountpoint y añadido a fstab (backup: $FSTAB_BACKUP)"
}

cmd_unmount() {
    local uuid="$1"
    local expected_mountpoint="$2"
    local dev

    require_root
    validate_uuid "$uuid"
    validate_mountpoint "$expected_mountpoint"
    dev="$(resolve_device "$uuid")"

    load_mount_targets "$dev"
    [[ "${#ACTIVE_TARGETS[@]}" -eq 1 ]] \
        || die "se esperaba exactamente un punto de montaje activo; no se modificó nada"
    [[ "${ACTIVE_TARGETS[0]}" == "$expected_mountpoint" ]] \
        || die "el punto de montaje activo no coincide con el esperado; no se modificó nada"

    # Deliberadamente no lee ni escribe FSTAB. Nunca usar umount -f ni -l.
    umount -- "$expected_mountpoint" \
        || die "no se pudo desmontar $expected_mountpoint; fstab no fue modificada"
    log "desmontado ahora: $expected_mountpoint (fstab no se modificó)"
}

cmd_disable() {
    local uuid="$1"
    local expected_mountpoint="$2"
    local dev
    local -a fstab_targets=()

    require_root
    validate_uuid "$uuid"
    validate_mountpoint "$expected_mountpoint"
    [[ -r "$FSTAB" ]] || die "no se puede leer fstab: $FSTAB"

    mapfile -t fstab_targets < <(fstab_targets_for_uuid "$uuid")
    [[ "${#fstab_targets[@]}" -eq 1 ]] \
        || die "se esperaba exactamente una entrada de fstab para UUID=$uuid; no se modificó nada"
    [[ "${fstab_targets[0]}" == "$expected_mountpoint" ]] \
        || die "el punto de montaje de fstab no coincide con el esperado; no se modificó nada"

    dev="$(resolve_device "$uuid")"
    load_mount_targets "$dev"
    [[ "${#ACTIVE_TARGETS[@]}" -le 1 ]] \
        || die "el disco tiene varios puntos de montaje activos; no se modificó fstab"
    if [[ "${#ACTIVE_TARGETS[@]}" -eq 1 && "${ACTIVE_TARGETS[0]}" != "$expected_mountpoint" ]]; then
        die "el punto de montaje activo no coincide con el esperado; no se modificó fstab"
    fi

    # El backup se crea antes del desmontaje y de cualquier cambio en fstab.
    create_fstab_backup
    FSTAB_DIRTY=1

    if [[ "${#ACTIVE_TARGETS[@]}" -eq 1 ]]; then
        # Sin opciones de fuerza: si está ocupado, umount falla y fstab queda intacta.
        if ! umount -- "$expected_mountpoint"; then
            die "no se pudo desmontar $expected_mountpoint; la entrada de fstab se conservó"
        fi
    fi

    # Seguridad R7: confirmar que el destino ya no está montado antes de tocar fstab.
    # /proc/self/mountinfo no tiene la ambigüedad de findmnt.
    if awk -v mp="$expected_mountpoint" '$5 == mp { found=1 } END { exit !found }' /proc/self/mountinfo; then
        die "el destino $expected_mountpoint sigue montado; no se modifica fstab"
    fi

    remove_fstab_entry "$uuid" "$expected_mountpoint"
    FSTAB_DIRTY=0
    prune_fstab_backups
    if ! systemctl daemon-reload; then
        log "AVISO: fstab se actualizó, pero systemd no pudo recargarse"
    fi
    log "montaje eliminado de fstab; backup conservado en: $FSTAB_BACKUP"
}

main() {
    case "${1:-}" in
        --list)
            cmd_list
            ;;
        --mount)
            [[ $# -eq 3 ]] || die "uso: $PROG --mount <UUID> <punto_de_montaje>"
            cmd_mount "$2" "$3"
            ;;
        --unmount)
            [[ $# -eq 3 ]] || die "uso: $PROG --unmount <UUID> <punto_de_montaje>"
            cmd_unmount "$2" "$3"
            ;;
        --disable)
            [[ $# -eq 3 ]] || die "uso: $PROG --disable <UUID> <punto_de_montaje>"
            cmd_disable "$2" "$3"
            ;;
        *)
            die "uso: $PROG --list | --mount <UUID> <punto_de_montaje> | --unmount <UUID> <punto_de_montaje> | --disable <UUID> <punto_de_montaje>"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
