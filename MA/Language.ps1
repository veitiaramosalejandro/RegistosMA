<#
Language.ps1 - documented version 123.
Shared English/Portuguese UI dictionary and console helpers. Wrapper commands translate messages before calling the original PowerShell commands.

Conventions: State/Context arguments and $script: variables hold shared UI/session data.
Functions that save preferences or metadata write JSON; media work is delegated to external tools.
Comments describe the existing behavior; executable statements are unchanged.
#>
#Requires -Version 5.1
param([switch]$ChooseLanguage, [switch]$ChooseRecording, [switch]$StopMessage,
    [switch]$RecordingFinished, [switch]$RecordingAlreadyRunning, [switch]$ContinueOnly)

$script:UiConfigPath = Join-Path $PSScriptRoot 'config.json'
$script:UiLanguage = 'pt'
if (Test-Path -LiteralPath $script:UiConfigPath -PathType Leaf) {
    $uiConfig = Get-Content -LiteralPath $script:UiConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($uiConfig.Language -in @('en', 'pt')) { $script:UiLanguage = $uiConfig.Language }
}

$script:UiTranslations = [ordered]@{
    'Stopped' = 'Parada'
    'Paused' = 'Pausada'
    'Unknown' = 'Desconhecido'
    'Idle' = 'Inativa'
    'Running' = 'Em execução de programa'
    'Alarm' = 'Alarme'
    'Activity' = 'Atividade'
    'Inactive' = 'Inativa'
    'Warm-up' = 'Aquecimento'
    'Machining' = 'Maquinagem'
    'Tool change' = 'Troca de ferramenta'
    'Tool measurement' = 'Medição de ferramenta'
    'State' = 'Estado'
    'Recording extraction' = 'Extração de gravações'
    'Mark start for extraction' = 'Marcar início para extração'
    'Mark end for extraction' = 'Marcar fim para extração'
    'Clear markers for extraction' = 'Limpar marcações para extração'
    'Video alignment relative to audio in ms (positive advances video; negative delays video)' = 'Alinhamento do vídeo em relação ao áudio em ms (positivo adianta o vídeo; negativo atrasa o vídeo)'
    'not found beside the script, in the bin folder or on PATH.' = 'não encontrado junto do script, na pasta bin ou no PATH.'
    'Spectrogram' = 'Espectrograma'
    'Unable to set the console font size to 14: ' = 'Não foi possível definir o tamanho da fonte da consola para 14: '
    'Recording start' = 'Início da gravação'
    'Recording mode' = 'Modo de gravação'
    'Video + audio' = 'Vídeo + áudio'
    'Audio only' = 'Apenas áudio'
    'Camera only' = 'Apenas câmara'
    'Unknown mode' = 'Modo desconhecido'
    '(no metadata)' = '(sem metadata)'
    '(invalid metadata)' = '(metadata inválida)'
    'Spectrogram: L - Left / Ambient sound; R - Right / Spindle vibration' = 'Espectrograma: L - Esquerdo / Som ambiente; R - Direito / Vibração no fuso'
    'Spectrogram channel' = 'Canal do espectrograma'
    '(Enter accepts)' = '(Enter aceita)'
    'Choose L or R.' = 'Escolha L ou R.'
    'Spectrum gain (1 to 20; 1 = normal)' = 'Ganho do espectro (1 a 20; 1 = normal)'
    'Enter an integer between 1 and 20.' = 'Introduza um número inteiro entre 1 e 20.'
    'Arial was not found for chart labels.' = 'Arial não encontrada para as legendas.'
    'L - Ambient sound' = 'L - Som ambiente'
    'R - Spindle vibration' = 'R - Vibração no fuso'
    'Frequency spectrum' = 'Espectro de frequências'
    'Recording' = 'Gravação'
    'AudioBufferMilliseconds must be an integer from 0 to 2000; 0 uses the device default.' = 'AudioBufferMilliseconds deve ser um inteiro entre 0 e 2000; 0 usa a predefinição do dispositivo.'
    'Block' = 'Bloco'
    'Machining Monitor - Live recording' = 'Machining Monitor - Gravação em direto'
    'Machining Monitor - Recording' = 'Machining Monitor - Gravação'
    'Could not measure the screen; using a 720 pixel window.' = 'Não foi possível medir o ecrã; será usada uma janela de 720 píxeis.'
    'Live charts: L blue; R orange. Escape and pause keys (Space/P/S) are disabled. Closing the window does not stop recording. Use Parar_gravacao.bat.' = 'Gráficos em direto: L azul; R laranja. Escape e as teclas de pausa (Espaço/P/S) estão desativados. Fechar a janela não para a gravação. Use Parar_gravacao.bat.'
    'Charts unavailable; recording will continue: ' = 'Gráficos indisponíveis; a gravação vai continuar: '
    'Visualization ended. Recording continues; use Parar_gravacao.bat to stop it.' = 'A visualização terminou. A gravação continua; use Parar_gravacao.bat para a parar.'
    'Spectrum: L blue; R orange, fixed axes and averaging. Spectrogram: low to high frequencies left to right; history moves down. Space: pause; Escape: close.' = 'Espectro: L azul; R laranja, eixos fixos e média temporal. Espectrograma: graves à esquerda e agudos à direita; histórico desloca-se para baixo. Espaço: pausa; Escape: fechar.'
    'Could not protect the recording window from Escape.' = 'Não foi possível proteger a janela da gravação contra Escape.'
    'Recording folder [Enter uses default]' = 'Pasta das gravações [Enter usa a predefinida]'
    'Recording folder is not a directory: ' = 'O local de gravação não é uma pasta: '
    'Unable to set playback window width to 220 columns: ' = 'Não foi possível definir a janela da reprodução para 220 colunas: '
    'Available recordings:' = 'Gravações disponíveis:'
    'Press Escape when choosing a recording to exit.' = 'Prima Escape ao escolher uma gravação para sair.'
    'No recordings found. Press any key to refresh the list.' = 'Sem gravações. Prima uma tecla para atualizar.'
    'Selected recording: ' = 'Gravação escolhida: '
    'Playback finished. Returning to the recordings list...' = 'Reprodução terminada. A voltar à lista...'
    'Enter accepts the previous value; Ctrl+U clears it; Escape cancels context.' = 'Enter aceita o valor anterior; Ctrl+U limpa; Escape cancela o contexto.'
    'Recording metadata (Escape cancels without metadata)' = 'Metadados da gravação (Escape cancela sem metadados)'
    'General data' = 'Dados gerais'
    'Name' = 'Nome'
    'Type' = 'Tipo'
    'Material' = 'Material'
    'Length [mm]' = 'Comprimento [mm]'
    'RC (corner radius) [mm]' = 'RC (Raio de canto) [mm]'
    'Tool corner radius [mm]' = 'RC (Raio de canto) [mm]'
    'Teeth/inserts (cutting edges)' = 'Dentes/navalhas (arestas de corte)'
    'Estimated remaining use [%]' = 'Utilização restante estimada [%]'
    'Height [mm]' = 'Altura [mm]'
    'Diameter [mm]' = 'Diâmetro [mm]'
    'Invalid numeric value. Enter a number or leave blank.' = 'Valor numérico inválido. Introduza um número ou deixe vazio.'
    'Enter a non-negative number or leave blank.' = 'Introduza um número não negativo ou deixe vazio.'
    'The programmed value and percentage produce an invalid adjusted speed.' = 'O valor programado e a percentagem produzem uma velocidade ajustada inválida.'
    'The programmed speed is blank; automatic calculation is unavailable.' = 'A velocidade programada está vazia; o cálculo automático não está disponível.'
    'An adjusted speed cannot be nonzero when the programmed speed is zero.' = 'A velocidade ajustada tem de ser zero quando a velocidade programada é zero.'
    'These speeds produce an invalid percentage.' = 'Estas velocidades produzem uma percentagem inválida.'
    'The percentage cannot be calculated from a programmed speed of zero; it will remain blank.' = 'Não é possível calcular a percentagem com velocidade programada zero; ficará vazia.'
    'Could not send ''q'' to FFmpeg.' = 'Não foi possível enviar ''q'' ao FFmpeg.'
    'Stop requested. Sending ''q'' to FFmpeg...' = 'Paragem pedida. A enviar ''q'' ao FFmpeg...'
    'Use Parar_gravacao.bat to stop recording safely.' = 'Use Parar_gravacao.bat para parar a gravação em segurança.'
    'MP4 audio: camera audio converted to AAC' = 'Áudio MP4: áudio da câmara convertido para AAC'
    'Video: camera HEVC/H.265' = 'Vídeo: câmara HEVC/H.265'
    'Recording audio volume:' = 'Volume de áudio da gravação:'
    'Starting recording...' = 'A iniciar gravação...'
    'Recording finished.' = 'Gravação terminada.'
    'Could not start FFmpeg.' = 'Não foi possível iniciar FFmpeg.'
    'FFmpeg finished with exit code' = 'FFmpeg terminou com código'
    'Metadata saved to:' = 'Metadados guardados em:'
    'Output folder:' = 'Pasta de gravação:'
    'Block duration:' = 'Duração do bloco:'
    'Recording mode:' = 'Modo de gravação:'
    'Camera + Audio device' = 'Câmara + Dispositivo de áudio'
    'Audio device only' = 'Apenas dispositivo de áudio'
    'Choose 1 or 2' = 'Escolha 1 ou 2'
    'Machining parameters' = 'Parâmetros de maquinagem'
    'Programmed spindle speed [rpm]' = 'Velocidade programada do fuso [rpm]'
    'Adjusted spindle speed [rpm]' = 'Velocidade ajustada do fuso [rpm]'
    'Spindle speed adjustment [%]' = 'Ajuste do fuso [%]'
    'Programmed feed rate [mm/min]' = 'Avanço programado [mm/min]'
    'Adjusted feed rate [mm/min]' = 'Avanço ajustado [mm/min]'
    'Feed rate adjustment [%]' = 'Ajuste do avanço [%]'
    'Tool height [mm]' = 'Altura da ferramenta [mm]'
    'Tool diameter [mm]' = 'Diâmetro da ferramenta [mm]'
    'Tool material' = 'Material da ferramenta'
    'Tool type' = 'Tipo de ferramenta'
    'Part material' = 'Material da peça'
    'Recording folder' = 'Pasta da gravação'
    'No.' = 'Nº'
    'Review context' = 'Rever contexto'
    'C - Confirm entered data' = 'C - Confirmar os dados introduzidos'
    'R - Re-enter data' = 'R - Reintroduzir os dados'
    'Escape - Exit without saving data' = 'Escape - Sair sem guardar os dados'
    'Camera unavailable or timed out.' = 'A câmara não está acessível ou excedeu o tempo limite.'
    'Recording cancelled.' = 'Gravação cancelada.'
    'No recording data was produced. Metadata and defaults were not saved.' = 'Não foram produzidos dados de gravação. Os metadados e os valores anteriores não foram guardados.'
    'Machine' = 'Máquina'
    'Operator' = 'Operador'
    'Mould' = 'Molde'
    'Work' = 'Programa'
    'Program' = 'Programa'
    'Usage time at program start [hh:mm:ss]' = 'Tempo de uso no início do programa [hh:mm:ss]'
    'Operation' = 'Operação'
    'Strategy' = 'Estratégia'
    'Notes' = 'Notas'
    'Part' = 'Peça'
    'Tool' = 'Ferramenta'
    'Adjustment:' = 'Ajuste:'
    'Start    :' = 'Início   :'
    'End      :' = 'Fim      :'
    'Duration :' = 'Duração  :'
    'Mode:' = 'Modo:'
    'WAV audio:' = 'Áudio WAV:'
    ' minutes' = ' minutos'
    ' percent' = ' por cento'
    'Choose C, S or T' = 'Escolha C, S ou T'
    'C - Camera audio; S - External audio; T - Mixed audio' = 'C - Áudio da câmara; S - Dispositivo de áudio; T - Áudio misto'
    'Audio input from configuration:' = 'Entrada de áudio da configuração:'
    'Detecting DirectShow audio inputs...' = 'A detetar entradas de áudio DirectShow...'
    'Choose the audio input number' = 'Escolha o número da entrada de áudio'
    'Invalid number. Please try again.' = 'Número inválido. Tente novamente.'
    'Selected input:' = 'Entrada escolhida:'
    'Configuration saved.' = 'Configuração guardada.'
    'Save the video configuration?' = 'Guardar a configuração do vídeo?'
    'Save the audio configuration?' = 'Guardar a configuração do áudio?'
    'Camera RTSP URL' = 'URL RTSP da câmara'
    'Audio offset in ms (positive delays; negative advances)' = 'Offset do áudio em ms (positivo atrasa; negativo adianta)'
    'Enter an integer value in milliseconds.' = 'Introduza um valor inteiro em milissegundos.'
    'The offset applies to external audio; camera audio is unchanged.' = 'O offset será aplicado ao áudio externo; o áudio da câmara mantém-se.'
    'Continuous block playback. Escape closes the player.' = 'Reprodução contínua dos blocos. Escape fecha o leitor.'
    'Playback cancelled.' = 'Reprodução cancelada.'
    'External audio not found.' = 'Áudio externo não encontrado.'
    'The player exited with an error.' = 'O leitor terminou com erro.'
    'FFmpeg failed while preparing playback.' = 'FFmpeg terminou com erro ao preparar a reprodução.'
    'No audio or video files were found.' = 'Não foram encontrados ficheiros de áudio ou vídeo.'
    'Playback took too long to terminate.' = 'O processo de reprodução demorou a terminar.'
    'Timing list is incomplete; using file durations.' = 'Lista de tempos incompleta; serão usadas as durações dos ficheiros.'
    'Unable to determine screen size. Using a 960x540 window.' = 'Não foi possível medir o ecrã. Será usada uma janela de 960x540.'
    'Preview is open. Closing it does not stop recording.' = 'Pré-visualização aberta. Pode fechar a janela sem interromper a gravação.'
    'Context cancelled. No metadata.json was created. Audio and video files were preserved.' = 'Contexto cancelado. Não foi criado metadata.json. Os ficheiros de áudio e vídeo foram mantidos.'
    'Unable to read previous values. Fields will be blank.' = 'Não foi possível ler os últimos valores. Os campos serão apresentados vazios.'
    'Unable to authorize recording-window activation.' = 'Não foi possível autorizar a ativação da janela da gravação.'
    'Unable to identify the batch window for focus restoration.' = 'Não foi possível identificar a janela do batch para devolver o foco.'
    'Unable to restore focus to the batch window.' = 'Não foi possível devolver o foco à janela do batch.'
    'Windows did not allow batch-window activation. Click it to enter the context.' = 'O Windows não permitiu ativar a janela do batch. Clique nela para preencher o contexto.'
    'Unable to open preview:' = 'Não foi possível abrir a pré-visualização:'
    ' Recording continues.' = ' A gravação continua.'
    'Unable to close preview:' = 'Não foi possível fechar a pré-visualização:'
    'Unable to save previous values:' = 'Não foi possível guardar os últimos valores:'
    'Unable to start the player.' = 'Não foi possível iniciar o leitor.'
    'Detection exceeded 30 seconds.' = 'A deteção excedeu 30 segundos.'
    'No DirectShow device found. Check drivers and dshow support.' = 'Nenhum dispositivo DirectShow encontrado. Verifique os controladores e o suporte dshow.'
    'Invalid camera URL. Use rtsp:// or rtsps:// with the camera address.' = 'URL da câmara inválido. Use rtsp:// ou rtsps:// com o endereço da câmara.'
    'AudioDevice contains invalid characters.' = 'AudioDevice contém caracteres inválidos.'
    'The device name contains invalid characters.' = 'O nome do dispositivo contém caracteres inválidos.'
    'PreviewVideo must be true or false in config.json.' = 'PreviewVideo deve ser true ou false no config.json.'
    'AudioVolumePercent must be between 0 and 1000. 100 preserves the original volume.' = 'AudioVolumePercent deve ser um número entre 0 e 1000. 100 mantém o volume original.'
    'SegmentMinutes must be greater than 0 and at most 1440 (minutes).' = 'SegmentMinutes deve ser um número maior que 0 e até 1440 (minutos).'
    'A console is required to cancel context with Escape.' = 'O contexto requer uma consola interativa para permitir cancelar com Escape.'
    'Error:' = 'Erro:'
    'No recording is running.' = 'Não existe nenhuma gravação em curso.'
    'A recording is already running, or an old state file remains.' = 'Já existe uma gravação em curso, ou ficou um ficheiro de estado antigo.'
    'If you are sure no recording is running, delete recording.pid.' = 'Se tiver a certeza de que não está a gravar, apague recording.pid.'
    'Press any key to continue...' = 'Prima uma tecla para continuar...'
    'Machining Monitor - Recording Preview' = 'Machining Monitor - Pré-visualização da gravação'
    'Machining Monitor - Playback' = 'Machining Monitor - Reprodução'
    'ffplay.exe was not found beside the script or on PATH.' = 'ffplay.exe não encontrado junto do script ou no PATH.'
    'FFmpeg was not found. Place ffmpeg.exe beside Gravar_Sessoes.ps1 or on PATH.' = 'FFmpeg não encontrado. Coloque ffmpeg.exe junto do Gravar_Sessoes.ps1 ou no PATH.'
    'The list must be opened through Gerir_Gravacoes.bat.' = 'A lista deve ser iniciada pelo Gerir_Gravacoes.bat.'
    'Unable to read ' = 'Não foi possível ler '
    'Unable to read JSON file ' = 'Não foi possível ler o ficheiro JSON '
    'The file must contain a valid JSON object.' = 'O ficheiro deve conter um objeto JSON válido.'
    'Unable to save configuration to ' = 'Não foi possível guardar a configuração em '
    'The property ' = 'A propriedade '
    ' in config.json must be text.' = ' do config.json deve ser texto.'
    ' was not found beside the script or on PATH.' = ' não encontrado junto do script ou no PATH.'
    'Unable to start ' = 'Não foi possível iniciar '
    ' must be an integer between -3600000 and 3600000 milliseconds.' = ' deve ser um número inteiro entre -3600000 e 3600000 milissegundos.'
    'Missing recording folder ' = 'Pasta da gravação '
    ' is missing.' = ' em falta.'
    '[invalid metadata.json]' = '[metadata.json inválido]'
    '[no metadata.json]' = '[sem metadata.json]'
}

