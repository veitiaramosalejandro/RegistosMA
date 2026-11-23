using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading.Tasks;
namespace MachiningMonitor {
 public sealed class AlignmentWave235 {
  public string Path,Format;
  public int Rate,Channels,Align;
  public long Data,Bytes,Start,End;
  public static AlignmentWave235 Read(string path) {
   using(FileStream f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
   using(BinaryReader r=new BinaryReader(f)) {
    string magic=Encoding.ASCII.GetString(r.ReadBytes(4));r.ReadUInt32();
    if((magic!="RIFF"&&magic!="RF64")||Encoding.ASCII.GetString(r.ReadBytes(4))!="WAVE")throw new InvalidDataException("Unsupported WAV: "+path);
    AlignmentWave235 w=new AlignmentWave235();w.Path=path;ulong largeData=0;int tag=0,bits=0;
    while(f.Position+8<=f.Length) {
     string kind=Encoding.ASCII.GetString(r.ReadBytes(4));uint size=r.ReadUInt32();long begin=f.Position;
     if(kind=="ds64"&&size>=28){r.ReadUInt64();largeData=r.ReadUInt64();}
     if(kind=="fmt "&&size>=16){tag=r.ReadUInt16();w.Channels=r.ReadUInt16();w.Rate=(int)r.ReadUInt32();r.ReadUInt32();w.Align=r.ReadUInt16();bits=r.ReadUInt16();if(tag==65534&&size>=40){f.Position=begin+24;tag=r.ReadUInt16();}}
     if(kind=="data") {w.Data=begin;w.Bytes=(long)Math.Min((ulong)(f.Length-begin),size==uint.MaxValue&&largeData>0?largeData:size);break;}
     long next=begin+size+(size&1);if(next>f.Length||next<=begin)break;f.Position=next;
    }
    if(w.Rate<=0||w.Channels<=0||w.Data<=0||w.Align<=0||w.Align!=w.Channels*(bits/8))throw new InvalidDataException("Invalid WAV layout: "+path);
    if(tag==1&&(bits==8||bits==16||bits==24||bits==32))w.Format=bits==8?"u8":"s"+bits+"le";
    else if(tag==3&&(bits==32||bits==64))w.Format="f"+bits+"le";
    else throw new InvalidDataException("Unsupported WAV sample format: "+path);
    return w;
   }
  }
 }
 // A bounded stream of original PCM samples, addressed by output time and the
 // offset table. Increasing a delay repeats samples; decreasing it skips them.
 // No resampling, listening gain or camera adjustment happens in this class.
 public sealed class AlignmentAudioStream235 : IDisposable {
  AlignmentWave235[] files;long[] starts,ends,delays;
  NamedPipeServerStream pipe;Task work;volatile bool disposed;long position,limit;
  public string PipePath {get;private set;}
  public string Failure {get;private set;}
  static long Samples(double seconds,int rate){return (long)Math.Round(seconds*rate,MidpointRounding.AwayFromZero);}
  public static AlignmentAudioStream235 Create(string[] paths,double[] durations,double[] blockStarts,double[] blockDurations,int[] offsets,double start) {
   return new AlignmentAudioStream235(paths,durations,blockStarts,blockDurations,offsets,start);
  }
  AlignmentAudioStream235(string[] paths,double[] durations,double[] blockStarts,double[] blockDurations,int[] offsets,double start) {
   if(paths.Length==0||paths.Length!=durations.Length||blockStarts.Length==0||blockStarts.Length!=offsets.Length||blockStarts.Length!=blockDurations.Length)throw new InvalidDataException("Incomplete alignment table");
   files=new AlignmentWave235[paths.Length];double time=0;
   for(int i=0;i<paths.Length;i++){
    files[i]=AlignmentWave235.Read(paths[i]);
    if(i>0&&(files[i].Rate!=files[0].Rate||files[i].Channels!=files[0].Channels||files[i].Format!=files[0].Format))throw new InvalidDataException("WAV formats differ between blocks");
    files[i].Start=Samples(time,files[0].Rate);time+=durations[i];files[i].End=Samples(time,files[0].Rate);
   }
   int rate=files[0].Rate;starts=new long[offsets.Length];ends=new long[offsets.Length];delays=new long[offsets.Length];
   for(int i=0;i<offsets.Length;i++){starts[i]=Samples(blockStarts[i],rate);ends[i]=Samples(blockStarts[i]+blockDurations[i],rate);delays[i]=Samples(offsets[i]/1000.0,rate);}
   position=Samples(start,rate);limit=ends[ends.Length-1];
   string name="ma-aligned-"+Guid.NewGuid().ToString("N");PipePath=@"\\.\pipe\"+name;
   pipe=new NamedPipeServerStream(name,PipeDirection.Out,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,65536,65536);
   work=Task.Run((Action)Produce);
  }
  int Block(long p){int lo=0,hi=ends.Length-1;while(lo<hi){int mid=(lo+hi)/2;if(p<ends[mid])hi=mid;else lo=mid+1;}return lo;}
  int FileAt(long p){int lo=0,hi=files.Length-1;while(lo<hi){int mid=(lo+hi)/2;if(p<files[mid].End)hi=mid;else lo=mid+1;}return lo;}
  void Produce() {
   FileStream source=null;int opened=-1;
   try{
    pipe.WaitForConnection();int align=files[0].Align;byte[] buffer=new byte[Math.Max(65536/align,1)*align];
    while(!disposed&&position<limit){
     int block=Block(position);long input=position-delays[block];
     long count=Math.Min(buffer.Length/align,Math.Min(limit-position,ends[block]-position));
     int index=-1;
     if(input<0)count=Math.Min(count,-input);
     else if(input<files[files.Length-1].End){index=FileAt(input);count=Math.Min(count,files[index].End-input);}
     if(count<=0)throw new InvalidDataException("Non-contiguous alignment table");
     int bytes=checked((int)(count*align));Array.Clear(buffer,0,bytes);
     if(files[0].Format=="u8")for(int i=0;i<bytes;i++)buffer[i]=128;
     if(index>=0){
      AlignmentWave235 f=files[index];long local=input-f.Start;long available=f.Bytes/align-local;
      if(available>0){
       if(opened!=index){if(source!=null)source.Dispose();source=new FileStream(f.Path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete,65536,FileOptions.SequentialScan);opened=index;}
       source.Position=f.Data+local*align;int wanted=(int)(Math.Min(count,available)*align),read=0;
       while(read<wanted){int n=source.Read(buffer,read,wanted-read);if(n==0)throw new EndOfStreamException(f.Path);read+=n;}
      }
     }
     pipe.Write(buffer,0,bytes);position+=count;
    }
   }catch(Exception e){if(!disposed)Failure=e.Message;}
   finally{if(source!=null)source.Dispose();try{pipe.Dispose();}catch{}}
  }
  public void Dispose(){if(disposed)return;disposed=true;pipe.Dispose();try{work.Wait(1000);}catch{}}
 }
}
