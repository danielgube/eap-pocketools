# SSL Truster

SSL Truster permite aprobar una URL HTTPS sin desactivar la validación TLS. Usa
la confianza de Windows como referencia y comprueba la conexión con EAP, Node,
Java, Python y Go cuando esos runtimes están disponibles en el profile activo.

## Uso

Abra el menú interactivo:

```powershell
ssltruster
```

También puede usarlo mediante comandos:

```powershell
ssltruster approve https://repo.maven.apache.org/maven2/
ssltruster list
ssltruster recheck
ssltruster repair
ssltruster status
```

Una respuesta HTTP, incluso `401` o `404`, confirma que DNS, proxy y TLS han
funcionado. SSL Truster muestra el código para que el usuario pueda distinguir
un problema de aplicación de un fallo de certificado.

## Certificados de empresa

Si Windows tampoco confía en la URL, solicite a TI el certificado de la CA raíz
o intermedia en formato `.cer`, `.crt` o PEM y ejecute:

```powershell
ssltruster import C:\ruta\ca-empresa.cer
```

Las raíces se instalan en `CurrentUser\Root` y las intermedias en
`CurrentUser\CA`; no se requieren privilegios de administrador. Antes de
instalar se muestran sujeto, emisor, caducidad, huella SHA-256 y destino. SSL
Truster rechaza certificados que no declaren `CA=true`.

Agregar una CA concede confianza a esa autoridad, no únicamente a la URL que
motivó la importación. Nunca importe un certificado cuya procedencia no haya
sido verificada.

## Estado y efectos

- Las URLs y las importaciones realizadas se registran en `EAP_POCKETOOL_DATA`.
- La política de confianza se activa sólo en el profile EAP desde el que se
  ejecuta el comando.
- Node mantiene la validación y añade las CA de Windows.
- Java usa el almacén nativo `Windows-ROOT` sin modificar el `cacerts` del JDK.
- Python, pip, Requests, curl y Git reciben un bundle PEM generado por EAP.
- Go usa el verificador nativo de Windows.
- SSL Truster nunca configura `NODE_TLS_REJECT_UNAUTHORIZED=0`, `strict-ssl=false`
  ni equivalentes inseguros.

Después de la primera aprobación, abra una terminal EAP nueva para que los
comandos ejecutados directamente desde esa shell reciban la política del
profile. Las comprobaciones realizadas durante la aprobación ya usan la nueva
confianza.

Una URL guardada representa una aprobación y una comprobación realizadas en un
momento concreto. Use `ssltruster recheck` después de cambios de proxy,
certificados o runtimes.
