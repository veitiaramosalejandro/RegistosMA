param([switch]$CheckOnly,[switch]$SmokeTest)
$ErrorActionPreference='Stop'
$app=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$root=[IO.Directory]::GetParent($app).FullName
$mutexName=if($SmokeTest){'Local\AudioRTSP_Migration_Test'}else{'Local\MA_RTSP_Transmissor_v1'}
$mutex=New-Object Threading.Mutex($false,$mutexName);$owned=$false
$plan=New-Object Collections.Generic.List[object]
$folders=New-Object Collections.Generic.List[object]
try {
    $owned=$mutex.WaitOne(0)
    if(-not $owned){throw 'Feche o AudioRTSP antes de reorganizar as pastas.'}
    foreach($name in @('bin','licencas')){
        $source=[IO.Path]::GetFullPath((Join-Path $app $name));$target=[IO.Path]::GetFullPath((Join-Path $root $name))
        # Exact named roots: no recursive moving/deleting and no computed paths outside these folders.
        if((Split-Path $source -Parent) -ne $app -or (Split-Path $target -Parent) -ne $root){throw 'Caminho de reorganizacao invalido.'}
        if(-not(Test-Path -LiteralPath $source)){continue}
        $sourceItem=Get-Item -LiteralPath $source
        if(-not $sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Pasta de origem invalida: $source"}
        if(Test-Path -LiteralPath $target){
            $targetItem=Get-Item -LiteralPath $target
            if(-not $targetItem.PSIsContainer -or ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Pasta de destino invalida: $target"}
        }
        foreach($file in Get-ChildItem -LiteralPath $source -Force){
            if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Conteudo inesperado na pasta: $($file.FullName). Reorganize esta pasta manualmente."}
            $destination=Join-Path $target $file.Name
            $duplicate=$false
            if(Test-Path -LiteralPath $destination){
                $existing=Get-Item -LiteralPath $destination
                if($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $destination).Hash){
                    throw "Existe um ficheiro diferente em $destination. Nenhum ficheiro foi movido. Confirme as versoes antes de reorganizar."
                }
                $duplicate=$true
            }
            $plan.Add([pscustomobject]@{Source=$file.FullName;Target=$destination;Duplicate=$duplicate})
        }
        $folders.Add([pscustomobject]@{Source=$source;Target=$target})
    }
    if($CheckOnly){Write-Host ('Verificacao concluida: '+$plan.Count+' ficheiros preparados.');return}
    # Only mutate after both folders have passed the complete conflict check.
    foreach($folder in $folders){$null=New-Item -ItemType Directory -Path $folder.Target -Force}
    foreach($item in $plan){
        if($item.Duplicate){
            if((Get-FileHash -LiteralPath $item.Source).Hash -ne (Get-FileHash -LiteralPath $item.Target).Hash){throw 'O ficheiro de destino mudou. Origem preservada.'}
            Remove-Item -LiteralPath $item.Source
        }else{Move-Item -LiteralPath $item.Source -Destination $item.Target}
    }
    foreach($folder in $folders){Remove-Item -LiteralPath $folder.Source} # Empty folders only, without -Recurse.
    Write-Host 'Reorganizacao concluida. bin e licencas ficam ao lado de AudioRTSP.'
} finally {if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
