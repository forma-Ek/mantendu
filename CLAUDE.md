# Mantendu — Contexto para Claude Code

## Descripción
Herramienta de administración de sistemas Windows. SPA local que arranca un servidor HTTP PowerShell y abre el navegador automáticamente. Requiere ejecutarse como Administrador en Windows 10/11.

Publicada en GitHub: https://github.com/forma-Ek/mantendu
Landing page + demo online: mantendu.vercel.app
Descarga: `https://github.com/forma-Ek/mantendu/releases/latest/download/Mantendu_v1.0.zip`

## Ficheros del proyecto
| Fichero | Descripción |
|---|---|
| `app.html` | SPA principal (~71 KB minificado en ZIP como `index.html`) |
| `server.ps1` | Servidor HTTP PowerShell, puerto 8080 |
| `INICIAR.bat` | Lanzador: copia a `C:\WinAdminTool\`, arranca servidor, abre Edge/Chrome |
| `index.html` | Landing page estática para Vercel (no es la app) |
| `winadmin-sim.html` | Demo offline con datos mock (publicada en Vercel) |
| `Mantendu_v1.0.zip` | Paquete de distribución: contiene `index.html` (= app.html), `server.ps1`, `INICIAR.bat` |

> **INICIAR.bat**: si existe `app.html` (repo clonado) lo copia como `index.html` a `C:\WinAdminTool\`. Si solo existe `index.html` (ZIP descargado) lo usa directamente.

## Módulos (sidebar, en orden)
| ID sección | Emoji | Nombre | Función JS principal |
|---|---|---|---|
| `users` | 👤 | Usuarios del sistema + Usuarios locales | `loadUsers()`, `loadLocalUsers()` |
| `format` | 💾 | Formateo de unidades | `loadDrives()`, `executeFormat()` |
| `cleanup` | 🧹 | Limpieza del sistema | `loadCleanup()`, `executeCleanup()` |
| `pst` | 🔍 | Buscador de ficheros | `scanFiles()`, `copyPst()` |
| `network` | 🌐 | Red y diagnóstico | `loadNetwork()`, `doPing()` |
| `perf` | 📊 | Monitor de rendimiento | `startPerf()`, `perfTick()` |
| `evlog` | 📋 | Visor de eventos (Event Log) | `evLoadSource()`, `evLoadCounts()` |
| `printers` | 🖨️ | Impresoras | `loadPrinters()`, `renderPrinters()` |
| `services` | ⚙️ | Servicios Windows | `loadServices()`, `renderServicesFiltered()` |
| `datacopy` | 📦 | Copia de datos | `initDataCopy()`, `dcBrowseTo()`, `dcStartCopy()` |

## Convenciones del frontend (app.html)

### Navegación
- `navigate(section)` muestra/oculta secciones y dispara la carga lazy de datos
- Cada sección: `<section id="section-X" class="section">` — activa con clase `.active`
- Lazy loading: flags booleanos `usersLoaded`, `drivesLoaded`, `servicesLoaded`, `printersLoaded`, etc.
- `usersLoaded` y demás flags se ponen a `true` **dentro del bloque try, después de renderizar**, nunca antes

### i18n
- Diccionario: objeto `LANG = { es: { ... }, en: { ... } }` al inicio del JS
- Función `t(key)` para traducir. Etiquetas en HTML usan `data-i18n="clave"`
- `setLang(lang)` cambia idioma y refresca con `refreshDynamicLabels()`
- **Siempre añadir claves nuevas en AMBOS idiomas** (`es` y `en`)

### Llamadas a la API
```js
const data = await api.get('/api/endpoint');           // GET
const data = await api.post('/api/endpoint', payload); // POST con JSON
```
- Ambos métodos usan `AbortController` internamente

### Paths de Windows en onclick HTML — CRÍTICO
**Nunca usar `escAttr()` para paths de Windows en atributos onclick.**
Las backslashes en strings JS dentro de HTML se interpretan como escapes y se pierden silenciosamente.
Usar siempre `jsStr()` para paths en onclicks:
```js
// MAL: onclick="fn('${escAttr(path)}')"  → 'C:\Users' se convierte en 'C:Users'
// BIEN: onclick="fn('${jsStr(path)}')"   → 'C:\\Users' funciona correctamente
function jsStr(s) { return String(s).replace(/\\/g,'\\\\').replace(/'/g,"\\'"); }
```

### Patrón de módulo nuevo
1. Añadir ítem al sidebar: `<div class="nav-item" data-section="X" onclick="navigate('X')">`
2. Añadir sección HTML: `<section id="section-X" class="section">...</section>`
3. Flag de estado: `let xLoaded = false;`
4. En `navigate()`: `if (section === 'X' && !xLoaded) loadX();`
5. Funciones JS: `async function loadX()`, `function renderX(data)` — poner `xLoaded = true` solo tras render exitoso
6. Clave i18n en `LANG.es` y `LANG.en`

## Convenciones del backend (server.ps1)

### Funciones helper disponibles
```powershell
Send-Response $ctx $data              # Responde JSON (code 200)
Send-Response $ctx $data 400          # Con código HTTP específico
Send-Response $ctx $data -AsArray     # OBLIGATORIO cuando la función devuelve un array
Read-Body $request                    # Lee el body de un POST (devuelve string)
Get-FolderSize -Path "C:\ruta"        # Tamaño recursivo de carpeta (long)
Format-Bytes -Bytes 1234567           # Formatea bytes a "1.18 MB"
Write-Log "mensaje"                   # Log a server_debug.log
```

### `-AsArray` — CRÍTICO para endpoints que devuelven listas
PowerShell **desenvuelve** arrays de un solo elemento al pasar como argumento, y arrays vacíos `@()` se convierten en `$null`. Sin `-AsArray`, `ConvertTo-Json` serializa como `{...}` o `null` en lugar de `[...]`, y el frontend falla con `Array.isArray()`.

```powershell
# MAL: si hay 1 usuario devuelve {"Name":"..."} en vez de [{"Name":"..."}]
Send-Response $ctx (Get-SystemUsers)

# BIEN: siempre devuelve [...]
Send-Response $ctx (Get-SystemUsers) -AsArray
```

Todos los endpoints que devuelven arrays ya usan `-AsArray`: `/api/users`, `/api/drives`, `/api/local-users`, `/api/cleanup-preview`, `/api/scan-files`, `/api/network`, `/api/evlog`, `/api/services`, `/api/printers`, `/api/printer-jobs`, `/api/printer-drivers`.

### Rutas raíz de unidad — CRÍTICO
`Get-BrowsePath` no hace `TrimEnd("\")` en rutas raíz (`C:\`, `D:\`). En PowerShell, `C:` sin backslash apunta al directorio actual del proceso, no a la raíz de la unidad.

### Patrón de endpoint nuevo
```powershell
# 1. Función de lógica (antes del bloque HTTP Server)
function Get-MiModulo {
    $items = Get-Something | ForEach-Object { [PSCustomObject]@{ ... } }
    return @($items)   # wrap en array siempre
}

# 2. Router (dentro del switch)
"/api/mi-endpoint" {
    Send-Response $ctx (Get-MiModulo) -AsArray   # -AsArray si devuelve lista
}
```

### Body de POST
```powershell
$body   = Read-Body $req | ConvertFrom-Json
$campo  = $body.campo
```

## Endpoints API (resumen)
```
GET  /api/health              # Health check
GET  /api/users               # Perfiles C:\Users
GET  /api/user-size           # Tamaño perfil (?username=nombre)
GET  /api/user-folders        # Carpetas de usuario (?username=nombre)
GET  /api/drives              # Unidades disponibles
POST /api/format              # Formatear unidad { drive, label, filesystem }
GET  /api/cleanup-preview     # Ítems de limpieza disponibles
GET  /api/cleanup-size        # Tamaño ítem limpieza (?id=catId)
POST /api/cleanup             # Ejecutar limpieza { items: [...] }
GET  /api/scan-files          # Buscar ficheros (?drive=C&exts=.pdf&minsize=0)
POST /api/copy-pst            # Copiar ficheros { files, destination }
GET  /api/browse              # Navegar filesystem (?path=C:\ruta)
POST /api/recycle             # Papelera { paths: [...] }
GET  /api/local-users         # Usuarios locales Windows
POST /api/local-user-create   # Crear usuario { username, password, fullname, isAdmin, noPassword }
POST /api/local-user-delete   # Eliminar usuario { username }
POST /api/local-user-toggle   # Habilitar/deshabilitar { username, enable }
POST /api/local-user-password # Cambiar contraseña { username, password }
GET  /api/network             # Adaptadores de red
POST /api/flush-dns           # ipconfig /flushdns
POST /api/release-ip          # Release IP { adapter }
POST /api/renew-ip            # Renew IP { adapter }
POST /api/ping                # Ping { host, count }
GET  /api/perf                # Snapshot CPU/RAM/Disco/Red/Procesos
POST /api/kill-process        # Matar proceso { pid }
GET  /api/evlog               # Eventos (?log=System&level=2&days=7&maxevents=500&ids=)
GET  /api/printers            # Lista de impresoras
GET  /api/printer-jobs        # Trabajos de impresora (?printer=nombre)
POST /api/printer-default     # Establecer impresora por defecto { printer }
POST /api/printer-delete      # Eliminar impresora { printer }
POST /api/printer-queue-clear # Vaciar cola { printer }
POST /api/printer-job-cancel  # Cancelar trabajo { printer, jobId }
POST /api/printer-add         # Añadir impresora TCP/IP { name, ip, driver }
GET  /api/printer-drivers     # Drivers instalados
GET  /api/services            # Lista de servicios Windows
POST /api/service-start       # Iniciar servicio { service }
POST /api/service-stop        # Detener servicio { service }
POST /api/service-restart     # Reiniciar servicio { service }
POST /api/service-starttype   # Cambiar tipo inicio { service, startType }
POST /api/datacopy-preview    # Calcular tamaño copia { paths: [...] }
POST /api/datacopy-start      # Iniciar copia { sources: [...], dest }
GET  /api/datacopy-progress   # Progreso de copia en curso
POST /api/datacopy-cancel     # Cancelar copia en curso
POST /api/datacopy-verify     # Verificar copia { sources: [...], dest }
GET  /api/stop                # Detener servidor
```

## Módulo datacopy — notas de implementación
- La copia corre en un `Start-Job` de PowerShell en background
- El progreso se escribe en `$env:TEMP\mantendu_copy_progress.json` y se lee vía polling cada 1s
- `dcShowSourceDrives()` lista unidades al entrar por primera vez (no arranca en `C:\Users`)
- `dcBrowseUp()` al estar en raíz de unidad vuelve al listado de unidades

## Módulo evlog — notas de implementación
- Rango por defecto: **7 días** (no 1 día — en equipos sin errores recientes 24h da vacío)
- `evLoaded` solo controla si ya se cargó al navegar; el botón "Refresh" lo resetea
- Fuentes con `id:[...]` (boot, bsod) omiten el filtro Level en server.ps1 (esperado)

## Despliegue
- `C:\WinAdminTool\` — directorio de trabajo del servidor en máquina del técnico
- `C:\WinAdminTool\server.ps1` — servidor activo; **reiniciarlo tras cambios** (cerrar ventana "WinAdmin-Servidor" y volver a ejecutar `INICIAR.bat`)
- Para actualizar solo la UI sin reiniciar el servidor: copiar `app.html` como `C:\WinAdminTool\index.html` y recargar el navegador

## Publicación en GitHub / Vercel
- Repo: `git push origin main` → Vercel redeploya automáticamente la landing + demo
- Release ZIP: eliminar asset anterior y subir nuevo via GitHub API (ver historial de conversación)
- El ZIP contiene: `index.html` (= contenido de `app.html`), `server.ps1`, `INICIAR.bat`

## Requisitos del sistema
- Windows 10 / Windows 11
- PowerShell 5.1+ (incluido por defecto)
- Ejecutar como **Administrador**
- Puerto **8080** libre

## Fichero de demo (winadmin-sim.html)
Replica la UI completa con datos mock. Si añades un módulo nuevo o cambias la UI, actualiza también este fichero con los datos simulados correspondientes.

## Roadmap pendiente
- 📦 Separar app.html en módulos (CSS + JS independientes)
- 🧪 Tests con Pester para funciones PowerShell del backend
- 🔔 Toast notifications más elaboradas (progreso, undo)
