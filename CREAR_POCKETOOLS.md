# Manual para crear Pocketools EAP

Esta guía permite publicar una Pocketool sin conocer el código fuente de EAP.
Describe el contrato público de `pocketool.json` para `schemaVersion: 1`, sus
límites y el proceso completo de desarrollo, prueba y publicación.

## 1. Qué es una Pocketool

Una Pocketool es una utilidad pequeña, portable y orientada a comandos. EAP la
descarga, verifica, instala de forma global y publica uno o varios comandos en
`PATH`.

Use una Pocketool cuando:

- la utilidad se pueda distribuir como scripts, un ejecutable o un archivo JAR;
- no necesite un instalador ni hooks de instalación;
- deba conservar el directorio desde el que la invoca el usuario;
- su estado mutable pueda guardarse en `EAP_POCKETOOL_DATA`;
- no necesite modificar el entorno completo de un profile.

Use un componente cuando el software tenga proveedores o líneas de versiones,
deba publicar variables de entorno, launchers gráficos o rutas propias en el
profile, o necesite que EAP resuelva y valide un ZIP oficial. El contrato de los
componentes se documenta en el repositorio `eap-components`.

## 2. Límites actuales

- Sólo se admite Windows.
- La arquitectura puede ser `x64` o `any`.
- No hay scripts de instalación, desinstalación ni actualización.
- No hay un tipo de comando Bash.
- El payload instalado es inmutable. Los datos cambiantes deben escribirse en
  `EAP_POCKETOOL_DATA`.
- Los tipos `python`, `node` y `java-jar` no incluyen el runtime. Usan
  `python.exe`, `node.exe` o `java.exe` del profile activo.
- EAP no eleva privilegios. La Pocketool debe funcionar como usuario normal o
  gestionar explícitamente esa limitación.
- El repositorio GitHub público se descubre siempre desde la rama `main`.
- El manifiesto fuente de un repositorio GitHub no declara un artefacto. EAP
  construye y fija automáticamente el inventario de archivos al commit leído.

Si una necesidad no cabe en estos contratos, no añada campos inventados al
JSON: EAP no los convertirá en comportamiento. Proponga primero una ampliación
del esquema público.

## 3. Estructura del repositorio

Cada Pocketool ocupa una carpeta cuyo nombre coincide exactamente con su ID:

```text
pocketools/<id>/
  pocketool.json
  README.md
  src/
    ...
scripts/test.py
```

EAP descubre únicamente manifiestos situados exactamente en
`pocketools/<id>/pocketool.json`. Todos los archivos regulares contenidos en la
carpeta `<id>` forman parte del paquete; no se admiten enlaces simbólicos.

El `README.md` de la Pocketool no es obligatorio para el runtime, pero sí es
recomendable. Debe explicar casos de uso, ejemplos, requisitos y cualquier
efecto lateral importante.

## 4. Ejemplo mínimo completo

Cree `pocketools/saluda/pocketool.json`:

```json
{
  "schemaVersion": 1,
  "id": "saluda",
  "name": "Saluda",
  "version": "1.0.0",
  "description": "Muestra un saludo y recuerda el último nombre utilizado.",
  "license": "MIT",
  "platform": {
    "os": "windows",
    "architecture": "any"
  },
  "help": {
    "summary": "Muestra un saludo desde la consola.",
    "usage": "saluda [nombre] [--help]",
    "details": [
      "Sin nombre reutiliza el último valor guardado.",
      "El estado se conserva fuera del paquete instalado."
    ]
  },
  "commands": [
    {
      "name": "saluda",
      "type": "powershell",
      "entrypoint": "src/saluda.ps1",
      "arguments": []
    }
  ],
  "requires": {
    "pocketools": [],
    "components": []
  },
  "install": {
    "requiredFiles": [
      "src/saluda.ps1"
    ]
  }
}
```

Cree `pocketools/saluda/src/saluda.ps1`:

```powershell
param(
    [Parameter(Position = 0)]
    [string]$Name
)

$ErrorActionPreference = 'Stop'

if ($Name -in @('-h', '--help', 'help')) {
    Write-Output 'Uso: saluda [nombre] [--help]'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($env:EAP_POCKETOOL_DATA)) {
    Write-Error 'EAP_POCKETOOL_DATA no está definido.'
    exit 2
}

$stateDirectory = [IO.Path]::GetFullPath($env:EAP_POCKETOOL_DATA)
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$stateFile = Join-Path $stateDirectory 'ultimo-nombre.txt'

if (-not [string]::IsNullOrWhiteSpace($Name)) {
    Set-Content -LiteralPath $stateFile -Value $Name -Encoding UTF8
} elseif (Test-Path -LiteralPath $stateFile) {
    $Name = (Get-Content -LiteralPath $stateFile -Raw).Trim()
} else {
    $Name = 'mundo'
}

Write-Output "Hola, $Name"
```

