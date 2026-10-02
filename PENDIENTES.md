# Pendientes tras C1

Publicado en main: C1, C2, E1, E4, R1, R2, R4 (y de paso E2 y E3, cubiertos por C1).

Pendientes de probar en Debian, Ubuntu, Arch y Fedora:

- R7: findmnt y load_mount_targets tratan un error de consulta como "no montado". Requiere verificar cómo se comportan findmnt con NTFS, exFAT-FUSE, LUKS y Btrfs multidispositivo.

Mejoras menores:

- El rollback de cmd_mount usa cp -a directo sobre fstab; podría ser atómico (temp + mv) como remove_fstab_entry.
- R3: cmd_mount y fstab_targets_for_uuid usan criterios distintos para reconocer el UUID en fstab (grep vs awk).
- R5: la cancelación con SIGKILL puede dejar el comando corriendo como root en algunas versiones de sudo con use_pty. No hay trap.

### R7. Estado de montaje basado en códigos de salida de findmnt

Confirmado empíricamente con un shim de findmnt que devuelve 1 al consultar con --source.

findmnt devuelve 1 tanto para "sin coincidencias" como para cualquier error (según su man). El código interpreta 1 como "sin montajes" y findmnt -M en cmd_mount se comporta igual.

Impacto por operación:
- --unmount: exige exactamente un punto activo; con una lista vacía falsa aborta sin tocar nada.
- --mount: la comprobación de destino ocupado puede dar un falso "libre". Mitigado por el rollback y por la comprobación independiente de destinos en fstab.
- --disable: con una lista vacía falsa se saltaba umount y borraba la entrada de fstab con el disco aún montado. Mitigado con la comprobación en /proc/self/mountinfo antes de remove_fstab_entry (verificado con shim: Caso A aborta con fstab intacto).

Solución completa prevista: consultar findmnt sin filtro (la lista nunca está vacía) y emparejar por ruta canónica, abortando ante cualquier error; comprobar el destino con /proc/self/mountinfo en cmd_mount. Requiere probar NTFS, exFAT-FUSE, LUKS y Btrfs (subvolúmenes y multidispositivo).

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
