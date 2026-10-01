#!/usr/bin/env bash
#
# montar_disco.sh - Detecta discos secundarios, los monta y los deja
# persistentes en /etc/fstab de forma idempotente.
#
# Uso:
#   montar_disco.sh --list
#       Lista discos candidatos (excluye el disco raíz, /boot y swap)
#       en formato: NAME|FSTYPE|LABEL|UUID|SIZE|MOUNTPOINT
#
#   montar_disco.sh --mount <UUID> <punto_de_montaje>
#       Monta el disco identificado por UUID en el punto indicado
#       y añade la entrada a fstab si no existe ya.

set -euo pipefail

PROG="$(basename "$0")"
FSTAB="/etc/fstab"

log()  { printf '[%s] %s\n' "$PROG" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
    [[ "$EUID" -eq 0 ]] || die "esta operación requiere sudo/root"
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

        printf '%s|%s|%s|%s|%s|%s\n' \
            "$NAME" "$FSTYPE" "${LABEL:-}" "${UUID:-}" "$SIZE" "${MOUNTPOINT:-}"
    done
}

cmd_mount() {
    local uuid="$1"
    local mountpoint="$2"

    require_root

    [[ "$uuid" =~ ^[A-Za-z0-9-]+$ ]] || die "UUID con formato inesperado: $uuid"
    [[ "$mountpoint" == /mnt/* ]] || die "por seguridad, el punto de montaje debe estar bajo /mnt/"

    local dev
    dev="$(blkid -U "$uuid")" || die "no se encontró ningún disco con UUID $uuid"

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

main() {
    case "${1:-}" in
        --list)
            cmd_list
            ;;
        --mount)
            [[ $# -eq 3 ]] || die "uso: $PROG --mount <UUID> <punto_de_montaje>"
            cmd_mount "$2" "$3"
            ;;
        *)
            die "uso: $PROG --list | --mount <UUID> <punto_de_montaje>"
            ;;
    esac
}

main "$@"