# Translate known interface strings using the selected language dictionary.
function Get-UiText {
    param([AllowEmptyString()][string]$Text)
    # Normalize existing Portuguese messages before choosing the output language.
    $keys = @($script:UiTranslations.Keys | Sort-Object Length -Descending)
    foreach ($key in $keys) { $Text = $Text.Replace($script:UiTranslations[$key], $key) }
    if ($script:UiLanguage -eq 'pt') {
        foreach ($key in $keys) { $Text = $Text.Replace($key, $script:UiTranslations[$key]) }
    }
    return $Text
}

# Apply the selected language's formatting culture to the current execution context.
function Set-UiCulture {
    $name = 'pt-PT'
    if ($script:UiLanguage -eq 'en') { $name = 'en-GB' }
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($name)
}
Set-UiCulture

# Translate console output before forwarding it to PowerShell's original Write-Host command.
function Write-Host {
    param([Parameter(Position=0)][object]$Object, [switch]$NoNewline,
        [ConsoleColor]$ForegroundColor, [ConsoleColor]$BackgroundColor)
    if ($Object -is [string]) { $PSBoundParameters['Object'] = Get-UiText $Object }
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}
# Translate warning text before forwarding it to PowerShell's warning stream.
function Write-Warning {
    param([Parameter(Position=0)][string]$Message)
    Microsoft.PowerShell.Utility\Write-Warning (Get-UiText $Message)
}
# Translate the input prompt before calling PowerShell's original Read-Host command.
function Read-Host {
    param([Parameter(Position=0)][string]$Prompt)
    Microsoft.PowerShell.Utility\Read-Host -Prompt (Get-UiText $Prompt)
}

