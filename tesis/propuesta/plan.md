# Plan de Tesis - Proyecto Final Integrador

## Arquitectura de runtime con *proof gates* para delivery autónomo de software basado en *issues*

---

## 1. Títulos

### 1.1. Título principal

**Arquitectura de runtime con *proof gates* para delivery autónomo de software basado en *issues***

### 1.2. Título alternativo de trabajo

**Marco integrador para la ejecución controlada, observable y verificable de agentes de software sobre repositorios**

### 1.3. Carrera y asignatura

* **Carrera:** Ingeniería en Informática
* **Asignatura:** Tesis de Grado - Proyecto Final Integrador
* **Código de asignatura:** 3375
* **Tipo de tesis:** Investigación aplicada y desarrollo específico
* **Ámbito de desarrollo:** Repositorio propio del alumno, con posibilidad de validación sobre repositorios de prueba y escenarios reproducibles.

---

## 2. Integrantes

| Rol                                | Nombre                        | Matrícula   | Correo      | Observaciones                  |
| ---------------------------------- | ----------------------------- | ----------- | ----------- | ------------------------------ |
| Alumno                             | [Completar apellido y nombre] | [Completar] | [Completar] | [Completar]                    |
| Director de tesis                  | [Completar apellido y nombre] | No aplica   | [Completar] | [Completar institución/cargo]  |
| Codirector, si corresponde         | [Completar apellido y nombre] | No aplica   | [Completar] | [Completar]                    |
| Asesor profesional, si corresponde | [Completar apellido y nombre] | No aplica   | [Completar] | [Completar organización/cargo] |

**Tabla 1. Integrantes del proyecto.**
La tabla identifica al alumno, director, codirector y asesor profesional si correspondiera. Los datos personales y académicos se dejan como placeholders para ser completados en la versión formal.

---

## 3. Resumen

El presente plan de tesis propone el diseño, implementación y validación de una arquitectura de runtime para delivery autónomo de software basado en *issues*, entendidas como tareas o tickets de trabajo gestionados en un sistema de seguimiento. El problema abordado surge de la brecha existente entre la capacidad actual de los agentes de inteligencia artificial (IA) para generar cambios de código y la necesidad de ejecutar esos cambios dentro de un proceso de ingeniería de software controlable, auditable, recuperable y validado por evidencia.

La propuesta toma como base experimental el proyecto Symphony, en particular el repositorio `gaspardip/symphony`, y lo estudia como un marco integrador para orquestar agentes de software. El foco no está en desarrollar un nuevo agente de programación, sino en formalizar y validar una capa de control que convierta trabajo proveniente de *issues* en corridas aisladas por tarea, con políticas versionadas en el repositorio, *proof gates* —puntos de control basados en evidencia—, observabilidad operativa y recuperación ante fallas.

La validación se realizará mediante pruebas basales del software, escenarios reales reproducibles y métricas asociadas a trazabilidad, recuperabilidad, bloqueo correcto por gates, completitud de evidencia, observabilidad y diagnóstico operacional. El resultado esperado es un prototipo funcional o adaptación verificable sobre Symphony, una arquitectura documentada, una matriz de trazabilidad entre vacancias, requisitos y pruebas, y una evaluación técnica del enfoque propuesto.

---

## 4. Palabras clave

Agentes de software; ingeniería de software; delivery autónomo; integración continua; observabilidad; *proof gates*; *policy-as-code*; runtime; *issues*; Symphony.

---

## 5. Abstract

This thesis plan proposes the design, implementation, and validation of a runtime architecture for issue-based autonomous software delivery. The problem addressed is the gap between the current ability of artificial intelligence agents to generate code changes and the need to execute those changes within a software engineering process that is controllable, auditable, recoverable, and validated through evidence.

The proposal uses Symphony, particularly the `gaspardip/symphony` repository, as an experimental basis. The goal is not to build a new programming agent, but to formalize and validate a control layer that transforms issue-based work intake into isolated task executions with repository-versioned policies, proof gates, operational observability, and failure recovery mechanisms.

Validation will be performed through baseline software tests, reproducible real-world scenarios, and metrics related to traceability, recoverability, correct gate blocking, evidence completeness, observability, and operational diagnosis. The expected result is a functional prototype or verifiable adaptation over Symphony, a documented architecture, a traceability matrix connecting gaps, requirements, components, tests, and metrics, and a technical evaluation of the proposed approach.

---

## 6. Keywords

Software agents; software engineering; autonomous delivery; continuous integration; observability; proof gates; policy-as-code; runtime; issues; Symphony.

---

## 7. Introducción

El tema seleccionado se ubica en la intersección entre ingeniería de software, automatización del delivery, agentes de software, observabilidad operativa y validación de cambios sobre repositorios. En este documento, el término delivery se utiliza para referirse al proceso mediante el cual una tarea de software pasa desde su definición hasta una salida revisable o integrable, por ejemplo un *pull request* (PR), es decir, una solicitud de integración de cambios en un repositorio.

En los últimos años surgieron herramientas capaces de ejecutar tareas de programación en segundo plano a partir de *issues*, comentarios, prompts o tickets. Estas herramientas permiten delegar tareas de desarrollo a agentes de IA que pueden inspeccionar un repositorio, modificar código, ejecutar pruebas y proponer cambios mediante PRs. Sin embargo, el desafío central no es únicamente que el agente pueda generar código, sino que ese trabajo se ejecute dentro de un proceso de software controlable, auditable, recuperable y validado por evidencia.

GitHub Copilot cloud agent permite iniciar tareas de desarrollo desde GitHub Issues, GitHub Copilot Chat y otros puntos de entrada. Según la documentación oficial, el agente trabaja en un entorno impulsado por GitHub Actions, puede investigar el repositorio, crear un plan, modificar código en una rama y opcionalmente abrir un PR (GitHub Docs, 2026a). OpenHands, por su parte, ofrece una GitHub Action que puede activarse desde una issue con un label o comentario específico, intentando resolver la tarea y generando un PR para revisión (OpenHands Docs, 2026). Estos antecedentes muestran que el patrón “issue → ejecución automatizada → PR” ya existe y, por lo tanto, no constituye por sí mismo una contribución original.

La oportunidad de tesis se encuentra en otro punto: formalizar una capa de control que integre intake de trabajo, ejecución aislada por unidad de trabajo, políticas versionadas en el repositorio, *proof gates*, recuperación ante fallas y observabilidad operacional. En esta propuesta, un *proof gate* se define como un punto de control que exige evidencia verificable antes de permitir que una corrida avance en el flujo. Esa evidencia puede incluir pruebas automatizadas, checks de integración continua, actualización de artefactos de progreso, metadatos de funcionalidad o estado final de corrida.

La propuesta toma como base experimental el proyecto Symphony, particularmente el repositorio `gaspardip/symphony` (Dip, 2026a). Symphony se presenta como un motor de delivery autónomo donde el runtime es dueño del flujo operativo. En el proyecto se documentan componentes como un servicio de orquestación en Elixir/OTP —donde OTP significa *Open Telecom Platform*, conjunto de bibliotecas y patrones de Erlang/Elixir para construir sistemas concurrentes y tolerantes a fallas—, intake desde Linear y carga manual, webhooks de GitHub, workspaces aislados por issue, API JSON —interfaz de programación de aplicaciones que intercambia datos en formato JavaScript Object Notation—, métricas Prometheus y un harness versionado en el repositorio (Dip, 2026a, 2026b, 2026e, 2026f).

