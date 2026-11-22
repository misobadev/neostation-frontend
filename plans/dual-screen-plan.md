# Plan: intercambio de pantallas en handhelds de doble pantalla

Estado: investigación y plan. La fase 2 está implementada (ver su sección); el resto, no. Rama: `feat/dual-screen-swap` (desde `origin/main`, `a91f2f0b`).

Dispositivos objetivo: AYN Thor, Retroid Pocket 6 y "AYN 2 Portal" (ver 1.3: no existe con dos pantallas).

> El archivo vive en `plans/` y no en `docs/`, a propósito: `docs/` es la wiki pública (`wiki.neostation.dev`, just-the-docs), y todo `.md` que llega ahí se publica.

Leyenda de fuentes: **[C]** confirmado en una fuente, **[I]** inferido, **[?]** sin verificar. Los enlaces están al final.

---

## 0. Punto de partida: lo que ya hace el código

NeoStation **ya tiene doble pantalla**, pero en un solo sentido: la UI principal arriba y el panel secundario abajo.

| Pieza | Archivo | Qué hace |
|---|---|---|
| Plugin vendorizado | `packages/sub_screen/` | `MultiDisplayFlutterActivity` + `FlutterPresentation`. Cuando aparece un display distinto de `DEFAULT_DISPLAY`, crea un **segundo `FlutterEngine`** (del mismo `FlutterEngineGroup`) dentro de una `android.app.Presentation` en ese display. El estado entre engines viaja por `SharedState` (snapshots JSON por MethodChannel). |
| Actividad | `android/app/src/main/kotlin/com/neogamelab/neostation/MainActivity.kt` | Extiende `MultiDisplayFlutterActivity`. Tiene el canal `.../secondary_display` (mostrar u ocultar el panel), un `DisplayListener` propio y `launchPackageOnSecondaryDisplay()`, que usa `ActivityOptions.setLaunchDisplayId()` para el dock de apps. |
| Presentation | `.../SecondaryAppsPresentation.kt` | `setCancelable(false)`, `FLAG_NOT_FOCUSABLE \| FLAG_ALT_FOCUSABLE_IM` y se traga BACK. Tiene su canal propio, `.../secondary_apps`. |
| Entrada del engine 2 | `lib/main.dart` → `subDisplay()` | `runApp(SecondaryScreen(...))` con su propio idioma, tema, SFX y `ScreenUtilInit(640x480)`. |
| UI secundaria | `lib/screens/secondary_screen/` | Now Playing, arte, video, logros de RA, dock de apps y scraping. Solo táctil. |
| Estado compartido | `lib/models/secondary_display_state.dart` | Unos 50 campos que el engine principal empuja al secundario. |
| Ajustes | `lib/screens/settings_screen/new_settings_options/secondary_settings_content.dart`, `lib/providers/sqlite_config_provider/secondary_display.dart` | Dim, logo, dock, acceso a capturas y `hide_bottom_screen`. |
| Vigilancia del display 2 | `.../ScreenshotAccessibilityService.kt` | `startWatch(pkg, displayId)` detecta cuándo se cierra la app del dock. |
| Notas nativas | `android/CLAUDE.md` | En el Thor la pantalla de abajo es el **display 4**. Detrás de la Presentation corre `com.android.launcher3/.secondarydisplay.SecondaryDisplayLauncher`. |

El código da por hechas tres cosas, y son justo las que un intercambio rompe:

1. **La actividad principal vive en el display 0.** `MultiDisplayHandler.subDisplay` es "el primer display que no es el default", y `MainActivity.setSecondaryDisplayVisible()` y `launchPackageOnSecondaryDisplay()` repiten esa regla (`firstOrNull { it.displayId != DEFAULT_DISPLAY }`).
2. **La Presentation nunca tiene foco de teclas** (`FLAG_NOT_FOCUSABLE`). Así todo el gamepad llega a `MainActivity.dispatchKeyEvent`, y vale porque la UI secundaria es solo táctil.
3. **Los emuladores se lanzan sin `ActivityOptions`.** `EmulatorLauncher.kt:265` hace `context.startActivity(intent)`, así que Android los abre en el display de quien llama.