# Format UI preference JSON for readable storage.
function Format-UiJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $builder = New-Object System.Text.StringBuilder

    $indentLevel = 0
    $inString = $false
    $isEscaped = $false

    for ($i = 0; $i -lt $Json.Length; $i++) {

        $char = $Json[$i]

        if ($inString) {

            [void]$builder.Append($char)

            if ($isEscaped) {
                $isEscaped = $false
            }
            elseif ($char -eq '\') {
                $isEscaped = $true
            }
            elseif ($char -eq '"') {
                $inString = $false
            }

            continue
        }

        switch ($char) {

            '"' {
                $inString = $true
                [void]$builder.Append($char)
            }

            '{' {
                [void]$builder.Append('{')
                [void]$builder.AppendLine()

                $indentLevel++

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )
            }

            '[' {
                [void]$builder.Append('[')
                [void]$builder.AppendLine()

                $indentLevel++

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )
            }

            '}' {
                [void]$builder.AppendLine()

                $indentLevel--

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )

                [void]$builder.Append('}')
            }

            ']' {
                [void]$builder.AppendLine()

                $indentLevel--

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )

                [void]$builder.Append(']')
            }

            ',' {
                [void]$builder.Append(',')
                [void]$builder.AppendLine()

                [void]$builder.Append(
                    ('  ' * $indentLevel)
                )
            }

            ':' {
                [void]$builder.Append(': ')
            }

            default {
                [void]$builder.Append($char)
            }
        }
    }

    return $builder.ToString()
}

