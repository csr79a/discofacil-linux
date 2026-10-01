# DiscoFácil Linux

Una pequeña herramienta con interfaz gráfica para identificar una partición de datos, montarla bajo `/mnt` y añadir una entrada basada en UUID a `/etc/fstab` para que se monte al iniciar Linux.

> **Estado: experimental.** Se ha probado en un solo equipo. El objetivo es admitir distribuciones Linux comunes como Debian, Ubuntu, Arch Linux y Fedora, pero todavía no se ha verificado en todas ellas. Lee las limitaciones y precauciones antes de usarla.

## Qué incluye

- `mount_disco_gui.py`: interfaz gráfica en PyQt6.
- `montar_disco.sh`: lista particiones candidatas y realiza el montaje.

La aplicación no formatea ni borra discos. Para montar y editar `/etc/fstab`, solicita privilegios mediante `sudo`. Antes de añadir una entrada, el script crea una copia de seguridad de `fstab`.

## Requisitos

- Una distribución **Linux con systemd** y una sesión gráfica. Debian, Ubuntu, Arch Linux y Fedora suelen cumplir este requisito con sus instalaciones estándar.
- Bash y herramientas de `util-linux`: `lsblk`, `findmnt`, `blkid` y `mount`.
- Python 3.10 o posterior y PyQt6.
- `sudo` para realizar el montaje persistente.
- Para NTFS, `ntfs-3g`; para exFAT, un paquete que proporcione `mount.exfat`.

La disponibilidad y el nombre de los paquetes pueden variar entre distribuciones. Los sistemas de archivos admitidos por el script son ext2/3/4, Btrfs, XFS, NTFS y exFAT, sujetos a que esté instalado el controlador correspondiente.

## Descargar y ejecutar

Clona el repositorio (reemplaza `USUARIO` por el nombre de la cuenta que lo publique):

```bash
git clone https://github.com/USUARIO/discofacil-linux.git
cd discofacil-linux
```

Inicia la interfaz:

```bash
python3 mount_disco_gui.py
```

La ventana lista las particiones candidatas. Selecciona una, revisa cuidadosamente el UUID y el punto de montaje sugerido, y pulsa **Montar y dejar permanente**. `sudo` solicitará la contraseña cuando sea necesario.

También se puede usar el script desde una terminal:

```bash
# Listar particiones candidatas (no modifica el sistema)
bash montar_disco.sh --list

# Montar una partición y añadirla a /etc/fstab
sudo bash montar_disco.sh --mount UUID /mnt/nombre
```

Sustituye `UUID` por el UUID exacto de la partición. El punto de montaje debe estar bajo `/mnt`; usa un nombre sencillo, por ejemplo `/mnt/juegos`.

## Precauciones y limitaciones conocidas

- Comprueba dos veces el dispositivo y su UUID antes de confirmar. Un montaje puede ocultar temporalmente los archivos que ya existan en el directorio de destino.
- El script modifica `/etc/fstab`. Aunque crea una copia antes de añadir una entrada, revisa el resultado y conserva una copia de seguridad propia.
- La comprobación actual del punto de montaje solo verifica que la ruta comience por `/mnt/`; no normaliza todos los componentes de la ruta. **No introduzcas rutas con `..`, rutas extrañas ni destinos que no controles.** Esta validación debe mejorarse antes de considerar el programa listo para uso general.
- Si la partición ya está montada en otro lugar, el script puede informar que ya está montada y aun así intentar guardar el destino solicitado en `fstab`. Comprueba que el destino elegido coincide con el montaje actual.
- No se ha probado todavía en una matriz de Debian, Ubuntu, Arch y Fedora, ni en todas sus variantes. Tampoco está pensado para macOS o Windows, ni para distribuciones que no usen systemd.

## Compatibilidad y aportes

Los informes de errores y pruebas en distintas distribuciones son bienvenidos. Incluye la distribución y versión, el entorno de escritorio, el tipo de sistema de archivos y el mensaje de error. **No publiques UUID privados, contraseñas ni información personal del equipo.**

## Licencia

Este repositorio todavía no incluye una licencia. Antes de publicarlo, el autor debe elegir una licencia si desea permitir explícitamente que otras personas reutilicen o modifiquen el código.