Por eso "intercambiar pantallas" no parte de cero: es **hacer que ese sistema no dependa de que la UI principal esté en el display 0**.

---

## 1. ¿Es posible en Android?

**Sí.** Abajo, qué hace falta.

### 1.1 APIs de Android

- **`DisplayManager`**: `getDisplays()` y `registerDisplayListener()`. Ya se usan. Los ids no son estables: en el Thor el de abajo es el 4, así que **no hay que fijarlos en el código**. [C]
- **`ActivityOptions.makeBasic().setLaunchDisplayId(id)`** (API 26+): abre una actividad en un display concreto. Sin esa opción, se abre en el display de quien llama. [C]
  - Desde Android 10, una app normal puede lanzar en displays físicos públicos. Las restricciones son para displays virtuales o privados ajenos. Antes de lanzar se puede consultar `ActivityManager.isActivityStartAllowedOnDisplay()`. [C]
  - ES-DE, Cannoli y Loki lo hacen como apps normales, sin permisos especiales, para abrir emuladores en la otra pantalla. [C]
  - NeoStation ya lo hace en el dock (`launchPackageOnSecondaryDisplay`).
- **Mover una tarea ya abierta de un display a otro**: no hay API pública para apps normales (`moveTaskToDisplay` es interna). [I] En la práctica, "mover" NeoStation significa **relanzar su actividad en el otro display**.
- **`resizeableActivity="false"` + `screenOrientation="landscape"`** (nuestro manifest): no impide abrir en un display secundario físico. Una actividad no redimensionable ocupa todo ese display. [C] Los 1240x1080 de abajo del Thor ya son apaisados, así que no hay conflicto con `landscape`. [I]
- **`Presentation`**: es un `Dialog` sobre un display ajeno al de su actividad dueña. Sirve para contenido de salida y toque, pero no recibe foco como una actividad, y muere con su dueña. [C]
- **Foco y teclas (Android 10+)**: hay un solo **display con foco** global, el último con el que se interactuó. Las teclas que no van ligadas a un display, incluido el gamepad, van a la ventana con foco de ese display. `config_perDisplayFocusEnabled` es para coches y AOSP no lo recomienda en otros equipos. [C] En el Thor el mando "sigue a la última pantalla tocada", lo que indica que el foco por display está apagado. [I]

### 1.2 Flutter con varios displays

- Flutter **no tiene multi-ventana ni multi-vista oficial en Android** a fecha de hoy. La API de ventanas nueva es para escritorio. [C/?]
- El patrón estándar es el que ya usamos: un segundo `FlutterEngine` (punto de entrada `@pragma('vm:entry-point')`) dentro de una `Presentation`, o dentro de una segunda `FlutterActivity` lanzada con `setLaunchDisplayId`. [C]
- `FlutterEngineGroup` comparte el contexto de GPU, las fuentes y el snapshot, unos 180 kB por engine extra. **No** comparte estado, plugins, cachés de imagen ni texturas. [C] Por eso ya tenemos `SharedState` y canales propios en la Presentation.
- La UI principal está ligada al engine de `MainActivity`. **Relanzar la actividad en otro display es, para Flutter, un arranque nuevo del engine principal**: se pierde la navegación y el estado en memoria, como cuando se reinicia la app. [I, por cómo `MultiDisplayFlutterActivity` crea el engine desde el grupo en cada `onCreate`]

### 1.3 Cómo expone el Thor la segunda pantalla

- **Arriba**: 6", AMOLED, 1920x1080, 120 Hz, **display 0 (default)**. **Abajo**: 3.92", AMOLED táctil, 1240x1080 (~1.15:1, casi cuadrada), 60 Hz, **display 4** en nuestros logs. Android 13. [C]
- **El firmware ya tiene "Screen Launch" por app.** Al mantener pulsado el icono de una app se elige Auto, Top o Bottom. El menú del botón AYN controla qué pantallas están encendidas, el brillo de cada una y en qué pantalla está cada tarea. Mantener pulsado el botón apaga la de abajo. [C]
- **No hay un interruptor global de "swap"** documentado. Hubo un "Focus Mode" en prototipos. [?]
- Problemas conocidos [C]:
  - El mando controla la última pantalla tocada.
  - El foco salta solo de pantalla.
  - El teclado sale en la pantalla equivocada (`ime_show_on_second`, que ya está en `android/CLAUDE.md`).
  - El botón AYN no manda ningún evento que una app pueda leer.
  - Solo se puede capturar el display 0.