El script puede leer su propio código mediante `EAP_POCKETOOL_ROOT`, pero no
debe escribir en esa ubicación. El ejemplo sólo guarda estado en la ruta que
EAP le proporciona.

## 5. Contrato de `pocketool.json`

Todos estos campos de primer nivel son obligatorios:

| Campo | Tipo | Contrato |
| --- | --- | --- |
| `schemaVersion` | entero | Debe ser `1`. |
| `id` | texto | Identificador técnico y nombre de la carpeta. |
| `name` | texto | Nombre visible no vacío. |
| `version` | texto | SemVer estricto `MAJOR.MINOR.PATCH`. |
| `description` | texto | Descripción breve no vacía. |
| `license` | texto | Licencia no vacía, por ejemplo `MIT`. |
| `platform` | objeto | Sistema operativo y arquitectura compatibles. |
| `help` | objeto | Ayuda mostrada por EAP. |
| `commands` | lista | Uno o varios comandos publicados. |
| `requires` | objeto | Dependencias de Pocketools y componentes. |
| `install` | objeto | Archivos que deben existir tras la instalación. |

No añada `artifact` al manifiesto fuente de un repositorio GitHub. Ese bloque
pertenece al catálogo interno que EAP genera después de inspeccionar el commit.

## 6. IDs, comandos y versiones

El ID debe comenzar por una letra o un número, medir como máximo 64 caracteres
y usar sólo letras ASCII, números, punto, guion o guion bajo. Evite diferencias
basadas únicamente en mayúsculas y minúsculas. Los nombres reservados de
Windows, como `CON`, `NUL`, `COM1` o `LPT1`, no son válidos.

La carpeta y el campo `id` deben coincidir exactamente:

```text
pocketools/saluda/pocketool.json  ->  "id": "saluda"
```

Los nombres de comando siguen las mismas reglas básicas. `cmd`, `eap`,
`powershell` y `pwsh` están reservados. EAP también rechaza, de forma
transaccional, colisiones con comandos de otras Pocketools, del propio EAP o de
componentes activos.

La versión debe tener exactamente tres números:

```text
1.0.0      válido
2.7.13     válido
1.0        no válido
v1.0.0     no válido
1.0.0-rc1 no válido en schemaVersion 1
```

Incremente la versión siempre que cambie cualquier archivo que se instale o su
comportamiento. Las dependencias usan comparación SemVer, no comparación de
texto.

## 7. Ayuda

`help` contiene:

- `summary`: resumen corto;
- `usage`: sintaxis de uso;
- `details`: lista opcional de textos adicionales.

EAP presenta estos datos con:

```powershell
eap.cmd pocketool help <repositorio>/<id>
```

Además, el propio comando debe implementar `--help` y devolver código `0`. Así
la ayuda también funciona después de activar un profile, sin depender del CLI
de EAP.

## 8. Comandos y runtimes

Cada entrada de `commands` requiere `name`, `type`, `entrypoint` y `arguments`.

| `type` | Ejecución realizada por EAP | Requisito |
| --- | --- | --- |
| `powershell` | Windows PowerShell con `-NoProfile -ExecutionPolicy Bypass -File` | Archivo `.ps1`. |
| `cmd` | `%COMSPEC% /d /c` | Archivo `.cmd` o `.bat`. |
| `exe` | Ejecutable directamente | Binario Windows compatible. |
| `python` | `python.exe <entrypoint>` | Python en `PATH` del profile activo. |
| `node` | `node.exe <entrypoint>` | Node.js en `PATH` del profile activo. |
| `java-jar` | `java.exe -jar <entrypoint>` | Java en `PATH` del profile activo. |

`entrypoint` es una ruta relativa a la carpeta de la Pocketool. `arguments` es
una lista de argumentos fijos que EAP coloca antes de los proporcionados por el
usuario. Por ejemplo:

```json
{
  "name": "informe-json",
  "type": "python",
  "entrypoint": "src/informe.py",
  "arguments": ["--format", "json"]
}
```

Si el usuario ejecuta `informe-json datos.csv`, el script recibe primero
`--format json` y después `datos.csv`.

Una Pocketool puede publicar varios comandos. Los nombres deben ser únicos:

```json
"commands": [
  {
    "name": "acme",
    "type": "powershell",
    "entrypoint": "src/acme.ps1",
    "arguments": []
  },
  {
    "name": "acme-admin",
    "type": "powershell",
    "entrypoint": "src/acme.ps1",
    "arguments": ["admin"]
  }
]
```

