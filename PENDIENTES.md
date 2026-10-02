# Pendientes tras C1

Publicado en main: C1, C2, E1, E4, R1, R2, R4 (y de paso E2 y E3, cubiertos por C1).

Pendientes de probar en Debian, Ubuntu, Arch y Fedora:

- R7: findmnt y load_mount_targets tratan un error de consulta como "no montado". Requiere verificar cómo se comportan findmnt con NTFS, exFAT-FUSE, LUKS y Btrfs multidispositivo.

## Mejoras menores (resueltas)

- Rollback atómico en cmd_mount: temp + mv en vez de cp directo. Verificado con shim de mount que falla: fstab idéntico a la copia prístina, sin residuales.
- Trap SIGINT/SIGTERM: si llega una señal con modificación de fstab en curso, restaura desde el backup y sale con 130. Verificado con shim de mount lento: fstab intacto tras SIGTERM y SIGINT.
- R3 (criterios de UUID inconsistentes): ya estaba resuelto por el parche de C1. El grep original de cmd_mount fue eliminado y todas las consultas a fstab pasan por fstab_targets_for_uuid.

### R7. Estado de montaje basado en códigos de salida de findmnt (resuelto)

findmnt devuelve 1 tanto para "sin coincidencias" como para cualquier error (según su man). El código interpretaba 1 como "sin montajes".

Corregido en tres capas:

1. load_mount_targets añade una comprobación de salud previa: si findmnt no responde (sin filtro, que nunca está vacío), aborta con "findmnt no responde".
2. Con findmnt funcionando, un rc=1 en la consulta por --source es fiable: significa "sin coincidencias".
3. Las comprobaciones de destino ocupado en cmd_mount y cmd_disable usan /proc/self/mountinfo, sin la ambigüedad de findmnt -M.

Verificado con shims de findmnt:

- Caso A: findmnt falla solo en --source con rc=1 → cmd_disable aborta por /proc/self/mountinfo, fstab intacto.
- Caso B: findmnt falla solo en --source con rc=2 → aborta con "findmnt falló al consultar", fstab intacto.
- Caso C: findmnt totalmente roto → aborta por la comprobación de salud, fstab intacto.
- Caso D: findmnt normal → funcionamiento normal intacto.

### R6. UUID duplicados (corregido)

Confirmado empíricamente: con dos dispositivos de bucle clonados con el mismo UUID, blkid -U devolvía solo uno (de forma no determinista entre ejecuciones) y --mount montaba ese sin avisar.

Corregido en resolve_device: usa blkid -t UUID=... -o device, recoge todos los dispositivos y rechaza si hay más de uno. Verificado con dos imágenes clonadas: aborta con mensaje "hay 2 dispositivos con UUID=..." y no toca fstab.

Consecuencia: Btrfs multidevice queda sin soporte (blkid -t devuelve varios dispositivos por diseño). Cambia el UUID o usa Btrfs de un solo dispositivo.

## Resultados de la matriz (parcial)

Probado en Debian 13 (kernel 7.1.13) y Fedora 44 (kernel 7.2.7). Ambos con ext4, NTFS, exFAT nativo, LUKS y Btrfs multidevice.

Resultados:
- ext4, NTFS y exFAT: mount/unmount/disable OK en las dos distros.
- nofail y pass correctos en todas las entradas generadas.
- fstab final limpio tras las pruebas, sin entradas residuales.
- Prompt de sudo fijo [discofacil-sudo] verificado con LANG=de_DE.UTF-8 en Debian y Fedora.
- SELinux Enforcing en Fedora no interfiere con el script.
- Root Btrfs con subvolúmenes (Fedora) correctamente excluido de --list.

Pendiente de probar: Ubuntu 24.04 y Arch Linux.

## Fixes aplicados durante la matriz

- fix-list-filtro: --list excluye LUKS, LVM, RAID, rom y Btrfs multidevice por FSTYPE y TYPE.
- fix-list-uuid-dup: --list deduplica UUIDs. Btrfs multidevice se excluye entero; otros FS con UUID repetido (p. ej. disco + partición en Fedora) se muestran una sola vez.

## Hallazgo nuevo: exFAT y sdd1 en Fedora

En Fedora, mkfs.exfat sobre el disco entero expone el filesystem tanto en /dev/sdd como en /dev/sdd1, con el mismo UUID. El script resuelve a sdd1 al montar. En Debian monta desde /dev/sdd. Funciona igual en ambas, pero el SOURCE reportado por mount difiere. Documentado, no requiere acción.

## Resultados de la matriz — CachyOS (Arch-based)

Probado en CachyOS x86_64 con kernel 7.2.8-2-cachyos, sobre Btrfs con subvolúmenes.

Resultados:
- ext4, NTFS (fuseblk), exFAT (nativo): mount/unmount/disable OK.
- nofail y pass correctos en todas las entradas.
- --list: solo discos soportados. Raíz Btrfs con subvolúmenes (/dev/sda2[/@]) correctamente excluida. Confirma el caso que el informe marcaba como potencialmente problemático.
- fstab final limpio.

Hallazgos específicos de Arch/CachyOS (documentación de setup, no del script):
- UFW activo por defecto; bloquea SSH hasta `sudo ufw allow 22/tcp`.
- ntfsprogs es un paquete separado de ntfs-3g; necesario para formatear NTFS, no para montarlo.
- exFAT expone el FS tanto en el disco como en sdd1 (igual que Fedora).

## Resultados de la matriz — Ubuntu 26.04

Kernel 7.0.0-38-generic. Raíz ext4.

Resultados:
- ext4, NTFS (fuseblk), exFAT (nativo): mount/unmount/disable OK.
- nofail y pass correctos.
- --list: solo discos soportados. Los 13 loops de snap correctamente excluidos.
- fstab final limpio.

Diferencias con otras distros:
- exFAT monta desde /dev/sdd (como Debian). Fedora y CachyOS montan desde sdd1.
- Sin firewall activo por defecto.

## Cobertura final de la matriz

Cuatro familias cubiertas: Debian 13, Ubuntu 26.04, Fedora 44, CachyOS (Arch-based).

Todas las operaciones (--list, --mount, --unmount, --disable) probadas con:
- ext4 (sistema de archivos base).
- NTFS (ntfs-3g).
- exFAT (nativo del kernel).
- LUKS (contenedor cifrado).
- Btrfs multidevice (RAID0 con dos discos).
- Raíz Btrfs con subvolúmenes (Fedora y CachyOS).

Sin fallos encontrados. Diferencia documentada entre distros: exFAT se resuelve a /dev/sdd en Debian y Ubuntu, a /dev/sdd1 en Fedora y CachyOS.

## Hallazgo de la matriz Ubuntu: prompt sudo envuelto

En Ubuntu, sudo con -p "[discofacil-sudo] " produce:

[sudo: [discofacil-sudo] ] Password:

Ubuntu envuelve el prompt con "[sudo: " delante y "] Password:" detrás. La regex original exigía el marcador al final de la línea, así que no coincidía en Ubuntu y la GUI no activaba el modo password.

Corregido: la regex ahora es \[discofacil-sudo\], que busca el marcador en cualquier posición. Cubre Debian, Fedora, CachyOS y Ubuntu.