- **AYN 2 Portal**: no existe un modelo con dos pantallas con ese nombre. El más cercano es el **Odin 2 Portal**: una pantalla OLED de 7" con salida de video por USB-C. [C] Para nosotros es como el RP6 con monitor externo.
- **Retroid Pocket 6**: una pantalla de 5.5" 1080p, salida DP por USB-C, y el accesorio **Dual Screen Add-on** (5.5" 1080p por USB-C). [C] Ahí la pantalla del equipo es el display 0 y el accesorio es externo y **se puede desconectar en caliente**, al revés que en el Thor. [I]

### 1.4 Veredicto

| Variante | ¿Posible? | Cómo |
|---|---|---|
| Elegir **en qué pantalla se abren los juegos** | Sí, fácil | `setLaunchDisplayId` en `EmulatorLauncher` (lo que hizo ES-DE 3.4) |
| **Intercambiar pantallas** (UI principal abajo, panel arriba) | Sí, con coste | Relanzar `MainActivity` en el otro display y poner la Presentation en el display libre. El engine principal reinicia. |
| Hacer el intercambio **sin reiniciar** la UI | No, en la práctica | No hay API pública para mover la tarea, y un engine no puede saltar de ventana entre displays sin recrear la superficie |
| Intercambiar **qué muestra** cada engine sin mover ventanas | No conviene | Los dos engines no son simétricos: el principal tiene todos los providers y la base de datos, y el secundario es un visor ligero |

---

## 2. Dificultad y riesgos

Dificultad total del intercambio real: **media-alta**. La parte de "elegir pantalla para los juegos" es **baja**.

