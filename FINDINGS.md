# NOEMAP -- FINDINGS (living doc)

Hallazgos activos, bugs en investigacion, y tareas sin resolver. Para
arquitectura estable ya implementada: ver ARCHITECTURE.md (mismo
directorio).

## EN CURSO -- sesion 2026-09-06

### noemap#502 (P1) -- migracion a subcomandos (absorbe remocion de --deep)

Reportado sin uso real en la practica. Grep completo del repo confirmo
todos los sitios (uno mas de lo que la tarea original listaba):

  bin/noemap            lineas 7, 196, 202, 208, 215, 235-238
                         comentario de uso, variable NOEMAP_DEEP=0,
                         parseo --deep en el case, export, y bloque
                         sudo-prompt completo para deep mode.

  lib/fingerprint.sh     lineas 11-14, 83, 120-130, 171-186
                         comentarios de diseno de deep mode, rama en
                         _detect_type que lee _FP_OS_OUT, bloque
                         completo de nmap -O en fingerprint_hosts.

  lib/scan.sh            lineas 26, 541-590
                         comentario de env var, bloque completo
                         if NOEMAP_DEEP (~50 lineas: escaneo amplio
                         alternativo con nmap/nc, unico camino que
                         llenaba _ssh_tmp con ese escaneo mas amplio).

  bin/nclip-set:118      NO listado en la tarea original. No es
                         codigo funcional -- es un mensaje de error
                         que sugiere 'noemap --deep' como remedio
                         cuando la identidad local no resuelve.
                         Reescribir sin la flag: 'run noemap first'.

  README.md:22           linea que documenta --deep.

  readme.txt             lineas 11-13, 17, 93-96 -- ejemplo de uso,
                         combinacion --deep --ports, y parrafo final
                         Fast mode vs Deep mode.

  install.sh             sin coincidencias, nada que tocar.

Detalle de diseno: en _detect_type, el parametro _ip (linea 87,
_3="${3:-}") se usa TANTO en la rama deep (linea 121, se elimina) COMO
en el banner grab pasivo que SI se queda (linea 103). La firma de la
funcion no cambia -- solo se vacia el cuerpo de la rama deep especifica.

Alcance confirmado por el usuario: eliminacion total, sin mencion ni
rastro en codigo, comentarios, ni texto de ayuda. Herramienta debe
quedar mas simple tras la purga.

Estado: diseno completo (ver ARCHITECTURE-nueva.md, mismo directorio,
para el detalle de los 8 subcomandos y los 3 puntos de diseno ya
decididos). Rama chore/remove-deep-mode CREADA y activa, con
ARCHITECTURE.md + FINDINGS.md + ARCHITECTURE-nueva.md ya commiteados en
el working tree (pendiente commit real). Codigo de bin/noemap, lib/*.sh
aun sin tocar -- migracion real todavia no ejecutada.

## PENDIENTES heredados (de investigacion previa, aun sin resolver)

noemap#500 (P2, RESUELTO -- confirmado via miko history 2026-09-04T23:05:27):
_self_register() corria 2 veces por corrida de noemap (discover_hosts y
sync_devices_to_nodes) sin guard de idempotencia a nivel de sesion,
causando dos ciclos commit+push+merge en _registry_write por una sola
corrida. Fix: guard _SELF_REGISTER_DONE (mismo patron que SESSION_TMP_DIR
en util.sh), ya presente en scan.sh (lineas 205, 257, 296) y confirmado
shippeado por miko. CORRECCION: la nota anterior en este archivo decia
"AUN NO RESUELTO / PENDIENTE DE RE-VERIFICACION" -- error de mi parte,
escrito sin haber consultado miko history primero. Regla aplicada de
ahora en adelante: nunca asumir estado de una tarea sin confirmar contra
miko antes de escribir una nota que lo de por hecho.

noemap#501 (P5, pendiente, no bloqueante): bin/ndevs, -h/--help TEXT
DESACTUALIZADO -- usage de --node-set/--node-add/--registry-set no
muestra [platform] pese a que las 3 funciones ya lo usan.

## QUE PUEDE FALLAR EN EL FUTURO (chequear aqui primero)

- Alias con ip vacio en devices.db, indefinidamente: causa mas probable
  es hostkey stale en registry.db rompiendo el fallback de
  fingerprint.sh. Diagnostico en un solo bloque:
    cat ~/.local/share/noemap/state/devices.db   # confirmar ip vacio
    cat ~/.noemap-registry/registry.db           # ver hostkey guardado
  Fix: 1) ndevs --update-ip <alias> <ip-real-conocida>, 2) nhkrefresh
  para reconciliar el hostkey. NO editar los .db a mano (regla del
  usuario) -- siempre via ndevs/nhkrefresh.

- ndevs --registry-set / --node-add sobre un nodo REMOTO nunca actualiza
  su hostkey (por diseno) -- solo nhkrefresh puede hacerlo, porque es el
  unico camino que llama _get_host_key_fingerprint contra la IP real del
  nodo remoto en vez de preservar el valor previo.

- sshd caido en un nodo: _get_host_key_fingerprint falla silencioso
  (2>/dev/null), el hostkey queda vacio o preserva el valor previo.
  Verificar con: pgrep -fl sshd ; cat $PREFIX/var/run/sshd.pid ;
  kill -0 <pid>. Reiniciar con: sshd (comando plano, sin flags, Termux).

- Un nodo con codigo desactualizado (sin git pull/deploy reciente): los
  triggers automaticos fallan silenciosamente porque las funciones
  nuevas no existen ahi todavia. Diagnostico: 'git log --oneline -1' en
  cada nodo, comparar contra origin/main. Fix: ut deploy noemap.

- Si algun binario nuevo llega a escribir directo a registry.db con
  printf en vez de llamar _registry_write, quedara con campos faltantes
  (sin hostkey/platform) -- rompe deteccion de mismatch y auto-trigger.
  Buscar con: grep -rn "node_id: %s.\\\\nalias" en todo el repo noemap,
  debe aparecer SOLO dentro de _registry_write en identity.sh.

- Un host nuevo cuyo alias de la nube YA existe localmente bajo otra IP
  no se auto-registra (guard explicito en output.sh) -- cae al flujo
  interactivo de "IP updated" existente, correcto por diseno.

- Equipo genuinamente nuevo en TODA la red (ninguna fila en ningun nodo
  aun): sigue preguntando alias/user, correcto por diseno, unico caso
  legitimo que requiere input humano.

## CASOS RESUELTOS -- historico (sesion 2026-09-04)

noemap#498 (P1): tx1 (node_id c62a5cd48d8c2ce0) no tenia fila en
registry.db -- _self_register() colgaba en un prompt de /dev/tty
durante discover_hosts, sin mensaje de error visible. Fix: escribir la
fila de tx1 en registry.db con el node_id correcto. Confirmado con
node_alias() resolviendo "tx1" tras el fix.

noemap#499 (P3): devices.db tenia ip vacio para tx2 (root cause:
hostkey guardado en registry.db estaba stale por reformateo previo del
dispositivo). Resuelto con ndevs --update-ip + nhkrefresh -- confirmado
con noemap corriendo de nuevo: CERO warnings, handshake OK, sync OK.
Nota sin investigar: hostkey "live" capturado por nhkrefresh DIFIRIO
del capturado horas antes por fingerprint_hosts en la misma sesion,
mismo host/ip/puerto. Causa no confirmada (posible reinicio de sshd o
inestabilidad de red). Si vuelve a ocurrir: comparar timestamps contra
logs de sshd en tx2 antes de asumir bug de codigo.
