# NOEMAP -- ARQUITECTURA NUEVA (propuesta, aun no implementada)

Este archivo documenta una PROPUESTA de rediseno, pendiente de aprobacion
y codificacion. No confundir con ARCHITECTURE.md (lo que YA existe
funcionando hoy). Una vez implementada y verificada, esta propuesta se
fusiona dentro de ARCHITECTURE.md y este archivo se retira.

Contexto: noemap hoy es un pipeline monolitico -- una sola invocacion
corre discover -> fingerprint -> register-new -> bootstrap-keys -> push,
todo junto, sin forma de ejecutar un paso aislado para diagnosticar donde
falla exactamente (ej. tras un cambio de red/wifi, o en un celular recien
formateado).

Ademas, el proyecto completo hoy vive repartido en 9 binarios (noemap,
nssh, nscp, nclip, nclip-listen, nclip-send, nclip-set, ndevs,
nhkrefresh) y 12 archivos de lib/, sin agrupacion por responsabilidad y
con varios sourceos duplicados de las mismas dependencias en distintos
binarios. Objetivo ampliado (sesion 2026-09-06): sintetizar todo en una
estructura simple, escalable y modular -- fusion de binarios donde tiene
sentido, reestructuracion de lib/ por dominio, nombres obvios.

## PARTE 1 -- Los 7 subcomandos de discovery (YA EN PROGRESO, noemap#502)

Descomponer el pipeline de discovery en subcomandos independientes,
ejecutables uno por uno, cada uno con nombre obvio y responsabilidad
unica. `noemap` SIN NINGUN ARGUMENTO sigue siendo el atajo que corre el
pipeline completo -- comportamiento actual sin cambio. CORRECCION
(sesion 2026-09-06): 'all' NO se expone como subcomando que el usuario
escriba (no existe 'noemap all'); solo es el nombre interno de la
funcion _do_all, usado cuando no se pasa ningun argumento. El dispatcher
ya lo maneja asi: noemap_dispatch() hace _sub="${1:-all}" -- el default
cae a _do_all internamente sin que el usuario lo escriba.

  noemap discover        Fase 0/1/2 de scan.sh: ping hosts registrados,
                          ARP/TCP-SYN ping, probe de puerto SSH. Encuentra
                          QUE hosts estan vivos en la red ahora mismo.
                          No modifica devices.db. Persiste su resultado
                          para que `fingerprint` lo consuma despues.

  noemap self-register   Registra ESTE nodo (alias/user/port/platform) en
                          devices.db y registry.db. Ya standalone-safe
                          (_self_register + _prompt_self_identity).

  noemap seed             Trae filas de OTROS nodos desde registry.db
                          (la nube) hacia devices.db local. Ya standalone
                          (_seed_from_registry).

  noemap fingerprint      Clasifica el tipo de cada host que `discover`
                          encontro (TTL + puerto + banner pasivo SSH),
                          escribe hosts.db. Requiere que `discover` haya
                          corrido antes (lee su resultado persistido).

  noemap bootstrap-keys   Distribuye llaves SSH a los hosts recien
                          registrados en devices.db.

  noemap push             Empuja devices.db completo a todos los demas
                          nodos registrados (via nssh). Llama
                          _self_register internamente primero.

  (sin argumento)         Orquesta los subcomandos anteriores en orden,
                          en una sola invocacion, en memoria (_do_all
                          internamente) -- comportamiento identico al
                          `noemap` de hoy.

NOTA: register-new (registro interactivo de hosts nuevos encontrados por
fingerprint) se UNIFICA con ndevs --add bajo `noemap devices add` -- ver
PARTE 3. Ya no es un subcomando de top-level separado.

### Estado entre subcomandos -- DECIDIDO

Cada subcomando corre en su propia invocacion de shell, efimera -- las
variables de shell (HOST_LIST, _STALE_ALIAS_CANDIDATES) que hoy viven
solo en memoria durante la corrida completa NO sobreviven entre `noemap
discover` y `noemap fingerprint` como invocaciones separadas. Persisten
en disco:

  state/host_list.cache             una IP por linea (salida de discover)
  state/stale_candidates.cache      un alias por linea (salida de discover)

cache.sh NO se modifica -- estas dos listas viven en su propio archivo
cada una, mismo directorio state/ que ya usan devices.db/hosts.db/cache.env.

### Manejo de subcomando corrido sin su previo -- DECIDIDO

Si `noemap fingerprint` corre sin que `noemap discover` haya corrido
antes (host_list.cache vacio o no existe): preguntar interactivamente
(y/N) si se debe correr `discover` automaticamente antes de continuar.
Si la respuesta es no, salir sin hacer nada (exit 1). Mismo patron para
cualquier otro subcomando que dependa de un paso previo.