| Riesgo | Detalle | Mitigación |
|---|---|---|
| **Foco del gamepad** | Con la UI principal abajo, el display 4 tiene que ser el display con foco. Tocar la pantalla de arriba (la Presentation, `FLAG_NOT_FOCUSABLE`) en principio **no** mueve el foco, porque una ventana no enfocable no puede ser el destino. [I] Tocar otra app arriba sí lo mueve, y es el problema conocido del Thor. | Mantener `FLAG_NOT_FOCUSABLE` en la Presentation esté donde esté. Probar en el equipo: tocar arriba y comprobar que el D-pad sigue llegando a `dispatchKeyEvent`. El `GamepadNavigationManager` no cambia, porque las teclas siguen llegando a la misma actividad. |
| **HOME con NeoStation como launcher** | El `HOME` del display 0 apunta a `MainActivity`. Si la actividad está en el 4, pulsar HOME puede relanzarla en el 0 (`singleInstance`) y deshacer el intercambio, o abrir el selector de launcher. [I] El `SECONDARY_HOME` del display 4 es Quickstep (`SecondaryDisplayLauncher`). | En `onCreate`/`onNewIntent`, si el display actual no es el preferido, relanzar una vez con un guardia anti-bucle. Valorar declarar `SECONDARY_HOME` como hace Loki (eso es la fase 4, no ahora). Cannoli tuvo un bucle de reinicios por cambiar el foco en el touch-down. |
| **ScreenUtil por display** | Las dos UIs usan `designSize 640x480`. La principal en 1240x1080 escala por `min(w/640, h/480)`, y el layout aguanta un ~1.15:1 [I], pero **la pantalla mide 3.92"**: todo se verá físicamente pequeño y algunas rejillas de 16:9 quedarán apretadas. La secundaria arriba, en 16:9 a 6", deja barras o huecos laterales en paneles pensados para casi cuadrado. | Revisar con `logDisplayMetrics` (ya existe) en las dos posiciones. Es posible que haga falta un ajuste de escala de texto para la UI principal en pantallas pequeñas. Revisar los `background_builders` del panel secundario en 16:9. |
| **Ciclo de vida** | El relanzamiento destruye el engine principal. La Presentation ya sobrevive a reinicios del engine principal (`clearStaleSecondaryNowPlaying`), pero se tiene que recrear en el otro display. Hay música, scraping, subidas de NeoSync y el reloj de sesión en curso. | Solo permitir el intercambio en reposo: sin juego abierto, sin scraping ni sync activos. Pedir confirmación como en `restart_required_dialog.dart`. |
| **Supuestos "display 0 = principal"** | `MultiDisplayHandler`, `setSecondaryDisplayVisible`, `launchPackageOnSecondaryDisplay` y el `DisplayListener` de `MainActivity` (que ignora `DEFAULT_DISPLAY`). Si el firmware abre NeoStation abajo (Screen Launch = Bottom), **hoy la Presentation se intentaría crear en el mismo display 4** de la actividad. [I] | La fase 1 lo corrige: "secundario = cualquier display que no sea el de la actividad". |
| **Emuladores en el display elegido** | Si la tarea del emulador ya existe en el otro display, puede quedarse ahí (lo vio Cannoli). Los emuladores de DS/3DS (melonDS, DraStic, Azahar) usan las dos pantallas con su propia configuración. RetroArch y la mayoría solo usan una. | Opción "misma pantalla que NeoStation / pantalla grande / la otra", con `isActivityStartAllowedOnDisplay` y vuelta al display 0. Valorar `CLEAR_TASK` solo cuando el display cambia. Para DS/3DS, siempre arriba (la pantalla grande) y dejar que el emulador gestione la de abajo. |
| **Panel tapando la app** | Si un juego se abre en el display de la Presentation, esta (un `TYPE_PRESENTATION`) lo tapa. Es el mismo caso que ya resuelve `hideSecondaryForApp`. | Reusar `hideSecondaryForApp`/`ScreenshotAccessibilityService.startWatch` con el display de destino real. |
| **Display que se desconecta (RP6 + accesorio)** | Al quitar el accesorio, Android mueve sus actividades al display 0 con un cambio de configuración. [C] | Con `configChanges` ya declarados no se recrea la actividad. Hay que volver el modo a "normal" y no relanzar mientras el preferido no exista. |
| **Pruebas** | El usuario prueba en un Retroid Pocket, que tiene una sola pantalla. | AVD con varios displays: en el emulador, Extended controls → Displays, o `adb shell settings put global overlay_display_devices 1240x1080/240`. Los overlay displays pueden comportarse distinto que uno físico [?]. **La prueba final tiene que ser en un Thor.** |

---

## 3. Alternativas mejores, o complementarias

1. **Mostrar contenido secundario en la otra pantalla en lugar de intercambiar.** Es lo que ya hacemos: arte, video, logros, dock. Es el patrón de ES-DE Companion, Blip y el panel de detalle de Loki. [C] **Ya está resuelto**: el valor nuevo está en lo que sigue.
2. **Dejar que lo haga el sistema.** El "Screen Launch → Bottom" del Thor ya sirve para poner NeoStation abajo, **siempre que NeoStation no asuma el display 0** (fase 1). Es el intercambio más barato, y sin reinicio propio, porque el sistema abre la app directamente allí.
3. **Elegir la pantalla de los juegos.** Es lo que hizo ES-DE: "Launch games on the other screen" en 3.4.0, y por sistema o por juego en 3.5.0. [C] Para el usuario del Thor suele ser lo que de verdad quiere (menú abajo y juego arriba), sin mover NeoStation.
4. **Intercambio dentro de la app.** Loki tiene un interruptor de intercambio y un tile de ajustes rápidos, con modos auto, dual, una sola pantalla y couch. Cocoon 3.1 dice permitir cambiar de pantalla al vuelo. [C] Es lo más completo y también lo más caro.

Qué hacen los demás:

