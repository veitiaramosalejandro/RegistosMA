# Metadata en la URL RTSP de reproducción

Cuando la emisión de audio está activa y se pulsa Play en una grabación, MA publica una única URL RTSP con dos pistas RTP:

- `trackID=0`: `MPEG4-GENERIC/48000/{canales}`, audio AAC.
- `trackID=1`: `x-machining-metadata/1000`, aplicación RTP propia de MA.

La vista de configuración existente no cambia. La autenticación configurada en esa vista protege la lectura de ambas pistas. La publicación interna de FFmpeg solo se acepta desde loopback.

## Payload de metadatos

Cada mensaje ocupa uno o más paquetes RTP. Se concatena el payload RTP de los paquetes de una misma marca RTP y se interpreta así:

```text
4 bytes: ASCII MAM1
4 bytes: longitud JSON, UInt32 big-endian
N bytes: JSON UTF-8
```

El consumidor debe reensamblar por `sequence` RTP y utilizar la marca `marker` del último fragmento. El campo `sequence` dentro del JSON es independiente del número de secuencia RTP.

## Mensajes

Los mensajes contienen `type`, `recordingId`, `timestampSeconds` y `sequence`.

- `stream_start`: datos completos de `metadata.json` y duración.
- `snapshot`: contexto, parámetros y calidad efectivos en la posición indicada.
- `event`: una entrada de `events.json` cuando se cruza su timestamp.
- `stream_pause` / `stream_resume`: cambio de reproducción.
- `stream_seek`: reposicionamiento; el consumidor debe esperar el `snapshot` siguiente.
- `stream_end`: final de reproducción.

Los tiempos son segundos relativos a la reproducción y corresponden a `time_reference: playback_seconds`.