El objetivo de la tesis no es construir “otro agente que programa”, sino estudiar, formalizar y validar una arquitectura de runtime para delivery autónomo de software basado en *issues*, donde el runtime controle las invariantes operativas: elegibilidad de tareas, aislamiento, límites de ejecución, pruebas, evidencia, observabilidad, recuperación y handoff hacia revisión humana o integración continua.

El documento se organiza de acuerdo con la guía del Plan de Tesis - Proyecto Final Integrador. Primero se presenta el estado del arte, luego el problema detectado y las vacancias, la solución propuesta, la validación prevista, el plan de actividades, las referencias y los anexos.

---

## 8. Estado del Arte

El estado del arte se organiza en categorías que permiten conectar los antecedentes técnicos con las vacancias que fundamentan el problema. No se busca presentar una lista desordenada de herramientas, sino identificar qué capacidades ya existen, cuáles están parcialmente cubiertas y qué integración falta para el tipo de sistema propuesto.

### 8.1. Agentes de software basados en *issues* y flujo issue-to-PR

GitHub Copilot cloud agent representa un antecedente directo porque permite iniciar trabajo autónomo desde *issues* y otros puntos de entrada de GitHub. La documentación oficial indica que el agente puede trabajar en segundo plano, investigar el repositorio, crear un plan, modificar código y opcionalmente abrir un PR (GitHub Docs, 2026a). Este enfoque cubre una parte importante del ciclo issue-to-PR, pero se encuentra fuertemente integrado al control plane de GitHub y a su entorno de ejecución basado en GitHub Actions.

OpenHands GitHub Action es otro antecedente relevante. Su documentación indica que la acción puede dispararse desde una issue mediante el label `fix-me` o mediante un comentario que mencione al agente. Luego intenta resolver la issue, genera un PR y permite iterar mediante comentarios o revisiones (OpenHands Docs, 2026). Este caso demuestra que el modelo de automatización desde *issues* también existe en el ecosistema open source.

Estos sistemas prueban que la activación de agentes desde *issues* no es novedosa. La vacancia aparece cuando se requiere una arquitectura propia, auditable y autoalojable que conecte issue, workspace, runtime, políticas, gates, observabilidad, recuperación y handoff de manera explícita.

### 8.2. Orquestación y ejecución durable

LangGraph es un framework de orquestación de agentes que introduce conceptos relevantes para tareas largas y recuperables. Su documentación define la ejecución durable como la capacidad de guardar progreso en puntos clave para pausar y reanudar workflows, incluso ante interrupciones, errores o intervención humana (LangChain Docs, 2026a). También documenta mecanismos de *Human in the Loop* (HITL), donde ciertas acciones se pausan para que una persona apruebe, edite o rechace el paso propuesto (LangChain Docs, 2026b).

Estos antecedentes resuelven parcialmente el problema de persistencia, pausas e intervención humana. Sin embargo, no proveen por defecto una semántica específica para delivery de software basada en *issues*, workspaces por tarea, PRs, checks de integración continua, pruebas de repositorio, revisión y handoff. En consecuencia, sirven como referencia conceptual, pero no reemplazan la necesidad de una arquitectura especializada para el problema planteado.

### 8.3. *Policy-as-code* y validación por gates

Open Policy Agent (OPA) es un motor de políticas de propósito general que permite expresar reglas como código y desacoplar la decisión de política respecto del sistema que la ejecuta (Open Policy Agent, 2026). Este enfoque es relevante porque la tesis busca que las reglas del flujo no queden solamente en instrucciones informales, sino que puedan representarse como contratos verificables.

En el ámbito de repositorios, GitHub permite proteger ramas mediante reglas que exigen revisiones aprobatorias o checks exitosos antes de permitir un merge (GitHub Docs, 2026b). GitHub Actions, a su vez, permite definir workflows automatizados en archivos YAML versionados en el repositorio, incluyendo procesos de construcción, prueba y despliegue (GitHub Docs, 2026c). Estos mecanismos muestran que los gates y la automatización del pipeline ya son prácticas maduras en DevOps.

La diferencia del problema abordado es que, cuando un agente modifica código de manera autónoma, los gates no sólo deben validar el código final, sino también preservar trazabilidad del proceso: qué issue originó la corrida, qué workspace se usó, qué evidencia se produjo, por qué una corrida avanzó o se bloqueó y cómo puede diagnosticarse una falla.

### 8.4. Observabilidad operativa

La observabilidad es una condición necesaria para operar sistemas automatizados de larga duración. Prometheus, por ejemplo, se presenta como un sistema de monitoreo y base de datos de series temporales orientado a recolectar y consultar métricas de sistemas (Prometheus, 2026). En el contexto de agentes de software, la observabilidad no se limita a exponer métricas generales, sino que debe permitir reconstruir el estado de una corrida, los eventos relevantes, los resultados de validación y la razón por la cual una tarea avanzó, falló o quedó bloqueada.

Esta categoría es relevante para la tesis porque muchos sistemas issue-to-PR ofrecen logs o resultados finales, pero no necesariamente una vista operacional estructurada que vincule issue, workspace, estado, evidencia, gates y handoff.

### 8.5. *Harness engineering* y conocimiento versionado en el repositorio

El enfoque de *harness engineering* publicado por OpenAI propone tratar el conocimiento del repositorio como fuente de verdad estructurada, versionada y verificable. El artículo describe cómo un repositorio puede organizar documentación, planes, especificaciones, reglas de calidad y validaciones para que los agentes operen con mayor legibilidad y menor dependencia de instrucciones extensas o desactualizadas (Lopopolo, 2026).

Symphony se vincula con esta línea mediante artefactos como `WORKFLOW.md`, `.symphony/harness.yml`, documentación de conocimiento en `.symphony/knowledge` y validaciones asociadas al harness (Dip, 2026e, 2026f). Esta aproximación es relevante porque el control del sistema no se delega únicamente al prompt ni al proveedor del agente, sino que se desplaza hacia contratos versionados dentro del repositorio.

### 8.6. Symphony como antecedente directo

El proyecto upstream `openai/symphony` define Symphony como un servicio de automatización de larga duración que lee trabajo desde un issue tracker, crea un workspace aislado por issue y ejecuta una sesión de agente dentro de ese workspace (OpenAI, 2026a). La especificación indica que el sistema busca convertir la ejecución de *issues* en un workflow repetible, aislar agentes por issue, mantener políticas de workflow en el repositorio mediante `WORKFLOW.md` y proveer observabilidad suficiente para operar corridas concurrentes (OpenAI, 2026a).

La implementación Elixir upstream describe un flujo donde Symphony consulta Linear, crea un workspace por issue, lanza Codex en modo App Server dentro del workspace, envía un prompt de workflow y mantiene al agente trabajando hasta que la tarea se complete o llegue a un estado terminal (OpenAI, 2026b).

El fork `gaspardip/symphony` amplía este marco con documentación de arquitectura, producto, harness, observabilidad y planes de autopiloto (Dip, 2026a, 2026b, 2026c, 2026d, 2026e, 2026f). Por eso, en esta tesis Symphony se toma como base experimental y no como contribución terminada. La contribución de la tesis será formalizar el problema, derivar requisitos desde vacancias, adaptar o implementar componentes verificables y validar el modelo mediante casos de prueba reproducibles.

### 8.7. Síntesis del estado del arte y vacancias