| Frontend | Doble pantalla | ¿Intercambio? |
|---|---|---|
| ES-DE | Dibuja en una sola pantalla. Puede abrir los juegos en la otra (por sistema o por juego desde 3.5.0). | Solo para los juegos |
| ES-DE Companion | App aparte en la otra pantalla. Lee `es_log.txt` y muestra arte, video, manuales y un dock. | Puede abrir apps en "esta" o "la otra" pantalla |
| Loki (Thor-Launcher) | Rejilla en una pantalla y detalle en la otra. HOME en los dos displays. | **Sí**: interruptor y tile |
| Cocoon | UI estilo 3DS | "Swap" en la beta 3.1 [?] |
| Blip | Arte, manual e info abajo | No |
| Beacon | Una sola pantalla | No |
| Daijisho | Sin funciones de doble pantalla | No |
| Launcher de AYN | Screen Launch por app y menú de pantallas | Por app, a nivel del sistema |

---

## 4. Enfoque recomendado

**Hacerlo por capas, de lo más barato a lo más caro, y parar donde el valor ya compense:**

1. Hacer NeoStation **agnóstica al display**, para que el "Screen Launch" del Thor funcione ya.
2. Añadir **la pantalla de destino de los juegos**.
3. Solo después, el **intercambio dentro de la app** con relanzamiento.

### Fase 0: medir en el Thor (sin código)

- `adb shell dumpsys display | grep -E "mDisplayId|mBaseDisplayInfo"` y `dumpsys activity activities` con NeoStation arriba y con Screen Launch = Bottom.
- Anotar qué pasa hoy con Screen Launch = Bottom: si la Presentation choca con la actividad, si el gamepad funciona y qué hace HOME.
- Anotar `logDisplayMetrics` de las dos UIs.
- Resultado: una nota en `android/CLAUDE.md` con lo observado.

### Fase 1: roles de display, en lugar de "default = principal" (esfuerzo S)

- Un helper en Kotlin, `DisplayRoles`:
  - `mainDisplay` = el display de la actividad (`activity.display` en API 30+, `windowManager.defaultDisplay` antes).
  - `secondaryDisplay` = el otro display público. Si hay más de uno, el de **tamaño físico** más distinto (como Cannoli: píxeles / densidad).
- Usarlo en:
  - `packages/sub_screen/.../MultiDisplayHandler.kt`: `subDisplay` y `onDisplayAdded`/`onDisplayRemoved` dejan de comparar con `DEFAULT_DISPLAY`. Pasar el display de la actividad desde `init(activity)`.
  - `MainActivity.kt`: `setSecondaryDisplayVisible`, `launchPackageOnSecondaryDisplay` (pasa a ser "la otra pantalla") y el `DisplayListener`.
  - `ScreenshotAccessibilityService.kt`: recibe el id real, sin cambios de lógica.
- Exponer a Dart `getDisplayRoles()` (ids, tamaños, cuál es la grande) por el canal `.../secondary_display`.
- Resultado: con Screen Launch = Bottom, NeoStation abajo y el panel arriba, sin escribir el intercambio.

### Fase 2: pantalla de destino de los juegos (esfuerzo S-M) — implementada

