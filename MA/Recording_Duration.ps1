# Read the actual video track duration, rather than container/audio length or
# elapsed startup/finalization time. Only headers are read; large mdat/data blocks
# are skipped. Existing recording metadata is never rewritten by the browser.
if(-not ('MachiningMonitor.MediaDuration161' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
namespace MachiningMonitor {
 public static class MediaDuration161 {
  struct Box {public string Type;public long Data,End;}
  static uint U32(BinaryReader r) {byte[] b=r.ReadBytes(4);if(b.Length!=4)throw new EndOfStreamException();return ((uint)b[0]<<24)|((uint)b[1]<<16)|((uint)b[2]<<8)|b[3];}
  static ulong U64(BinaryReader r) {return ((ulong)U32(r)<<32)|U32(r);}
  static string Text(BinaryReader r,int n) {byte[] b=r.ReadBytes(n);if(b.Length!=n)throw new EndOfStreamException();return Encoding.ASCII.GetString(b);}
  static bool Next(BinaryReader r,long limit,out Box box) {
   box=new Box();long start=r.BaseStream.Position;if(limit-start<8)return false;
   ulong size=U32(r);string type=Text(r,4);if(size==1)size=U64(r);
   if(size==0)size=(ulong)(limit-start);
   if(size>(ulong)(limit-start) || size<(ulong)(r.BaseStream.Position-start))return false;
   box.Type=type;box.Data=r.BaseStream.Position;box.End=start+(long)size;return box.End>start;
  }
  static double Media(BinaryReader r,long end,bool video) {
   string handler=null;double seconds=-1;Box box;
   while(Next(r,end,out box)) {
    if(box.Type=="hdlr" && box.End-box.Data>=12){r.BaseStream.Position=box.Data+8;handler=Text(r,4);}
    if(box.Type=="mdhd" && box.End-box.Data>=24){
     r.BaseStream.Position=box.Data;byte version=r.ReadByte();
     if(version==0 || (version==1 && box.End-box.Data>=36)){
      r.BaseStream.Position=box.Data+(version==1?20:12);uint scale=U32(r);ulong duration=version==1?U64(r):U32(r);
      if(scale>0 && duration!=(version==1?ulong.MaxValue:uint.MaxValue))seconds=(double)duration/scale;
     }
    }
    r.BaseStream.Position=box.End;
   }
   return handler==(video?"vide":"soun")?seconds:-1;
  }
  static double Track(BinaryReader r,long end,bool video) {
   Box box;while(Next(r,end,out box)){
    if(box.Type=="mdia"){double seconds=Media(r,box.End,video);if(seconds>=0)return seconds;}
    r.BaseStream.Position=box.End;
   }return -1;
  }
  static double Movie(BinaryReader r,long end,bool video) {
   Box box;while(Next(r,end,out box)){
    if(box.Type=="trak"){double seconds=Track(r,box.End,video);if(seconds>=0)return seconds;}
    r.BaseStream.Position=box.End;
   }return -1;
  }
  static double Wav(BinaryReader r) {
   string riff=Text(r,4);if(riff!="RIFF" && riff!="RF64")return -1;
   r.ReadUInt32();if(Text(r,4)!="WAVE")return -1;
   uint rate=0;ulong data=0,rf64=0;bool found=false;
   while(r.BaseStream.Length-r.BaseStream.Position>=8){
    string kind=Text(r,4);uint size=r.ReadUInt32();long start=r.BaseStream.Position;
    if(kind=="fmt " && size>=12){r.BaseStream.Position=start+8;rate=r.ReadUInt32();}
    if(kind=="ds64" && size>=16){r.BaseStream.Position=start+8;rf64=r.ReadUInt64();}
    if(kind=="data"){
     data=(size==uint.MaxValue && rf64>0)?rf64:size;
     data=Math.Min(data,(ulong)(r.BaseStream.Length-start));found=true;
     if(rate>0)return (double)data/rate;
    }
    long next=start+size+(size%2);if(next<=start || next>r.BaseStream.Length)break;r.BaseStream.Position=next;
   }return found && rate>0?(double)data/rate:-1;
  }
  public static double Read(string path,bool video) {
   try {
    using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))
    using(var r=new BinaryReader(file)){
     if(Path.GetExtension(path).Equals(".wav",StringComparison.OrdinalIgnoreCase))return Wav(r);
     Box box;while(Next(r,file.Length,out box)){
      if(box.Type=="moov")return Movie(r,box.End,video);
      file.Position=box.End;
     }
    }
   }catch(IOException){}catch(UnauthorizedAccessException){}catch(ArgumentException){}
   return -1;
  }
 }
}
'@
}
if(-not $script:RecordedDurationCache){$script:RecordedDurationCache=@{}}
function Get-RecordedFileSeconds {
    param($File,[bool]$Video=$true)
    try {
        if($File -is [string]){$File=Get-Item -LiteralPath $File -ErrorAction Stop}
        $File.Refresh();$key=$File.FullName+'|'+$Video
        $fingerprint=[string]$File.Length+'|'+$File.LastWriteTimeUtc.Ticks
        $cached=$script:RecordedDurationCache[$key]
        if($cached -and $cached.Fingerprint -eq $fingerprint){return $cached.Seconds}
        $value=[MachiningMonitor.MediaDuration161]::Read($File.FullName,$Video)
        $seconds=$null;if($value -ge 0 -and -not [double]::IsInfinity($value)){$seconds=$value}
        $script:RecordedDurationCache[$key]=@{Fingerprint=$fingerprint;Seconds=$seconds}
        return $seconds
    }catch{return $null}
}
function Get-RecordedFilesSeconds {
    param([object[]]$Files,[bool]$Video=$true)
    if(-not $Files.Count){return $null}
    $total=0.0
    foreach($file in $Files){$seconds=Get-RecordedFileSeconds $file $Video;if($null -eq $seconds){return $null};$total+=$seconds}
    return $total
}
function Get-RecordedSessionSeconds {
    param([string]$Folder)
    try{
        $files=@(Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop)
        $video=@($files|Where-Object {$_.Name -match '^video(?:_\d+)?\.mp4$'})
        if($video.Count){return Get-RecordedFilesSeconds $video $true}
        $audio=@($files|Where-Object {$_.Name -match '^audio(?:_\d+)?\.wav$'})
        return Get-RecordedFilesSeconds $audio $false
    }catch{return $null}
}
