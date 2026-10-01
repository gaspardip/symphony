# Plan de evolución de la arquitectura de Symphony

Fecha del plan original: 25 de septiembre de 2026. Seguimiento: las unidades se integran por separado; el contrato C5 se describe en su registro de progreso. Coordinación: tarea actual de Tesis.

## Objetivo y corte de referencia

Cerrar las garantías pendientes del sistema, reducir el acoplamiento del coordinador y hacer comprobable el contrato con los proveedores. Incorporar cada unidad validada a `main` antes de acumular trabajo dependiente. Después, evaluar modelos nuevos sobre el mismo contrato y casos de aceptación.

Corte histórico de la revisión original: `main`, `45fae0239176288712dd1acee5fac8d7facc632d`, en `/Users/gaspar/src/symphony`, limpia. La recuperación `b29ce72` está integrada localmente. La última validación registrada del árbol de producto tiene 1.365 pruebas sin fallos, 82,11 % de cobertura y los siete controles aprobados; esta revisión no volvió a ejecutarlos. Permanece abierto el fallo temporal observado en WorkflowStore y la aceptación funcional de tesis. La cifra de pruebas no demuestra aceptación ni ausencia de condiciones de carrera.

La planificación parte del [contrato vigente](RUNTIME_CONTRACT.md), las [lecturas asíncronas ya incorporadas](tracker-poll-async.md) y los contratos de [dispatch](dispatch-audit.md), [deploy](deploy-audit.md) y [leases](lease-exclusion.md). Los documentos históricos de diseño describen propuestas: no se convierten automáticamente en alcance de esta iniciativa.

## Decisiones de diseño propuestas

- Conservar una aplicación Elixir/OTP, los workers existentes por intento y un único propietario del estado del coordinador. Extraer responsabilidades al migrar una ruta real, con pruebas de comportamiento. No usar la cantidad de líneas como criterio de aceptación.
- El coordinador decide admisión, capacidad y propiedad. Las tareas de lectura devuelven datos o errores; no reciben una copia de `State` ni ejecutan efectos de entrega. El motor conserva el ciclo de entrega y delega operaciones externas a límites explícitos.
- Mantener el almacenamiento local y sus garantías declaradas. Un cambio de base de datos o un nuevo proceso residente por ejecución exige una necesidad medida y un diseño separado.
- Preservar presupuestos, permisos, validación y auditoría aunque cambie el modelo. Las capacidades del proveedor deben ser explícitas; no simular una sesión persistente o una confirmación que el protocolo no proporciona.
- Ejecutar cambios pequeños y reversibles. La integración local, publicación remota, CI, release cargada y aceptación funcional conservan estados independientes.

## Autoridad e identidad de ejecución

| Información | Autoridad y límite |
|---|---|
| Etapa, consumo acumulado y progreso confirmado | Snapshot validado de RunStateStore. No asumir reconstrucción íntegra desde el ledger. |
| Límites y política efectiva | Configuración validada y resolución vigente de RunPolicy, combinadas con el contexto actual. La identidad no congela límites históricos del snapshot. |
| Autorización y evento confirmado | Operaciones checked del ledger, vinculadas al snapshot/journal. Los escritores históricos que ocultan fallos se deben inventariar y migrar por rutas concretas. |
| Propiedad actual | Lease vigente; su copia en el snapshot no sustituye la consulta vigente. |
| Operación incierta | Journal pendiente: bloquea los efectos incompatibles. El vencimiento del lease no elimina esta barrera. |
| Pedido y estado del servicio externo | Tracker y evidencia del servicio correspondiente. Un estado Done no prueba aceptación local. |
| Código validado y cargado | Revisión/manifiesto de la validación y evidencia del proceso/release que realmente ejecuta. |

`run_id` identificará un ciclo lógico y sobrevivirá a reintentos y reinicios. El `dispatch_id` existente identificará cada admisión de un worker; no se agrega otro `attempt_id` independiente. El contador de retry mantiene su función de política. Sesión del proveedor, operación auditada y evento conservan sus identidades propias.

`owner + epoch`, PID/ref y generación de la operación siguen siendo controles de vigencia. `run_id` no los reemplaza. El epoch del lease puede comenzar de nuevo en 1 cuando no existe archivo; no es un contador histórico global.

La identidad se crea y persiste en admisión autorizada, antes de abrir el gate o ejecutar hooks/proveedor. Nunca se genera en lecturas, renderizados o defaults. Datos históricos sin identidad siguen siendo legibles; su adopción requiere un registro explícito y conserva consumo, etapa y aprobaciones. Corrupción, contradicción o journal pendiente impiden la adopción. No se reescribe la historia del ledger. Abrir un ciclo nuevo para una tarea terminada queda fuera del primer bloque de identidad.

## Orden de ejecución