A partir del estado del arte se observa que las piezas necesarias para el delivery autónomo de software existen de manera parcial y distribuida: agentes issue-driven, frameworks de orquestación, *policy-as-code*, integración continua, branch protection, harness engineering y observabilidad. La vacancia principal no es la inexistencia de estas piezas, sino su falta de integración en un modelo de runtime explícito para delivery autónomo basado en *issues*.

Las principales brechas detectadas son las siguientes:

1. **Ejecución issue-driven parcialmente resuelta:** herramientas como GitHub Copilot cloud agent y OpenHands permiten disparar trabajo desde *issues*, pero el control del proceso suele quedar acoplado a la plataforma o a una acción puntual.
2. **Aislamiento por tarea no siempre formalizado:** muchos sistemas ejecutan en entornos aislados o runners, pero no siempre convierten el workspace por issue en una invariante explícita, auditable y verificable.
3. **Policy-as-code desacoplado del runtime:** existen motores de política y checks de integración continua, pero suelen operar como capas separadas del agente y no como parte de una semántica completa de delivery autónomo.
4. **Proof gates limitados a CI:** los checks de integración continua validan parte del resultado, pero no necesariamente verifican evidencia de proceso, progreso, trazabilidad, metadatos o razón de bloqueo.
5. **Observabilidad insuficiente para corridas agentic:** los logs y métricas generales no siempre permiten reconstruir qué hizo el agente, por qué se bloqueó una corrida o qué evidencia quedó disponible.
6. **Recuperación ante fallas poco clara:** la reanudación de tareas largas existe en frameworks de orquestación, pero no siempre se conecta con tracker, filesystem, workspace, estado de corrida y handoff.
7. **Handoff poco formalizado:** muchos sistemas finalizan en un PR o comentario, pero no modelan estados intermedios como bloqueado, retry, proof-failed, review-ready o merged.

| Vacancia                          | Estado actual en herramientas existentes              | Oportunidad para la tesis                                                             |
| --------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Ejecución issue-driven            | Existe en GitHub Copilot cloud agent y OpenHands.     | Formalizar el runtime completo, no sólo la activación por issue.                      |
| Aislamiento por unidad de trabajo | Algunas herramientas usan runners o entornos propios. | Definir workspaces por issue como invariante verificable.                             |
| Policy-as-code                    | Existe en OPA y CI/CD.                                | Integrar políticas al runtime y al repositorio como contrato operacional.             |
| Proof gates                       | Existen checks de CI y branch protection.             | Ampliar la noción de prueba hacia evidencia de corrida, progreso, metadatos y estado. |
| Observabilidad                    | Existen logs, dashboards y métricas generales.        | Definir observabilidad específica para corridas agentic de delivery.                  |
| Recuperación ante fallas          | Existen frameworks de ejecución durable.              | Evaluar un modelo de recuperación basado en tracker, filesystem y estado de corrida.  |
| Handoff operacional               | Usualmente queda reducido a PR o revisión humana.     | Modelar estados explícitos de ejecución, bloqueo, revisión y cierre.                  |

**Tabla 2. Síntesis de vacancias del estado del arte.**
La tabla resume las principales brechas detectadas y su relación con oportunidades de desarrollo para la tesis.

---

## 9. Problema detectado y/o faltante

Los sistemas actuales de desarrollo asistido por agentes pueden generar cambios sobre un repositorio, pero presentan limitaciones para operar dentro de un proceso de software reproducible, auditable y recuperable.

El problema específico es la falta de una arquitectura de runtime que permita:

* recibir trabajo desde *issues* o mecanismos equivalentes;
* ejecutar una tarea en un workspace aislado;
* aplicar límites explícitos de concurrencia, reintentos y elegibilidad;
* validar avances mediante *proof gates*;
* registrar evidencia y estado de corrida;
* recuperar o diagnosticar fallas;
* exponer información suficiente para el operador humano;
* diferenciar claramente entre generación de código y validación del proceso.

En ausencia de esta capa de control, la autonomía del agente queda parcialmente gobernada por prompts, scripts ad hoc, intervención humana informal o restricciones del proveedor de plataforma. Esto limita la trazabilidad, dificulta la recuperación ante fallas y reduce la confianza en un proceso de delivery autónomo.

### 9.1. Caso basal representativo del problema

Una issue elegible ingresa al sistema. El runtime la selecciona, crea un workspace aislado, ejecuta el agente, registra el estado de corrida, aplica los gates definidos por el repositorio y bloquea o publica el resultado según la evidencia disponible. Si falla una prueba de integración continua, la corrida no avanza a handoff final y queda registrada la causa de bloqueo para revisión del operador.

Este caso sintetiza el problema: el valor no está únicamente en generar código, sino en que cada transición del flujo quede controlada, justificada y diagnosticable.

---

## 10. Solución propuesta

La solución preliminar consiste en un marco integrador —framework— de runtime que actúe como capa de control entre el intake de trabajo y la ejecución de agentes de software.

El runtime se organizará en los siguientes módulos conceptuales:

1. **Intake de trabajo:** recepción de tareas desde un tracker, carga manual o eventos de revisión.
2. **Contratos del repositorio:** definición versionada de reglas, políticas, instrucciones de ejecución y límites del flujo.
3. **Orchestrator / runtime state:** componente responsable de polling, scheduling, dispatch, concurrencia, retries, reconciliación y estado autoritativo de corridas.
4. **Workspace aislado por issue:** entorno de ejecución por unidad de trabajo, asociado a una issue o tarea.
5. **Agent bridge:** adaptador hacia el agente de código utilizado para ejecutar la tarea.
6. **Proof and verification gates:** validaciones que deben cumplirse antes de publicar o avanzar.
7. **Publish / review / merge flow:** etapas de publicación, PR, checks, revisión y eventual integración.
8. **Operator control plane:** superficie para visualizar estado, métricas, reportes, logs, razones de bloqueo y evidencia de corrida.

El `SPEC.md` de Symphony define al servicio como una automatización de larga duración que lee trabajo desde un issue tracker, crea un workspace aislado por issue y ejecuta una sesión de agente dentro de ese workspace (Dip, 2026b; OpenAI, 2026a). También define objetivos concretos: polling con concurrencia acotada, estado autoritativo del orquestador, workspaces determinísticos, stop de corridas cuando cambia la elegibilidad, recuperación ante fallas transitorias, carga del comportamiento desde `WORKFLOW.md`, observabilidad y recuperación tras reinicio sin requerir una base de datos persistente (Dip, 2026b; OpenAI, 2026a).

### 10.1. Objetivo general

Diseñar, implementar y validar una arquitectura preliminar de runtime para delivery autónomo de software basado en *issues*, con límites explícitos, aislamiento por unidad de trabajo, *proof gates* versionados en repositorio, observabilidad operacional y criterios de validación reproducibles.

### 10.2. Objetivos específicos

1. Analizar el estado del arte de agentes de software issue-driven, runtimes de agentes, orquestadores, *policy-as-code*, *proof gates* y observabilidad.
2. Identificar vacancias funcionales y no funcionales vinculadas a control, trazabilidad, recuperación y validación.
3. Derivar requisitos preliminares desde las vacancias detectadas.
4. Diseñar una arquitectura conceptual para un runtime de delivery autónomo basado en *issues*.
5. Implementar o adaptar un prototipo sobre Symphony para validar la arquitectura.
6. Definir pruebas basales del software y casos de prueba sobre escenarios reales.
7. Medir trazabilidad, recuperabilidad, bloqueo por gates, completitud de evidencia y capacidad de diagnóstico.
8. Documentar limitaciones, riesgos, decisiones de diseño y futuras líneas de trabajo.