> **Estado:** implementada en `feat/dual-screen-swap`, sin commit y sin probar en un Thor. Se eligió hacer solo esta fase.
>
> Diferencias con el diseño de abajo:
>
> - **No hay ajuste global.** Por defecto, el juego se abre en la pantalla 0, sin enviar nada (igual que antes).
> - **Por sistema:** un interruptor "Abrir juegos en la pantalla secundaria" en la pestaña General de los ajustes del sistema. Solo aparece si hay segunda pantalla y en sistemas reales, no en Todos, Favoritos ni colecciones.
> - **Por juego:** una sección "Pantalla" en la pestaña Emulador de los ajustes del juego, con tres opciones: Por defecto del sistema, Pantalla principal y Pantalla secundaria. El ajuste del juego gana sobre el del sistema.
> - **Datos:** una tabla propia, `user_launch_display (scope, target, display)` (migración v192), en lugar de columnas en `user_system_settings`/`user_roms`. Así no hay que propagarla por todas las consultas de carga. La lógica está en `lib/services/launch_display_service.dart`.
> - **Nativo:**
>   - `launch_display` ("primary" o "secondary") viaja en `launchGenericIntent`.
>   - `EmulatorLauncher.startOnDisplay` usa `ActivityOptions.setLaunchDisplayId` con `isActivityStartAllowedOnDisplay`. Si Android lo rechaza, lanza normal.
> - **Fin de sesión.** Un juego en la otra pantalla no pausa `MainActivity`. Por eso `startGameOnOtherDisplay` guarda la hora de inicio y cierra la sesión con lo primero que llegue: el watch de accesibilidad (la ventana del juego deja su display) o que NeoStation recupere el foco (`onTopResumedActivityChanged`). Ignora los primeros 5 s. Si el juego va a la pantalla del panel Now Playing, lo oculta como hace el dock y lo restaura al salir.
> - **Pendiente de verificar en el equipo:**
>   - Que el foco del mando pase al juego y vuelva a NeoStation al salir.
>   - Que un emulador que ya tenía su tarea abierta en la otra pantalla respete el display pedido. Si no, valorar `FLAG_ACTIVITY_CLEAR_TASK` solo cuando cambia el display.
>   - Que sin el servicio de accesibilidad tocar la pantalla de NeoStation a mitad de partida cierra la sesión. Es una limitación conocida, porque Flutter ya la cerraba con ese mismo evento.

Diseño original:

- Ajuste global "Abrir juegos en": *La misma pantalla que NeoStation* (por defecto, que es el comportamiento de hoy), *La pantalla grande* o *La otra pantalla*.
- `EmulatorLauncher.kt`: acepta un `launchDisplayId` opcional y crea `ActivityOptions` con `isActivityStartAllowedOnDisplay`. Si falla, vuelve al display de la actividad.
- Si el destino es el display de la Presentation, llamar a `hideSecondaryForApp` antes de lanzar y restaurar al volver.
- Dart:
  - `lib/services/game_launch_manager.dart` / `lib/utils/game_launch_utils.dart`: resolver el display de destino.
  - `lib/models/config_model.dart`, `lib/data/datasources/sqlite_migrations.dart`, `sqlite_config_service.dart`: una columna nueva, `game_launch_display`.
  - `secondary_settings_content.dart`: una fila nueva. Ojo con el orden de índices del gamepad, que está documentado en la cabecera de la clase.
  - `lib/l10n/app_locale*.dart`: textos en los 12 idiomas.
- Más adelante, si se pide: un override por sistema (`system_emulator_settings_dialog`), como ES-DE 3.5.

### Fase 3: "Intercambiar pantallas" dentro de la app (esfuerzo M-L, con riesgo)

- Preferencia persistente `main_ui_display`: `auto` o `large` (arriba en el Thor) / `small` (abajo). Se guarda **por rol, no por id**, porque los ids cambian.
- Acción "Intercambiar pantallas", en Ajustes → Pantalla secundaria, y quizá en el menú rápido:
  1. Solo en reposo: sin juego, scraping ni sync activos.
  2. Confirmación del tipo "La interfaz se reiniciará en la otra pantalla".
  3. Guardar la preferencia, cerrar la Presentation, `startActivity(intent propio, setLaunchDisplayId(otro))` y `finish()`.
- En `MainActivity.onCreate` y `onNewIntent`: si la preferencia indica otro display y ese display existe, relanzar **una vez**, con un guardia por extra del intent o un timestamp, para cubrir HOME y los arranques en frío.
- La Presentation se crea siempre en el display que deja libre la actividad (gracias a la fase 1). Se mantiene `FLAG_NOT_FOCUSABLE`.
- Layout:
  - Revisar la UI principal a 1240x1080 / 3.92": rejillas, cabecera, diálogos. Valorar un factor de escala de UI propio para pantallas pequeñas.
  - Revisar el panel secundario a 1920x1080: `lib/screens/secondary_screen/background_builders.dart`, `widgets/now_playing_panel.dart`, `widgets/app_dock.dart`.