1. **C1: predespacho ordinario.** Continuar el trabajo A+B ya integrado, en una sola ruta, sin esperar bajo una lease.
2. **C2: retries.** Reutilizar la continuación de C1 conservando consumo y metadata.
3. **P1: modelo solicitado.** Corregir la opción ya expuesta de modelo por turno; no incorporar modelos nuevos todavía. Es independiente y puede prepararse mientras se revisan C1/C2, con integración y controles secuenciales.
4. **I1: nacimiento de identidad.** Contrato y persistencia mínima. C1/C2 sólo necesitan identidad efímera y no dependen de esta migración durable.
5. **C3–C6: rutas asíncronas restantes**, una por unidad. C3 exige resolver primero la propiedad de la lease pendiente; C6 exige concretar el deadline del control.
6. **I2, P2 y P3: propagación y proveedores.** Integrar I2 antes de usar cambios de proveedor como demostración de trazabilidad. P2 y P3 se implementan separados.
7. **I3 y E1: recuperación, evidencia y campaña funcional.** El diagnóstico de I3 puede prepararse antes en modo de lectura. Las reconciliaciones inciertas requieren diseño específico. La evaluación comparativa de modelos empieza con una versión estable y criterios fijados.

La separación de decisiones y efectos se realiza dentro de estas unidades. Una extracción mayor del motor sólo se propone si una ruta sigue siendo difícil de probar o mantener después de sus correcciones.

## C. Disponibilidad del coordinador

Usar TrackerReader y el contexto fijo de configuración existentes. Cada continuación guarda ref, propósito, identidad de issue, generación y pruebas de vigencia necesarias. Al retornar, el propietario vuelve a evaluar capacidad, política, pausas, presupuesto y auditorías desde el estado actual.

| Unidad | Cambio acotado | Aceptación observable |
|---|---|---|
| C1. Predespacho ordinario | Separar la lectura previa a adquirir lease de la decisión de admisión. Inicialmente una admisión pendiente a la vez, con orden/capacidad acotados y política explícita respecto del lector B. | Con la lectura retenida, snapshot y mensajes de workers progresan. Stop, pausa, cambio de configuración/capacidad, issue ausente/terminal o ID distinto impiden spawn tardío. Una respuesta vieja no adquiere lease ni limpia trabajo reciente. Si el candidato A falla/desaparece, el siguiente B elegible avanza. |
| C2. Reintentos | Identidad de timer, metadata de retry conservada durante lectura y continuación por C1. Mantener candidatos para retry ordinario y lookup individual para continuación pasiva. | Timer viejo/duplicado no consume el retry nuevo. Descartar una respuesta vieja no incrementa attempt; error/429 conserva la política. Consumo acumulado se mantiene. |
| C3. Promoción pasiva a activa | Separar la revalidación que hoy ocurre después de obtener lease. Definir expiración/renovación y liberación condicional antes del cambio. | Pérdida de propiedad durante la consulta impide el worker y no libera la lease sucesora. Comparación y liberación están protegidas en una misma operación. |
| C4. Inbox Linear | Una cabeza pendiente por inbox; confirmar sólo el prefijo procesado de la misma cola. | No hay ack adelantado. 429 mantiene la cabeza. Cambio de raíz/configuración no confirma otra cola. Se preservan las reglas actuales de descarte. |
| C5. Eventos GitHub | Distinguir resolución inicial y refresh después de efectos ya realizados. | Respuesta tardía/repetida no repite transición o escritura ni reabre trabajo detenido. Se comprueban PR, etapa y propiedad vigentes. |
| C6. Controles | Ruta local directa y lookup remoto con respuesta final una sola vez. Deadline transportado desde la frontera de llamada. | Consulta que agota el plazo no inicia después la acción. No se agrega una segunda consulta para diagnóstico ni una respuesta de éxito prematura. |

Una operación por issue no limita el total de lecturas. C1 debe definir el límite global y la convivencia con B antes de escribir el cambio; la opción inicial propuesta es una sola lectura de admisión pendiente además de la lectura B existente, sin cola ilimitada. Al completarse, se recalcula elegibilidad y capacidad. Conservar un cursor/lista del lote vigente sin acumular lotes de polls posteriores, o una continuación equivalente que garantice avanzar hacia el siguiente candidato tras un descarte. Reiniciar siempre desde el primer candidato en cada poll podría dejar sin atención a los demás. La continuación también se invalida ante cambios pertinentes de configuración/lifecycle.

C3 no puede resolverse leyendo epoch y llamando luego a `LeaseManager.release/2`: esa función compara owner, y la comprobación separada deja una ventana. Además, la renovación actual recorre `running`; una admisión pendiente no pertenece aún a ese conjunto. La unidad empieza por cerrar ambas condiciones con una reproducción controlada.

