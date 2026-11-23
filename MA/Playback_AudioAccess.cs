// Dynamic, memory-only reader credentials. MediaMTX remains alive between analyses.
// Authentication and administration are loopback-only; no passwords enter its YAML.
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Collections;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
namespace MachiningMonitor.Broadcast {
 public sealed class AudioTokenAccess : IDisposable {
  readonly object gate=new object();readonly TcpListener listener;readonly Thread worker;
  readonly string route="/auth-"+Guid.NewGuid().ToString("N"),admin=Guid.NewGuid().ToString("N"),adminPassword=Guid.NewGuid().ToString("N");
  string user="",publisher;byte[] hash;DateTime expires;volatile bool disposed;
  public string AuthUrl {get;private set;}public int ApiPort {get;private set;}
  public AudioTokenAccess(string publisherAddress){
   publisher=publisherAddress;var probe=new TcpListener(IPAddress.Loopback,0);probe.Start();ApiPort=((IPEndPoint)probe.LocalEndpoint).Port;probe.Stop();
   listener=new TcpListener(IPAddress.Loopback,0);listener.Start();AuthUrl="http://127.0.0.1:"+((IPEndPoint)listener.LocalEndpoint).Port+route;
   worker=new Thread(Run);worker.IsBackground=true;worker.Start();
  }
  static byte[] Hash(string value){using(var sha=SHA256.Create())return sha.ComputeHash(Encoding.UTF8.GetBytes(value));}
  static bool Equal(byte[] left,byte[] right){if(left==null||right==null||left.Length!=right.Length)return false;int difference=0;for(int i=0;i<left.Length;i++)difference|=left[i]^right[i];return difference==0;}
  public void SetToken(string username,string token,DateTime expiry){
   if(String.IsNullOrEmpty(username)||token.Length<43||expiry.ToUniversalTime()<=DateTime.UtcNow)throw new ArgumentException("Token ou validade inválidos.");
   RevokeToken();lock(gate){user=username;hash=Hash(token);expires=expiry.ToUniversalTime();}
  }
  public void RevokeToken(){string old;lock(gate){old=user;user="";hash=null;expires=DateTime.MinValue;}if(old.Length>0)ThreadPool.QueueUserWorkItem(_=>Kick(old));}
  bool Authorize(Dictionary<string,object> request,out string body){
   body="{}";Func<string,string> text=key=>request.ContainsKey(key)?Convert.ToString(request[key]):"";
   var action=text("action");var address=text("ip");
   if(action=="publish")return text("path")=="audio"&&address==publisher;
   if(action=="api")return (address=="127.0.0.1"||address=="::1")&&text("user")==admin&&Equal(Hash(text("password")),Hash(adminPassword));
   if(action!="read"||text("path")!="audio")return false;
   lock(gate){if(user.Length==0||text("user")!=user||expires<=DateTime.UtcNow||!Equal(hash,Hash(text("password"))))return false;body="{\"expireAt\":\""+expires.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")+"\"}";return true;}
  }
  static string Line(Stream stream){var bytes=new List<byte>();while(bytes.Count<8192){int item=stream.ReadByte();if(item<0)throw new EndOfStreamException();if(item==10)return Encoding.ASCII.GetString(bytes.ToArray()).TrimEnd('\r');bytes.Add((byte)item);}throw new IOException("Header too large.");}
  void Run(){
   while(!disposed){TcpClient socket=null;try{socket=listener.AcceptTcpClient();socket.ReceiveTimeout=1000;socket.SendTimeout=1000;using(socket)using(var stream=socket.GetStream()){
    var first=Line(stream);int size=0;string line;while((line=Line(stream)).Length>0){if(line.StartsWith("Content-Length:",StringComparison.OrdinalIgnoreCase))Int32.TryParse(line.Substring(15).Trim(),out size);}
    bool allowed=false;string body="{}";
    if(first=="POST "+route+" HTTP/1.1"&&size>0&&size<=65536){var bytes=new byte[size];int offset=0;while(offset<size){int read=stream.Read(bytes,offset,size-offset);if(read==0)throw new EndOfStreamException();offset+=read;}allowed=Authorize(new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(Encoding.UTF8.GetString(bytes)),out body);}
    var payload=Encoding.UTF8.GetBytes(body);var header=Encoding.ASCII.GetBytes("HTTP/1.1 "+(allowed?"200 OK":"401 Unauthorized")+"\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "+payload.Length+"\r\n\r\n");stream.Write(header,0,header.Length);stream.Write(payload,0,payload.Length);
   }}catch{if(socket!=null)socket.Close();if(disposed)break;}}
  }
  string Api(string path,string method){
   var request=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:"+ApiPort+path);request.Method=method;request.Proxy=null;request.Timeout=1000;request.ReadWriteTimeout=1000;
   request.Headers["Authorization"]="Basic "+Convert.ToBase64String(Encoding.UTF8.GetBytes(admin+":"+adminPassword));
   if(method=="POST")request.ContentLength=0;
   using(var response=request.GetResponse())using(var reader=new StreamReader(response.GetResponseStream()))return reader.ReadToEnd();
  }
  void Kick(string username){
   // Only readers authenticated by the revoked user are disconnected, never the publisher or a new session.
   for(int attempt=0;attempt<3&&!disposed;attempt++){try{
    var reply=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(Api("/v3/rtsp/sessions/list?itemsPerPage=1000","GET"));
    foreach(Dictionary<string,object> item in (IEnumerable)reply["items"]){if(Convert.ToString(item["user"])==username&&Convert.ToString(item["state"])=="read"&&Convert.ToString(item["path"])=="audio")Api("/v3/rtsp/sessions/kick/"+Convert.ToString(item["id"]),"POST");}
    return;
   }catch{Thread.Sleep(100);}}
  }
  public void Dispose(){if(disposed)return;disposed=true;lock(gate){user="";hash=null;}listener.Stop();worker.Join(1200);}
 }
}
