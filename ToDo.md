# Ax-Less — Pendientes

Plan de trabajo para `axless.core`. Lo verificado y funcionando está abajo;
lo pendiente, ordenado por valor por unidad de riesgo.

## NC — Bug conocido y no resuelto (monitores)

### 1. Pared al mover el cursor entre pantallas (compositor, no el menú)

**Síntoma (reportado por el usuario, aclarado):** NO es el arrastre del menú de
monitores. Es el **cursor del compositor**: al moverlo de un borde de pantalla
a la otra se nota "como una pared" que lo frena — hay que insistir para cruzar.

**Hecho probado en vivo (06-10):**
Las dos pantallas están **apiladas en vertical**, no una junto a la otra:

```
eDP-1    Logical position: 0, 850    altura 960   -> ocupa 850..1810
HDMI-A    Logical position: 0, -40    altura 864   -> ocupa -40..824
----> hueco vertical entre ellas: 850 - 824 = 26 px
```

Ese hueco de **26 px en Y** es la "pared": el cursor choca contra él y, como
el desplazamiento cruzado es vertical (de 0,850 hacia 0,-40), atraviesa un
vacío de 26 px donde no hay ninguna pantalla. Es **comportamiento normal** de
niri: no hay salto de cursor ni warping configurado, el cursor cruza solo
donde las pantallas se tocan.

**Opciones (decidir con el usuario):**
1. **Dejarlo**: es el hueco legítimo entre dos pantallas apiladas. La pared
   desaparece si las pantallas se superponen 0-1 px (alinear sus bordes).
   "Colocar juntos" en el menú de monitores sirve para eso.
2. **`focus-ring` / warp de cursor en borde**: niri no expone warp de cursor
   por borde; habría que revisar keybinds de niri (`niri msg action move-cursor
   ...`) si existe, para mover el foco/cursor de pantalla con atajo en lugar de
   por arrastre. NO está en la funcionalidad estándar.

**Para el menú de monitores (relacionado, ya casi resuelto):** la UI de
arrastre del lienzo es correcta (ver commit "widen horizontal drag bound"), y
el NC anterior del "insistir con el ratón" quedó descartado como síntoma de
este hueco vertical, no de la fórmula del arrastre.

---

## Sidebar de IA — animaciones alineadas con Ambxst (06-10)

El port de la sidebar traía el sistema de animación de NothingLess
(`Anim.qml` con tokens Material 3 + `AnimatedBehavior.qml`), que fue
sustituido por `NumberAnimation { duration: Config.animDuration; easing: OutQuart }`
plano en ~40 sitios. Decisión final del usuario: **usar las animaciones
originales de Ambxst**, sin portar el sistema de tokens.

Dos cambios en `payload/modules/sidebar/AssistantSidebar.qml`:

1. **Posicionamiento/apertura**: la sidebar animaba la propiedad `x`
   calculada desde `parent.width`. Dentro de `UnifiedShellPanel` el padre
   es el overlay a pantalla completa, así que `x` iba de `parent.width` a
   `parent.width - width` y el recorrido se medía contra el ancho de toda
   la pantalla (de ahí que "cruciera la pantalla de izquierda a derecha").
   Sustituido por el bloque **idéntico al de Ambxst**: anclar a
   `parent.left`/`parent.right` y animar `leftMargin`/`rightMargin` entre
   `0` y `-width`, con `Easing.OutCubic` y `Config.animDuration`.
   Verificado por comparación línea a línea contra el original de Ambxst
   (22/22 líneas iguales).
2. **Curvas**: Ambxst usa **solo** `Easing.OutCubic` en toda su sidebar; la
   del mod tenía 35 `OutQuart` + 2 `InQuad` heredados de NothingLess.
   Los 37 alineados a `OutCubic` → ahora 39/39 `OutCubic`.

Nota: los 6 componentes que NothingLess extrajo (`SidebarHeader.qml`,
`SidebarInputBar.qml`, `SidebarMessageBubble.qml`, `SidebarModeBar.qml`,
`SidebarChatHistory.qml`, `QuickAddAgentPopup.qml`) están referenciados por
**0 archivos** — código muerto ya en NothingLess, no se portan.