Para C6, los 5 segundos actuales incluyen el tiempo que el pedido pasa en el buzón del coordinador. El diseño no puede iniciar otra ventana completa en `handle_call`. El plazo y error final se fijan antes de implementarlo; no se amplía a infinito. Una escritura ya iniciada conserva su incertidumbre y contrato propios.

Medir por ruta mediante barreras de mensajes: retener la lectura y demostrar progreso antes de liberarla. Registrar pendientes, descartes por obsolescencia y causas de bloqueo. Inventariar por separado las escrituras del tracker, operaciones GitHub y otros efectos aún síncronos antes de prometer disponibilidad global. Ninguna unidad de lectura acredita un stop inmediato de todo el sistema.

## I. Identidad y recuperación

| Unidad | Alcance | Aceptación observable |
|---|---|---|
| I1. Nacimiento durable | Agregar run_id al snapshot/admisión y vincular dispatch_id. Validar identidad en este límite, sin convertir todo el snapshot a un struct. Adopción explícita de legado con auditoría completa. | Relectura y reinicio conservan run; nueva admisión del mismo ciclo crea otro dispatch. Fallo de persistencia impide hooks/worker/proveedor. Admisión concurrente no crea dos identidades efectivas. Lectura de legado no cambia bytes; adopción conserva consumo y etapa. |
| I2. Propagación | Correlacionar AgentRunner, DeliveryEngine, proveedor, consumo, eventos y evidencia. Mantener todos los controles de vigencia existentes. | Un resultado de otro intento/run no cambia el actual. Cambio de sesión conserva run. Se puede recorrer run → dispatch → sesión → operación desde la evidencia y las superficies de diagnóstico. |
| I3. Recuperación explícita | Inspección de snapshot, lease, journals y evidencia. Reutilizar reconciliaciones exactas ya admitidas; diseñar por separado cada caso hoy incierto. | Lectura repetida no altera bytes. Caídas antes/después de intención, autorización y confirmación producen recuperación respaldada o bloqueo explicado. No se repiten publicación/deploy ni se elimina pending por timeout. |

La integración de identidad necesita probar el fallo entre persistir identidad y autorizar el trabajo. Agregar campos en dos archivos no hace atómica esa operación. Los escritores legacy del ledger se enumeran y migran por autoridad y efecto; no se da por cerrada PB10 porque se incorpore run_id.

## P. Contrato de proveedores

| Unidad | Alcance | Aceptación observable |
|---|---|---|
| P1. Modelo solicitado transmitido | Pasar `opts[:model]` a `turn/start` en Codex AppServer, con regresiones del binario simulado y documentación de la persistencia del override. | JSON contiene el modelo explícito; dos turnos pueden solicitar valores distintos. Ausencia de opción conserva herencia; rechazo del servidor se propaga. Effort, sandbox y aprobación no cambian. |
| P2. Proveedor por etapa | Hacer explícito el par proveedor/sesión. Reutilizar sesión mientras coincida proveedor; cerrarla y abrir la siguiente cuando la configuración por etapa cambie. El verificador conserva su sesión independiente. | A→B produce inicio/turno/cierre de A y luego B. A→A conserva sesión. Error al abrir B detiene el trabajo, conserva progreso/consumo y no ejecuta con A. Cada sesión se cierra una sola vez. |
| P3. Efectos comunes de entrega | Separar transporte del formato, commits y modificación de evidencia que hoy hacen Claude/CodexCLI. La política común decide y registra efectos/errores. | Evidencia ausente permanece ausente y bloquea donde el contrato la exige. Un verificador no modifica evidencia ni crea commits. Error de preparación/commit se informa. Un adapter por sí mismo no altera HEAD por postprocesamiento. |

P1 se apoya en el esquema local generado por `codex-cli 0.156.1`: `TurnStartParams.model` admite un override para ese turno **y los posteriores**. Omitirlo después no significa volver al modelo inicial. ThreadStartResponse informa modelo al abrir hilo; TurnStartResponse no confirma cuál se ejecutó en cada turno. Por ello el nombre y la prueba de P1 se limitan a la solicitud transmitida. Acreditar modelo efectivo requiere evidencia adicional que el proveedor realmente exponga.

P2 puede perder el contexto interno del proveedor anterior; la continuidad debe descansar en progreso persistido y prompt. No agregar fallback automático ni reiniciar presupuesto. P3 distingue una extracción mecánica de una corrección semántica: retirar el relleno artificial de evidencia y propagar fallos son cambios observables y deben tener regresiones propias. La extracción que conserve comportamiento y las correcciones semánticas van en commits separados y probados, aunque el parche sea pequeño. Revisar `needs_another_turn` y diferencias de cancelación mediante capacidades explícitas; no homogeneizarlas con valores inventados.

## E1. Evidencia y aceptación

