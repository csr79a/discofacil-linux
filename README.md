# DiscoFácil Linux

Una pequeña herramienta con interfaz gráfica para identificar particiones de datos, montarlas bajo `/mnt` y administrar su montaje persistente en `/etc/fstab`.

> **Estado: experimental.** Probada en Debian 13, Ubuntu 26.04, Fedora 44 y CachyOS. Lee las limitaciones y precauciones antes de usarla.

## Qué incluye

- `mount_disco_gui.py`: interfaz gráfica en PyQt6.
- `montar_disco.sh`: lista, monta y desmonta particiones.

La aplicación no formatea ni borra discos. Para montar, desmontar y editar `/etc/fstab`, solicita privilegios mediante `sudo`. Cada cambio en `/etc/fstab` crea una copia (`/etc/fstab.discofacil-bak.XXXXXXXX`); se conservan las 5 más recientes y las anteriores se borran tras una operación correcta. «Desmontar ahora» (`--unmount`) no crea copias.

## Requisitos

- Una distribución **Linux con systemd** y una sesión gráfica. Debian, Ubuntu, Arch Linux y Fedora suelen cumplir este requisito con sus instalaciones estándar.
- Bash y herramientas de `util-linux`: `lsblk`, `findmnt`, `blkid` y `mount`.
- Python 3.10 o posterior y PyQt6.
- `sudo` para realizar el montaje persistente. Algunas instalaciones mínimas pueden no incluirlo; instálalo antes de usar la herramienta.
- Para NTFS, `ntfs-3g`. Para exFAT basta con el soporte nativo del kernel (Linux 5.7 o posterior); si no está disponible, `exfat-fuse` o `exfatprogs`.

La disponibilidad y el nombre de los paquetes pueden variar entre distribuciones. Los sistemas de archivos admitidos por el script son ext2/3/4, Btrfs, XFS, NTFS y exFAT, sujetos a que esté instalado el controlador correspondiente.

## Descargar y ejecutar

Clona el repositorio:

```bash
git clone https://github.com/csr79a/discofacil-linux.git
cd discofacil-linux
```

Inicia la interfaz:

```bash
python3 mount_disco_gui.py
```

La ventana lista las particiones candidatas y muestra su punto de montaje actual y su configuración de inicio.

- **Montar y dejar permanente**: monta el disco y añade su UUID a `/etc/fstab`.
- **Desmontar ahora**: desmonta solo la sesión actual; no consulta ni modifica `/etc/fstab`. Si tiene una entrada persistente, volverá a montarse al iniciar.
- **Desmontar y quitar del inicio**: guarda una copia de `fstab`, desmonta el disco y quita únicamente la entrada inequívoca de ese UUID. Si el disco está ocupado, hay más de un montaje o los puntos no coinciden, aborta sin cambiar `fstab`.

Las opciones de desmontaje nunca fuerzan la operación. `sudo` solicitará la contraseña cuando sea necesario.

También se puede usar el script desde una terminal:

```bash
# Listar particiones candidatas (no modifica el sistema)
bash montar_disco.sh --list

# Montar una partición y añadirla a /etc/fstab
sudo bash montar_disco.sh --mount UUID /mnt/nombre

# Desmontar ahora, sin modificar fstab
sudo bash montar_disco.sh --unmount UUID /mnt/nombre

# Desmontar y quitar la entrada persistente exacta de fstab
sudo bash montar_disco.sh --disable UUID /mnt/nombre
```

Sustituye `UUID` por el UUID exacto de la partición y usa el punto de montaje canónico que aparece en la lista, por ejemplo `/mnt/juegos`. Solo se admiten rutas sencillas bajo `/mnt`, sin espacios, enlaces simbólicos ni componentes `.` o `..`.

## Pruebas

Las pruebas del repositorio usan un `fstab` temporal y simulaciones de `findmnt`, `umount` y `systemctl`; no desmontan unidades reales ni escriben en `/etc/fstab`:

```bash
bash tests/test_mount_operations.sh
```

Cubren las operaciones de desmontaje, reversión y la compuerta de `DISCOFACIL_FSTAB` (que solo se respeta con `DISCOFACIL_TEST=1`). Otras tres pruebas requieren `sudo`: usan dispositivos de bucle y `unshare -m`, no tocan el `/etc/fstab` real, y salen con código 77 si no pueden ejecutarse.

```bash
sudo bash tests/test_fstab_rollback.sh   # rollback de --mount si el montaje falla
sudo bash tests/test_signal_trap.sh      # trap de SIGTERM, SIGINT y SIGHUP
sudo bash tests/test_btrfs_subvol.sh     # --list excluye el Btrfs raíz con /.snapshots
```

`DISCOFACIL_TEST` y `DISCOFACIL_FSTAB` son solo para el entorno de pruebas; no los uses en producción.

## Precauciones y limitaciones conocidas

- Comprueba dos veces el dispositivo y su UUID antes de confirmar. Un montaje puede ocultar temporalmente los archivos que ya existan en el directorio de destino.
- El script modifica `/etc/fstab`. Cada cambio en `/etc/fstab` crea una copia (`/etc/fstab.discofacil-bak.XXXXXXXX`); se conservan las 5 más recientes y las anteriores se borran tras una operación correcta. Las copias antiguas con otros nombres (por ejemplo `/etc/fstab.bak.*`) no se tocan nunca; el script solo borra las suyas (`/etc/fstab.discofacil-bak.*`). «Desmontar ahora» no crea copias. Revisa el resultado y conserva una copia propia.
- `--mount` valida antes de escribir en `fstab`: rechaza si el disco ya está montado en otro sitio, si el destino ya tiene algo montado, o si `fstab` ya usa ese destino o ya tiene una entrada para ese UUID. La entrada se escribe con `nofail`, de modo que un disco ausente no bloquee el arranque.
- Si el montaje falla después de escribir la entrada, `--mount` intenta restaurar `fstab` desde la copia de seguridad. La restauración es atómica (archivo temporal + `mv`), y una interrupción con `SIGINT`, `SIGTERM` o `SIGHUP` también restaura `fstab`.
- Los puntos de montaje deben ser rutas canónicas sencillas bajo `/mnt`. Los desmontajes comparan el UUID, el destino persistente y los montajes activos; ante discrepancias o ambigüedades se niegan a continuar.
- Probado en Debian 13, Ubuntu 26.04, Fedora 44 y CachyOS (Arch-based), con ext4, NTFS, exFAT y Btrfs de un solo dispositivo; LUKS y Btrfs multidevice no están soportados y se excluyen de la lista. Cubre las tres familias principales (Debian/Ubuntu, Red Hat, Arch) en --list, --mount, --unmount y --disable. No está pensado para macOS o Windows, ni para distribuciones que no usen systemd.
- Limitaciones conocidas: no se admiten Btrfs multidevice ni UUID duplicados (`--mount` aborta si hay más de un dispositivo con el mismo UUID). En NTFS y exFAT se añaden `uid`/`gid` del usuario que ejecutó `sudo` (`SUDO_UID`); si esa variable no existe, el montaje queda accesible solo para root. En ext4, Btrfs y XFS el punto de montaje queda como `root:root`: ajusta propietario o permisos a mano si lo necesitas. El historial de cambios y las decisiones aplazadas están en `HISTORIAL.md`.

## Compatibilidad y aportes

Los informes de errores y pruebas en distintas distribuciones son bienvenidos. Incluye la distribución y versión, el entorno de escritorio, el tipo de sistema de archivos y el mensaje de error. **No publiques UUID privados, contraseñas ni información personal del equipo.**

## Licencia

Este repositorio todavía no incluye una licencia. Antes de publicarlo, el autor debe elegir una licencia si desea permitir explícitamente que otras personas reutilicen o modifiquen el código.