## NothingClaw — bucle de agente + tools de máquina (06-10)

NothingClaw era un **bridge pasivo**: publicaba ~29 tools y dejaba que el
modelo del otro lado decidiera. Ahora además conduce sus propias tools.
**No se eliminó**: se empezó a borrarlo y se restauró tal cual.

**`agent_loop.py`** (nuevo, 1 kb) — bucle `goal -> model -> tool_calls ->
execute -> observe -> repeat`, la forma que comparten Aider, smolagents y
Anthropic's building-effective-agents. Backend Ollama `/api/chat`, el mismo
host que `server.py` ya consultaba para detectar capabilities, así que no
aporta ninguna dependencia nueva.

- `POST /agent` → `{goal, model, max_steps, max_seconds, tools}`; devuelve
  `answer`, `transcript` completo y `stopped_reason` (`done` / `max_steps` /
  `timeout` / `model_error`).
- `GET /agent/models` → modelos locales disponibles.

**Tres cosas que lo hacen funcionar con modelos pequeños:**

1. **Recuperación de tool calls escritas como texto.** `llama3.2` ignora el
   campo `tools` nativo y escribe la llamada como texto JSON — y además con
   comillas internas sin escapar, o sea JSON inválido:
   `{"name": "run_shell_command", "parameters": {"command": "ls -name "*.md""}}`.
   Sin recuperación el loop lo leía como respuesta final y paraba en un paso
   sin hacer nada. `_extract_tool_calls` cubre JSON desnudo, fences ```json,
   bloques ```tool_call, wrappers `{"function": {...}}` y, como último recurso,
   salva pares `"key": "value"` de JSON malformado. Queda registrado en el
   transcript como `recovered_call`.
2. **Observaciones recortadas** a 8000 chars antes de volver al historial, para
   que un `list_installed_apps` no se coma el contexto en el turno cuatro.
3. **Presupuesto estricto** de `max_steps` y `max_seconds`.

**`fs_tools.py`** (nuevo) — `list_dir`, `read_file`, `write_file`,
`search_files`. El bridge era solo-escritorio: podía cambiarte la ventana pero
no tocar la máquina. Todo confinado a `NOTHINGCLAW_FS_ROOT` (por defecto `~`),
con la contención comprobada **después** de `realpath`, así que se rechazan
tanto `../..` como escapes por symlink. Binarios se detectan y se rechazan.

**Bug de diseño arreglado:** `execute_command` mandaba shell arbitrario por
`axctl system execute` (capa IPC del compositor, timeout 5 s) — un `find`
reventaba por timeout. Se añadió **`run_shell_command`**: subprocess directo,
timeout configurable (máx 300 s), devuelve stdout y stderr. `execute_command`
queda para acciones del compositor. El README ya referenciaba un
`run_shell_command` que nunca existió.

**Verificado de verdad contra Ollama con `llama3.2`:**
- `list_windows` → enumeró las 4 ventanas reales del escritorio (2 pasos, 67 s).
- Tarea de encadenado → recuperó la tool del texto, ejecutó, y **escribió el
  archivo correcto** con los 4 markdown reales de Ax-Less (2 pasos, 35 s).
- Sandbox: `../../etc/shadow`, `/etc/passwd` y `cwd: ../../etc` → rechazados.
- 8 casos de parsing de tool calls (JSON roto, fences, wrapper OpenAI,
  argumentos como string, varios en uno, prosa, JSON-no-call).

## OpenCode + conexiones MCP de referencia (06-10)

Cerrado el otro frente de "más conexiones de agentes".

