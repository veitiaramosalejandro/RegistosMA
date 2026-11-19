# Consume native process pipes in memory; no diagnostic output is retained or written.
if(-not ('AudioRTSP.ProcessOutput6' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
namespace AudioRTSP {
 public sealed class ProcessOutput6 : IDisposable {
  readonly StreamReader output,error;readonly Thread outputThread,errorThread;
  public volatile bool Listening,Publishing; public volatile string LastError=""; public volatile string ErrorText="";
  public ProcessOutput6(StreamReader stdout,StreamReader stderr){
   output=stdout;error=stderr;
   outputThread=new Thread(()=>Read(output,false));errorThread=new Thread(()=>Read(error,true));
   outputThread.IsBackground=true;errorThread.IsBackground=true;outputThread.Start();errorThread.Start();
  }
  void Read(StreamReader reader,bool isError){
   try{string line;while((line=reader.ReadLine())!=null){
    if(isError && line.Length>0){LastError=line;lock(this){ErrorText=(ErrorText+"\n"+line);if(ErrorText.Length>8192)ErrorText=ErrorText.Substring(ErrorText.Length-8192);}}
    if(line.IndexOf("listener opened",StringComparison.Ordinal)>=0 || line.IndexOf("started with listeners",StringComparison.Ordinal)>=0)Listening=true;
    if(line.IndexOf("is publishing to path",StringComparison.Ordinal)>=0)Publishing=true;
   }}catch(IOException){}catch(ObjectDisposedException){}
  }
  public void Dispose(){
   if(!outputThread.Join(1000)){output.Dispose();outputThread.Join(1000);}
   if(!errorThread.Join(1000)){error.Dispose();errorThread.Join(1000);}
  }
 }
}
'@
}
