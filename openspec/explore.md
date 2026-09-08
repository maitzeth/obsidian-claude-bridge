# SDD Explore — Obsidian-Claude Bridge

## 1. Problema

El usuario quiere que Claude Code **siempre consulte su vault de Obsidian** antes de modificar código, sin tener que pedirlo manualmente cada vez. Además quiere:
- Instalador `.sh` que configure todo automáticamente.
- Si el MCP de Obsidian no está instalado, que lo instale pidiendo autorización.
- Append idempotente al `CLAUDE.md` (no duplicar en re-runs).
- Comando `uninstall` para revertir cambios.
- README incluido.

## 2. Entorno detectado

- **Claude Code** almacena configuración en rutas tipo:
  - `~/.claude/CLAUDE.md` (instrucciones de proyecto globales)
  - `CLAUDE.md` en el directorio de trabajo o ancestros (instrucciones por proyecto)
  - Configuración MCP en archivos JSON tipo `settings.json` o `claude_mcp_settings.json`
- Se encontró un `CLAUDE.md` existente en el sistema que usa **marcadores HTML comments** (`<!-- name:v1.0 -->`) para inyección idempotente y uninstall limpio. Esa es la técnica a replicar.
- VS Code tiene su `mcp.json` pero Claude Code usa su propia configuración.

## 3. Opciones arquitectónicas evaluadas

### A. MCP server nativo de Obsidian (REST API)
- Obsidian tiene un plugin "Local REST API" que expone endpoints.
- Un MCP server puede consumir esa API.
- **Problema**: requiere plugin activo en Obsidian, más setup.

### B. MCP server filesystem directo (recomendado)
- Leer directamente los archivos `.md` del vault desde el filesystem.
- No depende de Obsidian estando abierto ni de plugins.
- Más simple, más robusto para un instalador `.sh`.
- Se puede hacer en Python (stdlib) o Node.

### C. Sync estático a `CLAUDE.md`
- Exportar notas a un `DOMAIN_CONTEXT.md` en el repo.
- **Problema**: el usuario pidió lectura dinámica del vault, no snapshot estático.

## 4. Decisión preliminar

**Opción B (MCP filesystem) + marcadores en CLAUDE.md** es la más viable para un instalador `.sh` auto-contenido:
- No requiere plugins de Obsidian.
- El MCP server puede ser un script Python simple que exponga `search_vault` y `read_note`.
- El instalador configura la ruta al vault, registra el MCP en la config de Claude Code, y appendea la sección al `CLAUDE.md` con marcadores.
- El uninstall elimina la sección entre marcadores y desregistra el MCP.

## 5. Hallazgos clave

- **Idempotencia**: Usar marcadores HTML comments `<!-- obsidian-bridge:v1 --> ... <!-- /obsidian-bridge:v1 -->` permite append seguro y uninstall limpio.
- **Ubicación de CLAUDE.md**: El instalador debe detectar si existe `CLAUDE.md` en el repo actual o en `~/.claude/CLAUDE.md` (global). Por defecto, opera sobre el repo donde se ejecuta.
- **Autorización**: El instalador debe mostrar qué va a hacer y pedir `y/N` antes de tocar archivos.
- **MCP Config**: Claude Code usa `mcpServers` en su settings JSON. El MCP server puede ser un script Python ejecutado via `python` o `python3`.

## 6. Riesgos

- **R1**: Si Claude Code cambia la ruta o formato de su config, el instalador se rompe.
- **R2**: Si el vault es muy grande, el MCP server puede devolver demasiados tokens. Mitigación: limitar resultados de búsqueda.
- **R3**: Windows vs Unix paths. El `.sh` asume Git Bash / WSL / MSYS. Para PowerShell nativo habría que hacer `.ps1` aparte.
