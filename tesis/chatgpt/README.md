# Workflow de tesis con ChatGPT Pro

Este directorio define cómo usar ChatGPT Pro como herramienta de revisión y redacción sin perder trazabilidad en Git.

## Regla principal

El repositorio es la fuente de verdad. ChatGPT Pro puede proponer redacción, reordenamientos, comparativas, tablas o mejoras académicas, pero todo cambio aceptado debe volver a los archivos versionados en `tesis/`.

## Proyecto sugerido en ChatGPT

Mantener un proyecto llamado `Tesis` con estos documentos fuente:

1. `tesis/propuesta/plan.md`
2. guía de Blackboard del Plan de Tesis - Proyecto Final Integrador
3. devoluciones del profesor
4. `tesis/chatgpt/contexto-base.md`
5. documentos exportados anteriores, sólo como referencia histórica

No usar el historial del chat como fuente única. Si ChatGPT produce una versión útil, copiarla al repo y commitearla.

## Flujo recomendado

1. Actualizar primero los archivos del repo.
2. Subir a ChatGPT Pro el archivo fuente actual y la devolución del profesor.
3. Pedir una salida concreta: Markdown completo, sección puntual o tabla comparativa.
4. Revisar que no invente datos personales, referencias o capacidades de Symphony.
5. Traer el resultado al repo.
6. Regenerar DOCX/PDF desde el Markdown.
7. Commit con una descripción clara del cambio.

## Prompt base

```text
Actuá como editor académico senior para una tesis de Ingeniería en Informática.

Usá como fuente de verdad el archivo plan.md adjunto, la guía de Blackboard y la devolución del profesor. No inventes datos personales, director, matrícula, correo, fechas, referencias ni capacidades del sistema. Si falta un dato, marcá explícitamente que falta.

Objetivo: mejorar el documento manteniendo el tema, el alcance y la consistencia con Symphony.

Restricciones:
- cuerpo principal en español;
- sólo Abstract y Keywords en inglés;
- mantener términos técnicos como proof gate, runtime, issue, pull request, policy-as-code y harness cuando sean necesarios;
- separar claramente Symphony existente del aporte de tesis;
- evitar diagramas complejos si la entrega será DOCX;
- mantener tablas numeradas con breve descripción;
- usar referencias verificables y estilo consistente;
- devolver sólo el Markdown final o la sección pedida, sin explicación fuera del documento.
```

## Qué pedirle a ChatGPT Pro

Para cambios grandes:

```text
Devolvé el Markdown final completo, listo para versionar en tesis/propuesta/plan.md.
```

Para correcciones del profesor:

```text
Compará la devolución adjunta contra el plan actual. Proponé cambios concretos por sección y luego devolvé sólo las secciones modificadas en Markdown.
```

Para controlar calidad antes de entregar:

```text
Auditá el plan contra la guía de Blackboard. Decime qué requisitos de la guía están cubiertos, cuáles faltan y qué cambios mínimos harías antes de entregar.
```

## Estructura de trabajo en el repo

```text
tesis/
  propuesta/
    plan.md
  entrega/
    plan-tesis-proyecto-final-integrador.docx
  chatgpt/
    README.md
    contexto-base.md
```

Si la tesis crece, separar luego `estado-del-arte/`, `problema/`, `solucion/`, `validacion/`, `gestion/` y `anexos/`. Mientras la entrega sea chica, `propuesta/plan.md` debe seguir siendo el documento canónico.
