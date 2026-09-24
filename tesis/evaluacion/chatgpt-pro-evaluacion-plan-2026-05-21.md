# Evaluación ChatGPT Pro del plan de tesis

Fecha: 21/05/2026

Interfaz utilizada: ChatGPT en Chrome. Primero se pidió una evaluación con la consigna resumida de Blackboard; luego se realizó una nueva revisión con el selector visible en `Pro` sobre el DOCX final adjunto.

## Resultado

1. **Puntaje total: 88/100**

2. **Tabla breve por sección/rubro**

| Sección / rubro                                  | Puntaje | Justificación corta                                                                                                                                                          |
| ------------------------------------------------ | ------: | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Formato, carátula y presentación                 |    8/10 | DOCX exportado con carátula/formato presentable. Riesgo original: el Markdown no garantizaba por sí mismo A4, Times, encabezado, pie y numeración.                         |
| 1. Títulos                                       |     5/5 | Tema claro, específico, acotado y alineado con Symphony. Buen título principal y alternativo.                                                                                |
| 2. Integrantes                                   |     3/5 | Incluye alumno, matrícula, director y correos. Penalización inicial por dominio de correo incorrecto, ya corregido a `dip.gaspar@gmail.com`.                                  |
| 3-6. Resumen, palabras clave, abstract, keywords |    8/10 | Cumple estructura bilingüe. Resumen sólido y orientado a contribución. Faltaría verificar calidad del abstract completo y consistencia terminológica.                        |
| 7. Introducción                                  |     8/9 | Bien planteada: contexto, motivación, brecha y encuadre de Symphony como base/prototipo, no como entrega acrítica.                                                           |
| 8. Estado del Arte                               |   13/15 | Muy buen mapa de herramientas, vacancias y dimensiones técnicas. Penaliza que parece más apoyado en documentación/repositorios que en literatura académica formal.           |
| 9. Problema detectado/faltante                   |   10/10 | Claro, evaluable y entendible en primera lectura. Está muy bien delimitado y conectado con necesidades concretas.                                                            |
| 10. Solución propuesta                           |   13/14 | Arquitectura, componentes, alcance, fuera de alcance, objetivos, requisitos y tecnologías bien definidos. Muy defendible.                                                    |
| 11. Experimentación / validación                 |   12/13 | Fuerte: pruebas basales, casos reproducibles y métricas cuantitativas. Faltaría precisar un poco más el diseño experimental y cómo se recolecta evidencia.                   |
| 12. Plan de actividades                          |   11/12 | Completo: metodología, entregables, hitos, tiempos, riesgos, calidad, documentación y dependencias. Muy alineado con la guía.                                                |
| 13. Referencias                                  |     6/8 | Hay referencias relevantes y formato APA-like. Riesgo: mejorar APA 6 real y sumar papers/estándares académicos más fuertes.                                                  |
| 14. Anexos                                       |     4/4 | Bien: glosario, bibliografía complementaria, estructura de repo, formato de exportación y cierre.                                                                            |

3. **Bloqueantes para entregar hoy**

* **Corregir el dominio del email del alumno**. Era un error formal visible en una sección sensible; no entregaría sin corregirlo.
* **Verificar el DOCX final**, no sólo el Markdown: A4, Times New Roman 11, títulos 14/16, interlineado 1,5, encabezado, pie con apellido y página, numeración de tablas/gráficos.
* **Revisar que no haya títulos consecutivos sin breve descripción**, porque la guía lo menciona explícitamente.

4. **Mejoras no bloqueantes**

* Pasar referencias de "APA-like" a **APA 6 consistente**.
* Agregar 3-6 fuentes académicas más fuertes sobre agentes de software, ingeniería de software asistida por IA, orquestación, verificación, trazabilidad o CI/CD autónomo.
* Hacer más explícita la diferencia entre **validar el runtime** y **validar la calidad del código generado por LLMs**.
* Precisar cómo se documentará cada corrida: logs, métricas, evidencia, estado final, causa de bloqueo/falla.
* Asegurar que el Estado del Arte no parezca una lista de herramientas, sino una síntesis crítica con vacancias justificadas.

5. **Veredicto final**

**Sí, lo entregaría hoy al director/Blackboard, pero sólo después de corregir el email y revisar el DOCX final.**

Como plan de tesis está **bien acotado, técnicamente defendible, consistente con Symphony y bastante alineado con la guía**. No parece un trabajo inflado ni genérico: tiene problema, solución, validación, alcance y métricas. La mayor debilidad no es conceptual, sino formal/bibliográfica.

## Acciones posteriores a la evaluación

- Se agregaron frases breves entre encabezados consecutivos en `tesis/propuesta/plan.md`.
- Se corrigió el correo del alumno a `dip.gaspar@gmail.com`.
- Se regeneró `tesis/entrega/plan-tesis-proyecto-final-integrador.docx`.
- Se verificó estructuralmente el DOCX: hoja A4, encabezado, pie de página, tablas, email actualizado y ausencia del correo anterior.
- Se generó una previsualización con Quick Look en `/tmp/symphony_tesis_preview/plan-tesis-proyecto-final-integrador.docx.png`.

