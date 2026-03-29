# WinAdmin Tool — Contexto para Claude Code

## Descripción
Herramienta de administración de sistemas Windows. SPA local que arranca un servidor HTTP PowerShell y abre el navegador automáticamente. Requiere ejecutarse como Administrador en Windows 10/11.

## Stack
- **Frontend**: `index.html` — HTML + CSS + JS todo en un único fichero (~197 KB)
- **Backend**: `server.ps1` — PowerShell, HttpListener, puerto 8080
- **Lanzador**: `INICIAR.bat` — copia ficheros a C:\WinAdminTool\, espera servidor, abre Edge/Chrome
- **Demo sin servidor**: `winadmin-sim.html` — misma UI con datos mock generados en el navegador

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

## Convenciones del frontend (index.html)

### Navegación
- `navigate(section)` muestra/oculta secciones y dispara la carga lazy de datos
- Cada sección: `<section id="section-X" class="section">` — activa con clase `.active`
- Lazy loading: flags booleanos `usersLoaded`, `drivesLoaded`, etc.

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
- Para búsquedas cancelables usar `fsAbortCtrl` (AbortController global del módulo PST)

### Patrón de módulo nuevo
1. Añadir ítem al sidebar: `<div class="nav-item" data-section="X" onclick="navigate('X')">`
2. Añadir sección HTML: `<section id="section-X" class="section">...</section>`
3. Flag de estado: `let xLoaded = false;`
4. En `navigate()`: `if (section === 'X' && !xLoaded) loadX();`
5. Funciones JS: `async function loadX()`, `function renderX(data)`
6. Clave i18n en `LANG.es` y `LANG.en`

## Convenciones del backend (server.ps1)

### Funciones helper disponibles
```powershell
Send-Response $ctx $data          # Responde JSON (code 200 por defecto)
Send-Response $ctx $data 400      # Responde con código HTTP específico
Read-Body $request                # Lee el body de un POST (devuelve string)
Get-FolderSize -Path "C:\ruta"    # Tamaño recursivo de carpeta (long)
Format-Bytes -Bytes 1234567       # Formatea bytes a "1.18 MB"
Write-Log "mensaje"               # Log a winadmin_debug.log
```

### Patrón de endpoint nuevo
```powershell
# 1. Función de lógica (antes del bloque HTTP Server)
function Get-MiModulo {
    # lógica...
    return @{ dato = "valor" }
}

# 2. Registro en el switch del router (dentro del bloque HTTP Server)
"/api/mi-endpoint" {
    $result = Get-MiModulo
    Send-Response $ctx $result
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
GET  /api/user-size           # Tamaño perfil (?user=nombre)
GET  /api/user-folders        # Carpetas de usuario (?user=nombre)
GET  /api/drives              # Unidades disponibles
POST /api/format              # Formatear unidad { drive, label, fs }
GET  /api/cleanup-preview     # Ítems de limpieza disponibles
GET  /api/cleanup-size        # Tamaño ítem limpieza (?id=catId)
POST /api/cleanup             # Ejecutar limpieza { items: [...] }
GET  /api/scan-files          # Buscar ficheros (?drives=C,D&exts=.pdf)
POST /api/copy-pst            # Copiar ficheros { files, dest }
GET  /api/browse              # Navegar filesystem (?path=C:\ruta)
POST /api/recycle             # Papelera { paths: [...] }
GET  /api/local-users         # Usuarios locales Windows
POST /api/local-user-create   # Crear usuario { username, password, fullname }
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
GET  /api/evlog               # Eventos (?src=System&hours=24&levels=Error)
GET  /api/stop                # Detener servidor
```

## Requisitos del sistema
- Windows 10 / Windows 11
- PowerShell 5.1+ (incluido por defecto)
- Ejecutar como **Administrador** (necesario para formateo, gestión usuarios, Event Log de seguridad, release/renew IP)
- Puerto **8080** libre

## Fichero de demo (winadmin-sim.html)
Replica la UI completa con datos mock. **Si añades un módulo nuevo o cambias la UI, actualiza también este fichero** con los datos simulados correspondientes. Los mocks de rendimiento usan `_simCpu` y `_simRam` con variación aleatoria.

## Mejoras pendientes (roadmap)
- 🔧 Gestión de servicios Windows (iniciar/detener/deshabilitar)
- 🖨️ Gestión de impresoras y colas de impresión
- 🔔 Notificaciones toast para feedback de acciones
- 📦 Separar index.html en módulos (CSS + JS independientes)
- 🧪 Tests con Pester para funciones PowerShell del backend
