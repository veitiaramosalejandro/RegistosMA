# Portable access settings: only password hashes are persisted.
function Get-AudioCredentialHash([string]$Value){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return 'sha256:'+ [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))}finally{$sha.Dispose()}
}
function Assert-AudioPassword([string]$Password){
    if([string]::IsNullOrEmpty($Password) -or $Password -match '[:\x00-\x1f\x7f]'){
        throw 'A palavra-passe não pode estar vazia nem conter dois-pontos ou caracteres de controlo.'
    }
}
function Get-AudioAccessSettings($Config){
    $enabled=$false;$username='';$hash=''
    if($null -ne $Config){
        if($Config.PSObject.Properties['AuthEnabled']){
            if($Config.AuthEnabled -isnot [bool]){throw 'A opção de autenticação deve ser true ou false.'}
            $enabled=$Config.AuthEnabled
        }
        if($Config.PSObject.Properties['AuthUsername']){$username=[string]$Config.AuthUsername}
        if($Config.PSObject.Properties['AuthPasswordHash']){$hash=[string]$Config.AuthPasswordHash}
    }
    return [pscustomobject]@{Enabled=$enabled;Username=$username;PasswordHash=$hash}
}
function Assert-AudioAccess($Access){
    if(-not $Access.Enabled){return}
    if([string]::IsNullOrWhiteSpace($Access.Username) -or $Access.Username -match '[\x00-\x20:\x7f]'){
        throw 'Defina um utilizador sem espaços, dois-pontos ou caracteres de controlo.'
    }
    if($Access.PasswordHash -notmatch '^sha256:[A-Za-z0-9+/]{43}=$'){
        throw 'Defina uma palavra-passe antes de ativar a autenticação.'
    }
}
function ConvertTo-AudioClientUrl([string]$Url,[string]$Username,[string]$Password){
    if([string]::IsNullOrEmpty($Username) -or [string]::IsNullOrEmpty($Password)){throw 'Introduza o utilizador e a palavra-passe de acesso.'}
    $credentials=[Uri]::EscapeDataString($Username)+':'+[Uri]::EscapeDataString($Password)+'@'
    return $Url.Replace('rtsp://',('rtsp://'+$credentials))
}