**`mcp/opencode/server.py`** (nuevo) — adaptador. `opencode serve` expone
una API de agente completa (`/session`, `/file`, `/find`, `/mcp`,
`/experimental/tool`) pero **no habla el protocolo** que espera
`HttpAgentClient` (`GET /tools` + `POST /tools` con `{name, arguments}`).
El adaptador republica 10 tools sobre esa API:
`opencode_{health,list_files,read_file,find_in_files,find_files,find_symbols,run_shell,list_agents,list_mcp_servers,list_sessions}`.
- `run_shell` crea y cachea una sesión porque OpenCode la exige.
- Auth básica pasada tal cual (`OPENCODE_SERVER_PASSWORD` /
  `OPENCODE_SERVER_USERNAME`).
- **Fuera de alcance a propósito**:iciar turnos de agente. Ambxst ya tiene su
  propio bucle de conversación y anidarlos pelearía por el modelo. Es "que el
  shell vea el proyecto por los ojos de opencode", no "lanzar un segundo agente".

**⚠ Sin verificar contra un servidor real.** En esta máquina solo está
**OpenCode Desktop** (Electron, 1.18.34) y no el CLI, así que no había
`opencode serve` contra el que probar. Se probó contra un **mock transcrito de
la spec publicada** (https://opencode.ai/docs/server/): las 10 tools
responden, tool desconocida → error claro, upstream caído → "Is `opencode
serve` running?". Lo que queda sin cubrir es que el servidor real se haya
apartado de su propia documentación.

**6 presets nuevos** en Settings → AI → Agent Connections:

| Preset | Tipo | Qué es |
|---|---|---|
| OpenCode | http-bridge | el adaptador de arriba, puerto 8791 |
| Filesystem MCP | mcp-stdio | `npx @modelcontextprotocol/server-filesystem` |
| Fetch MCP | mcp-stdio | `uvx mcp-server-fetch` |
| Memory MCP | mcp-stdio | `npx @modelcontextprotocol/server-memory` |
| Git MCP | mcp-stdio | `uvx mcp-server-git` — **nace desactivado** |
| SQLite MCP | mcp-stdio | `uvx mcp-server-sqlite` |

Los servidores MCP oficiales corren sin instalar nada porque `npx`/`uvx` los
bajan bajo demanda (ya presentes en la máquina). **Git** se crea desactivado a
propósito: `mcp-server-git` exige `--repository` y `$HOME` no es un repo, así
que lleva una ruta placeholder `/ruta/a/tu/repo` que hay que editar.

## Implementación pendiente (features de NothingLess)

| # | Feature | Archivos fuente (NothingLess) | Notas |
|---|---|---|---|
| F1 | **Island de barra** | `modules/bar/IslandContent.qml`, `BarContent.qml` (`barMode`, `Loader` island), `config/defaults/bar.js` | Sin resolver el NC-1 no tocar `BarContent` (conflicto con parche). |
| ~~F2~~ | ~~**Métricas en el notch**~~ ✅ **portado** | `MetricsGroup.qml`, `MetricsGroupWrapper.qml`, `DefaultView.qml`, `NotchMetrics.qml` | Hecho: `patches/notch-metrics.patch` + overlay de `defaults/notch.js`. |
| ~~F3~~ | ~~**Posiciones por monitor**~~ ✅ **portado** | `modules/services/PerMonitorConfig.qml` | Hecho: singleton + `patches/per-monitor-positions.patch` cablea bar/dock/notch. |
| F4 | **Motor de wallpaper de vídeo + interpol + palette** | `VideoWallpaperService.qml`, `GpuDetector.qml`, shaders `interpol.*`, `palette.*`, `Wallpaper.qml` | FPS real: Ambxst **no tiene** fuente de FPS, solo `refreshRate` por monitor desde `axctl` (sin usar). Los `.qsb` se generan con `qsb` (incluido en el sistema), hay que compilarlos. No tocar `Wallpaper.qml` si F2 lo toca. |
| ~~F5~~ | ~~**Tablero de tareas**~~ ✅ **portado** | `modules/widgets/dashboard/todo/TodoTab.qml`, `TodoBoard.qml`, `Dashboard.qml` (tab 4) | Hecho: ver sección "Ya portado". |
| F6 | **Hax spotlight** | `modules/widgets/spotlight/*` (5227 líneas), `Calculator.qml`, `PluginManager.qml` | Proceso standalone (`qs -n -p spotlight_entry.qml`), apenas toca el árbol. Necesita subcomando `ambxst spotlight`. |
| F7 | **Splash con el logo** | `shell.qml` (bloque splash) + `assets/ambxst/*.svg` | **Descartado por el usuario (06-10): no quiere splash.** Se implementó y se revirtió; los parches se pueden recuperar del commit `11cf152`. |

## Parchado / mantenimiento

- `path/settings-i18n.patch` → su contenido le muevo a `settings-i18n` cuando
  se genere una feature nueva que añada claves. Las traducciones se generan
  desde el conjunto real de claves usadas por el payload (ver commit de
  "traducciones completas"). Nunca insertar claves sueltas a mano.

## Lo que falta por portear de NothingLess al mod (inventario completo)

Fuente: `~/Documentos/GitHub/NothingLess` (fork v1.1.0). Ambxst 1.3.10
(`~/.local/src/ambxst`) ya tiene **en su backend Go** muchas de estas cosas
(clipboard, OCR/QR, screenshots, system monitor, keystore, link preview,
weather, night light, game mode, caffeine, power profile, recorder) — esas se
**excluyen** y NO se portea para no revertir trabajo nativo multi-compositor.
Solo se portea lo que Ambxst no tiene, ya sea en Go o pidiendo a axctl.

### Ya portado y verificado en `axless.core`
- [x] Agente/NLP: `Ai.qml`+estrategias+`AgentManager`/`AgentStore`/MCP/HTTP/command+`mcp/nothingclaw` (3.3 k-linas). Reemplaza `Ai.qml` (overlay con sha).
- [x] Menú de compositor único (sección 8) con opciones por compositor + `CompositorKeywords.qml` (73 claves de NothingLess, vía Hyprland; ocultas en niri).
- [x] Monitores por compositor + arrangement canvas arrastrable (`MonitorsPanel.qml`).
- [x] **Tablero de tareas (F5)**: `services/TodoBoard.qml` (singleton, persiste en `~/.config/ambxst/todo/tasks.json`, recordatorios vía `Notifications`), `widgets/dashboard/todo/{TodoTab,TodoCalendar,TodoCalendarDayButton}.qml` + `todoCalendarLayout.js` (calendario propio con selección de rango; NO se tocó el `calendar/` del dashboard de Ambxst), `Icons.todo` añadido, cuarto tab en `Dashboard.qml`. Adaptación: `nothingless/todo`→`ambxst/todo`, `Anim.*`→`Config.animDuration`. Verificado: carga sin errores, `tasks.json` se crea y la lógica ordena/overdue correctamente.
  - **Fixes post-port (06-10)**: (a) `getYForIndex` de `Dashboard.qml` estaba hardcodeado a 3 tabs (`idx <= 2`) → al pulsar el tab ToDo la píldora de resaltado saltaba al botón de settings; ahora `idx < root.tabCount` (igual que NL) + clamp para que un tab desbordado nunca pinte sobre el gear. (b) Los botones de tab que cruzarían el área del botón de settings se ocultan (`visible: index*(h+spacing)+h <= controlsButtonContainer.y`). (c) Tab ToDo ensanchado a 640 px en `nonAnimWidth` (400 px ahogaba la tabla con el calendario lateral de 280 px); `TodoTab` implicitWidth 800→640/600→430, panel de calendario 280→232 px y plegable con botón "Cal" en el header.
  - **Fixes del selector de fechas (06-10)**: el popup de fecha no tenía altura propia (`width: 320` sin `height`) y la `ColumnLayout` comprimía todos los hijos — los botones quedaban "aplanados de arriba y abajo". Ahora: altura fija 396 px (título 24 + días 6×32 + hora 32 + botones 36 + márgenes), título "Select date", celdas del mes con `Layout.maximumHeight: 32`, botones de ambos popups 28/32→36 px, campos de hora con fondo transparente y borde (antes estilo Material por defecto), SpinBoxes con altura fija 32. `color: rangePopup.item` es válido en Ambxst (`StyledRect.item` existe) — no era bug del port.
  - **Aplastado real de botones + popup desbordado (06-10, 2º pase)**: la causa
    de fondo era que en Qt Quick Layouts un hijo con `Layout.preferredHeight`
    pero **sin `Layout.minimumHeight`** se encoge cuando el layout no tiene
    espacio (`minimumHeight` por defecto = 0). Añadido `minimumHeight` a los
    29 elementos con altura fija (chips del header 24, botones 28/32/36, filas)
    y a las filas header/new-task (44). Los popups ya no tienen altura fija:
    `width: Math.min(320, parent.width-16)`, `height: Math.min(396, parent.height-16)`
    (rango: 340/440) y su contenido va en un `Flickable` con `ScrollBar`, así
    si el tab es más bajo que la rejilla el contenido se desplaza en vez de
    cortarse. Además se corrigió un `ReferenceError: modelData is not defined`
    en el delegate de los días de la semana (faltaba `required property var
    modelData`), que salía 7 veces por cada apertura del selector.
    **Medido en runtime** (probe sobre el tab a 640x430): chips del header
    24.0 px, botones del selector de fecha Clear/Cancel/Save 36.0 px, los del
    selector de rango Cancel/Clear/Apply 36.0 px, popup de fecha 396 px y de
    rango 414 px — ambos dentro de los 430 px del tab, sin recorte.
- [x] Traducciones completas (grep del payload, no batch suelto).
- [x] **Métricas en el notch (F2)**: `NotchMetrics.qml` (nuevo) + `MetricsGroup.qml`
  y `MetricsGroupWrapper.qml`. Se activa con `Config.notch.showMetrics`
  (`~/.config/ambxst/config/notch.json`). Muestra CPU/GPU/RAM/DSK desde el
  `SystemResources` de Ambxst.
  **Alcance deliberado**: NL también pintaba potencia y FPS, pero el backend Go
  de Ambxst (`backend/pkg/svc/systemmonitor`) solo emite
  `cpu{usage,temp}`, `ram`, `disk{usage}`, `gpu{usages,temps}` — no hay vatios
  ni frame rate. Se omiten en vez de inventarlos.
  **Dos bugs reales encontrados al integrarlo:**
  1. `SystemResources.monitoringActive` solo se activaba con el tab de métricas
     del dashboard abierto, así que el notch leía una suscripción muerta
     (siempre ceros). Ampliado a `|| Config.notch.showMetrics`.
  2. `ConfigValidator.validate()` reconstruye la config iterando
     `for (var key in defaults)`: **descarta toda clave que no esté en
     `defaults/notch.js`**. Añadir la propiedad solo a `Config.qml` no servía —
     el shell borraba `showMetrics` de `notch.json` en el siguiente guardado y
     el ajuste se reseteaba solo. Por eso el overlay de `defaults/notch.js`
     necesita `replace: true` + `expectedSha256`.
  Verificado: con el flag activo `metricsActive`/`monitoringActive` pasan a
  true, `notch.json` conserva la clave tras reiniciar el shell, el ancho del
  notch crece (386 px) y llegan muestras reales (CPU 9.2% / 67 °C, RAM 78.8 %,
  disco 12.1 %).
- [x] **Posiciones por monitor (F3)**: `services/PerMonitorConfig.qml` lee
  `~/.config/ambxst/config/monitors.json` y expone
  `resolve(screen, domain, key, default)`.
  `patches/per-monitor-positions.patch` lo cablea en `BarContent`,
  `DockContent` y `NotchContent` (el dock lee los tres porque su posición final
  se deriva de dónde estén barra y notch **en ese** monitor, no globalmente).
  **Arreglo importante**: el patrón de NothingLess (`Component.onCompleted` +
  `onLoaded`) carga el singleton de forma no determinista; se sustituyó por
  `FileView { blockLoading: true }` + un `Timer` de intervalo 0, que garantiza
  la carga. Sin eso la config se ignora en silencio y todo resolve() devuelve
  el valor global. Verificado con un `monitors.json` real: HDMI-A-1 → barra
  abajo, eDP-1 → barra a la izquierda, y los dominios sin override vuelven al
  global.
  Nota: si `monitors.json` no existe, QML avisa por consola igual que hace la
  config propia de Ambxst.
### Pendiente de portar (features)
| # | Feature | Archivos (NothingLess) | Excluido por backend Go? |
|---|---|---|---|
| F1 | Island de barra | `modules/bar/IslandContent.qml`, `BarContent.qml`, `config/defaults/bar.js` | no |
| ~~F2~~ | ~~Métricas en notch~~ ✅ **portado** | `MetricsGroup*.qml`, `DefaultView.qml`, `NotchMetrics.qml` | datos de `SystemResources` (Go) |
| ~~F3~~ | ~~Posiciones por monitor~~ ✅ **portado** | `modules/services/PerMonitorConfig.qml` | no |
| F4 | Wallpaper de vídeo + interpol + palette | `VideoWallpaperService.qml`, `GpuDetector.qml`, shaders `interpol.*`, `palette.*`, `Wallpaper.qml` | FPS real NO existe en Ambxst (solo `refreshRate` por monitor) |
| ~~F5~~ | ~~Tablero de tareas~~ ✅ **portado** | `modules/widgets/dashboard/todo/TodoTab.qml`, `TodoBoard.qml`, `Dashboard.qml` | no |
| F6 | Hax spotlight | `modules/widgets/spotlight/*` (5.2 k-linas), `Calculator.qml`, `PluginManager.qml` | no (proceso standalone) |
| ~~F7~~ | ~~Splash con logo~~ ❌ **descartado** | bloque splash de `shell.qml` | el usuario decidió no llevarlo |

### Explicitamente excluido (Ambxst ya lo hace mejor en Go; NO portar)
- **Clipboard** (`svc/clipboard` + sqlite cifrado + fts5 + wlr-data-control) — NothingLess usa bash+python.
- **Screenshot / thumbnails / recorder** (`internal/screenshot`, `thumbs_native.go`, `recorder`) — NothingLess usa python/ffmpeg.
- **OCR / QR** (`svc/ocr`: tesseract+gozxing en Go) — NothingLess usa scripts.
- **System monitor / FPS de juegos** (`svc/systemmonitor`) — NothingLess usa `system_monitor.py`/`fps_monitor.py` (776 l.). Usar `SystemResources`/`Screenshot` en su lugar.
- **Keystore / link preview / weather / night light / game mode / caffeine / power profile** (`svc/*`) — NothingLess reimplementa en QML/python.
- **Compositor**: `sync-hyprland.py` (1533 l., Hyprland-only) y las ~150 claves extra — Ambxst generaliza en `backend/pkg/svc/compositor` (multi-compositor). La parte de hyprctl ya está en el menú.
- **ScreenTranslation / MusicRecognizer**: huérfanos incluso en NothingLess.

## Backlog (no-prioritario)

- **Monitores**: "Identify" actualmente parpadea el canvas (no hay verbo
  `flash` en niri/hyprctl); mantener.
- **Compositor**: las 73 claves de NothingLess solo tienen vía en Hyprland
  (`hyprctl keyword`). En niri están ocultas de propósito (no hay interfaz de
  keywords en runtime). Documentar, no forzar.

## Referencia "no tocar" (lecciones de este repo)

- `property var x: { ... }` en QML es un binding a declaración de objeto, no
  un literal JS → usar `({ ... })`.
- `Layout.preferredHeight: child.implicitHeight` solo si el hijo no depende
  del ancho que se le asigna; si depende, QML rompe el ciclo con ancho 0 y la
  sección queda en blanco.
- `I18n.t()` cae en `humanize()` si la clave falta → el botón muestra el
  nombre de la clave. Traducciones siempre desde el conjunto real de claves.
- Los parches de este repo solo **insertan** líneas (salvo 4 ensanchamientos
  de condición en `SettingsTab`). No re-numerar `panelComponents`
  (`SettingsTab.qml` indexa por id de sección).