### Dispatcher -- YA APLICADO Y VERIFICADO

lib/noemap-dispatch.sh (movido de bin/ a lib/ -- _source_mods busca en
$LIB, no en bin/) centraliza el case sobre el subcomando y delega a cada
_do_<subcomando>. Todos los subcomandos toman el mismo lock global
(acquire_lock/release_lock) via _dispatch_lock_wrap, llamado una sola vez
en noemap_dispatch() antes del case final -- no cada _do_* individual.
bin/noemap queda como entry point delgado: resuelve BASE, hace source de
los modulos via _source_mods, pasa el control a noemap_dispatch con los
argumentos recibidos. Verificado bash -n OK, probado con salida real
(noemap -h, noemap discover corren sin errores fatales).

### --deep / NOEMAP_DEEP -- ELIMINADO (noemap#502)

Reportado sin uso real en la practica. Sitios confirmados por grep
completo del repo: bin/noemap, lib/fingerprint.sh, lib/scan.sh,
bin/nclip-set:118 (mensaje de error, no codigo funcional -- reescribir
sin la flag), README.md:22, readme.txt (lineas 11-13,17,93-96). Alcance:
eliminacion total, sin mencion ni rastro en codigo, comentarios, ni texto
de ayuda.

## PARTE 2 -- Reestructuracion de lib/ (DECIDIDO, pendiente de ejecutar)

