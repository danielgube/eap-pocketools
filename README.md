# EAP Pocketools

Repositorio público de utilidades pequeñas, portables y gestionadas por EAP.
Cada Pocketool vive en su propia carpeta, declara su contrato en
`pocketool.json` y EAP la descarga directamente desde el árbol `main` del
repositorio. No hay catálogos generados, ZIPs, tags ni GitHub Releases.

## Estructura

```text
pocketools/<id>/
  pocketool.json              manifiesto fuente
  README.md                   ayuda ampliada
  src/                        código de la utilidad
scripts/test.py               valida contratos y comportamiento
```

## Crear una Pocketool

El contrato completo, los tipos de comando, las restricciones de seguridad y
el procedimiento de prueba están en
[`CREAR_POCKETOOLS.md`](CREAR_POCKETOOLS.md).

## Pocketools disponibles

- `sessionkeep`: mantiene activa la sesión de Windows durante tareas largas.
- `ssltruster`: aprueba URLs HTTPS y verifica la confianza TLS con Windows,
  EAP y los runtimes activos sin desactivar la validación.
- `zipme`: empaqueta el fuente de un proyecto respetando `.gitignore` o,
  cuando no existe, omitiendo artefactos reconstruibles habituales.

## Desarrollo y publicación

```powershell
python scripts/test.py
```

Para publicar una versión:

1. Actualizar el código y `version` en el manifiesto.
2. Ejecutar `python scripts/test.py`.
3. Hacer commit y push a `main`.

En la siguiente actualización del índice, EAP descubre automáticamente el
manifiesto. La versión debe incrementarse cuando cambie el comportamiento o el
código instalado.

## Contrato de seguridad

- EAP fija cada instalación al commit de `main` consultado y descarga los
  archivos desde `raw.githubusercontent.com` usando ese commit.
- El tamaño y el identificador de cada blob se contrastan con el árbol GitHub.
- Los paquetes no tienen hooks de instalación ni pueden escribir fuera de su
  payload durante la instalación.
- Los datos mutables se guardan en la ruta `EAP_POCKETOOL_DATA` que proporciona
  EAP y no dentro del paquete versionado.
- Las dependencias se declaran como Pocketools o capacidades de componentes;
  EAP las resuelve antes de ejecutar el comando.

Licencia: MIT.
