# NINA -- ARQUITECTURA NUEVA (propuesta, aun no implementada)

Este archivo documenta una PROPUESTA de rediseno, pendiente de codificacion.
No confundir con ARCHITECTURE.md (lo que YA existe funcionando hoy, bajo el
nombre noemap). Una vez implementada y verificada, esta propuesta se
fusiona dentro de ARCHITECTURE.md y este archivo se retira.

RENOMBRE TOTAL CONFIRMADO (2026-09-06, sesion siguiente): el proyecto
completo se renombra de 'noemap' a 'nina'. Alcance: nombre del repo/carpeta,
nombre del binario fusionado, nombre de cada comando/subcomando, y
cualquier mencion en codigo/docs/texto de ayuda. 'noemap' no debe aparecer
en ningun lado tras el renombre. Este documento usa 'nina' en todo lo
nuevo; las referencias a archivos/lineas del codigo ACTUAL (que hoy sigue
llamandose noemap en disco) se mantienen como bin/noemap, lib/*.sh, etc.,
porque ese renombre de archivos aun no se ha ejecutado -- ver PENDIENTES.

Contexto: el proyecto hoy es un pipeline monolitico -- una sola invocacion
corria discover -> fingerprint -> register-new -> bootstrap-keys -> push,
todo junto, sin forma de ejecutar un paso aislado para diagnosticar donde
falla exactamente (ej. tras un cambio de red/wifi, o en un celular recien
formateado).

Ademas, el proyecto completo hoy vive repartido en 9 binarios (noemap,
nssh, nscp, nclip, nclip-listen, nclip-send, nclip-set, ndevs,
nhkrefresh) y 12 archivos de lib/, sin agrupacion por responsabilidad y
con varios sourceos duplicados de las mismas dependencias en distintos
binarios. Objetivo: sintetizar todo en una estructura simple, escalable y
modular -- fusion de binarios donde tiene sentido, reestructuracion de
lib/ por dominio, nombres obvios, sin doble-guion en ningun subcomando de
todo el proyecto (convencion: `add`, no `--add`; un solo guion entre
palabras SI esta permitido, ej. `client-setup`, `update-ip`).

## ESTADO DE EJECUCION (actualizado 2026-09-06, sesion siguiente)

PARTE 1 (dispatcher de discovery): YA MERGEADO A MAIN bajo el nombre
noemap. Commit 25ef7a6 "feat(noemap): add subcommand dispatcher, fix
ssh-setup key handling", branch feat/subcommands-dispatcher, fast-forward
merge confirmado via reflog. bin/noemap y lib/noemap-dispatch.sh en el
estado descrito en PARTE 1 son el codigo REAL que corre hoy con el nombre
viejo -- el renombre a nina sucede junto con la fusion de PARTE 3, no
antes.

PARTE 2 (reestructuracion de lib/): DECIDIDO, 0 git mv ejecutados.

PARTE 3 (fusion de binarios + renombre a nina): DECIDIDO, 0 codigo
tocado.

PARTE 4 (subcomando 'tails', tailscale): NUEVO esta sesion. Diseno
PARCIAL -- un punto critico sin resolver, ver seccion propia abajo.

bin/noemap.bak: eliminado via rm el 2026-09-06 (sesion siguiente). No
queda pendiente sobre este archivo.

## PARTE 1 -- Los subcomandos de discovery (COMPLETADO, en main, nombre viejo)

`nina` (hoy `noemap`) SIN NINGUN ARGUMENTO sigue siendo el atajo que
corre el pipeline completo -- comportamiento identico al de antes de la
migracion. 'all' NO se expone como subcomando que el usuario escriba (no
existe 'nina all'); es solo el nombre interno de _do_all, usado cuando no
se pasa ningun argumento (noemap_dispatch hace _sub="${1:-all}").

  nina discover        Fase 0/1/2 de scan.sh: ping hosts registrados,
                        ARP/TCP-SYN ping, probe de puerto SSH. Encuentra
                        que hosts estan vivos en la red LAN ahora mismo.
                        No modifica devices.db. Persiste su resultado
                        para que `fingerprint` lo consuma despues.

  nina tails            NUEVO (ver PARTE 4) -- descubrimiento via
                        tailscale, separado de discover. Comparte el
                        mismo host_list.cache.

  nina self-register   Registra ESTE nodo (alias/user/port/platform) en
                        devices.db y registry.db.

  nina seed             Trae filas de OTROS nodos desde registry.db
                        (la nube) hacia devices.db local.

  nina fingerprint      Clasifica el tipo de cada host que `discover` o
                        `tails` encontro (TTL + puerto + banner pasivo
                        SSH), escribe hosts.db. Requiere que al menos uno
                        de los dos haya corrido antes (lee su resultado
                        persistido).

  nina bootstrap-keys   Distribuye llaves SSH a los hosts recien
                        registrados en devices.db.

  nina push             Empuja devices.db completo a todos los demas
                        nodos registrados (via nssh). Llama
                        _self_register internamente primero.

  (sin argumento)       Orquesta discover + fingerprint + bootstrap-keys
                        + push en una sola invocacion, en memoria
                        (_do_all internamente). NO incluye tails
                        automaticamente -- tails se corre aparte, a
                        menos que se decida lo contrario mas adelante.

NOTA: register-new (registro interactivo de hosts nuevos encontrados por
fingerprint) se UNIFICA con `devices add` sin argumentos -- ver PARTE 3.
Ya no es un subcomando de top-level separado.

### Estado entre subcomandos

Cada subcomando corre en su propia invocacion de shell, efimera -- las
variables de shell (HOST_LIST, _STALE_ALIAS_CANDIDATES) que antes vivian
solo en memoria durante la corrida completa no sobreviven entre
invocaciones separadas. Persisten en disco:

  state/host_list.cache             una IP por linea (salida de discover
                                    Y de tails -- cache COMPARTIDO, ver
                                    PARTE 4)
  state/stale_candidates.cache      un alias por linea (salida de discover)

cache.sh no se modifica -- estas dos listas viven en su propio archivo
cada una, mismo directorio state/ que ya usan devices.db/hosts.db/cache.env.

### Manejo de subcomando corrido sin su previo

Si `nina fingerprint` corre sin que `discover` o `tails` hayan corrido
antes (host_list.cache vacio o no existe): pregunta interactivamente
(y/N) si se debe correr `discover` automaticamente antes de continuar.
Si la respuesta es no, sale sin hacer nada (exit 1). Mismo patron para
cualquier otro subcomando que dependa de un paso previo.

### Dispatcher -- codigo real, verificado (bajo el nombre viejo hoy)

lib/nina-dispatch.sh (hoy lib/noemap-dispatch.sh) centraliza el case
sobre el subcomando y delega a cada _do_<subcomando>. Todos los
subcomandos toman el mismo lock global (acquire_lock/release_lock) via
_dispatch_lock_wrap, llamado una sola vez en el dispatch antes del case
final. bin/nina (hoy bin/noemap) es entry point delgado: resuelve BASE,
hace source de los modulos via _source_mods, pasa el control al
dispatcher con los argumentos recibidos.

Ademas del dispatch, el binario YA TIENE HOY (fuera del dispatcher, con
su propio flag de deteccion antes de _source_mods):

  nina client-setup     Emite un script standalone para configurar el
                        lado CLIENTE del clipboard (Mac/Termux). Detecta
                        OS: macOS -> LaunchAgent (pbsync); Linux/Termux
                        -> listener en background. Agrega RemoteForward
                        al ssh config del cliente. Se corre en el
                        servidor, el output se ejecuta EN el cliente.

  nina ssh-setup <alias>  Configura auth por llave Ed25519 para un
                        device registrado: genera clave si falta,
                        instala via ssh-copy-id (o fallback manual),
                        verifica la conexion, ofrece purgar
                        authorized_keys al final (solo interactivo).

Ninguno de los dos pasa por el lock global del dispatcher -- se detectan
y ejecutan antes de _source_mods/dispatch.

### --deep / NOEMAP_DEEP -- ELIMINADO

Sin uso real en la practica. Sitios confirmados por grep completo del
repo: bin/noemap, lib/fingerprint.sh, lib/scan.sh, bin/nclip-set:118
(mensaje de error, no codigo funcional), README.md:22, readme.txt
(lineas 11-13,17,93-96). Alcance: eliminacion total, sin mencion ni
rastro en codigo, comentarios, ni texto de ayuda. PENDIENTE: README.md y
readme.txt aun no actualizados a los subcomandos nuevos ni al nombre
nina (ver PENDIENTES al final).

## PARTE 2 -- Reestructuracion de lib/ (DECIDIDO, pendiente de ejecutar)

lib/ pasa de 12 archivos sueltos a 8 rutas agrupadas por dominio (rutas
mostradas con el nombre de archivo actual; el contenido no cambia de
nombre con el renombre a nina, solo bin/nina como entry point):

  core/blockdb.sh              (infra pura, sin conocimiento de dominio)
  core/lock.sh
  core/cache.sh
  core/util.sh
  core/nina-dispatch.sh         (hoy noemap-dispatch.sh)

  identity/identity.sh          (identity.sh lineas 1-210: is_local_ip,
                                _own_devices_ip, node_id, node_alias,
                                node_registry_row -- "quien soy yo")

  registry/registry.sh          (identity.sh lineas 211-406:
                                _registry_write, node_alias_set,
                                registry_row_by_alias,
                                registry_row_by_hostkey,
                                _distribute_registry -- registry.db
                                compartido, su propio git remoto)

  discovery/iface.sh
  discovery/scan.sh             (incluye _purge_unrescued_stale_aliases,
                                linea 361 -- no esta en fingerprint.sh)
  discovery/fingerprint.sh

  connection/devices.sh         (resolve_device, _ensure_user,
                                resolve_scp_target -- usado por nssh, nscp,
                                clip get/send/set, NO por el pipeline de
                                discovery en si)

  output/output.sh

  transfer/ssh_bootstrap.sh      (ssh_key_bootstrap -- llama a nssh como
                                subproceso externo en 2 puntos, lineas
                                569 y 593 de util.sh original; nssh
                                sobrevive como binario propio asi que
                                esta llamada NO cambia con la fusion)

Corte de identity.sh: identity/ real termina en linea 210 (incluye
is_local_ip, _own_devices_ip, node_id, node_alias, node_registry_row);
registry/ real empieza en linea 211 (_registry_write en adelante).

### Dependencias cruzadas confirmadas (3)

  (a) node_alias() [identity] llamada por _registry_write() [registry].
  (b) is_local_ip() -> _own_devices_ip() -> node_alias() -- cadena
      interna a identity, no cruza modulos, pero toca el mismo punto de
      corte.
  (c) _registry_write() [registry, linea 250] llama
      _get_host_key_fingerprint() que vive en util.sh/core -- cruce
      registry->core.

### _source_mods usa ruta plana -- IMPLICACION CRITICA

bin/_bootstrap linea 44: _path="$LIB/$_mod" -- concatenacion PLANA, no
busca subcarpetas. Mover cualquier archivo a subcarpeta rompe el source
con '[ERROR] missing module' y exit 1 hasta actualizar cada linea
_source_mods que lo invoque.

DECISION: se actualiza la lista de argumentos de cada _source_mods
afectado con las subrutas nuevas; _source_mods/_bootstrap NO se modifica.

Binarios que sourceaban identity.sh (necesitan DOS entradas nuevas,
identity/identity.sh + registry/registry.sh, en ese orden):
  bin/noemap, bin/nclip-send, bin/nclip-set, bin/ndevs, bin/nhkrefresh
  (tras la fusion de PARTE 3, estos 4 ultimos dejan de ser binarios
  propios y su _source_mods se consolida en el bin/nina fusionado)

Binarios que sourceaban devices.sh (necesitan connection/devices.sh):
  bin/nssh, bin/nclip, bin/nclip-send, bin/nclip-set, bin/nscp
  (bin/noemap no lo sourceaba antes de la fusion -- tras la fusion, el
  binario nina fusionado SI lo necesita para los subcomandos
  devices/clip. nssh y nscp sobreviven como binarios propios y mantienen
  su propio _source_mods con connection/devices.sh)

### Piezas que NO cambian (reutilizadas tal cual)

  _self_register          (scan.sh)       ya standalone-safe
  _seed_from_registry     (scan.sh)       ya standalone
  fingerprint_hosts       (fingerprint.sh) sin cambios de logica interna
  prompt_new_hosts        (output.sh)     ya lee de disco (hosts.db)
  ssh_key_bootstrap       (ssh_bootstrap.sh) sin cambios
  sync_devices_to_nodes   (scan.sh)       ya llama _self_register interno
  _prompt_self_identity   (output.sh)     flujo interactivo ya completo

## PARTE 3 -- Fusion de binarios + renombre a nina (DECIDIDO, pendiente de ejecutar)

De los 9 binarios de bin/, 7 se fusionan en un solo binario `nina` (hoy
se llamarian noemap) con subcomandos. nssh y nscp SOBREVIVEN como
binarios propios, separados, CON SUS MISMOS NOMBRES -- no se renombran a
'nina-ssh'/'nina-cp' ni similar; el renombre del proyecto no fue
especificado para estos dos binarios independientes, se mantienen tal
cual hasta que se diga lo contrario. Son los de mayor uso directo, no
pasan por dispatcher ni lock. Esto tambien resuelve sin friccion el
riesgo de que una sesion SSH larga (nssh <alias>) bloqueara el lock
global para otras invocaciones: al no fusionarse, nssh nunca entra al
dispatch ni toca acquire_lock/release_lock.

Convencion de nombres para TODO el arbol: ningun subcomando lleva
doble-guion. `add`, no `--add`. Un guion simple entre palabras SI se
permite (client-setup, update-ip, node-set, etc.).

### Arbol de subcomandos completo

  nina                            (sin args: pipeline completo, sin cambio)
  |-- discover / tails / self-register / seed / fingerprint / bootstrap-keys / push
  |-- client-setup                 (ya existente, sin cambios)
  |-- ssh-setup <alias>            (ya existente, sin cambios)
  |
  |-- devices
  |   |-- list                     (ex ndevs sin argumentos)
  |   |-- add [alias ip user port] (ex ndevs --add, UNIFICADO con
  |   |                            register-new -- sin argumentos:
  |   |                            interactivo/discovery; con argumentos:
  |   |                            alta manual)
  |   |-- edit                     (ex ndevs --edit)
  |   |-- rename                   (ex ndevs --rename)
  |   |-- remove                   (ex ndevs --remove)
  |   |-- update-ip                (ex ndevs --update-ip)
  |   |-- rollback                 (ex ndevs --rollback)
  |   |-- push-vpn                 (ex ndevs --push-vpn)
  |   |-- resetall                 (ex ndevs --resetall)
  |   |-- node-set                 (ex ndevs --node-set)
  |   |-- node-add                 (ex ndevs --node-add)
  |   |-- registry-set             (ex ndevs --registry-set)
  |   `-- hostkey-refresh          (ex nhkrefresh, sin argumentos)
  |
  `-- clip
      |-- get <alias:/path>        (ex nclip, pull remoto -> local)
      |-- send <alias>             (ex nclip-send, stdin local -> remoto)
      |-- set <src> <dst>          (ex nclip-set)
      |-- status                   (ex nclip-set status)
      |-- clear                    (ex nclip-set clear)
      |-- tunnel                   (ex nclip-listen, modo SOCKET/SSH
      |   start/stop/restart/       RemoteForward -- nssh lo arranca y
      |   status/foreground         detiene solo durante una sesion SSH)
      `-- serve                    (ex nclip-listen, modo TCP/ncat --
          start/stop/restart/       independiente de cualquier sesion SSH,
          status                    puerto 9988 por defecto)

  nssh <alias> [cmd...]            BINARIO PROPIO -- no se fusiona, no
                                    se renombra
  nscp [-r] <src> <dst>            BINARIO PROPIO -- no se fusiona, no
                                    se renombra

NOTA: el flag -f/--fresh del dispatcher de discovery (linea 437 del
bin/noemap actual) llama 'ndevs --resetall' como subproceso -- tras la
fusion total, se convierte en llamada interna directa a la funcion de
'devices resetall'.

### Nomenclatura tunnel/serve -- razon del cambio

nclip-listen agrupaba dos mecanismos bajo un solo verbo ambiguo
(start/start-tcp). Renombrado para que el mecanismo sea obvio sin leer el
codigo:
  - clip tunnel = modo SOCKET, viaja DENTRO de una conexion SSH ya
    abierta (via RemoteForward). nssh lo arranca/detiene solo,
    automaticamente, al abrir/cerrar una sesion interactiva. No requiere
    puerto de red propio.
  - clip serve  = modo TCP/ncat, puerto de red independiente (9988 por
    defecto). Funciona sin necesidad de una sesion SSH abierta al mismo
    tiempo. Usado por clip set/send en modo por defecto (CLIP_MODE=tcp).
  Ambos mecanismos se conservan -- cubren situaciones distintas, no son
  redundantes.

### Puntos de acoplamiento a reescribir (6)

  (a) bin/nssh (linea 80-83) llama nclip-listen start/stop via
      `command -v` -- pasa a invocar la funcion interna del nina
      fusionado (clip tunnel start/stop), no un binario externo.
  (b) bin/nclip-set (linea 38-39) hardcodea NCLIP_SEND=$_bindir/nclip-send
      y NSSH=$_bindir/nssh como RUTAS ABSOLUTAS -- NSSH se mantiene (nssh
      sigue siendo binario propio), NCLIP_SEND pasa a ser llamada de
      funcion interna (clip send) dentro del mismo nina fusionado.
  (c) bin/nclip-set (lineas 67,112,121,139) invoca
      "$NSSH" "$_dst" 'nclip-listen start-tcp' REMOTAMENTE via SSH --
      tras la fusion, el nodo remoto ejecuta 'nina clip serve start'
      (mismo binario fusionado, asumido YA DEPLOYADO alla). RIESGO
      CONFIRMADO: si tx1/tx2 quedan en versiones distintas del binario
      fusionado durante la migracion, esta llamada remota falla --
      deploy debe alcanzar TODOS los nodos antes de usar clip set/tunnel
      en produccion. Precondicion operativa, no solo de diseno.
  (d) bin/nhkrefresh (linea 581 exacta) llama 'ndevs --registry-set' como
      subproceso completo, capturando stdout con sed -- pasa a llamada
      de funcion interna (devices registry-set) dentro del mismo
      binario, ya no subproceso.
  (e) bin/ndevs _cmd_add/_cmd_update_ip (lineas 257,233) llaman nscp
      internamente -- nscp SOBREVIVE como binario propio, esta llamada
      se mantiene como invocacion de binario externo, sin cambio.
  (f) lib/ssh_bootstrap.sh (ssh_key_bootstrap, lineas 569 y 593 del
      archivo original) llama nssh dos veces como subproceso externo --
      nssh SOBREVIVE como binario propio, esta llamada NO cambia con la
      fusion (mismo tratamiento que el punto (e) con nscp).

### Dependencia rota preexistente

bin/nclip-listen invoca $_bindir/play-confirm.sh en 3 puntos (lineas
82,114,162), siempre con `2>/dev/null || true`. Confirmado por busqueda:
el archivo NO EXISTE. Falla silenciosa hoy, sin romper nada -- no-op de
facto. DECISION: se deja igual (no-op silencioso) al fusionar.

## PARTE 4 -- Subcomando 'tails' (descubrimiento via tailscale) -- NUEVO, DISENO PARCIAL

Decision de sesion previa (2026-09-06), retomada y ampliada esta sesion:
tailscale se integra como ruta de descubrimiento adicional, separada de
discover (LAN). Nombre final del subcomando: `tails` (NO `discover-vpn`,
nombre descartado durante el diseno).

### Lo decidido

  - `nina tails` es un subcomando de nivel superior, junto a discover,
    dentro del grupo de discovery.
  - Comparte el mismo state/host_list.cache que discover -- mismo
    formato (una IP por linea), misma funcion _save_host_list_cache.
    Razon: fingerprint prueba puertos SSH (22/8022/2222) contra cada IP
    de la lista igual sin importar si viene de LAN o de tailscale --
    nada corriente abajo distingue el origen, asi que dos archivos
    separados solo agregarian un paso de union sin beneficio.
  - El pipeline por defecto (`nina` sin argumentos) NO incluye tails
    automaticamente -- se corre aparte, salvo que se decida lo
    contrario en una sesion futura.
  - Contexto ya confirmado en sesion previa: tailscale-termux-cli
    instalado y autenticado en tx2 (IP 100.95.78.69, daemon corriendo
    como proceso suelto, servicio runit roto -- no sobrevive reinicio).
    tx1 NO tiene tailscale instalado.

### PENDIENTE CRITICO -- bloquea escribir codigo de 'tails'

De donde saca `tails` las IPs de tailscale. Tres opciones fueron
presentadas en sesion, NINGUNA fue elegida:
  1. Correr 'tailscale status' en vivo y parsear las IPs 100.* de los
     peers conectados.
  2. Leer las IPs 100.* ya guardadas en devices.db/registry.db (campo
     existente), sin invocar el binario tailscale en absoluto.
  3. Ambas: intentar 'tailscale status' primero, si falla (ej. daemon no
     corriendo, ver troubleshooting de runit arriba) caer a lo guardado
     en devices.db/registry.db.

Este documento NO asume ninguna de las tres -- queda como decision
abierta para la proxima sesion o continuacion de esta. Sin esta decision,
no se puede escribir la funcion _do_tails.

## PENDIENTES ANTES DE TOCAR CODIGO

1. Plan de deploy coordinado: el nina fusionado debe llegar a TODOS los
   nodos (tx1, tx2, y cualquier otro registrado) antes de que clip
   set/tunnel dependa de el remotamente. tx1 esta inalcanzable por SSH
   (ver FINDINGS.md) -- bloqueante real para probar la coordinacion
   multi-nodo del clip fusionado hasta que tx1 tenga sshd corriendo de
   nuevo. DECISION: continuar el trabajo de fusion SIN tx1 por ahora.
2. bin/noemap.bak: RESUELTO -- eliminado via rm.
3. Escribir el nuevo bloque _source_mods completo para bin/nina
   fusionado (rutas nuevas de lib/, mas las fusiones de binarios).
4. git mv de los 12 archivos de lib/ a sus 8 rutas nuevas, y
   consolidacion de los 7 binarios en el nina fusionado.
5. README.md y readme.txt: actualizar a los subcomandos nuevos y al
   nombre nina (aun documentan --deep, el pipeline monolitico viejo, y
   el nombre noemap).
6. Probar cada subcomando fusionado con salida real antes de dar la
   migracion por completa.
7. RENOMBRE FISICO: decidir y ejecutar el renombre de la carpeta/repo
   (~/unix-toolkit-tools/noemap/ -> ¿/nina/?), del binario en si, y de
   cualquier referencia a 'noemap' en el codigo restante -- aun no
   ejecutado, solo decidido a nivel de nombre de subcomandos en este
   documento.
8. PENDIENTE CRITICO nuevo: resolver el origen de las IPs de tailscale
   para 'tails' (ver PARTE 4) antes de escribir esa funcion.

Rama de trabajo: feat/unify-binaries, desde main (branch previa
feat/subcommands-dispatcher ya fue mergeada a main, confirmado via
reflog -- no reutilizable para este trabajo, que excede su alcance
original).

0 git mv ejecutados, 0 codigo de bin/ o lib/ tocado, 0 archivos
renombrados fisicamente de noemap a nina. Este documento reemplaza
integramente la version anterior de ARCHITECTURE-nueva.md.