### 10.3. Alcance

#### 10.3.1. Incluido

* Modelo de runtime basado en *issues*.
* Intake desde un tracker o carga manual.
* Workspaces aislados por tarea.
* Estado de corrida y razones de parada.
* *Proof gates* y validation gates.
* Observabilidad operacional.
* Recuperación básica o diagnóstico tras fallas.
* Casos de prueba reproducibles.
* Matriz de trazabilidad entre vacancias, requisitos, componentes, pruebas y métricas.

#### 10.3.2. Fuera de alcance

* Autonomía total sin revisión humana.
* Soporte completo de múltiples trackers.
* Soporte completo de múltiples proveedores de modelos.
* Garantía formal de corrección semántica del código generado.
* Scheduler distribuido generalista.
* Plataforma multi-tenant de producción.
* Evaluación comparativa de capacidad de modelos LLM como objetivo principal.

La tesis no medirá como objetivo central si el agente produce “mejor código” que otro agente. El foco será evaluar si el runtime mejora control, trazabilidad, recuperabilidad y validación del proceso.

### 10.4. Arquitectura conceptual propuesta

| Componente                    | Responsabilidad                                                           | Vacancia que atiende                            |
| ----------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------- |
| Intake de trabajo             | Recibir *issues*, carga manual o eventos de revisión.                     | Ejecución issue-driven incompleta.              |
| Contratos del repositorio     | Versionar reglas, políticas, instrucciones y criterios de validación.     | Policy-as-code desacoplado del runtime.         |
| Orchestrator / runtime state  | Controlar elegibilidad, dispatch, concurrencia, retries y reconciliación. | Recuperación ante fallas y control del proceso. |
| Workspace aislado por issue   | Separar ejecución, cambios, logs y estado por unidad de trabajo.          | Aislamiento poco formalizado.                   |
| Agent bridge                  | Desacoplar el runtime del agente concreto.                                | Dependencia del proveedor de agente.            |
| Proof and verification gates  | Bloquear avance sin evidencia suficiente.                                 | Proof gates limitados a CI.                     |
| Publish / review / merge flow | Modelar PR, revisión, checks, handoff e integración.                      | Handoff poco formalizado.                       |
| Operator control plane        | Exponer estado, métricas, reportes y razones de bloqueo.                  | Observabilidad insuficiente.                    |

**Tabla 3. Componentes de la arquitectura conceptual propuesta.**
La tabla describe los componentes generales de la solución, su responsabilidad y la vacancia del estado del arte que atienden.

### 10.5. Flujo operacional propuesto

| Paso              | Entrada                                     | Proceso                                                        | Salida                         |
| ----------------- | ------------------------------------------- | -------------------------------------------------------------- | ------------------------------ |
| 1. Intake         | Issue, carga manual o evento de revisión    | Registro de tarea candidata                                    | Tarea pendiente de evaluación  |
| 2. Elegibilidad   | Tarea candidata y contratos del repositorio | Evaluación de reglas, estado y límites                         | Tarea elegible o rechazada     |
| 3. Workspace      | Tarea elegible                              | Creación o recuperación de workspace aislado                   | Entorno de ejecución           |
| 4. Ejecución      | Workspace y agente                          | Generación de cambios, pruebas parciales y registro de eventos | Resultado de corrida           |
| 5. Gates          | Resultado de corrida                        | Validación de evidencia, pruebas y políticas                   | Aprobación o bloqueo           |
| 6. Handoff        | Resultado aprobado                          | Publicación, PR, revisión o integración                        | Estado final o etapa siguiente |
| 7. Observabilidad | Eventos y estados                           | Exposición de métricas, logs, reportes y razones de parada     | Diagnóstico operacional        |

**Tabla 4. Flujo operacional preliminar.**
La tabla reemplaza un diagrama complejo por una descripción paso a paso del flujo propuesto, indicando entradas, procesos y salidas.

### 10.6. Diferenciación entre Symphony existente y aporte de tesis

Para evitar que la tesis sea interpretada como una simple descripción o uso de un fork existente, se explicita la diferencia entre base experimental y contribución académica/técnica.

| Elemento                                    | Existe en Symphony | Se implementa/adapta en la tesis | Se valida en la tesis |
| ------------------------------------------- | -----------------: | -------------------------------: | --------------------: |
| Intake desde tracker o carga manual         |                 Sí |                               Sí |                    Sí |
| Workspace por issue                         |                 Sí |                               Sí |                    Sí |
| Estado de corrida                           |         Sí/parcial |                     Se formaliza |                    Sí |
| Proof gates / harness                       |         Sí/parcial |           Se categoriza y prueba |                    Sí |
| Observabilidad operativa                    |         Sí/parcial |            Se ordena como modelo |                    Sí |
| Matriz vacancia → requisito → prueba        |                 No |                               Sí |                    Sí |
| Criterios de aceptación cuantitativos       |                 No |                               Sí |                    Sí |
| Evaluación reproducible del runtime         |                 No |                               Sí |                    Sí |
| Comparación sistemática con estado del arte |                 No |                               Sí |                    Sí |
| Análisis de riesgos y permisos              |            Parcial |                               Sí |            Sí/parcial |

**Tabla 5. Diferenciación entre Symphony existente y aporte de tesis.**
La tabla separa los elementos ya presentes en Symphony de los aspectos que serán formalizados, adaptados o validados como aporte de la tesis.

La tesis no pretende atribuir como novedosos los componentes ya presentes en Symphony o en otros sistemas. El aporte se ubica en la formalización del problema, la derivación de requisitos, la arquitectura de integración, la validación mediante pruebas reproducibles y el análisis crítico de vacancias.

### 10.7. Requisitos preliminares

Los requisitos se derivan de las vacancias identificadas en el estado del arte. Se distinguen requisitos funcionales y no funcionales, tomando como referencia general las prácticas de especificación de requisitos de software. IEEE 830-1998 fue una referencia histórica para especificaciones de requisitos, reemplazada posteriormente por ISO/IEC/IEEE 29148 (IEEE Standards Association, 1998; ISO, 2018).

#### 10.7.1. Requisitos funcionales

| Código | Requisito funcional                                                                          |
| ------ | -------------------------------------------------------------------------------------------- |
| RF-01  | El sistema debe aceptar tareas desde *issues* o carga manual.                                |
| RF-02  | El sistema debe evaluar elegibilidad antes de despachar una tarea.                           |
| RF-03  | El sistema debe crear o reutilizar un workspace aislado por issue.                           |
| RF-04  | El sistema debe mantener estado de corrida por tarea.                                        |
| RF-05  | El sistema debe ejecutar *proof gates* antes de permitir publicación o handoff.              |
| RF-06  | El sistema debe registrar razón de parada, bloqueo o finalización.                           |
| RF-07  | El sistema debe permitir diagnóstico mediante API, dashboard, logs o artefactos persistidos. |
| RF-08  | El sistema debe manejar fallas transitorias mediante reintentos acotados.                    |
| RF-09  | El sistema debe exponer métricas mínimas de operación.                                       |
| RF-10  | El sistema debe separar la lógica del runtime de la lógica del agente concreto.              |

**Tabla 6. Requisitos funcionales preliminares.**
La tabla enumera las funciones principales que debe cumplir el prototipo o adaptación propuesta.

#### 10.7.2. Requisitos no funcionales

