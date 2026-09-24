# Documentación de tesis — Symphony

Esta carpeta conserva documentación académica y técnica del plan inicial de tesis sobre Symphony, elaborada en mayo y junio de 2026.

**Material histórico:** el plan usa ocho PB y siete CR; el protocolo de agosto amplió el alcance a catorce PB y doce CR. Estos documentos no sustituyen la propuesta posterior, el catálogo de 26 casos ni la entrega de septiembre. Las evaluaciones incluidas fueron generadas por ChatGPT Pro y no son calificaciones del docente. La investigación contiene texto en inglés y referencias pendientes de verificar antes de usarlas como bibliografía.

Los siete archivos originales proceden de la rama documental en `0fbd47d`; los dos documentos locales adicionales se preservaron sin cambiar sus bytes en `55bb9b5`. El estado vigente de cierre se mantiene en el proyecto Tesis de Codex, en `trabajo/cierre-actual/cierre-verificado.md`. La presencia de un archivo bajo `blackboard/` no acredita por sí sola su entrega.

## Documentos

- [`propuesta/plan.md`](propuesta/plan.md): plan de tesis para Proyecto Final Integrador, estructurado según la guía de Blackboard.
- [`entrega/plan-tesis-proyecto-final-integrador.docx`](entrega/plan-tesis-proyecto-final-integrador.docx): exportación editable para la entrega formal.
- [`chatgpt/README.md`](chatgpt/README.md): workflow para usar ChatGPT Pro sin perder trazabilidad del documento.
- [`evaluacion/chatgpt-pro-evaluacion-plan-2026-05-21.md`](evaluacion/chatgpt-pro-evaluacion-plan-2026-05-21.md): puntuación de ChatGPT Pro contra la consigna de Blackboard.

- [`fuentes/blackboard/plan-tesis-proyecto-final-integrador-2026-05-21.docx`](fuentes/blackboard/plan-tesis-proyecto-final-integrador-2026-05-21.docx): copia histórica del plan, preservada con su nombre de procedencia.
- [`investigacion/chatgpt-pro-deep-research-2026-06-09.md`](investigacion/chatgpt-pro-deep-research-2026-06-09.md): investigación histórica con referencias por verificar.

## Objetivo de la carpeta

Mantener versionada la documentación de tesis dentro del fork, separada del producto principal, para que cada ajuste de enfoque, comentario docente, matriz de validación o cambio de referencias quede trazado como commit.

## Exportador histórico

El siguiente comando corresponde al plan inicial. No debe ejecutarse para actualizar la entrega de septiembre ni sobrescribir el Word histórico sin una revisión expresa de su contenido:

```bash
/Users/gaspar/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 tesis/scripts/export_plan_docx.py
```

La plantilla exporta un DOCX con hoja A4, tipografía Times New Roman, carátula profesional, encabezado, pie de página, secciones jerarquizadas y tablas estilizadas.
