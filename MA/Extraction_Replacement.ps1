# Resolve direct children before replacing or deleting any existing directory.
function Get-SplitTargetPath {
    param([string]$Destination,[string]$Name,[string]$Source)
    $root=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
    foreach($basePath in @($root,$Source)){
        if(-not $basePath){continue}
        $directory=New-Object IO.DirectoryInfo([IO.Path]::GetFullPath($basePath))
        while($null -ne $directory){
            if($directory.Exists -and ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw (Get-QualityText 'A destination or source accessed through folder links cannot be replaced here.' 'Não é possível substituir pastas de destino ou origem acedidas através de ligações.')}
            $directory=$directory.Parent
        }
    }
    $path=[IO.Path]::GetFullPath((Join-Path $root $Name)).TrimEnd('\','/')
    if(-not [string]::Equals([IO.Path]::GetDirectoryName($path),$root,[StringComparison]::OrdinalIgnoreCase)){
        throw (Get-QualityText 'The extraction folder must be directly inside the destination.' 'A pasta da extração tem de estar diretamente dentro do destino.')
    }
    if($Source){
        $origin=[IO.Path]::GetFullPath($Source).TrimEnd('\','/')
        if($origin.Equals($path,[StringComparison]::OrdinalIgnoreCase) -or $origin.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)){
            throw (Get-QualityText 'The source recording cannot be replaced.' 'A gravação de origem não pode ser substituída.')
        }
    }
    return $path
}
function Test-SplitReplacementTree {
    param([string]$Path)
    $pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($Path)
    while($pending.Count){
        $current=$pending.Pop()
        if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw (Get-QualityText 'Folders containing links cannot be replaced here.' 'Pastas com ligações não podem ser substituídas nesta operação.')}
        foreach($child in [IO.Directory]::GetDirectories($current)){$pending.Push($child)}
        foreach($file in [IO.Directory]::GetFiles($current)){
            if(([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw (Get-QualityText 'Folders containing links cannot be replaced here.' 'Pastas com ligações não podem ser substituídas nesta operação.')}
        }
    }
}
function Get-SplitExistingTargets {
    param($Parts,[string]$Destination,[string]$Source)
    $names=@{}
    foreach($part in $Parts){
        $path=Get-SplitTargetPath $Destination $part.Name $Source
        if($names.ContainsKey($path)){throw (Get-QualityText 'Duplicate extraction names.' 'Existem nomes de extração repetidos.')};$names[$path]=$true
        if([IO.File]::Exists($path)){throw (Get-QualityText 'A file already uses this extraction name.' 'Já existe um ficheiro com este nome de extração.')}
        if([IO.Directory]::Exists($path)){Test-SplitReplacementTree $path; $path}
    }
}
function Publish-SplitExtraction {
    param([string]$Staging,[string]$Destination,[string]$Name,[string]$Source,[string[]]$ReplaceFolders=@())
    $target=Get-SplitTargetPath $Destination $Name $Source
    $stageFull=Get-SplitTargetPath $Destination ([IO.Path]::GetFileName($Staging)) $Source
    if(-not $stageFull.Equals([IO.Path]::GetFullPath($Staging),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($stageFull) -notlike '.divisao-*'){throw 'Invalid staging path.'}
    $backup=$null
    if([IO.Directory]::Exists($target)){
        if($target -notin $ReplaceFolders){throw (Get-QualityText 'Replacement of this folder was not confirmed.' 'A substituição desta pasta não foi confirmada.')}
        Test-SplitReplacementTree $target
        $backup=Get-SplitTargetPath $Destination ('.substituicao-'+[guid]::NewGuid().ToString('N')) $Source
        [IO.Directory]::Move($target,$backup)
    }
    try{[IO.Directory]::Move($stageFull,$target)}catch{
        if($backup -and -not [IO.Directory]::Exists($target)){[IO.Directory]::Move($backup,$target)}
        throw
    }
    if($backup){
        # Delete only the verified sibling backup after publication succeeds.
        $verified=Get-SplitTargetPath $Destination ([IO.Path]::GetFileName($backup)) $Source
        if(-not $verified.Equals($backup,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid replacement backup.'}
        Test-SplitReplacementTree $backup
        [IO.Directory]::Delete($backup,$true)
    }
}
