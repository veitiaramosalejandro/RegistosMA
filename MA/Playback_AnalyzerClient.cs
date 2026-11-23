using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
namespace MachiningMonitor {
 public sealed class PlaybackAnalyzerClient : IDisposable {
  sealed class Packet { public string Path,Body; public Guid Session;public bool Stop;public long Revision;public DateTime Created=DateTime.UtcNow; }
  readonly string endpoint,key,pin,preparePath,group="ma-analysis-"+Guid.NewGuid().ToString("N");readonly object gate=new object();
  readonly LinkedList<Packet> pending=new LinkedList<Packet>();readonly HashSet<Guid> stopped=new HashSet<Guid>(),stopAcks=new HashSet<Guid>(),started=new HashSet<Guid>();
  readonly AutoResetEvent wake=new AutoResetEvent(false);readonly Thread worker;
  bool stopping;long revision,acknowledged;volatile string failure;volatile bool ready,resync,prepareReady;
  HttpWebRequest active;Guid activeSession;long roundTrip;
  public string Failure {get{return failure;}}
  public bool Ready {get{return ready;}}
  public bool PrepareReady {get{return prepareReady;}}
  public bool NeedsResync {get{return resync;}}
  public long LastRoundTripMilliseconds {get{return Interlocked.Read(ref roundTrip);}}
  public int PendingCount {get{lock(gate)return pending.Count;}}
  public bool HasAcknowledgement {get{lock(gate)return revision>0&&acknowledged>=revision;}}
  public bool HasStarted(Guid session){lock(gate)return started.Contains(session);}
  public bool HasStopped(Guid session){lock(gate)return stopAcks.Contains(session);}
  // Force a fresh service capability check when playback resumes after the
  // user changes the service configuration while the recording is open.
  public void RefreshPreparation(){
   HttpWebRequest abort;
   lock(gate){prepareReady=false;failure=null;abort=active;}
   // A probe may be blocked waiting for an unreachable Analyzer. Abort it so
   // the next request can immediately observe a service-side 409 disabled
   // response instead of waiting for the Analyzer timeout.
   if(abort!=null)abort.Abort();
   wake.Set();
  }
  public void ClearResync(){resync=false;}
  static string Explain(Exception error){
   var web=error as WebException;var response=web==null?null:web.Response as HttpWebResponse;
   if(response!=null){var code=(int)response.StatusCode;response.Dispose();
    if(code==401)return "Chave de acesso ao serviço inválida (HTTP 401).";
    if(code==403)return "A chave não tem acesso a esta máquina (HTTP 403).";
    if(code==404)return "Atualize o serviço MachiningMonitor para v97 (HTTP 404).";
    if(code==409)return "A análise ao reproduzir gravações está desativada no serviço (HTTP 409).";
    if(code==503)return "Sem ligação ao Analyzer (HTTP 503).";
    return "Pedido de análise recusado pelo serviço (HTTP "+code+").";
   }
   return "Falha na ligação HTTPS/TLS ao serviço ou ao Analyzer.";
  }
  public PlaybackAnalyzerClient(string server,string apiKey,string certificateSha256,Guid machine){
   var uri=new Uri(server);if(uri.Scheme!="https"||!String.IsNullOrEmpty(uri.UserInfo)||machine==Guid.Empty)throw new ArgumentException("Configure HTTPS e MachineId do serviço.");
   endpoint=server.TrimEnd('/');key=apiKey;pin=certificateSha256;preparePath="/api/analysis/playback/"+machine+"/prepare";
   worker=new Thread(Run);worker.IsBackground=true;worker.Start();
  }
  public void SendPacket(Guid session,string body){
   lock(gate){if(stopping)throw new ObjectDisposedException("PlaybackAnalyzerClient");if(stopped.Contains(session))return;
    if(pending.Count>=6){resync=true;failure="A análise não acompanha a reprodução. É necessário pausar e retomar.";return;}
    pending.AddLast(new Packet{Path="/api/analysis/playback",Body=body,Session=session,Revision=++revision});}
   wake.Set();
  }
  public void StopAnalysis(Guid machine,Guid session){
   HttpWebRequest abort=null;
   lock(gate){if(stopped.Contains(session))return;stopped.Add(session);started.Remove(session);
    var node=pending.First;while(node!=null){var next=node.Next;if(node.Value.Session==session)pending.Remove(node);node=next;}
    pending.AddFirst(new Packet{Path="/api/analysis/playback/"+machine+"/"+session+"/stop",Body="{}",Session=session,Stop=true,Revision=++revision});
    if(active!=null&&(activeSession==session||activeSession==Guid.Empty))abort=active;
   }
   if(abort!=null)abort.Abort();wake.Set();
  }
  void Request(string path,string body,Guid session){
   var request=(HttpWebRequest)WebRequest.Create(endpoint+path);request.Method="POST";request.ContentType="application/json";request.Headers["X-Api-Key"]=key;
   request.Timeout=4500;request.ReadWriteTimeout=4500;request.AllowAutoRedirect=false;request.KeepAlive=true;request.ConnectionGroupName=group;
   request.ServicePoint.Expect100Continue=false;request.ServicePoint.ConnectionLimit=4;
   if(!String.IsNullOrEmpty(pin))request.ServerCertificateValidationCallback=ValidateCertificate;
   lock(gate){active=request;activeSession=session;}
   try{
    var watch=Stopwatch.StartNew();var bytes=Encoding.UTF8.GetBytes(body);request.ContentLength=bytes.Length;
    using(var output=request.GetRequestStream())output.Write(bytes,0,bytes.Length);
    using(var response=(HttpWebResponse)request.GetResponse())using(var input=response.GetResponseStream()){
     if(response.StatusCode!=HttpStatusCode.OK)throw new IOException("O serviço não confirmou o comando.");
     // Drain the response so HTTP/TLS connections can be reused by subsequent requests.
     var buffer=new byte[4096];while(input.Read(buffer,0,buffer.Length)>0){}
    }
    Interlocked.Exchange(ref roundTrip,watch.ElapsedMilliseconds);
   }finally{lock(gate){if(active==request){active=null;activeSession=Guid.Empty;}}}
  }
  void Run(){
   var prepared=DateTime.MinValue;
   try{while(true){
    Packet packet=null;lock(gate){if(pending.Count>0){packet=pending.First.Value;pending.RemoveFirst();}else if(stopping)break;}
    if(packet==null){
     bool idle;lock(gate)idle=started.Count==0;
     // Keep probing while a session is active too. Service configuration can
     // change during playback, and the status must not wait for the recording
     // to be closed (or for the session to stop) before noticing it.
     if(!prepareReady||((DateTime.UtcNow-prepared).TotalSeconds>=1)){try{Request(preparePath,"{}",Guid.Empty);ready=true;prepareReady=true;failure=null;prepared=DateTime.UtcNow;}catch(Exception error){ready=false;prepareReady=false;failure=Explain(error);wake.WaitOne(100);}}
     else wake.WaitOne(100);continue;
    }
    lock(gate){if(!packet.Stop&&stopped.Contains(packet.Session))continue;}
    if(!packet.Stop&&(DateTime.UtcNow-packet.Created).TotalMilliseconds>1000){resync=true;failure="Dados de análise atrasados. Pause e retome para sincronizar.";continue;}
    try{
     Request(packet.Path,packet.Body,packet.Session);ready=true;failure=null;
     lock(gate){acknowledged=Math.Max(acknowledged,packet.Revision);if(packet.Stop)stopAcks.Add(packet.Session);else started.Add(packet.Session);}
    }catch(Exception error){
     bool canceled;lock(gate){canceled=!packet.Stop&&stopped.Contains(packet.Session);if(stopping)break;}
     if(canceled)continue;
     ready=false;prepareReady=false;failure=Explain(error);
     // A failed stop must not monopolize the queue. The service has a session
     // lease, while the next prepare must be allowed to detect recovery.
     if(!packet.Stop)resync=true;
     wake.WaitOne(100);
    }
   }}finally{try{ServicePointManager.FindServicePoint(new Uri(endpoint)).CloseConnectionGroup(group);}catch{}}
  }
  bool ValidateCertificate(object sender,X509Certificate certificate,X509Chain chain,SslPolicyErrors errors){
   if(certificate==null||(errors&SslPolicyErrors.RemoteCertificateNameMismatch)!=0)return false;
   using(var cert=new X509Certificate2(certificate))using(var sha=SHA256.Create())return cert.NotBefore.ToUniversalTime()<=DateTime.UtcNow&&cert.NotAfter.ToUniversalTime()>DateTime.UtcNow&&String.Equals(BitConverter.ToString(sha.ComputeHash(cert.RawData)).Replace("-",""),pin,StringComparison.OrdinalIgnoreCase);
  }
  public void Dispose(){lock(gate)stopping=true;wake.Set();if(!worker.Join(1000)){HttpWebRequest abort;lock(gate)abort=active;if(abort!=null)abort.Abort();worker.Join(1000);}if(!worker.IsAlive)wake.Dispose();}
 }
}
