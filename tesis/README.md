# Documentación de tesis — Symphony

Esta carpeta contiene documentación académica y técnica vinculada al plan de tesis sobre Symphony.

## Documentos

- [`propuesta/plan.md`](propuesta/plan.md): plan de tesis para Proyecto Final Integrador, estructurado según la guía de Blackboard.
- [`entrega/plan-tesis-proyecto-final-integrador.docx`](entrega/plan-tesis-proyecto-final-integrador.docx): exportación editable para la entrega formal.
- [`chatgpt/README.md`](chatgpt/README.md): workflow para usar ChatGPT Pro sin perder trazabilidad del documento.
- [`evaluacion/chatgpt-pro-evaluacion-plan-2026-05-21.md`](evaluacion/chatgpt-pro-evaluacion-plan-2026-05-21.md): puntuación de ChatGPT Pro contra la consigna de Blackboard.

## Objetivo de la carpeta

Mantener versionada la documentación de tesis dentro del fork, separada del producto principal, para que cada ajuste de enfoque, comentario docente, matriz de validación o cambio de referencias quede trazado como commit.

## Exportación sugerida

El contenido fuente se mantiene en Markdown. Para regenerar el DOCX de entrega:

```bash
/Users/gaspar/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 tesis/scripts/export_plan_docx.py
```

La plantilla exporta un DOCX con hoja A4, tipografía Times New Roman, carátula profesional, encabezado, pie de página, secciones jerarquizadas y tablas estilizadas.
