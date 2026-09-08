# SDD Proposal — Obsidian-Claude Bridge

## Business Problem

Cuando Claude Code trabaja en un proyecto, no tiene acceso implícito al conocimiento de dominio que el usuario acumula en su vault de Obsidian. Esto fuerza al usuario a:
- Copiar y pegar contexto de Obsidian a cada sesión.
- Olvidar mencionar reglas de negocio relevantes.
- Repetir explicaciones de arquitectura ya documentadas.

El usuario quiere que Claude Code **consulte automáticamente su Obsidian** antes de modificar código, como si fuera memoria de dominio implícita.

## Target Users & Situations

- Desarrolladores que usan Obsidian como "segundo cerebro" técnico.
- Equipos con conocimiento de dominio documentado en notas `.md`.
- Proyectos donde la arquitectura y reglas de negocio evolucionan en Obsidian antes de codearse.

## Product Outcome

Un instalador `install.sh` (y `uninstall`) que:
1. Pida la ruta al vault de Obsidian.
2. Pregunte si se quiere modificar el `CLAUDE.md` global o uno de proyecto.
3. Cree e instale un MCP server minimalista basado en filesystem (Python).
4. Registre el MCP en la configuración de Claude Code.
5. Appendee una sección idempotente a `CLAUDE.md` que instruya al agente a buscar en el vault antes de codear.
6. Provea `uninstall` que revierta todos los cambios de forma limpia.

## In-Scope

- MCP server en Python (stdlib only) que exponga:
  - `search_vault`: busca notas por keyword en filenames y contenido.
  - `read_note`: lee el contenido completo de una nota.
  - `list_notes`: lista notas de una carpeta o del vault raíz.
- Instalador `.sh` interactivo (Git Bash / WSL / macOS / Linux).
- Soporte para `CLAUDE.md` global (`~/.claude/CLAUDE.md`) **por defecto**.
- Soporte para `CLAUDE.md` de proyecto (ruta custom pasada por flag o prompt).
- Append idempotente usando marcadores HTML comments (`<!-- obsidian-bridge:v1 -->`).
- Comando `uninstall` que elimine la sección del `CLAUDE.md` y desregistre el MCP.
- README con instrucciones de uso.
- Limitación de resultados de búsqueda para no saturar tokens (max 10 notas, max 2000 chars preview).

## Out-of-Scope

- Plugin de Obsidian (no se necesita, leemos filesystem directo).
- Soporte para Windows nativo sin Git Bash/WSL (PowerShell `.ps1` es post-MVP).
- Sync bidireccional (escritura a Obsidian desde Claude Code).
- Indexación semántica / embeddings (RAG local es post-MVP).
- Empaquetamiento como paquete npm/pip (es un repo clonable con scripts).

## First-Slice Scope

El MVP entrega:
1. `install.sh` interactivo.
2. `mcp_server.py` (Python 3.8+, sin dependencias externas).
3. `uninstall.sh`.
4. `README.md`.
5. Detecta `~/.claude/CLAUDE.md` por defecto, permite elegir ruta alternativa.

## Business Rules

- BR1: Si no existe `~/.claude/`, el instalador lo crea.
- BR2: Si el MCP ya está registrado en settings de Claude Code, se actualiza la ruta, no se duplica.
- BR3: Si la sección de obsidian-bridge ya existe en `CLAUDE.md`, se reemplaza (no se appendea duplicado).
- BR4: El uninstall solo elimina la sección entre marcadores; no toca el resto del `CLAUDE.md`.

## Edge Cases

- E1: Vault con miles de notas — limitar resultados de búsqueda.
- E2: Vault path con espacios — escapar correctamente en JSON y shell.
- E3: Usuario cancela mid-install — dejar el sistema en estado consistente (no half-written configs).

## Non-Goals

- Reemplazar Engram o memoria nativa de agente.
- Funcionar sin Obsidian (el vault debe existir como carpeta de `.md`).
- Instalar Python por el usuario (se asume Python 3.8+ instalado).

## Product Constraints

- Python stdlib only (no pip install).
- Shell portable: bash/sh compatible.
- No privilegios de admin requeridos.
