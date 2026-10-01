# DiscoFácil Linux

Una pequeña herramienta con interfaz gráfica para identificar particiones de datos, montarlas bajo `/mnt` y administrar su montaje persistente en `/etc/fstab`.

> **Estado: experimental.** Se ha probado en un solo equipo. El objetivo es admitir distribuciones Linux comunes como Debian, Ubuntu, Arch Linux y Fedora, pero todavía no se ha verificado en todas ellas. Lee las limitaciones y precauciones antes de usarla.

## Qué incluye

- `mount_disco_gui.py`: interfaz gráfica en PyQt6.
- `montar_disco.sh`: lista, monta y desmonta particiones.

La aplicación no formatea ni borra discos. Para montar, desmontar y editar `/etc/fstab`, solicita privilegios mediante `sudo`. Antes de añadir o quitar una entrada, el script crea una copia de seguridad de `fstab`.

## Requisitos

- Una distribución **Linux con systemd** y una sesión gráfica. Debian, Ubuntu, Arch Linux y Fedora suelen cumplir este requisito con sus instalaciones estándar.
- Bash y herramientas de `util-linux`: `lsblk`, `findmnt`, `blkid` y `mount`.
- Python 3.10 o posterior y PyQt6.
- `sudo` para realizar el montaje persistente.
- Para NTFS, `ntfs-3g`. Para exFAT basta con el soporte nativo del kernel (>= 5.7); si no está disponible, exfat-fuse o exfatprogs.

La disponibilidad y el nombre de los paquetes pueden variar entre distribuciones. Los sistemas de archivos admitidos por el script son ext2/3/4, Btrfs, XFS, NTFS y exFAT, sujetos a que esté instalado el controlador correspondiente.

## Descargar y ejecutar

Clona el repositorio (reemplaza `USUARIO` por el nombre de la cuenta que lo publique):

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

Las pruebas de las operaciones de desmontaje usan un `fstab` temporal y simulaciones de `findmnt`, `umount` y `systemctl`; no desmontan unidades reales ni escriben en `/etc/fstab`:

```bash
bash tests/test_mount_operations.sh
```

## Precauciones y limitaciones conocidas

- Comprueba dos veces el dispositivo y su UUID antes de confirmar. Un montaje puede ocultar temporalmente los archivos que ya existan en el directorio de destino.
- El script modifica `/etc/fstab`. Aunque crea una copia antes de añadir una entrada, revisa el resultado y conserva una copia de seguridad propia.
- Los puntos de montaje deben ser rutas canónicas sencillas bajo `/mnt`. Los desmontajes comparan el UUID, el destino persistente y los montajes activos; ante discrepancias o ambigüedades se niegan a continuar.
- Si la partición ya está montada en otro lugar, el comando de montaje todavía puede avisar que ya está montada; comprueba que el destino elegido coincide con el montaje actual antes de añadir una entrada persistente.
- No se ha probado todavía en una matriz de Debian, Ubuntu, Arch y Fedora, ni en todas sus variantes. Tampoco está pensado para macOS o Windows, ni para distribuciones que no usen systemd.

## Compatibilidad y aportes

Los informes de errores y pruebas en distintas distribuciones son bienvenidos. Incluye la distribución y versión, el entorno de escritorio, el tipo de sistema de archivos y el mensaje de error. **No publiques UUID privados, contraseñas ni información personal del equipo.**

## Licencia

Este repositorio todavía no incluye una licencia. Antes de publicarlo, el autor debe elegir una licencia si desea permitir explícitamente que otras personas reutilicen o modifiquen el código.
