#!/usr/bin/env bash
#
# montar_disco.sh - Detecta, monta y desmonta discos secundarios.
#
# Uso:
#   montar_disco.sh --list
#       Lista discos candidatos (excluye el disco raíz, /boot y swap)
#       en formato: NAME|FSTYPE|LABEL|UUID|SIZE|MOUNTPOINT
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
FSTAB="/etc/fstab"

log()  { printf '[%s] %s\n' "$PROG" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; }
die()  { err "$*"; exit 1; }

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
    local device
    device="$(blkid -U "$uuid")" || die "no se encontró ningún disco con UUID $uuid"
    [[ -n "$device" ]] || die "no se encontró ningún disco con UUID $uuid"
    printf '%s\n' "$device"
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

    if output="$(findmnt --raw --noheadings --source "$device" --output TARGET)"; then
        :
    else
        status=$?
        # findmnt devuelve 1 cuando no hay coincidencias; otros errores no
        # deben interpretarse como un disco desmontado.
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

    backup="$(mktemp "${FSTAB}.bak.XXXXXXXX")" || die "no se pudo crear un backup de fstab"
    if ! cp -a --remove-destination -- "$FSTAB" "$backup"; then
        rm -f -- "$backup"
        die "no se pudo crear el backup de fstab"
    fi
    FSTAB_BACKUP="$backup"
    log "backup de fstab creado en: $FSTAB_BACKUP"
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

    lsblk -P -o NAME,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINT,TYPE |
    while IFS= read -r line; do
        eval "$line"   # crea NAME= FSTYPE= LABEL= UUID= SIZE= MOUNTPOINT= TYPE=

        # Solo particiones/discos con sistema de archivos real
        [[ -n "${FSTYPE:-}" ]] || continue
        [[ "$FSTYPE" != "swap" ]] || continue

        local dev="/dev/${NAME}"

        # Excluye el disco/partición raíz actual
        [[ "$dev" != "$root_src" ]] || continue

        # Excluye lo que ya está montado en /, /boot, /home, etc.
        case "${MOUNTPOINT:-}" in
            "/"|/boot*|/home|/var*|/root|/srv) continue ;;
        esac

        local -a fstab_targets=()
        local fstab_target=""
        if [[ -n "${UUID:-}" && -r "$FSTAB" ]]; then
            mapfile -t fstab_targets < <(fstab_targets_for_uuid "$UUID")
            [[ "${#fstab_targets[@]}" -eq 1 ]] && fstab_target="${fstab_targets[0]}"
        fi

        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
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
            command -v mount.exfat >/dev/null 2>&1 \
                || die "filesystem exFAT pero no está instalado exfatprogs/exfat-utils"
            ;;
        *) die "filesystem '$fstype' no soportado por este script" ;;
    esac

    # ¿Ya está montado en algún sitio?
    local current_mp
    current_mp="$(findmnt -n -o TARGET "$dev" || true)"
    if [[ -n "$current_mp" ]]; then
        log "el disco ya está montado en: $current_mp"
    else
        mkdir -p "$mountpoint"
        mount -U "$uuid" "$mountpoint"
        log "montado correctamente en: $mountpoint"
    fi

    # ¿Ya existe una entrada para este UUID en fstab?
    if grep -qE "^[^#]*UUID=${uuid}[[:space:]]" "$FSTAB"; then
        log "fstab: ya existe una entrada para UUID=$uuid, no se modifica"
        return 0
    fi

    local backup
    backup="${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$FSTAB" "$backup"
    log "backup de fstab creado en: $backup"

    printf 'UUID=%s  %s  %s  defaults,noatime  0  2\n' "$uuid" "$mountpoint" "$fstype" >> "$FSTAB"
    log "entrada añadida a fstab"

    systemctl daemon-reload
    mount -a
    log "fstab recargado y verificado con 'mount -a'"
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

    if [[ "${#ACTIVE_TARGETS[@]}" -eq 1 ]]; then
        # Sin opciones de fuerza: si está ocupado, umount falla y fstab queda intacta.
        if ! umount -- "$expected_mountpoint"; then
            die "no se pudo desmontar $expected_mountpoint; la entrada de fstab se conservó"
        fi
    fi

    remove_fstab_entry "$uuid" "$expected_mountpoint"
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
