# NOEMAP -- ARCHITECTURE (living doc)

Referencia tecnica primaria de como esta construido noemap hoy. Leer
ESTO antes de re-investigar cualquier sintoma de identity/registry/
hostkey/devices.db. Actualizar en cada sesion que toque el subsistema
descrito, no crear archivos nuevos paralelos.

Para hallazgos activos, tareas sin resolver, y bugs en investigacion:
ver FINDINGS.md (mismo directorio).

## registry.db -- diseno base

registry.db (~/.noemap-registry/registry.db, cloud, git-backed) tiene
campo hostkey junto a node_id/alias/user/port/platform. Permite que un
host nuevo en un nodo, pero ya registrado en la nube por OTRO nodo, se
auto-registre sin preguntar alias/user y sin SSH con credenciales a un
host no registrado.

## Donde vive cada pieza

lib/util.sh             _get_host_key_fingerprint IP PORT
                         ssh-keyscan + ssh-keygen, sin auth. Compartida
                         por TODOS los binarios.

lib/identity.sh          _registry_write NODE_ID ALIAS USER PORT PLATFORM
                         (linea ~211) -- UNICA funcion que escribe
                         registry.db.
                         - Guard de colision de alias.
                         - Si NODE_ID == node_id() de esta maquina: escanea
                           su propio hostkey via 127.0.0.1:PORT.
                         - Si NODE_ID es de OTRO nodo: preserva el hostkey
                           que ya tenia esa fila (nunca se puede escanear
                           un hostkey ajeno sin SSH auth) -- esto significa
                           que ndevs --registry-set sobre un nodo remoto
                           NO refresca su hostkey; solo nhkrefresh (via
                           _get_host_key_fingerprint contra la IP real)
                           puede hacerlo.
                         - Guard de no-op: si la fila no cambio, salta
                           commit/push pero SIEMPRE llega a
                           _distribute_registry al final.

                         node_alias_set ALIAS USER PORT PLATFORM -- wrapper
                         delgado sobre _registry_write con node_id() propio.

                         registry_row_by_hostkey HOSTKEY / registry_row_by_alias
                         ALIAS -- lookups de solo lectura contra la nube.

                         _distribute_registry (linea ~340) -- tras cada
                         _registry_write: pull+verify MATCH en cada nodo
                         remoto via nssh. Si la fila de ese nodo remoto ya
                         actualizada no tiene hostkey, dispara via nssh un
                         'ndevs --node-set <alias> <user> <port>' remoto,
                         AUTOMATICO. user/port se toman de devices.db local.

lib/devices.sh           resolve_device(alias, db) -- IP viene SOLO de
                         devices.db local (nunca de la nube). Si ip esta
                         vacio: exit 1 duro, "empty IP for '<alias>'".
                         Este exit silencia corriente abajo cualquier
                         intento de handshake (ver bin/nhkrefresh abajo).
                         port/user si tienen fallback a registry.db.
                         Guard is_local_ip() bloquea handshake contra el
                         propio nodo (exit 1), confirmado funcionando.

lib/fingerprint.sh       _update_registered_hosts / new_hosts_list --
                         ambas hacen lookup ip-first + hostkey-fallback
                         (via _get_host_key_fingerprint) para reconciliar
                         un host visto en la red contra devices.db. El
                         fallback SOLO dispara si hay match exacto de
                         hostkey contra una fila existente -- si el
                         hostkey almacenado esta stale (dispositivo
                         reformateado), el fallback tambien falla y el
                         alias queda con ip vacio indefinidamente.

                         fingerprint_hosts -- entry point principal. Lee
                         HOST_LIST (de scan.sh), prueba puertos SSH
                         (22/8022/2222), clasifica tipo via heuristica de
                         puerto + banner pasivo (_detect_type), escribe
                         hosts.db. NOTA (2026-09-06): modo deep/NOEMAP_DEEP
                         referenciado en comentarios historicos de este
                         archivo esta siendo removido en su totalidad --
                         ver FINDINGS.md noemap#502. Clasificacion de tipo
                         queda solo: TTL + puerto + banner pasivo (SSH
                         directo via /dev/tcp, fallback nmap -sV).

