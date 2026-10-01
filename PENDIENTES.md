# Pendientes tras C1

Publicado en main: C1, C2, E1, E4, R1, R2, R4 (y de paso E2 y E3, cubiertos por C1).

Pendientes de probar en Debian, Ubuntu, Arch y Fedora:

- R7: findmnt y load_mount_targets tratan un error de consulta como "no montado". Requiere verificar cómo se comportan findmnt con NTFS, exFAT-FUSE, LUKS y Btrfs multidispositivo.
- R6: blkid -U devuelve solo el primero si hay UUID duplicados. Requiere validar blkid -t en las cuatro distribuciones. Btrfs multidispositivo queda sin soporte por ahora.

Mejoras menores:

- El rollback de cmd_mount usa cp -a directo sobre fstab; podría ser atómico (temp + mv) como remove_fstab_entry.
- R3: cmd_mount y fstab_targets_for_uuid usan criterios distintos para reconocer el UUID en fstab (grep vs awk).
- R5: la cancelación con SIGKILL puede dejar el comando corriendo como root en algunas versiones de sudo con use_pty. No hay trap.