# Load or request the preferred interface language and apply it.
function Select-UiLanguage {
    $default = '2'
    if ($script:UiLanguage -eq 'en') { $default = '1' }
    do {
        $choice = Microsoft.PowerShell.Utility\Read-Host "Language / Idioma: 1 - English; 2 - Português [Enter = $default]"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $default }
    } while ($choice -notin @('1','2'))
    $script:UiLanguage = 'pt'
    if ($choice -eq '1') { $script:UiLanguage = 'en' }
    Set-UiCulture
    $config = [pscustomobject]@{}
    if (Test-Path -LiteralPath $script:UiConfigPath) {
        $config = Get-Content -LiteralPath $script:UiConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $config -or $config -isnot [pscustomobject]) { throw 'Invalid config.json / config.json inválido.' }
    }
    $config | Add-Member NoteProperty Language $script:UiLanguage -Force
    [IO.File]::WriteAllText($script:UiConfigPath, (Format-UiJson ($config | ConvertTo-Json -Depth 20 -Compress)) + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false)))
    Clear-Host
}

# Adjust console dimensions for the interactive workflow.
function Set-ConsoleHeight {
    $consoleUi = $Host.UI.RawUI
    $window = $consoleUi.WindowSize
    $buffer = $consoleUi.BufferSize
    if ($buffer.Height -lt 40) {
        $buffer.Height = 40
        $consoleUi.BufferSize = $buffer
    }
    $window.Height = 40
    $consoleUi.WindowSize = $window
}

