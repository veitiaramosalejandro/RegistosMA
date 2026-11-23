# Defines the physical activity choices independently of the controller execution state.
function Get-MachineActivities {
    $path=Join-Path $PSScriptRoot 'machine_activities.json'
    $config=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $ids=@{};$localized=@()
    foreach($activity in $config.activities){
        $key=$activity.label_key; if(-not $key){$key=$activity.label}
        if([string]::IsNullOrWhiteSpace($activity.id) -or [string]::IsNullOrWhiteSpace($key) -or $ids.ContainsKey($activity.id)){throw 'machine_activities.json: atividades inválidas ou repetidas.'}
        $ids[$activity.id]=$true
        $localized+=[pscustomobject]@{id=$activity.id;label=(Get-UiText $key)}
    }
    if(-not $ids.ContainsKey([string]$config.default)){throw 'machine_activities.json: atividade predefinida inválida.'}
    return [pscustomobject]@{default=$config.default;activities=$localized}
}