lib/ pasa de 12 archivos sueltos a 8 rutas agrupadas por dominio:

  core/blockdb.sh              (infra pura, sin conocimiento de dominio)
  core/lock.sh
  core/cache.sh
  core/util.sh
  core/noemap-dispatch.sh       (dispatcher de subcomandos, noemap#502)

  identity/identity.sh          (identity.sh lineas 1-210: _identity_statedir,
                                _identity_registry_default, _node_config_load/save,
                                _identity_registry_warn_once, _gen_uuid,
                                _machine_seed, _sha256, _local_ips,
                                _own_devices_ip, is_local_ip, node_id,
                                node_alias, node_registry_row -- "quien soy yo")

  registry/registry.sh          (identity.sh lineas 211-406: _registry_write,
                                node_alias_set, registry_row_by_alias,
                                registry_row_by_hostkey, _distribute_registry
                                -- registry.db compartido, su propio git remoto)

  discovery/iface.sh
  discovery/scan.sh             (incluye _purge_unrescued_stale_aliases,
                                confirmado linea 361 -- no esta en fingerprint.sh)
  discovery/fingerprint.sh

  connection/devices.sh         (resolve_device, _ensure_user,
                                resolve_scp_target -- usado por nssh, nscp,
                                nclip, nclip-send, nclip-set, NO por noemap
                                pipeline en si)

  output/output.sh

  transfer/ssh_bootstrap.sh

Corte de identity.sh CORREGIDO (relectura completa sesion 2026-09-06): el
mapeo original proponia cortar en linea 195/196 -- impreciso. identity/
real termina en linea 210 (incluye is_local_ip, _own_devices_ip, node_id,
node_alias, node_registry_row); registry/ real empieza en linea 211
(_registry_write en adelante). Cortar en 195/196 hubiera partido el
docstring de _registry_write separado de la funcion que documenta.

### Dependencias cruzadas confirmadas (3, no 1)

  (a) node_alias() [identity] llamada por _registry_write() [registry] --
      la dependencia ciclica ya conocida entre los dos modulos.
  (b) is_local_ip() -> _own_devices_ip() -> node_alias() -- cadena
      INTERNA a identity, no cruza modulos, pero toca el mismo punto de
      corte -- verificar que el split no la parta a la mitad.
  (c) _registry_write() [registry, linea 250] llama
      _get_host_key_fingerprint() que vive en util.sh/core -- cruce
      registry->core no documentado en el mapeo original.

### _source_mods usa ruta plana -- IMPLICACION CRITICA

bin/_bootstrap linea 44: _path="$LIB/$_mod" -- concatenacion PLANA, no
busca subcarpetas. Mover cualquier archivo a subcarpeta (ej. identity.sh
-> identity/identity.sh) rompe el source con '[ERROR] missing module' y
exit 1 hasta actualizar cada linea _source_mods que lo invoque.

DECISION CONFIRMADA: se actualiza la lista de argumentos de cada
_source_mods afectado con las subrutas nuevas; _source_mods/_bootstrap
NO se modifica (no se agrega busqueda/glob).

Binarios que sourcean identity.sh hoy (necesitan DOS entradas nuevas,
identity/identity.sh + registry/registry.sh, en ese orden -- ambas solo
declaran funciones al cargar, sin ejecucion inmediata, no hay bloqueo de
ciclo en el source en si):
  bin/noemap, bin/nclip-send, bin/nclip-set, bin/ndevs, bin/nhkrefresh
  (tras la fusion de PARTE 3, estos 4 ultimos dejan de ser binarios
  propios y su _source_mods se consolida en el bin/noemap fusionado)

Binarios que sourcean devices.sh hoy (necesitan connection/devices.sh):
  bin/nssh, bin/nclip, bin/nclip-send, bin/nclip-set, bin/nscp
  (bin/noemap NO lo sourcea hoy -- el pipeline nunca resuelve un alias
  individual a IP/user/port; tras la fusion, el noemap fusionado SI lo
  necesita para los subcomandos devices/clip. nssh y nscp sobreviven
  como binarios propios y mantienen su propio _source_mods con
  connection/devices.sh)

Hallazgo colateral (CORREGIDO 2026-09-06, verificado via find): la nota
original de esta seccion afirmaba que bin/noemap.bak existia (128 lineas,
sin noemap-dispatch.sh en su _source_mods). Un find -iname "*.bak" real
sobre todo el repo NO lo encuentra -- solo existian FINDINGS.md.bak y
ARCHITECTURE-nueva.md.bak (backups de estos mismos documentos, no del
binario), ya eliminados via rm el 2026-09-06. La afirmacion original se
escribio sin correr find; se retracta aqui. No hay bin/noemap.bak que
decidir eliminar o conservar -- ese pendiente queda cerrado por
inexistencia del archivo.

### Piezas que NO cambian (reutilizadas tal cual)

  _self_register          (scan.sh)       ya standalone-safe
  _seed_from_registry     (scan.sh)       ya standalone
  fingerprint_hosts       (fingerprint.sh) sin cambios de logica interna
  prompt_new_hosts        (output.sh)     ya lee de disco (hosts.db)
  ssh_key_bootstrap       (ssh_bootstrap.sh) sin cambios
  sync_devices_to_nodes   (scan.sh)       ya llama _self_register interno
  _prompt_self_identity   (output.sh)     flujo interactivo ya completo

## PARTE 3 -- Fusion de binarios (DECIDIDO, pendiente de ejecutar)

Ampliacion de alcance confirmada sesion 2026-09-06: de los 9 binarios de
bin/, 7 se fusionan en un solo binario `noemap` con subcomandos. nssh y
nscp SOBREVIVEN como binarios propios, separados -- son los de mayor uso
directo, no pasan por dispatcher ni lock. Esto tambien resuelve sin
friccion el riesgo de que una sesion SSH larga (noemap ssh <alias>)
bloqueara el lock global para otras invocaciones: al no fusionarse, nssh
nunca entra a noemap_dispatch() ni toca acquire_lock/release_lock.

### Arbol de subcomandos completo

  noemap                          (sin args: pipeline completo, igual a hoy)
  |-- discover / self-register / seed / fingerprint / bootstrap-keys / push
  |-- ssh-setup <alias>            (ya existente, sin cambios)
  |
  |-- devices
  |   |-- list                     (ex ndevs sin argumentos)
  |   |-- add                      (ex ndevs --add, UNIFICADO con
  |   |                            register-new -- un solo subcomando
  |   |                            cubre alta manual Y alta interactiva
  |   |                            post-fingerprint)
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

  nssh <alias> [cmd...]            BINARIO PROPIO -- no se fusiona
  nscp [-r] <src> <dst>            BINARIO PROPIO -- no se fusiona

### Nomenclatura tunnel/serve -- razon del cambio

Sesion 2026-09-06: nclip-listen agrupaba dos mecanismos bajo un solo
verbo ambiguo (start/start-tcp). Renombrado para que el mecanismo sea
obvio sin leer el codigo:
  - clip tunnel = modo SOCKET, viaja DENTRO de una conexion SSH ya
    abierta (via RemoteForward). nssh lo arranca/detiene solo,
    automaticamente, al abrir/cerrar una sesion interactiva. No requiere
    puerto de red propio.
  - clip serve  = modo TCP/ncat, puerto de red independiente (9988 por
    defecto). Funciona sin necesidad de una sesion SSH abierta al mismo
    tiempo. Usado por clip set/send en modo por defecto (CLIP_MODE=tcp).
  Ambos mecanismos se conservan -- cubren situaciones distintas, no son
  redundantes.

### Verificacion cruzada nssh vs nclip-set -- confirma diseno, no bug

Grep dirigido (sesion 2026-09-06) sobre bin/nssh y bin/nclip-set confirma
que ambos mecanismos se activan hoy desde binarios distintos, con nombres
de subcomando distintos, tal como el diseno de arriba anticipa:
  bin/nssh:81         llama 'nclip-listen start' (sin sufijo -- modo
                       SOCKET/tunnel), en trap de apertura/cierre de una
                       sesion SSH interactiva.
  bin/nclip-set:112,121  llama 'nclip-listen start-tcp' (modo TCP/serve),
                       explicito, sin relacion a una sesion SSH.
No es inconsistencia de codigo: son dos mecanismos independientes por
diseno (ver arriba), cada uno con su propio punto de entrada. Tras la
fusion mapean limpio a PARTE 3: nssh -> 'clip tunnel start/stop'
(punto de acoplamiento (a)), nclip-set -> 'clip serve start'
(punto de acoplamiento (c)).

### Puntos de acoplamiento a reescribir (5, identificados por lectura
completa de los 9 binarios, sesion 2026-09-06)

  (a) bin/nssh (linea 80-83) llama nclip-listen start/stop via
      `command -v` -- pasa a invocar la funcion interna del noemap
      fusionado (clip tunnel start/stop), no un binario externo.
  (b) bin/nclip-set (linea 38-39) hardcodea NCLIP_SEND=$_bindir/nclip-send
      y NSSH=$_bindir/nssh como RUTAS ABSOLUTAS -- NSSH se mantiene (nssh
      sigue siendo binario propio), NCLIP_SEND pasa a ser llamada de
      funcion interna (clip send) dentro del mismo noemap fusionado.
  (c) bin/nclip-set (lineas 67,112,121,139) invoca
      "$NSSH" "$_dst" 'nclip-listen start-tcp' REMOTAMENTE via SSH --
      tras la fusion, el nodo remoto ejecuta 'noemap clip serve start'
      (mismo binario fusionado, asumido YA DEPLOYADO alla). RIESGO
      CONFIRMADO: si tx1/tx2 quedan en versiones distintas del binario
      fusionado durante la migracion, esta llamada remota falla --
      deploy debe alcanzar TODOS los nodos antes de usar clip set/tunnel
      en produccion. Precondicion operativa, no solo de diseno.
  (d) bin/nhkrefresh (linea 124) llama 'ndevs --registry-set' como
      subproceso completo, capturando stdout con sed -- pasa a llamada
      de funcion interna (devices registry-set) dentro del mismo
      binario, ya no subproceso.
  (e) bin/ndevs _cmd_add/_cmd_update_ip (lineas 257,233) llaman nscp
      internamente -- nscp SOBREVIVE como binario propio, esta llamada
      se mantiene como invocacion de binario externo, sin cambio.

