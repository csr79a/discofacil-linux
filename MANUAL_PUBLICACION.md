# Manual: crear y publicar el repositorio en GitHub

Esta guía publica los programas, la documentación y las pruebas desde `~/Descargas/montar_disco`. No subas archivos adicionales de tu equipo.

## 1. Elige el nombre

Nombre sugerido para mostrar: **DiscoFácil Linux**  
Nombre del repositorio: **`discofacil-linux`**  
Descripción sugerida: `Interfaz gráfica para montar discos de datos en Linux y configurar su montaje persistente.`

Antes de decidirte, busca `discofacil-linux` en GitHub para comprobar que el nombre esté disponible.

## 2. Decide la visibilidad y la licencia

En GitHub, elige si el repositorio será **público** o **privado**. Si lo haces público, cualquiera podrá ver el código.

Decide también la licencia antes de anunciarlo. Publicar el código sin una licencia no concede automáticamente permiso para reutilizarlo o distribuir versiones modificadas. Si eliges una licencia, añade el archivo correspondiente, normalmente llamado `LICENSE`, dentro de `montar_disco` antes de continuar.

## 3. Crea el repositorio vacío en GitHub

1. Inicia sesión en [github.com](https://github.com/).
2. Pulsa **New repository** (o **Nuevo repositorio**).
3. Escribe `discofacil-linux` como nombre.
4. Añade la descripción sugerida y elige la visibilidad.
5. Como ya tienes archivos locales, crea el repositorio **sin** README, `.gitignore` ni licencia automáticos. Evita iniciar el repositorio remoto con archivos para no crear historiales distintos.
6. Pulsa **Create repository**. Deja abierta la página: muestra la dirección que necesitarás en el siguiente paso.

## 4. Prepara Git en tu equipo

Abre una terminal y entra en la carpeta del proyecto:

```bash
cd ~/Descargas/montar_disco
```

Comprueba qué archivos hay; deberían estar los dos programas, los documentos y `.gitignore`:

```bash
ls -la
```

Si Git no está instalado, instálalo desde el gestor de paquetes de tu distribución. Configura tu nombre y correo para los commits si aún no lo has hecho:

```bash
git config --global user.name "Tu nombre"
git config --global user.email "tu-correo@example.com"
```

Usa el correo asociado a tu cuenta de GitHub si quieres que GitHub relacione el commit con tu perfil.

## 5. Crea el commit inicial

Ejecuta estos comandos desde `~/Descargas/montar_disco`:

```bash
git init -b main
git add .gitignore README.md MANUAL_PUBLICACION.md montar_disco.sh mount_disco_gui.py tests/test_mount_operations.sh
```

Si añadiste una licencia, inclúyela también, por ejemplo con `git add LICENSE`. Antes de confirmar, revisa exactamente qué se va a subir:

```bash
git status
git diff --cached --stat
```

Si aparecen archivos que no quieres publicar, no continúes hasta quitarlos del área preparada con `git restore --staged NOMBRE_DEL_ARCHIVO`.

Cuando la lista sea correcta:

```bash
git commit -m "Publica la primera versión de DiscoFácil Linux"
```

## 6. Conecta el repositorio y sube los archivos

En la página del repositorio de GitHub, copia la dirección HTTPS. Sustituye `USUARIO` si corresponde:

```bash
git remote add origin https://github.com/USUARIO/discofacil-linux.git
git remote -v
git push -u origin main
```

GitHub puede pedir autenticación. Para HTTPS, normalmente se usa el navegador o un token, no la contraseña de tu cuenta. **No pongas tokens ni contraseñas en los comandos, documentos o archivos del proyecto.**

Al terminar, actualiza la página del repositorio y confirma que aparecen los archivos esperados.

## 7. Para publicar cambios después

Desde la carpeta del proyecto:

```bash
git status
git add .gitignore README.md MANUAL_PUBLICACION.md montar_disco.sh mount_disco_gui.py tests/test_mount_operations.sh
git diff --cached --stat
git commit -m "Describe brevemente el cambio"
git push
```

Revisa siempre el estado y los archivos preparados antes de cada `git commit` y `git push`.