EAP conserva como directorio de trabajo el directorio desde el que el usuario
invocó el comando. No suponga que el directorio actual es el payload; use
`EAP_POCKETOOL_ROOT` para localizar archivos incluidos.

## 9. Variables proporcionadas al proceso

EAP añade estas variables antes de lanzar el comando:

| Variable | Contenido |
| --- | --- |
| `EAP_POCKETOOL_ID` | ID instalado. |
| `EAP_POCKETOOL_VERSION` | Versión instalada. |
| `EAP_POCKETOOL_ROOT` | Raíz inmutable del payload. |
| `EAP_POCKETOOL_DATA` | Directorio persistente y escribible de la Pocketool. |

Reglas prácticas:

- lea plantillas, scripts auxiliares y recursos desde `EAP_POCKETOOL_ROOT`;
- guarde configuración generada, caché, logs, PID y estado en
  `EAP_POCKETOOL_DATA`;
- use el directorio actual para entradas y salidas elegidas por el usuario;
- no incluya contraseñas, tokens ni otros secretos en el repositorio.

## 10. Dependencias

`requires` siempre contiene las listas `pocketools` y `components`, aunque
estén vacías.

### 10.1 Dependencia de otra Pocketool

```json
"requires": {
  "pocketools": [
    {
      "id": "otra-utilidad",
      "minimumVersion": "2.1.0"
    }
  ],
  "components": []
}
```

Si se omite `repository`, EAP busca la dependencia en el mismo repositorio. Para
referenciar explícitamente otro:

```json
{
  "id": "otra-utilidad",
  "minimumVersion": "2.1.0",
  "repository": "empresa"
}
```

EAP instala las dependencias en orden, rechaza ciclos y bloquea la
desinstalación de una Pocketool que todavía tenga dependientes.

### 10.2 Dependencia de un componente

Las dependencias no usan el ID del componente, sino una capacidad pública:

```json
"requires": {
  "pocketools": [],
  "components": [
    {
      "capability": "runtime.python",
      "minimumTrack": "3.12"
    }
  ]
}
```

Capacidades habituales del catálogo oficial:

| Necesidad | Capacidad | Ejemplo de track mínimo |
| --- | --- | --- |
| Java | `runtime.java` | `21` |
| Python | `runtime.python` | `3.12` |
| Node.js | `runtime.nodejs` | `22` |
| Git | `tool.git` | `2` |
| Maven | `tool.maven` | `3` |

EAP comprueba la capacidad contra los componentes activos del profile tanto al
instalar como al ejecutar. Por ello, una Pocketool `python`, `node` o
`java-jar` debe declarar la capacidad correspondiente. En tracks numéricos EAP
compara números; en el resto exige una coincidencia compatible con el track.

## 11. Archivos y rutas seguras

`install.requiredFiles` enumera los archivos imprescindibles del payload. EAP
comprueba su existencia antes de completar la instalación:

```json
"install": {
  "requiredFiles": [
    "src/programa.py",
    "resources/defaults.json"
  ]
}
```

Incluya al menos todos los entrypoints y los recursos sin los que el comando no
puede funcionar.

Todas las rutas del manifiesto:

- son relativas y usan `/`, incluso en Windows;
- no pueden contener `.` o `..` como segmentos;
- no pueden empezar por `/` ni por una letra de unidad;
- no admiten `\\`, caracteres de control ni `:< >\"|?*`;
- no pueden terminar en punto o espacio;
- no pueden usar nombres de dispositivo reservados por Windows.

EAP rechaza rutas duplicadas sin distinguir mayúsculas, enlaces simbólicos,
escapes del payload y más de 10.000 archivos por Pocketool. También limita el
tamaño total descargable según la configuración local.

## 12. Descubrimiento, integridad e instalación

Al actualizar un repositorio GitHub, EAP:

1. consulta el árbol de la rama `main`;
2. descubre `pocketools/*/pocketool.json`;
3. valida cada manifiesto y que el ID coincida con su carpeta;
4. fija la revisión al hash de commit consultado;
5. inventaría cada archivo, su tamaño y su identificador de objeto Git;
6. descarga desde `raw.githubusercontent.com` usando ese commit;
7. vuelve a contrastar tamaños e identificadores antes de publicar comandos.

Una actualización incompleta no sustituye el índice anterior. La instalación y
los shims de comandos también se publican de forma transaccional.

No hacen falta tags, GitHub Releases, archivos ZIP ni un catálogo generado. Un
push a `main` basta para que una actualización posterior pueda descubrir la
nueva versión.

## 13. Desarrollo y pruebas locales

### Paso 1: crear los archivos

Copie el ejemplo más cercano, cambie el ID, los metadatos y el código, y añada
pruebas de comportamiento específicas cuando la utilidad no sea trivial.

