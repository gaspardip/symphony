# Evaluación ChatGPT Pro del plan de tesis

Fecha: 21/05/2026

Interfaz utilizada: ChatGPT Pro en Chrome. El modelo visible en la corrida final fue `Medium`; dos intentos previos con el adjunto completo en modo `Pro` quedaron en `Stopped thinking` sin respuesta evaluable. Para evitar el bloqueo, la evaluación final se pidió con un resumen estructural fiel de la consigna de Blackboard y del plan actual.

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