| Código | Requisito no funcional                                                                      |
| ------ | ------------------------------------------------------------------------------------------- |
| RNF-01 | El flujo debe ser trazable desde issue hasta handoff o bloqueo.                             |
| RNF-02 | La evidencia mínima de cada corrida debe quedar persistida.                                 |
| RNF-03 | Los límites de concurrencia y retry deben ser explícitos.                                   |
| RNF-04 | Las políticas y contratos deben ser versionables en el repositorio.                         |
| RNF-05 | El sistema debe permitir recuperación o diagnóstico luego de interrupciones.                |
| RNF-06 | El prototipo debe poder ejecutarse en un entorno controlado y reproducible.                 |
| RNF-07 | El sistema debe minimizar el acceso del agente a credenciales y recursos innecesarios.      |
| RNF-08 | La validación debe ser independiente de la calidad absoluta del código generado por el LLM. |

**Tabla 7. Requisitos no funcionales preliminares.**
La tabla define propiedades de calidad, operación y seguridad esperadas para el sistema propuesto.

### 10.8. Tecnologías previstas

#### 10.8.1. Tecnologías de implementación

| Tecnología                 | Uso previsto                   | Justificación                                                                                                                                                            |
| -------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Elixir/OTP                 | Servicio de orquestación       | Symphony ya posee implementación basada en Elixir/OTP y este ecosistema es adecuado para procesos concurrentes y supervisados (Dip, 2026a; OpenAI, 2026b; Elixir, 2026). |
| Phoenix / Phoenix LiveView | Dashboard o superficie web     | Permite construir interfaces web con estado del lado servidor y actualización en tiempo real (Phoenix Framework, 2026).                                                  |
| JSON API                   | Consulta de estado y reportes  | Permite exponer estado de runtime de manera estructurada y consumible por dashboard o scripts.                                                                           |
| Prometheus                 | Métricas operativas            | Prometheus recolecta métricas como series temporales y es adecuado para observabilidad de sistemas (Prometheus, 2026).                                                   |
| Git / GitHub               | Repositorio, ramas y PRs       | El flujo de software a validar se apoya en repositorios y PRs.                                                                                                           |
| GitHub Actions             | Checks de integración continua | Permite workflows versionados en YAML dentro del repositorio (GitHub Docs, 2026c).                                                                                       |
| Linear                     | Tracker inicial                | Es el tracker contemplado por la especificación actual de Symphony (Dip, 2026b; OpenAI, 2026a).                                                                          |
| Codex App Server           | Agente de código inicial       | El App Server provee una API para integrar clientes con Codex (Chen, 2026).                                                                                              |
| Markdown / YAML            | Contratos versionados          | Permiten definir documentación, workflow y harness como archivos legibles y versionados.                                                                                 |

**Tabla 8. Tecnologías previstas para implementación.**
La tabla resume las tecnologías consideradas para el prototipo y su justificación.

#### 10.8.2. Tecnologías de validación

* Tests unitarios sobre componentes del runtime.
* Tests de integración sobre orquestador, workspace y gates.
* Scripts de preflight, validación, smoke test y post-merge.
* Integración continua con checks requeridos.
* Métricas y estado de corrida persistido.
* Fixtures de *issues* y escenarios reproducibles.

---

## 11. Experimentación y/o validación

La validación se enfocará en el runtime y el proceso, no en la calidad absoluta del código generado por el agente. El alcance de la validación será: control de ejecución, trazabilidad, aislamiento, gates, recuperación, observabilidad y diagnóstico.

### 11.1. Validación conceptual

Se verificará que la arquitectura propuesta responda a las vacancias detectadas en el estado del arte.

Criterios:

* cada componente debe cubrir una vacancia identificada;
* cada vacancia debe derivar en al menos un requisito;
* cada requisito relevante debe tener al menos un caso de prueba;
* las métricas deben evaluar propiedades del runtime y no sólo resultados del agente.

### 11.2. Matriz de trazabilidad

| Vacancia                            | Requisito derivado  | Componente de la solución         | Caso de prueba                          | Métrica                                          |
| ----------------------------------- | ------------------- | --------------------------------- | --------------------------------------- | ------------------------------------------------ |
| Ejecución issue-driven incompleta   | RF-01, RF-02        | Intake + Orchestrator             | Happy path                              | Tasa de corridas completadas                     |
| Aislamiento poco formalizado        | RF-03, RNF-06       | Workspace aislado                 | Creación de workspace                   | 100% de workspaces por issue válida              |
| Policy-as-code desacoplado          | RF-05, RNF-04       | Contratos del repositorio + gates | Bloqueo por policy                      | Tasa de bloqueos correctos                       |
| Proof gates limitados a CI          | RF-05, RF-06        | Proof & Verification Gates        | Falla de evidencia                      | 100% de inválidos bloqueados                     |
| Observabilidad insuficiente         | RF-04, RF-07, RF-09 | Operator Control Plane            | Diagnóstico operacional                 | Completitud de evidencia y tiempo de diagnóstico |
| Recuperación ante fallas poco clara | RF-08, RNF-05       | Orchestrator / Runtime State      | Crash y recuperación                    | Porcentaje de recuperaciones correctas           |
| Handoff no formalizado              | RF-06, RNF-01       | Publish / Review / Merge Flow     | Handoff a revisión                      | Trazabilidad issue → PR/revisión                 |
| Dependencia del proveedor de agente | RF-10               | Agent Bridge                      | Ejecución con stub o bridge alternativo | Separación runtime/agente demostrada             |
| Riesgo por permisos o secretos      | RNF-07              | Seguridad y hardening             | Intento fuera de alcance                | Acceso bloqueado o documentado                   |

**Tabla 9. Matriz de trazabilidad entre vacancias, requisitos, componentes, pruebas y métricas.**
La tabla conecta el estado del arte con la solución y la validación, permitiendo verificar que cada prueba responde a una vacancia identificada.

### 11.3. Pruebas basales del software

| Caso  | Descripción                     | Resultado esperado                                      |
| ----- | ------------------------------- | ------------------------------------------------------- |
| PB-01 | Carga de `WORKFLOW.md` válido   | El runtime carga configuración e instrucciones.         |
| PB-02 | Carga de `WORKFLOW.md` inválido | El runtime expone error de configuración.               |
| PB-03 | Creación de workspace           | Se crea workspace aislado para una issue elegible.      |
| PB-04 | Control de concurrencia         | No se despachan más corridas que el máximo configurado. |
| PB-05 | Persistencia de estado          | La corrida deja etapa, estado y razón final.            |
| PB-06 | Validación de harness           | Se detecta ausencia de artefactos requeridos.           |
| PB-07 | Exposición de observabilidad    | El runtime expone estado, métricas o reportes.          |
| PB-08 | Retry controlado                | Una falla transitoria genera reintento acotado.         |

**Tabla 10. Pruebas basales del software.**
La tabla define pruebas técnicas mínimas para verificar el comportamiento del prototipo.

### 11.4. Casos de prueba sobre escenarios reales