### Paso 2: ejecutar el validador del repositorio

Desde la raíz de `eap-pocketools`:

```powershell
python scripts/test.py
```

Este script revisa todos los manifiestos, entrypoints, archivos requeridos y
colisiones internas. También ejecuta las pruebas de comportamiento incluidas
en el repositorio. La aceptación final la realiza EAP al refrescar la fuente.

### Paso 3: probar mediante un fork GitHub

Publique temporalmente la rama `main` en un fork y añádalo con un ID de
repositorio distinto:

```powershell
eap.cmd pocketool repository add pruebas https://github.com/usuario/eap-pocketools --yes
eap.cmd pocketool refresh pruebas
eap.cmd pocketool list --available
```

Para no afectar a un profile de trabajo, cree uno desechable:

```powershell
eap.cmd profile create pruebas-pocketool
eap.cmd pocketool install pruebas/saluda --profile pruebas-pocketool --yes
eap.cmd pocketool help pruebas/saluda
eap.cmd doctor
```

Abra una shell con ese profile y pruebe ayuda, errores y uso normal:

```powershell
eap.cmd shell --profile pruebas-pocketool --type cmd
saluda --help
saluda Daniel
saluda
```

Al terminar:

```powershell
eap.cmd pocketool uninstall pruebas/saluda --yes
eap.cmd pocketool repository remove pruebas --yes
eap.cmd profile delete pruebas-pocketool --yes
```

Compruebe además:

- códigos de salida `0` en éxito y distintos de cero en error;
- argumentos con espacios, acentos y rutas largas;
- ejecución desde directorios distintos;
- comportamiento sin estado previo y con estado existente;
- ausencia del runtime o dependencia requerida;
- que ninguna escritura accidental llegue a `EAP_POCKETOOL_ROOT`.

## 14. Publicación y actualización

Antes de publicar:

1. ejecute las pruebas;
2. incremente `version` si ha cambiado algún archivo o comportamiento;
3. revise que la licencia permita distribuir todos los archivos incluidos;
4. haga commit y push a `main`;
5. refresque un EAP limpio y repita una instalación real.

EAP fija cada instalación a una versión y a un commit. Cambiar archivos sin
incrementar `version` crea una identidad ambigua y puede dejar instalaciones ya
existentes sin actualizar. No reutilice una versión publicada.

## 15. Errores frecuentes

### `id y carpeta no coinciden`

Renombre la carpeta o el campo `id`; deben ser idénticos.

### `Comando reservado` o `colisión de comandos`

Elija un nombre más específico. No sustituya comandos del sistema, de EAP, de
otra Pocketool o de un componente.

### `necesita python.exe`, `node.exe` o `java.exe`

El runtime no está activo en el profile. Declare la capacidad correspondiente
en `requires.components` e instale ese componente en el profile.

### `Entrypoint Pocketool ausente`

Revise mayúsculas, ruta relativa y que el archivo se haya incluido en el
commit. Declare también el entrypoint en `install.requiredFiles`.

### `ruta ... no válida` o `fuera del payload`

Use `/`, elimine segmentos `..` y mantenga todos los recursos dentro de la
carpeta de la Pocketool.

### El estado desaparece después de actualizar

La utilidad está escribiendo en su payload. Guarde los datos mutables bajo
`EAP_POCKETOOL_DATA`.

### Funciona directamente pero no como comando EAP

No dependa del profile personal de PowerShell, del directorio del script ni de
variables no declaradas. EAP ejecuta PowerShell con `-NoProfile` y conserva el
directorio actual del usuario.

## 16. Checklist antes de una pull request

- [ ] La carpeta es `pocketools/<id>` y coincide con `id`.
- [ ] `schemaVersion` es `1`.
- [ ] `version` es SemVer estricto y no se ha reutilizado.
- [ ] Nombre, descripción y licencia son claros.
- [ ] La plataforma es Windows `x64` o `any`.
- [ ] Todos los comandos tienen nombre único y no reservado.
- [ ] Cada entrypoint y recurso esencial aparece en `requiredFiles`.
- [ ] Las rutas son relativas, seguras y usan `/`.
- [ ] `--help` funciona y concuerda con el bloque `help`.
- [ ] Los códigos de salida distinguen éxito y error.
- [ ] Los runtimes y Pocketools necesarios están declarados en `requires`.
- [ ] El código usa `EAP_POCKETOOL_DATA` para todo estado mutable.
- [ ] No hay secretos, binarios sin licencia ni enlaces simbólicos.
- [ ] `python scripts/test.py` termina correctamente.
- [ ] Se ha probado refresh, instalación y ejecución mediante EAP.