# Shared by recording, playback, recording selection and stop-command consoles.
# Run the guarded application workflow. Catch reports failures; finally releases the resources allocated by this workflow.
try { Set-ConsoleHeight } catch {
    # Noninteractive hosts and terminals that manage their own size retain it.
}

if ($ChooseLanguage) {
    Select-UiLanguage
    if ($script:UiLanguage -eq 'en') { exit 1 }; exit 2
}
# Read a recording-selection choice from the console.
function Read-RecordingChoice {
    $max = [int]$env:COUNT
    while ($true) {
        $prompt = "Choose a recording [1-$max]; N/Right: next page; P/Left: previous; Escape: exit: "
        if ($script:UiLanguage -eq 'pt') { $prompt = "Escolha a gravação [1-$max]; N/Direita: seguinte; P/Esquerda: anterior; Escape: sair: " }
        Write-Host $prompt -NoNewline
        $text = ''
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape) { Write-Host ''; return 0 }
            if ($key.Key -in @([ConsoleKey]::N, [ConsoleKey]::RightArrow, [ConsoleKey]::PageDown)) { Write-Host ''; return 2147483646 }
            if ($key.Key -in @([ConsoleKey]::P, [ConsoleKey]::LeftArrow, [ConsoleKey]::PageUp)) { Write-Host ''; return 2147483645 }
            if ($key.Key -eq [ConsoleKey]::Enter) { Write-Host ''; break }
            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($text.Length) { $text = $text.Substring(0,$text.Length-1); Write-Host "`b `b" -NoNewline }
            }
            elseif ($key.KeyChar -match '[0-9]' -and $text.Length -lt 9) {
                $text += $key.KeyChar; Write-Host ([string]$key.KeyChar) -NoNewline
            }
        }
        $number = 0
        if ([int]::TryParse($text,[ref]$number) -and $number -ge 1 -and $number -le $max) { return $number }
        if ($script:UiLanguage -eq 'pt') { Write-Host 'Escolha inválida. Tente novamente.' }
        else { Write-Host 'Invalid selection. Please try again.' }
    }
}