lib/output.sh            prompt_new_hosts -- ante host nuevo, calcula su
                         hostkey y cruza contra registry_row_by_hostkey
                         ANTES de preguntar. Si hay match sin colision de
                         alias local: auto-registra, sin preguntas.

lib/scan.sh              discover_hosts -- entry point de descubrimiento.
                         Fase 0: valida hosts ya registrados via ping.
                         Fase 1: ARP ping (nmap -sn -PR), fallback TCP-SYN.
                         Fase 2: probe de puerto SSH sobre candidatos.
                         _self_register -- auto-registra la IP propia en
                         devices.db (guard de idempotencia por sesion,
                         _SELF_REGISTER_DONE). _seed_from_registry --
                         trae filas de otros nodos desde la nube aunque
                         nunca hayan sido vistos por LAN. sync_devices_to_
                         nodes -- push de devices.db a todos los nodos
                         registrados via nssh, best-effort.

bin/ndevs                --registry-set NODE_ID ALIAS [USER] [PORT] [PLATFORM]
                         edita a mano cualquier fila remota -- NO refresca
                         hostkey de un nodo remoto (ver limitacion arriba).
                         --update-ip ALIAS NEWIP -- unico camino para
                         poblar el campo ip de devices.db; limpia
                         known_hosts de la IP vieja y propaga devices.db
                         via nscp al terminar.

bin/nhkrefresh           Escanea TODOS los alias de devices.db, compara
                         hostkey live (via _get_host_key_fingerprint
                         contra la IP local ya almacenada) contra el
                         hostkey guardado en registry.db (via
                         registry_row_by_alias), y en caso de mismatch
                         pregunta [y/N] antes de aplicar
                         'ndevs --registry-set' con el node_id/user/port/
                         platform ya conocidos de la fila remota.
                         LIMITACION (no un bug, precondicion de diseno):
                         si devices.db tiene ip vacio para ese alias,
                         nhkrefresh hace SKIP inmediato -- no intenta
                         resolver la IP por otra via. Requiere
                         'ndevs --update-ip <alias> <ip>' corrido a mano
                         ANTES, con la IP obtenida de otra fuente.
                         Uso: nhkrefresh (sin argumentos), o nhkrefresh -h.

bin/nclip-set            Define direccion de clipboard entre dos nodos
                         (src envia, dst recibe). Escribe state/clip-dir
                         .conf, arranca nclip-listen en dst via nssh,
                         corre smoke-test send+read. Direccion explicita,
                         no inferida. No persiste entre reboots.

## Puntos del diseno original fuera de alcance (no tocados)

(4) modelo de datos IP-nunca-en-registry -- ya funcionaba, no se toco.
(6) distribucion en malla con 3+ nodos -- no implementado, solo 2 nodos
    probados (tx1, tx2).
(7) reporte explicito de motivo de fallo por nodo inalcanzable -- no
    implementado.
(8) purga inmediata de registro viejo si cambia de red/subred -- no
    implementado (ver noemap#292/#463, resueltas para deteccion de
    cambio de subred PROPIA via ifconfig, pero purga inmediata de todo
    el registro anterior en ese caso sigue sin confirmar shippeada).

## Commits relevantes (main, orden cronologico)

Sesion 2026-08-30/31 (arquitectura base hostkey en registry.db):
  7873966  fix(devices): always prefer registry.db port over local
  89892d6  feat(noemap): cross-ref new hosts via registry hostkey
  165c58b  fix(registry): consolidate write path into _registry_write
  2647f78  fix(output): remove duplicated printf arg line
  b3a48f2  feat(registry): auto-trigger remote hostkey registration
  e1f6b77  fix(registry): always distribute even on no-op local write

Sesion 2026-09-04 (identity fix + nhkrefresh):
  43618df  feat(noemap): add nhkrefresh hostkey reconciliation script
