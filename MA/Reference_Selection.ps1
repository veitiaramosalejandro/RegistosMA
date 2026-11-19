# Select-Object in Windows PowerShell 5.1 prepends a Selected.* type name to
# reused PSCustomObjects. Repeating it on timer ticks grows their type metadata.
# Return the original reference without creating projected objects or type names.
function Select-PlaybackReference {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$First)
    begin {$found=$false;$selected=$null}
    process {
        if(-not $found -or -not $First){$selected=$InputObject;$found=$true}
    }
    end {if($found){$selected}}
}
