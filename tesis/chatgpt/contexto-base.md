# Contexto base para ChatGPT Pro

## Tema

Plan de Tesis - Proyecto Final Integrador para Ingeniería en Informática.

Título principal:

> Arquitectura de runtime con proof gates para delivery autónomo de software basado en issues

Título alternativo:

> Marco integrador para la ejecución controlada, observable y verificable de agentes de software sobre repositorios

## Datos académicos

- Autor: Gaspar Dip
- Matrícula: 49012185
- Correo: dip.gaspar@gmaill.com
- Pendiente formal: confirmar si el dominio correcto del correo es `gmaill.com` o `gmail.com` antes de subir a Blackboard.
- Carrera: Ingeniería en Informática
- Asignatura: Tesis de Grado - Proyecto Final Integrador
- Director de tesis: Dr. Jorge Salvador Ierache
- Codirector: No corresponde
- Asesor profesional: No corresponde

## Base experimental

La tesis toma Symphony como base experimental. La contribución no debe presentarse como la creación de un agente nuevo ni como la invención del flujo issue-to-PR. La contribución debe formularse como arquitectura, formalización, adaptación y validación de un runtime de delivery autónomo.

## Diferenciación obligatoria

Separar siempre:

1. capacidades ya presentes en Symphony;
2. adaptaciones o formalizaciones propuestas por la tesis;
3. validación académica que se realizará durante el trabajo.

## Enfoque de validación

La validación debe medir el runtime y el proceso, no la calidad absoluta del código generado por un modelo. Métricas relevantes:

- trazabilidad issue -> workspace -> corrida -> evidencia -> resultado;
- recuperabilidad;
- bloqueo correcto por proof gates;
- completitud de evidencia;
- observabilidad operacional;
- diagnóstico de fallas;
- control de concurrencia;
- separación entre runtime y agente concreto.

## Restricciones de redacción

- El cuerpo principal debe estar en español.
- Sólo Abstract y Keywords deben estar en inglés.
- Términos técnicos como proof gate, runtime, issue, pull request, policy-as-code, harness, handoff y CI/CD pueden conservarse en inglés si se definen.
- No inventar referencias, personas, fechas, capacidades del sistema ni resultados de validación.
- Preferir tablas simples y texto explicativo antes que diagramas complejos, porque la entrega formal se exporta a DOCX.
- Mantener un tono académico, claro y defendible ante el director de tesis.