- Vincular los artefactos a revisión de código, run/dispatch, comando y resultado. El consumidor debe comprobar integridad y correspondencia de la afirmación; un hash válido por sí solo no prueba corrección.
- Completar el contrato CR11 de contenido ausente, vacío, contradictorio y de otro commit/ejecución. Acordar compatibilidad antes de cambiar el consumidor; conservar los resultados de los casos que hoy pasan indebidamente.
- Verificar la revisión realmente cargada por el runner, además del puntero de release.
- Repetir campañas de presupuesto/reinicio, duplicación, recuperación y controles sobre el corte integrado correspondiente. Un pase sobre un commit anterior no se transfiere automáticamente.
- Completar E3 y selección representativa E4 conforme al protocolo de tesis; registrar métricas, fallos, bloqueos legítimos y límites. Modelos nuevos se comparan después sobre tareas y criterios constantes, con modelo solicitado/observado diferenciados.

Los 26 casos y las métricas académicas conservan sus criterios originales. Este plan técnico no concede aprobaciones ni promete una fecha de defensa. Publicación, merge, despliegue y pruebas con servicios reales requieren concretar su alcance antes de ejecutarse.

## Coordinación, revisión e integración

El coordinador conserva el plan, ordena dependencias y es el único integrador. Se delegan inspecciones, revisión adversarial y preparación de casos; hay un único escritor por archivo compartido. Orchestrator, DeliveryEngine y RunStateStore no se editan desde dos frentes a la vez. Preparar trabajo independiente en paralelo no autoriza ejecutar dos suites que compartan el runtime de prueba.

Cada unidad debe entregar:

1. Problema reproducible, cambio de comportamiento exacto, archivos previstos, criterios y límites. Si afecta cinco o más archivos, exponer el alcance antes de editar.
2. Regresiones observables en los límites reales. No debilitar aserciones ni reemplazar errores por éxito. Las adaptaciones legítimas de fixtures deben justificarse por la semántica cambiada.
3. Pruebas focales y después los controles completos configurados: formato, lint/specs, suite, cobertura, Dialyzer, build y harness. Usar el entorno aislado con tracker controlado y registrar manifiesto/comandos/salidas. No lanzar el workflow operativo contra tareas reales para validar una corrección local.
4. Revisión independiente de obsolescencia, presupuesto, propiedad, efectos y compatibilidad, según el alcance.
5. Commit convencional de una sola preocupación; incorporar localmente a `main`; cotejar árbol probado, diff y limpieza. Conservar el SHA y los resultados en el registro de cierre. Las ramas/worktrees históricos se preservan.

Las corridas fallidas permanecen registradas. Un fallo intermitente preexistente requiere atribución y repetición acotada intacta cuando corresponda; no se convierte en una excepción automática para declarar la unidad aprobada. Si aparecen dos fallos nuevos, detener la ampliación del parche, informar y diagnosticar antes de seguir.

Durante esta revisión no hay herramienta LSP callable. Antes de editar código se vuelve a comprobar disponibilidad; si sigue ausente, documentar la limitación y usar fuente, compilación, specs y Dialyzer sin presentarlos como diagnósticos LSP.

No se ejecutan push, merge remoto, despliegue ni borrado de tareas/worktrees por registrar este plan. La integración local ya solicitada es parte de cada unidad; la publicación remota conserva una decisión separada.

## Revisión técnica del plan

Tres revisiones de lectura examinaron disponibilidad, identidad y proveedores sobre el mismo corte. Incorporaciones concretas:

- Separar promoción pasiva de predespacho ordinario por la lease ya adquirida.
- Acotar globalmente las lecturas; una por issue no es límite suficiente.
- Contar el deadline del control desde envío, incluyendo espera en buzón.
- Reutilizar dispatch_id y no equiparar run_id con ownership ni frescura.
- Conservar legado sin fabricar historia ni convertir ledger en autoridad de reconstrucción inexistente.
- Diferenciar modelo solicitado, modelo informado al abrir sesión y ejecución efectiva.
- Mantener worker por intento y almacenamiento local mientras no exista una necesidad demostrada para reemplazarlos.

La revisión original eligió C1 como primer paquete. Los registros de progreso y los receipts externos conservan la implementación, pruebas e integración de cada unidad; las cifras del corte histórico anterior no describen automáticamente el árbol posterior.

C5 separa la resolución inicial del refresh posterior a efectos, comparte B y la admisión A existentes, difiere efectos mientras vive el worker y conserva el deadline original hasta el gate. Su [registro de progreso](../.symphony/progress/architecture-C5.md) describe el contrato y los límites; la aceptación depende de revisar y ejecutar el corte compuesto. C6, P2/I3, la autoridad y consumo de evidencia E1, la comprobación de release cargada y los 26 casos mantienen sus propios criterios. La comparación de modelos viene después de esas garantías.
