# RTSP credentials for recording clients, protected with Windows CurrentUser DPAPI.
Add-Type -AssemblyName System.Security
function Protect-RecordingPassword([string]$Password){
    if(-not $Password.Length){return ''}
    $bytes=[Text.Encoding]::UTF8.GetBytes($Password)
    try{return 'dpapi:'+[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))}
    finally{[Array]::Clear($bytes,0,$bytes.Length)}
}
function Get-RecordingCredentialText($Object,[string]$Name){
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property -or $null -eq $property.Value){return ''}
    if($property.Value -isnot [string]){throw (Get-QualityText 'Credential settings must contain text.' 'As configurações de credenciais devem conter texto.')}
    return [string]$property.Value
}
function Unprotect-RecordingPassword([string]$Protected){
    if(-not $Protected.Length){return ''}
    try {
        if(-not $Protected.StartsWith('dpapi:')){throw 'Invalid protected value'}
        $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Protected.Substring(6)),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        try{return [Text.Encoding]::UTF8.GetString($bytes)}finally{[Array]::Clear($bytes,0,$bytes.Length)}
    }catch{throw (Get-QualityText 'Unable to read the saved password on this Windows account. Enter it again in Settings.' 'Não foi possível ler a palavra-passe guardada nesta conta do Windows. Volte a introduzi-la na Configuração.')}
}
function Get-RecordingEndpoint {
    param([string]$Url,[string]$Username='',[string]$PasswordProtected='',[switch]$ForEditing)
    $uri=$null;$password='';$needsPassword=$false
    if([Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -and $uri.UserInfo){
        $parts=$uri.UserInfo.Split([char[]]':',2)
        if(-not $Username){$Username=[Uri]::UnescapeDataString($parts[0])}
        if($parts.Count -gt 1){$password=[Uri]::UnescapeDataString($parts[1])}
        $Url=[regex]::Replace($Url,'^(rtsps?://)[^/]*@','$1',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if($PasswordProtected){
        try{$password=Unprotect-RecordingPassword $PasswordProtected}
        catch{if(-not $ForEditing){throw};$password='';$needsPassword=$true}
    }
    return [pscustomobject]@{Url=$Url;Username=$Username;Password=$password;NeedsPassword=$needsPassword}
}
function Join-RecordingEndpoint($Endpoint){
    if($Endpoint.Username -match '[:\x00-\x1f\x7f]' -or $Endpoint.Password -match '[\x00-\x1f\x7f]'){
        throw (Get-QualityText 'Invalid username or password. The username cannot contain a colon; control characters are not allowed.' 'Utilizador ou palavra-passe inválidos. O utilizador não pode conter dois-pontos; não são permitidos caracteres de controlo.')
    }
    if(-not $Endpoint.Username){
        if($Endpoint.Password){throw (Get-QualityText 'Enter a username for the password provided.' 'Introduza um utilizador para a palavra-passe indicada.')}
        return $Endpoint.Url
    }
    $auth=[Uri]::EscapeDataString($Endpoint.Username)+':'+[Uri]::EscapeDataString($Endpoint.Password)+'@'
    return [regex]::Replace($Endpoint.Url,'^(rtsps?://)',('$1'+$auth),[Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
function Get-RecordingCameraEndpoint {
    param($Camera,[switch]$ForEditing)
    Get-RecordingEndpoint ([string]$Camera.Url) (Get-RecordingCredentialText $Camera 'Username') (Get-RecordingCredentialText $Camera 'PasswordProtected') -ForEditing:$ForEditing
}
