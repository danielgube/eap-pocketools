# EAP Pocketools

Repositorio público de utilidades pequeñas, portables y gestionadas por EAP.
Cada Pocketool vive en su propia carpeta, declara su contrato en
`pocketool.json` y se publica como un ZIP verificable. EAP consume
`pocketools.catalog.json`; no necesita Git para instalar una utilidad.

## Estructura

```text
pocketools.catalog.json       catálogo generado y consumido por EAP
pocketools/<id>/
  pocketool.json              manifiesto fuente
  README.md                   ayuda ampliada
  src/                        código de la utilidad
scripts/build.py              genera ZIPs y catálogo con SHA256
```

## Desarrollo y publicación

```powershell
python scripts/build.py
python scripts/test.py
```

El catálogo y los ZIPs son deterministas. Para publicar una versión:

1. Actualizar el código y `version` en el manifiesto.
2. Ejecutar `python scripts/build.py` y versionar el catálogo resultante.
3. Crear y subir el tag `<id>-v<version>`, por ejemplo
   `sessionkeep-v1.0.0`.

La automatización crea la GitHub Release y adjunta el ZIP cuyo nombre está
declarado en el catálogo.

## Contrato de seguridad

- Los artefactos se descargan sólo por HTTPS y se verifican con SHA256.
- Los paquetes no tienen hooks de instalación ni pueden escribir fuera de su
  payload durante la instalación.
- Los datos mutables se guardan en la ruta `EAP_POCKETOOL_DATA` que proporciona
  EAP y no dentro del paquete versionado.
- Las dependencias se declaran como Pocketools o capacidades de componentes;
  EAP las resuelve antes de ejecutar el comando.

Licencia: MIT.