## Nueva revisión ChatGPT Pro sobre DOCX final adjunto

Modelo visible: `Pro`

Archivo revisado: `tesis/entrega/plan-tesis-proyecto-final-integrador.docx`

1. **Puntaje total sobre 100: 89/100**

2. **Tabla breve por sección/rubro**

| Sección / rubro                                            | Puntaje parcial | Justificación corta                                                                                                                                                                                                                  |
| ---------------------------------------------------------- | --------------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Formato y presentación DOCX                                |            8/12 | Carátula correcta, A4, Times, encabezado centrado, pie con apellido y página, tablas numeradas y descriptas. Penaliza: interlineado no plenamente 1,5, listas numeradas que no reinician y enlaces Markdown visibles en referencias. |
| Secciones obligatorias                                     |             8/8 | Están las 14 secciones requeridas y el orden general respeta la guía.                                                                                                                                                                |
| Resumen, palabras clave, abstract, keywords e introducción |            9/10 | Muy claro el foco: runtime, proof gates, trazabilidad, recuperación y Symphony como base experimental. Buen encuadre bilingüe.                                                                                                       |
| Estado del Arte                                            |           13/15 | Mapea bien antecedentes, herramientas, vacancias y oportunidad de tesis. Penaliza que depende mucho de documentación técnica/repositorios y poco de literatura académica formal.                                                     |
| Problema detectado/faltante                                |           10/10 | Excelente: claro, conciso, evaluable en primera lectura y conectado con un caso basal concreto.                                                                                                                                      |
| Solución propuesta                                         |           13/15 | Arquitectura defendible, componentes bien separados, alcance/fuera de alcance correcto, requisitos RF/RNF sólidos y buena diferenciación respecto de Symphony.                                                                       |
| Experimentación y validación                               |           11/12 | Buenas pruebas basales, casos reales, matriz de trazabilidad y métricas cuantitativas. Falta precisar un poco más cómo se capturará y auditará la evidencia en cada corrida.                                                         |
| Plan de actividades                                        |           10/10 | Completo: metodología, entregables, hitos, cronograma, riesgos, calidad, reuniones, documentación, dependencias y seguridad.                                                                                                         |
| Referencias y anexos                                       |             7/8 | Glosario y anexos útiles. Referencias pertinentes, pero deben limpiarse a APA 6 real y corregir los enlaces visibles tipo Markdown.                                                                                                  |

3. **Bloqueantes para entregar hoy, si hay**

* **No hay bloqueante conceptual.** El plan es sólido, acotado y defendible.
* **Sí hay bloqueantes formales para una entrega Blackboard prolija:**
  * Corregir la numeración de listas que continúa indebidamente: módulos de solución empiezan en 8, objetivos en 16, metodología en 24 y resultados esperados en 33.
  * Ajustar interlineado a **1,5 real y consistente** si la cátedra lo exige estrictamente.
  * Corregir referencias: los enlaces aparecen como Markdown visible `[url](url)`; debe quedar formato APA/Word limpio.
* El riesgo del correo quedó resuelto: ahora figura `dip.gaspar@gmail.com`.

4. **Mejoras no bloqueantes**

* Sumar algunas fuentes académicas/papers además de documentación técnica.
* Convertir referencias a APA 6 consistente.
* Agregar, si queda tiempo, un diagrama simple de arquitectura o flujo.
* Precisar por cada prueba qué evidencia queda: log, métrica, artefacto, estado, razón de bloqueo o reporte.
* Reforzar una frase final sobre originalidad: el aporte no es Symphony como repo, sino la formalización, validación reproducible y matriz vacancia-requisito-prueba.

5. **Veredicto final**

**Al director: sí, lo entregaría hoy.**

**A Blackboard: lo entregaría hoy sólo después de corregir numeración, interlineado y referencias.** Sin esos ajustes, el contenido aprueba con margen, pero la versión final queda expuesta a descuentos formales evitables.

## Acciones posteriores a la revisión Pro del DOCX

- Se ajustó `tesis/scripts/export_plan_docx.py` para que cada bloque de lista numerada use una definición propia y reinicie en 1.
- Se normalizó el interlineado del cuerpo exportado a 1,5.
- Se limpiaron los enlaces Markdown visibles en la exportación DOCX; las referencias ahora muestran la URL sin sintaxis `[url](url)`.
- Se regeneró `tesis/entrega/plan-tesis-proyecto-final-integrador.docx`.
- Se verificó estructuralmente el DOCX final: sin links Markdown visibles, sin correo incorrecto, con `dip.gaspar@gmail.com`, sin anexos internos removidos y con listas numeradas separadas por `numId`.