| Caso  | Escenario                                                                                                  | Resultado esperado                                                                    |
| ----- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| CR-01 | Una issue simple es tomada por el runtime, se crea workspace, se ejecuta el agente y se validan los gates. | Corrida exitosa con evidencia completa.                                               |
| CR-02 | Una issue cambia de estado mientras está en ejecución o deja de cumplir criterios de elegibilidad.         | El runtime detecta el cambio, detiene o libera la corrida y registra razón de parada. |
| CR-03 | El agente o una dependencia falla temporalmente.                                                           | El runtime aplica retry con backoff y evita duplicar dispatch.                        |
| CR-04 | El agente modifica código, pero no actualiza progreso, evidencia o metadatos requeridos.                   | El gate bloquea el avance y registra la causa.                                        |
| CR-05 | El cambio genera un PR o pre-PR, pero falla un check requerido.                                            | El sistema no avanza hacia merge y deja evidencia del fallo.                          |
| CR-06 | Se interrumpe el proceso del runtime durante una corrida.                                                  | Al reiniciar, el sistema reconstruye el estado suficiente y evita duplicar trabajo.   |
| CR-07 | Se entrega al evaluador una corrida fallida y se debe reconstruir qué ocurrió.                             | Se puede diagnosticar usando dashboard, API, métricas, logs y `run_state`.            |

**Tabla 11. Casos de prueba sobre escenarios reales.**
La tabla presenta escenarios representativos para validar la solución en condiciones cercanas al uso esperado.

### 11.5. Criterios de aceptación cuantitativos

| Métrica                        | Criterio de aceptación preliminar                                                                      |
| ------------------------------ | ------------------------------------------------------------------------------------------------------ |
| Duplicación de dispatch        | 0 duplicaciones incorrectas en los casos de prueba definidos.                                          |
| Completitud de evidencia       | 100% de corridas con estado final, razón de parada y evidencia mínima.                                 |
| Recuperación tras falla        | Al menos 80% de escenarios de interrupción recuperados o diagnosticados correctamente.                 |
| Bloqueo por proof gate         | 100% de casos inválidos bloqueados antes de publish/handoff.                                           |
| Diagnóstico operacional        | Reconstruir una corrida fallida usando artefactos del sistema sin inspección manual del código fuente. |
| Trazabilidad issue → resultado | 100% de casos reales con vínculo entre issue, workspace, corrida y resultado final.                    |
| Control de concurrencia        | 0 violaciones del límite configurado durante pruebas.                                                  |
| Exposición de métricas         | Métricas disponibles en 100% de corridas ejecutadas durante la validación.                             |

**Tabla 12. Criterios de aceptación cuantitativos.**
La tabla define umbrales preliminares para considerar satisfecha la validación del prototipo.

---

## 12. Plan de actividades

Se utilizará una metodología iterativa e incremental, organizada en ciclos de análisis, diseño, implementación y validación. La validación seguirá un enfoque de investigación aplicada: primero se derivarán requisitos desde las vacancias del estado del arte, luego se implementará o adaptará el prototipo y finalmente se ejecutarán pruebas basales y escenarios reales reproducibles.

### 12.1. Metodología de trabajo

1. **Relevamiento y estado del arte:** análisis de herramientas, frameworks, especificaciones y documentación técnica.
2. **Síntesis de vacancias:** identificación de brechas funcionales y no funcionales.
3. **Derivación de requisitos:** formulación de requisitos funcionales y no funcionales a partir de vacancias.
4. **Diseño de arquitectura:** definición de componentes, flujos y responsabilidades.
5. **Implementación/adaptación del prototipo:** desarrollo incremental sobre Symphony.
6. **Pruebas basales:** validación de componentes individuales.
7. **Casos reales reproducibles:** ejecución de escenarios representativos.
8. **Medición y discusión:** análisis de métricas, límites y resultados.
9. **Documentación final:** consolidación de tesis, anexos, demos y video.

### 12.2. Entregables e hitos

| Etapa                  | Actividades                                          | Entregables                                   |
| ---------------------- | ---------------------------------------------------- | --------------------------------------------- |
| 1. Definición del tema | Ajuste de título, problema y alcance                 | Propuesta preliminar                          |
| 2. Estado del arte     | Relevamiento de herramientas, papers y documentación | Tabla comparativa y síntesis de vacancias     |
| 3. Requisitos          | Derivación de RF/RNF desde vacancias                 | ERS preliminar y matriz de trazabilidad       |
| 4. Diseño              | Arquitectura, flujos y componentes                   | Documento de diseño                           |
| 5. Implementación      | Adaptación o desarrollo del prototipo                | Código, configuración y documentación técnica |
| 6. Pruebas basales     | Tests unitarios e integración                        | Reporte de pruebas basales                    |
| 7. Casos reales        | Ejecución de escenarios representativos              | Reporte de validación                         |
| 8. Discusión           | Análisis de métricas, límites y riesgos              | Resultados y discusión                        |
| 9. Cierre              | Redacción final, anexos, video y presentación        | Documento final de tesis                      |

**Tabla 13. Plan de actividades, entregables e hitos.**
La tabla presenta las etapas principales del trabajo y los entregables esperados.

### 12.3. Cronograma tentativo

| Fase                          | Duración estimada | Actividades principales                                      |
| ----------------------------- | ----------------: | ------------------------------------------------------------ |
| Definición del tema y alcance |     2 a 3 semanas | Ajuste de problema, título, objetivos y alcance.             |
| Estado del arte               |     4 a 6 semanas | Relevamiento, análisis comparativo y síntesis de vacancias.  |
| Requisitos y arquitectura     |     3 a 4 semanas | ERS preliminar, matriz de trazabilidad y diseño conceptual.  |
| Implementación/adaptación     |     6 a 8 semanas | Desarrollo o adaptación del prototipo sobre Symphony.        |
| Pruebas basales               |     3 a 4 semanas | Tests unitarios, integración y validación técnica.           |
| Casos reales y métricas       |     4 a 5 semanas | Ejecución de escenarios reproducibles y medición.            |
| Discusión y cierre            |         4 semanas | Análisis de resultados, conclusiones, anexos y presentación. |

**Tabla 14. Cronograma tentativo.**
La tabla resume tiempos estimados por fase. Las fechas concretas deberán ajustarse al calendario formal de la cátedra.

### 12.4. Gestión de alcance

El alcance se controlará mediante la matriz de trazabilidad. Sólo se considerarán obligatorios los componentes vinculados a vacancias principales y casos de prueba definidos. Las extensiones como soporte multi-provider, multi-tracker o hardening avanzado quedarán como trabajo futuro salvo que resulten indispensables para la validación.

### 12.5. Gestión de tiempos y estimaciones

La planificación se realizará por etapas, con entregables parciales revisables. Cada fase deberá producir evidencia documentada: notas de análisis, tablas comparativas, requisitos, diseño, pruebas, resultados o conclusiones parciales. El avance se controlará mediante revisión periódica con el director de tesis.

### 12.6. Gestión de riesgos

| Riesgo                                | Impacto | Probabilidad | Mitigación                                                             |
| ------------------------------------- | ------: | -----------: | ---------------------------------------------------------------------- |
| Cambios en APIs externas              |   Medio |        Media | Mantener modo de carga manual y fixtures.                              |
| Dependencia de proveedor de agente    |    Alto |        Media | Evaluar el runtime con tareas simuladas o agente stub.                 |
| CI inestable                          |   Medio |        Media | Definir checks locales reproducibles.                                  |
| Scope demasiado amplio                |    Alto |        Media | Acotar a un tracker, un repositorio y un proveedor inicial.            |
| Resultados variables del agente       |    Alto |         Alta | No medir calidad absoluta del código como objetivo principal.          |
| Gráficos poco legibles en exportación |    Bajo |        Media | Mantener diagramas simples, tablas y documentación versionada.         |
| Ambigüedad entre fork y aporte        |    Alto |        Media | Mantener tabla de diferenciación Symphony existente vs aporte tesis.   |
| Manejo inseguro de secretos           |    Alto |        Media | Minimizar credenciales, documentar permisos y usar entorno controlado. |
| Falta de datos reales                 |   Medio |         Baja | Diseñar escenarios reproducibles con issues de prueba.                 |