- Si el display preferido desaparece (RP6 + accesorio), volver solos a `auto` sin relanzar.

### Fase 4 (opcional): integración más profunda

- Un tile de ajustes rápidos para intercambiar, como Loki.
- Declarar `SECONDARY_HOME` para ser launcher también en la pantalla de abajo. Requiere una segunda actividad y engine, y cambia mucho el modelo actual de Presentation.
- Pantalla de destino por juego.

### Archivos que se tocarían

| Fase | Archivos |
|---|---|
| 1 | `packages/sub_screen/android/src/main/kotlin/com/hcoderlee/subscreen/sub_screen/MultiDisplayHandler.kt`, `MultiDisplayFlutterActivity.kt`; `android/app/src/main/kotlin/com/neogamelab/neostation/MainActivity.kt`, nuevo `DisplayRoles.kt`; `lib/providers/sqlite_config_provider/secondary_display.dart`; `android/CLAUDE.md` |
| 2 | `EmulatorLauncher.kt`, `MainActivity.kt`; `lib/services/game_launch_manager.dart`, `lib/utils/game_launch_utils.dart`; `lib/models/config_model.dart`, `lib/data/datasources/sqlite_migrations.dart`, `sqlite_config_service.dart`, `sqlite_service.dart`; `secondary_settings_content.dart`; `lib/l10n/app_locale*.dart`; tests en `test/` para la migración y la resolución del display |
| 3 | `MainActivity.kt`, `SecondaryAppsPresentation.kt`; `lib/screens/settings_screen/new_settings_options/secondary_settings_content.dart`; `lib/widgets/restart_required_dialog.dart` (reusar); `lib/screens/secondary_screen/**` (layout 16:9); config y migración (`main_ui_display`); l10n |

### Orden y criterio de parada

- **Fase 0 + 1** se pueden hacer ya: son pocas líneas, arreglan un caso real (Screen Launch = Bottom) y no cambian nada para quien no toca el firmware.
- **Fase 2** es lo que más piden los usuarios del Thor, y es lo que copió ES-DE.
- **Fase 3** solo si, tras la fase 1, el Screen Launch del firmware no basta (por ejemplo, si HOME lo deshace siempre). Su coste real está en el layout de la UI principal a 3.92" y en el reinicio del engine.

---

## Fuentes

- Android, lanzamiento en varios displays: https://source.android.com/docs/core/display/multi_display/activity-launch
- Android, displays y foco: https://source.android.com/docs/core/display/multi_display/displays
- Android, displays conectados: https://developer.android.com/develop/ui/compose/layouts/adaptive/support-connected-displays
- Flutter, varios engines: https://docs.flutter.dev/add-to-app/multiple-flutters
- Pantallas del AYN Thor: https://www.androidauthority.com/ayn-thor-screen-size-3589297
- Guía de configuración del Thor (Screen Launch, botón AYN): https://retrohandhelds.gg/ayn-thor-setup-guide/
- Guía de handhelds Android de doble pantalla: https://retrogamecorps.com/2025/10/27/dual-screen-android-handheld-guide/
- Cannoli, roles por tamaño y foco: https://kennethreitz.org/essays/2026-07-18-teaching_cannoli_which_screen_is_home
- Loki / Thor-Launcher: https://github.com/Prof-Mags/Thor-Launcher
- Changelog de ES-DE: https://gitlab.com/es-de/emulationstation-de/-/raw/master/CHANGELOG.md
- ES-DE Companion: https://github.com/RobZombie9043/es-de-companion
- Beta 3.1 de Cocoon: https://androidauthority.com/cocoon-3-1-beta-update-3728453
- Blip: https://retrododo.com/blip-is-a-new-android-frontend-designed-for-dual-screen-devices/
- Odin 2 Portal: https://androidcentral.com/gaming/android-games/ayn-odin-2-portal-announced
- Retroid Pocket 6 y Dual Screen Add-on: https://www.notebookcheck.net/New-Retroid-Pocket-6-hands-on-shows-compatibility-with-secondary-display-accessory.1199974.0.html
