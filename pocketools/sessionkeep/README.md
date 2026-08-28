# Session Keep

Mantiene activa una sesión de Windows cuando interesa evitar el bloqueo de la
pantalla o que una aplicación marque inactividad durante una tarea larga. No
requiere permisos de administrador.

```text
sessionkeep start
sessionkeep status
sessionkeep stop
sessionkeep --help
```

`start` crea un único worker oculto. El worker solicita a Windows que mantenga
el sistema y la pantalla disponibles y, cada cuatro minutos, realiza una
actividad mínima: desplaza el cursor un píxel, lo devuelve a su posición y
envía una pulsación inocua de Shift. `stop` usa una señal cooperativa; no mata
procesos ajenos por PID.

El PID, el heartbeat y la señal de parada se guardan en
`EAP_POCKETOOL_DATA`. Al actualizar o reinstalar la Pocketool ese estado se
conserva.

Para diagnóstico, `sessionkeep run` mantiene el worker en primer plano. Se
detiene con `Ctrl+C`.
