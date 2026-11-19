# Playback-only padding. Original media files are never changed.
# The caller supplies a finite output -t equal to the recording's complete duration.
function Set-PlaybackFullDurationArguments {
    param([string[]]$Items,[double]$DurationSeconds)
    if($DurationSeconds -le 0 -or [double]::IsNaN($DurationSeconds) -or [double]::IsInfinity($DurationSeconds)){return @($Items)}
    $length=$DurationSeconds.ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
    $result=@($Items)
    $filterIndex=[Array]::IndexOf($result,'-filter_complex')
    $graph='';if($filterIndex -ge 0){$graph=[string]$result[$filterIndex+1]}
    $inputInfo=@{};$inputNumber=0;$inputSeek=0.0
    for($i=0;$i -lt $result.Count-1;$i++){
        if($result[$i] -eq '-ss'){$inputSeek=[double]::Parse($result[$i+1],[Globalization.CultureInfo]::InvariantCulture)}
        if($result[$i] -eq '-i'){
            $gaps=@();$path=$result[$i+1]
            if([IO.Path]::GetExtension($path) -eq '.ffconcat' -and (Test-Path -LiteralPath $path)){
                foreach($line in [IO.File]::ReadLines($path)){if($line -match '^# ma-gap ([0-9.]+) ([0-9.]+)$'){$gaps+=@{From=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture);To=[double]::Parse($Matches[2],[Globalization.CultureInfo]::InvariantCulture)}}}
            }
            $inputInfo[[string]$inputNumber]=@{Seek=$inputSeek;Gaps=$gaps};$inputNumber++;$inputSeek=0.0
        }
    }
    $rawVideo=@{}
    for($i=0;$i -lt $result.Count-1;$i++){
        if($result[$i] -eq '-map' -and $result[$i+1] -match '^(\d+:v:\d+)\??$'){
            $reference=$Matches[1];$label='ma_raw_'+$rawVideo.Count
            $graph+=';['+$reference+']null['+$label+']'
            $result[$i+1]='['+$label+']';$rawVideo[$reference]=$label
        }
    }
    $graph=$graph.TrimStart(';')
    $references=@([regex]::Matches($graph,'\[(\d+:[av]:\d+)\]') | ForEach-Object {$_.Groups[1].Value} | Select-Object -Unique)
    $prefix='';$number=0;$hasVideo=$false
    foreach($reference in $references){
        $token='['+$reference+']';$count=[regex]::Matches($graph,[regex]::Escape($token)).Count
        $labels=@();for($i=0;$i -lt $count;$i++){$labels+='ma_full_'+$number;$number++}
        $filter='aresample=async=1:first_pts=0,apad=whole_dur='+$length+',atrim=duration='+$length;$split='asplit'
        if($reference -match ':v:'){
            $hasVideo=$true;$split='split';$info=$inputInfo[$reference.Split(':')[0]];$leading=0.0
            if($info){foreach($gap in $info.Gaps){if($info.Seek -gt $gap.From -and $info.Seek -lt $gap.To){$leading=$gap.To-$info.Seek}}}
            $lead=$leading.ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
            $filter='setpts=PTS-STARTPTS,tpad=start_mode=add:start_duration='+$lead+':stop_mode=add:stop_duration='+$length+':color=black,fps=25'
            if($info){foreach($gap in $info.Gaps){
                $from=[Math]::Max(0,$gap.From-$info.Seek).ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
                $to=[Math]::Max(0,$gap.To-$info.Seek).ToString('0.######',[Globalization.CultureInfo]::InvariantCulture)
                $filter+=",drawbox=color=black:t=fill:enable='gte(t,"+$from+")*lt(t,"+$to+")'"
            }}
            $filter+=',trim=duration='+$length
        }
        $prefix+=$token+$filter
        if($count -gt 1){$prefix+=','+$split+'='+$count}
        foreach($label in $labels){$prefix+='['+$label+']'}
        $prefix+=';'
        $start=0
        foreach($label in $labels){$index=$graph.IndexOf($token,$start);$replacement='['+$label+']';$graph=$graph.Remove($index,$token.Length).Insert($index,$replacement);$start=$index+$replacement.Length}
    }
    if(-not $references.Count){return $result}
    $graph=$prefix+$graph
    if($filterIndex -ge 0){$result[$filterIndex+1]=$graph}
    else{$result=@($result[0..($result.Count-2)])+@('-filter_complex',$graph,$result[-1])}
    if($hasVideo){
        for($i=0;$i -lt $result.Count-1;$i++){if($result[$i] -eq '-c:v' -and $result[$i+1] -eq 'copy'){$result[$i+1]='libx264'}}
        if($result -notcontains '-preset'){$result=@($result[0..($result.Count-2)])+@('-preset','ultrafast',$result[-1])}
    }
    return $result
}