### Dependencia rota preexistente (hallazgo colateral, no introducida
por esta migracion)

bin/nclip-listen invoca $_bindir/play-confirm.sh en 3 puntos (lineas
82,114,162), siempre con `2>/dev/null || true`. CONFIRMADO POR
BUSQUEDA (find -iname "play-confirm*" en todo el repo): el archivo NO
EXISTE. Falla silenciosa hoy, sin romper nada -- no-op de facto. Al
fusionar, decidir si se elimina la llamada muerta o se deja igual
(silenciosamente no-op) por ahora.

## PENDIENTE ANTES DE CUALQUIER git mv O EDICION DE CODIGO

1. Confirmar plan de deploy coordinado: el noemap fusionado debe llegar
   a TODOS los nodos (tx1, tx2, y cualquier otro registrado) antes de
   que clip set/tunnel dependa de el remotamente. tx1 esta HOY
   inalcanzable por SSH (ver FINDINGS.md, diagnostico completo) --
   bloqueante real para probar la coordinacion multi-nodo del clip
   fusionado hasta que tx1 tenga sshd corriendo de nuevo.
2. Decidir bin/noemap.bak: eliminar via maid o conservar.
3. Escribir el nuevo bloque _source_mods completo para bin/noemap
   fusionado (13 rutas nuevas de lib/, mas las 7 fusiones de binarios).
4. Recien despues: git mv de los 12 archivos de lib/ a sus 8 rutas
   nuevas, y consolidacion de los 7 binarios en el noemap fusionado.

Todo lo pendiente quedo decidido -- 0 git mv ejecutados, 0 codigo
tocado. Este documento reemplaza integramente la version anterior de
ARCHITECTURE-nueva.md.