if ($ChooseRecording) { exit (Read-RecordingChoice) }
if ($StopMessage) {
    if ($script:UiLanguage -eq 'pt') { Write-Host 'Pedido de paragem enviado. A janela da gravação será ativada para preencher o contexto.' }
    else { Write-Host 'Stop requested. The recording window will be activated for context entry.' }
}
if ($RecordingFinished -or $RecordingAlreadyRunning -or $ContinueOnly) {
    if ($RecordingAlreadyRunning) {
        Write-Host 'A recording is already running, or an old state file remains.'
        Write-Host 'If you are sure no recording is running, delete recording.pid.'
    }
    elseif ($RecordingFinished) { Write-Host 'Recording finished.' }
    Write-Host 'Press any key to continue...' -NoNewline
    [void][Console]::ReadKey($true)
    Write-Host ''
}

# Position the console window near the center of the screen.
function Center-ConsoleWindow {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if (-not ('MachiningMonitor.ConsolePosition' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
    public static class ConsolePosition {
        [StructLayout(LayoutKind.Sequential)]
        public struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    }
}
"@ -ErrorAction Stop
        }
        $window = [MachiningMonitor.ConsolePosition]::GetConsoleWindow()
        if ($window -eq [IntPtr]::Zero -or -not [MachiningMonitor.ConsolePosition]::IsWindowVisible($window)) { return }
        $rect = New-Object MachiningMonitor.ConsolePosition+Rect
        if (-not [MachiningMonitor.ConsolePosition]::GetWindowRect($window, [ref]$rect)) { return }
        $area = [Windows.Forms.Screen]::FromHandle($window).WorkingArea
        $x = $area.Left + [int][Math]::Max(0, [Math]::Floor(($area.Width - ($rect.Right - $rect.Left)) / 2))
        $y = $area.Top + [int][Math]::Max(0, [Math]::Floor(($area.Height - ($rect.Bottom - $rect.Top)) / 2))
        # NOSIZE | NOZORDER | NOACTIVATE: change only the window position.
        [void][MachiningMonitor.ConsolePosition]::SetWindowPos($window, [IntPtr]::Zero, $x, $y, 0, 0, 0x15)
    } catch {
        # Hosts without a standalone console retain their window position.
    }
}

