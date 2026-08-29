# ZipMe

Empaqueta un proyecto para compartir solamente su fuente y los archivos que
forman parte del trabajo. La ejecución más habitual no necesita argumentos:

```text
cd C:\proyectos\mi-aplicacion
zipme
```

El resultado será `C:\proyectos\mi-aplicacion\mi-aplicacion.7z`. El archivo se
reconstruye por completo en cada ejecución; nunca conserva entradas obsoletas
de una compresión anterior y nunca se incluye a sí mismo.

También se puede indicar otro proyecto, elegir el destino o crear un ZIP:

```text
zipme C:\proyectos\otra-aplicacion
zipme . -Output C:\transferencias\fuentes.7z
zipme . -Output C:\transferencias\fuentes.zip
zipme . -List
zipme --help
```

## Selección de archivos

Si existe un `.gitignore` en la raíz, ZipMe aplica sus reglas y las de los
`.gitignore` anidados. Cuando `git.exe` está disponible utiliza el propio motor
de Git sobre metadatos temporales, por lo que no importa que el proyecto real
sea Git, SVN o no use control de versiones. Si Git no está disponible se usa un
intérprete integrado compatible con los patrones habituales, incluidos `*`,
`**`, `?`, rutas ancladas, directorios y negaciones con `!`.

Si no existe `.gitignore`, ZipMe omite automáticamente los artefactos más
habituales: `target`, `node_modules`, `dist`, `build`, `bin`, `obj`, entornos y
cachés de Python, salidas de cobertura, carpetas de IDE y metadatos de Git, SVN
o Mercurial. No elimina dependencias binarias o carpetas `vendor` que podrían
ser necesarias para trabajar offline.

Los enlaces simbólicos y junctions se omiten para impedir que el archivo salga
accidentalmente de la carpeta del proyecto. La compresión usa el 7-Zip incluido
en EAP; Git es opcional.
