# Portuguese/English labels and notices for the portable AudioRTSP interface.
$script:AudioLanguage='pt'
$languagePath=Join-Path $PSScriptRoot 'config.json'
if(Test-Path -LiteralPath $languagePath){
    try{$languageConfig=Get-Content -LiteralPath $languagePath -Raw | ConvertFrom-Json
        if($languageConfig.PSObject.Properties['Language'] -and $languageConfig.Language -in @('pt','en')){$script:AudioLanguage=$languageConfig.Language}
    }catch{}
}
$script:AudioEnglish=@{
    'Serviço não instalado'='Service not installed'
    'Serviço em execução'='Service running'
    'Serviço parado'='Service stopped'
    'Serviço a mudar de estado...'='Service changing state...'
    'Instalar serviço'='Install service'
    'Desinstalar serviço'='Uninstall service'
    'Iniciar serviço'='Start service'
    'Parar serviço'='Stop service'
    'Arrancar automaticamente com o Windows'='Start automatically with Windows'
    'O servidor RTSP não arrancou. Verifique a porta e a configuração de acesso.'='The RTSP server did not start. Check the port and access settings.'
    'Transmissão interrompida. Verifique a placa de som e a rede e volte a iniciar.'='Streaming stopped. Check the sound card and network, then start again.'
    'Verifique a placa de som, as permissões do microfone e a ligação de rede.'='Check the sound card, microphone permissions and network connection.'
    'Exigir utilizador e palavra-passe'='Require username and password'
    'Utilizador'='Username'
    'Palavra-passe'='Password'
    'Em branco: mantém a palavra-passe guardada.'='Leave blank to keep the saved password.'
    'Guardar acesso'='Save access'
    'Configuração de acesso guardada.'='Access settings saved.'
    'Defina um utilizador sem espaços, dois-pontos ou caracteres de controlo.'='Enter a username without spaces, colons or control characters.'
    'Defina uma palavra-passe antes de ativar a autenticação.'='Set a password before enabling authentication.'
    'A opção de autenticação deve ser true ou false.'='Authentication must be true or false.'
    'Introduza o utilizador e a palavra-passe de acesso.'='Enter the access username and password.'
    'A palavra-passe não pode estar vazia nem conter dois-pontos ou caracteres de controlo.'='The password must not be empty or contain colons or control characters.'
    'Escolha a entrada da placa de som que pretende transmitir.'='Choose the sound card input to stream.'
    'Entrada de áudio'='Audio input'
    'Atualizar entradas'='Refresh inputs'
    'Rede / endereço IP de transmissão'='Network / streaming IP address'
    'Atualizar redes'='Refresh networks'
    'Porta RTSP'='RTSP port'
    'Canais'='Channels'
    'Qualidade AAC'='AAC quality'
    'Estéreo (2)'='Stereo (2)'
    'Iniciar transmissão'='Start streaming'
    'Parar'='Stop'
    'Parado'='Stopped'
    'URL RTSP para acesso à transmissão de áudio'='RTSP URL to access the audio stream'
    'Copiar endereço'='Copy URL'
    'Na primeira utilização, permita o acesso pela rede privada na Firewall do Windows.'='On first use, allow private-network access in Windows Firewall.'
    'Configuracao invalida; escolha novamente as opcoes.'='Invalid settings; please select the options again.'
    'Não foi possível guardar o config.json.'='Unable to save the settings.'
    'O IP guardado não está disponível. Selecione uma rede ativa.'='The saved IP is unavailable. Select an active network.'
    'Pronto. Selecione a entrada e inicie a transmissão.'='Ready. Select an input and start streaming.'
    'A entrada guardada não está disponível. Selecione outra entrada.'='The saved input is unavailable. Select another input.'
    'Nenhuma entrada encontrada. Ligue a placa e atualize as entradas.'='No inputs found. Connect the sound card and refresh the inputs.'
    'Selecione uma entrada de audio.'='Select an audio input.'
    'Selecione a rede / endereço IP de transmissão.'='Select the network / streaming IP address.'
    'A iniciar...'='Starting...'
    'A iniciar'='Starting'
    'A transmitir'='Streaming'
    'Nao foi possivel iniciar.'='Unable to start streaming.'
    'Transmissao interrompida'='Streaming stopped'
    'Verifique a placa de som e as permissoes do microfone.'='Check the sound card and microphone permissions.'
    'Registos: '='Logs: '
    'Ja existe um transmissor aberto neste PC.'='AudioRTSP is already open on this PC.'
    'Selecione um endereco IPv4 do PC.'='Select an IPv4 address belonging to this PC.'
    'A porta deve estar entre 1024 e 65535.'='The port must be between 1024 and 65535.'
    'Formato de audio invalido.'='Invalid audio format.'
    'O servidor RTSP demorou demasiado a arrancar.'='The RTSP server took too long to start.'
}
function Get-AudioText([string]$Text){
    if($script:AudioLanguage -ne 'en'){return $Text}
    if($script:AudioEnglish.ContainsKey($Text)){return $script:AudioEnglish[$Text]}
    if($Text -match '^A porta (\d+) esta ocupada(?: neste IP)?\. Escolha outra porta\.$'){return "Port $($Matches[1]) is in use. Choose another port."}
    if($Text -match '^O IP (.+) nao esta disponivel neste PC\. Atualize as redes e selecione outro IP\.$'){return "IP $($Matches[1]) is unavailable on this PC. Refresh networks and select another IP."}
    if($Text -match '^Falta bin\\(.+)\. Extraia o pacote completo\.$'){return "Missing bin\$($Matches[1]). Extract the complete package."}
    if($Text -match '^Falta \.\.\\bin\\(.+)\. Coloque bin ao lado da pasta AudioRTSP\.$'){return "Missing ..\bin\$($Matches[1]). Place bin next to the AudioRTSP folder."}
    return $Text
}

