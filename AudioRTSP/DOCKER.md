# AudioRTSP Web + Docker Linux

La aplicación web está implementada con React/Vite y Node.js. El contenedor usa Linux, FFmpeg y MediaMTX. No depende de Windows PowerShell.

## Ejecutar

```powershell
Copy-Item .env.example .env
docker compose build --pull
docker compose up -d
docker compose ps
```

Panel: `http://localhost:8080`  
RTSP: `rtsp://localhost:8554/audio`

La configuración se conserva en el volumen `audiortsp-data`.

## Fuente de audio

Por defecto se usa un tono de prueba para garantizar que el contenedor funcione sin hardware. Para audio real en Linux, el dispositivo debe exponerse al contenedor y configurarse con ALSA, por ejemplo:

```yaml
    devices:
      - /dev/snd:/dev/snd
```

```env
TEST_TONE=false
AUDIO_DEVICE=default
```

## Captura de audio de Windows

El contenedor Linux no puede leer directamente los drivers DirectShow de Windows. Para capturar la entrada de la PC anfitriona se incluye un agente Node nativo:

```powershell
$env:FFMPEG_BIN = 'C:\ruta\a\ffmpeg.exe'
$env:AUDIO_AGENT_PORT = '8090'
node .\host-agent\index.js
```

Después configura en `.env`:

```env
TEST_TONE=false
AUDIO_AGENT_URL=http://host.docker.internal:8090
AUDIO_DEVICE=
```

La web consultará `/devices` del agente, mostrará las entradas DirectShow de Windows y el agente publicará el audio hacia MediaMTX dentro del contenedor. Si se utiliza `AUDIO_AGENT_TOKEN`, debe establecerse el mismo valor en el agente y en `.env`.

Para iniciarlo automáticamente después de reiniciar Windows, mantén el mismo puerto en
`AUDIO_AGENT_PORT` y `AUDIO_AGENT_URL` del archivo `.env` y ejecuta una vez:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-AudioRTSPHostAgentTask.ps1
```

La tarea `AudioRTSP Host Agent` se ejecuta al iniciar sesión. Docker continúa ejecutando la
web y MediaMTX; el agente es necesario porque un contenedor Linux no puede acceder directamente
a los drivers DirectShow de Windows.

## Diagnóstico

```powershell
docker compose logs -f audiortsp
curl.exe http://localhost:8080/api/health
docker inspect --format '{{json .State.Health}}' audiortsp
```

Una respuesta saludable confirma la API, pero hay que probar la URL RTSP con VLC o FFplay para validar reproducción real.