**Tabla 15. Matriz de riesgos.**
La tabla identifica riesgos previsibles, su impacto, probabilidad y estrategia de mitigación.

### 12.7. Gestión de calidad

La calidad se verificará mediante:

* pruebas automatizadas;
* criterios de aceptación cuantitativos;
* documentación técnica en Markdown;
* revisión periódica con director;
* trazabilidad entre requisito y prueba;
* registro de decisiones de diseño;
* separación entre código, documentación, resultados y anexos.

### 12.8. Reuniones y seguimiento

Se prevé realizar reuniones periódicas con el director o tutor para revisar:

* avance del estado del arte;
* definición del problema;
* alcance;
* arquitectura;
* implementación;
* resultados de pruebas;
* riesgos;
* documentación final.

Las minutas de reunión podrán versionarse en el repositorio de documentación de tesis.

### 12.9. Documentación

La documentación se organizará en Markdown dentro del repositorio, separando propuesta, estado del arte, problema, solución, validación, gestión y anexos. Esto permitirá trazabilidad entre comentarios del profesor, cambios de diseño, implementación y resultados.

### 12.10. Disponibilidad de datos, infraestructura, servidumbres y dependencias

#### Datos

No se requieren datasets masivos. La validación puede realizarse con:

* repositorios de prueba;
* *issues* diseñadas para escenarios específicos;
* fixtures de tracker;
* corridas controladas;
* evidencia generada por el propio runtime.

#### Infraestructura

Se requerirá:

* entorno local de desarrollo;
* repositorio Git;
* ejecución de tests;
* integración con GitHub Actions o equivalente;
* runtime Elixir/OTP;
* almacenamiento de workspaces;
* métricas y logs locales;
* eventualmente contenedores para aislar ejecución.

#### Servidumbres y dependencias

| Dependencia      | Riesgo                     | Alternativa                                              |
| ---------------- | -------------------------- | -------------------------------------------------------- |
| Linear           | API externa o credenciales | Carga manual o fixtures de issues                        |
| GitHub           | Disponibilidad de PR/CI    | Repositorio local con scripts de validación              |
| Codex App Server | Proveedor específico       | Agente stub o bridge alternativo para pruebas de runtime |
| GitHub Actions   | CI externa                 | Tests locales reproducibles                              |
| Prometheus       | Métricas externas          | Exportación básica de métricas o logs estructurados      |

**Tabla 16. Servidumbres y dependencias.**
La tabla resume dependencias externas relevantes y alternativas para mitigar riesgos durante la validación.

### 12.11. Seguridad, permisos y secretos

Como el sistema ejecuta agentes que pueden modificar repositorios, la tesis debe considerar explícitamente seguridad, permisos y secretos.

Principios de seguridad:

* El agente no debe recibir más permisos de los necesarios.
* Las credenciales deben estar separadas del repositorio.
* El acceso a APIs externas debe estar limitado al alcance de prueba.
* El workspace debe estar acotado por tarea.
* Los logs no deben exponer secretos.
* Los casos de prueba deben incluir al menos un escenario de intento fuera de alcance.

El prototipo no buscará resolver seguridad de producción completa. Sin embargo, documentará qué credenciales se requieren, qué permisos tiene el agente, qué rutas del filesystem puede modificar, cómo se limita la ejecución y qué riesgos quedan como trabajo futuro.

Como línea futura se propone evaluar hardening mediante contenedores, sandboxing, restricciones de red, credenciales de menor privilegio y políticas explícitas por tipo de tarea.

### 12.12. Resultados esperados

Se espera obtener:

1. Un estado del arte comparativo sobre agentes issue-driven, runtimes, *policy-as-code*, *proof gates* y observabilidad.
2. Una síntesis de vacancias funcionales y no funcionales.
3. Una arquitectura conceptual de runtime para delivery autónomo basado en *issues*.
4. Un prototipo funcional o adaptación verificable sobre Symphony.
5. Una matriz de trazabilidad vacancia → requisito → componente → prueba → métrica.
6. Un conjunto de pruebas basales del software.
7. Un conjunto de casos de prueba sobre escenarios reales reproducibles.
8. Un análisis de resultados, límites y riesgos.
9. Documentación técnica versionada en el repositorio.

---

## 13. Referencias

