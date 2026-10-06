# Ax-Less — Pendientes

Plan de trabajo para `axless.core`. Lo verificado y funcionando está abajo;
lo pendiente, ordenado por valor por unidad de riesgo.

## NC — Bug conocido y no resuelto (monitores)

### 1. Arrastre entre pantallas exige "insistir" con el ratón

**Síntoma (reportado por el usuario):** hay que insistir con el ratón para
desplazar un monitor de un lado al otro; no se mueve con un único gesto limpo.

**Qué ya se descartó:**

- *Fórmula del arrastre*: la de NothingLess (`pcx` capturado en `onPressed`,
  restado de `mouse.x + monItem.x`) es correcta — verificada por simulación
  paso a paso, no por intuición. La variante de solo-delta-dentro-de-la-caja
  está rota y NO debe volver.
- *Límite de X*: ahora permite un ancho de monitor de margen a cada lado
  (`[-3072, 3072]` para un vecino de 1536). No bloquea colocaciones con aire.
- *Imantado*: 16 px arrastrando / 24 px al soltar, en unidades lógicas.
- *Coordenadas negativas*: se pasan con `--`, niri las acepta.
- *Escala*: `pixelsAreLogical` es correcto en niri (píxeles) y en
  Hyprland/Mango (÷scale).

**Líneas a investigar (en orden):**

1. **`dRY` y el agarre** — si el punto de agarre se desplaza hacia arri/abajo
   `y` al arrastrar, el monitor "pelea" y hay que re-presionar. Comprobar que
   `pcy` se captura una vez y que `onPositionChanged` no reasigna `pcy`.
2. **El `monItem` persigue al cursor, no el modelo** — `dragX`/`dragY` son
   copias; el `MouseArea` está sobre `monItem`. Si el `mouse` sale del `Item`
   durante el arrastre (cursor rápido), `onPositionChanged` deja de darse y el
   `Item` no crece. Con un escritorio de 3656 px a escala ~0.11 los monitores
   son pequeños (50-150 px) y a alta velocidad el cursor se les escapa fácil.
   Solución probable: usar `drag.target` de QML (`MouseArea.drag.target:
   monItem`) con `drag.axis` y `drag.threshold`, o capturar la posición global
   del ratón (QMLE tiene `Grabber` local; en `MouseArea` hay
   `mouse.accepted` y se puede rastrear con `containsMouse`), y hacer que el
   `MouseArea` cubra todo el canvas mientras `dragging`.
3. **Ratio de traducción** — confirmar que la posición del compositor tras el
   arrastre coincide con el punto de agarre (no con la esquina) comparando
   `monItem` en pantalla contra `niri msg --json outputs` después del solt.

**Cómo probarlo:** en los pasos 2-3, mostrar un `console.log` en
`onPositionChanged`/`onPressed`/`onReleased` con `mouse.x`, `monItem.x`,
`pcx`, `dRX`, `newX` y comparar contra el log de `apply()` al soltar.

---

## Implementación pendiente (features de NothingLess)

| # | Feature | Archivos fuente (NothingLess) | Notas |
|---|---|---|---|
| F1 | **Island de barra** | `modules/bar/IslandContent.qml`, `BarContent.qml` (`barMode`, `Loader` island), `config/defaults/bar.js` | Sin resolver el NC-1 no tocar `BarContent` (conflicto con parche). |
| F2 | **Métricas en el notch** | `modules/widgets/defaultview/MetricsGroup.qml`, `MetricsGroupWrapper.qml`, `DefaultView.qml` (`metricsActive`), `Notch.qml`, `NotchContent.qml` | Usar `SystemResources` de Ambxst para los datos, NO `system_monitor.py`. |
| F3 | **Posiciones por monitor** | `modules/services/PerMonitorConfig.qml` | Depende de NC-1 porque la UI de colocación por pantalla comparte el canvas. |
| F4 | **Motor de wallpaper de vídeo + interpol + palette** | `VideoWallpaperService.qml`, `GpuDetector.qml`, shaders `interpol.*`, `palette.*`, `Wallpaper.qml` | FPS real: Ambxst **no tiene** fuente de FPS, solo `refreshRate` por monitor desde `axctl` (sin usar). Los `.qsb` se generan con `qsb` (incluido en el sistema), hay que compilarlos. No tocar `Wallpaper.qml` si F2 lo toca. |
| F5 | **Tablero de tareas** | `modules/widgets/dashboard/todo/TodoTab.qml`, `TodoBoard.qml`, `Dashboard.qml` (tab 4) | El más limpio: 3 inserciones append-only en `Dashboard.qml`. |
| F6 | **Hax spotlight** | `modules/widgets/spotlight/*` (5227 líneas), `Calculator.qml`, `PluginManager.qml` | Proceso standalone (`qs -n -p spotlight_entry.qml`), apenas toca el árbol. Necesita subcomando `ambxst spotlight`. |
| F7 | **Splash con el logo del shell** | `shell.qml` (bloque splash) + `assets/ambxst/*.svg` | Usar `assets/ambxst/ambxst-icon.svg` / `ambxst-logo.svg`, no el `NOTHING_splash.webp`. |

## Parchado / mantenimiento

- `path/settings-i18n.patch` → su contenido le muevo a `settings-i18n` cuando
  se genere una feature nueva que añada claves. Las traducciones se generan
  desde el conjunto real de claves usadas por el payload (ver commit de
  "traducciones completas"). Nunca insertar claves sueltas a mano.

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