# Apply the console font size used by the application.
function Set-ConsoleFontSize {
    if (-not ('MachiningMonitor.ConsoleFont' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace MachiningMonitor {
    public static class ConsoleFont {
        [StructLayout(LayoutKind.Sequential)] public struct Coord { public short X, Y; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct FontInfo {
            public uint Size, Index; public Coord Cell; public uint Family, Weight;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Face;
        }
        [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr GetStdHandle(int handle);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] private static extern bool GetCurrentConsoleFontEx(IntPtr output, bool maximum, ref FontInfo font);
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] private static extern bool SetCurrentConsoleFontEx(IntPtr output, bool maximum, ref FontInfo font);
        public static void SetHeight(short height) {
            IntPtr output = GetStdHandle(-11);
            FontInfo font = new FontInfo(); font.Size = (uint)Marshal.SizeOf(typeof(FontInfo));
            if (!GetCurrentConsoleFontEx(output, false, ref font)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (font.Cell.Y == height) return;
            // Keep the existing typeface/weight; let Windows choose its width for this height.
            font.Cell.X = 0; font.Cell.Y = height;
            if (!SetCurrentConsoleFontEx(output, false, ref font)) throw new Win32Exception(Marshal.GetLastWin32Error());
            FontInfo actual = new FontInfo(); actual.Size = font.Size;
            if (!GetCurrentConsoleFontEx(output, false, ref actual)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (actual.Cell.Y != height) throw new InvalidOperationException("The console font does not support the requested size.");
        }
    }
}
'@ -ErrorAction Stop
    }
    [MachiningMonitor.ConsoleFont]::SetHeight(14)
}