Chen, C. (2026). *Unlocking the Codex harness: How we built the App Server*. OpenAI. Recuperado el 8 de mayo de 2026, de [https://openai.com/index/unlocking-the-codex-harness/](https://openai.com/index/unlocking-the-codex-harness/)

Dip, G. (2026a). *gaspardip/symphony* [Repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/gaspardip/symphony](https://github.com/gaspardip/symphony)

Dip, G. (2026b). *SPEC.md* [Archivo en repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/gaspardip/symphony/blob/main/SPEC.md](https://github.com/gaspardip/symphony/blob/main/SPEC.md)

Dip, G. (2026c). *architecture.md* [Archivo en repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/gaspardip/symphony/blob/main/.symphony/knowledge/architecture.md](https://github.com/gaspardip/symphony/blob/main/.symphony/knowledge/architecture.md)

Dip, G. (2026d). *product.md* [Archivo en repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/gaspardip/symphony/blob/main/.symphony/knowledge/product.md](https://github.com/gaspardip/symphony/blob/main/.symphony/knowledge/product.md)

Dip, G. (2026e). *AGENT_HARNESS.md* [Archivo en repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/gaspardip/symphony/blob/main/docs/AGENT_HARNESS.md](https://github.com/gaspardip/symphony/blob/main/docs/AGENT_HARNESS.md)

Dip, G. (2026f). *harness.yml* [Archivo en repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/gaspardip/symphony/blob/main/.symphony/harness.yml](https://github.com/gaspardip/symphony/blob/main/.symphony/harness.yml)

Elixir. (2026). *Elixir documentation*. Recuperado el 8 de mayo de 2026, de [https://elixir-lang.org/docs.html](https://elixir-lang.org/docs.html)

GitHub Docs. (2026a). *About GitHub Copilot cloud agent*. Recuperado el 8 de mayo de 2026, de [https://docs.github.com/copilot/concepts/about-copilot-coding-agent](https://docs.github.com/copilot/concepts/about-copilot-coding-agent)

GitHub Docs. (2026b). *About protected branches*. Recuperado el 8 de mayo de 2026, de [https://docs.github.com/articles/about-protected-branches](https://docs.github.com/articles/about-protected-branches)

GitHub Docs. (2026c). *GitHub Actions documentation*. Recuperado el 8 de mayo de 2026, de [https://docs.github.com/en/actions](https://docs.github.com/en/actions)

IEEE Standards Association. (1998). *IEEE 830-1998: IEEE recommended practice for software requirements specifications*. Recuperado el 8 de mayo de 2026, de [https://standards.ieee.org/standard/830-1998.html](https://standards.ieee.org/standard/830-1998.html)

ISO. (2018). *ISO/IEC/IEEE 29148:2018 Systems and software engineering — Life cycle processes — Requirements engineering*. Recuperado el 8 de mayo de 2026, de [https://www.iso.org/standard/72089.html](https://www.iso.org/standard/72089.html)

LangChain Docs. (2026a). *LangGraph durable execution*. Recuperado el 8 de mayo de 2026, de [https://docs.langchain.com/oss/python/langgraph/durable-execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)

LangChain Docs. (2026b). *Human-in-the-loop*. Recuperado el 8 de mayo de 2026, de [https://docs.langchain.com/oss/python/langchain/human-in-the-loop](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)

Lopopolo, R. (2026). *Harness engineering: Leveraging Codex in an agent-first world*. OpenAI. Recuperado el 8 de mayo de 2026, de [https://openai.com/index/harness-engineering/](https://openai.com/index/harness-engineering/)

Open Policy Agent. (2026). *Open Policy Agent documentation*. Recuperado el 8 de mayo de 2026, de [https://www.openpolicyagent.org/docs](https://www.openpolicyagent.org/docs)

OpenAI. (2026a). *Symphony service specification* [Archivo en repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/openai/symphony/blob/main/SPEC.md](https://github.com/openai/symphony/blob/main/SPEC.md)

OpenAI. (2026b). *Symphony Elixir* [Archivo en repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/openai/symphony/blob/main/elixir/README.md](https://github.com/openai/symphony/blob/main/elixir/README.md)

OpenHands Docs. (2026). *OpenHands GitHub Action*. Recuperado el 8 de mayo de 2026, de [https://docs.openhands.dev/openhands/usage/how-to/github-action](https://docs.openhands.dev/openhands/usage/how-to/github-action)

Phoenix Framework. (2026). *Phoenix LiveView* [Repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/phoenixframework/phoenix_live_view](https://github.com/phoenixframework/phoenix_live_view)

Prometheus. (2026). *Overview*. Recuperado el 8 de mayo de 2026, de [https://prometheus.io/docs/introduction/overview/](https://prometheus.io/docs/introduction/overview/)

---

## 14. Anexos

### Anexo A. Glosario de siglas y términos

| Término o sigla | Definición                                                                                                                                               |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IA              | Inteligencia Artificial.                                                                                                                                 |
| LLM             | Modelo de lenguaje de gran escala. Se mantiene la sigla por su uso extendido en la literatura técnica.                                                   |
| Issue           | Tarea o ticket de trabajo registrado en un sistema de seguimiento.                                                                                       |
| PR              | *Pull Request*: solicitud de integración de cambios en un repositorio.                                                                                   |
| CI              | Integración continua. Proceso automatizado de construcción, pruebas y validación de cambios.                                                             |
| CD              | Entrega o despliegue continuo, según el contexto.                                                                                                        |
| API             | Interfaz de programación de aplicaciones.                                                                                                                |
| JSON            | Formato de intercambio de datos basado en JavaScript Object Notation.                                                                                    |
| YAML            | Formato legible de serialización usado frecuentemente para configuración.                                                                                |
| OTP             | Open Telecom Platform, conjunto de bibliotecas y patrones del ecosistema Erlang/Elixir.                                                                  |
| HITL            | Human in the Loop: intervención humana dentro de un proceso automatizado.                                                                                |
| Runtime         | Capa de ejecución y coordinación responsable de controlar el flujo operativo.                                                                            |
| Runtime-owned   | Enfoque en el cual el runtime controla las invariantes del proceso, en lugar de depender sólo de prompts o supervisión humana informal.                  |
| Proof gate      | Punto de control que exige evidencia verificable antes de avanzar.                                                                                       |
| Policy-as-code  | Definición de políticas como artefactos versionados, verificables y ejecutables.                                                                         |
| Harness         | Conjunto de herramientas, contratos, documentación, validadores y procesos que permiten operar agentes de manera más confiable dentro de un repositorio. |
| Handoff         | Estado de transferencia hacia revisión humana, PR, integración continua u otra etapa definida por el workflow.                                           |
| ERS             | Especificación de Requisitos de Software.                                                                                                                |

**Tabla 17. Glosario de siglas y términos.**
La tabla concentra definiciones para consulta rápida. En el documento, las siglas principales se explican también en su primera aparición.

### Anexo B. Bibliografía complementaria

All Hands AI. (2026). *openhands-github-action* [Repositorio GitHub]. GitHub. Recuperado el 8 de mayo de 2026, de [https://github.com/All-Hands-AI/openhands-github-action](https://github.com/All-Hands-AI/openhands-github-action)

GitHub Docs. (2026d). *Managing cloud agents*. Recuperado el 8 de mayo de 2026, de [https://docs.github.com/en/copilot/how-tos/use-copilot-agents/manage-agents](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/manage-agents)

GitHub Docs. (2026e). *Starting GitHub Copilot sessions*. Recuperado el 8 de mayo de 2026, de [https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/start-copilot-sessions](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/start-copilot-sessions)

LangChain Docs. (2026c). *LangGraph documentation*. Recuperado el 8 de mayo de 2026, de [https://docs.langchain.com/oss/python/langgraph/](https://docs.langchain.com/oss/python/langgraph/)

OpenAI. (2026c). *An open-source spec for Codex orchestration: Symphony*. Recuperado el 8 de mayo de 2026, de [https://openai.com/index/open-source-codex-orchestration-symphony/](https://openai.com/index/open-source-codex-orchestration-symphony/)

OpenAI Developers. (2026). *OpenAI developers documentation*. Recuperado el 8 de mayo de 2026, de [https://developers.openai.com/](https://developers.openai.com/)

### Anexo C. Organización propuesta del repositorio de tesis

Se propone mantener la documentación de tesis dentro del fork de Symphony, en una carpeta separada, para facilitar trazabilidad entre investigación, diseño, implementación y validación.

```text
tesis/
  README.md
  propuesta/
    plan.md
    resumen.md
  estado-del-arte/
    taxonomia.md
    matriz-comparativa.md
    referencias.md
  problema/
    vacancias.md
    requisitos.md
    matriz-trazabilidad.md
  solucion/
    arquitectura.md
    tecnologias.md
  validacion/
    pruebas-basales.md
    casos-reales.md
    metricas.md
    resultados.md
  gestion/
    cronograma.md
    riesgos.md
    reuniones.md
  anexos/
    glosario.md
    exportacion.md
```

Esta organización permite versionar cambios, vincular documentación con código, revisar avances desde GitHub y exportar el contenido a PDF o DOCX con herramientas como Pandoc, Quarto u otros conversores de Markdown.

### Anexo D. Formato sugerido para exportación

Para adaptar el documento a la guía de Blackboard se recomienda:

* hoja A4;
* fuente Times New Roman 11 para cuerpo de texto;
* fuente 14 para títulos intermedios;
* fuente 16 para títulos principales;
* interlineado 1,5;
* encabezado con el nombre del trabajo;
* pie de página con apellidos de integrantes y número de página;
* tablas numeradas con título y breve descripción;
* carátula y acta según modelos de la cátedra;
* conversión a DOCX/PDF para entrega formal.

### Anexo E. Cierre preliminar

La propuesta se orienta a estudiar y construir una arquitectura de runtime para delivery autónomo de software donde el foco no está en reemplazar al desarrollador ni en demostrar que un agente escribe mejor código, sino en controlar el proceso mediante límites explícitos, aislamiento, *proof gates*, políticas versionadas y observabilidad.

El aporte esperado es una solución acotada, verificable y alineada con una tesina de grado: un prototipo funcional, una formalización de arquitectura, una matriz de trazabilidad, criterios de aceptación cuantitativos y una evaluación sobre escenarios reproducibles.
