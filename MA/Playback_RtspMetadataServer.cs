using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace MachiningMonitor.Broadcast {
    public sealed class ProcessLifetime : IDisposable {
        const uint JobObjectExtendedLimitInformation = 9, KillOnJobClose = 0x2000;
        IntPtr handle;
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimitInformation info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr value);
        [StructLayout(LayoutKind.Sequential)] struct BasicLimitInformation { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount; public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimitInformation { public BasicLimitInformation BasicLimitInformation; public IoCounters IoInfo; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
        public ProcessLifetime() {
            handle=CreateJobObject(IntPtr.Zero, null); if(handle==IntPtr.Zero) throw new InvalidOperationException("No se pudo crear el grupo de procesos de transmisión.");
            var info=new ExtendedLimitInformation();info.BasicLimitInformation.LimitFlags=KillOnJobClose;
            if(!SetInformationJobObject(handle,(int)JobObjectExtendedLimitInformation,ref info,(uint)Marshal.SizeOf(typeof(ExtendedLimitInformation)))){var code=Marshal.GetLastWin32Error();CloseHandle(handle);handle=IntPtr.Zero;throw new InvalidOperationException("No se pudo configurar el cierre del proceso de transmisión: "+code);}
        }
        public void Attach(Process process) { if(process==null || process.HasExited) throw new InvalidOperationException("El codificador de transmisión no está disponible."); if(!AssignProcessToJobObject(handle,process.Handle)){var code=Marshal.GetLastWin32Error();throw new InvalidOperationException("No se pudo vincular FFmpeg al ciclo de vida de MA: "+code);} }
        public void Dispose() { if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;} }
    }
    public sealed class MetadataRtspServer : IDisposable {
        readonly IPAddress address; readonly int port; readonly int channels; readonly string user; readonly string passwordHash;
        readonly TcpListener listener; readonly List<Client> clients = new List<Client>(); readonly List<byte[]> metadataHistory = new List<byte[]>(); readonly object gate = new object();
        Thread acceptThread; volatile bool stopping; long metadataSequence; ushort metadataRtpSequence; uint metadataTimestamp;
        string announcedSdp = "";
        public volatile bool Listening; public volatile bool Publishing;
        public MetadataRtspServer(IPAddress address, int port, int channels, string user, string passwordHash) {
            this.address = address; this.port = port; this.channels = channels == 1 ? 1 : 2; this.user = user ?? ""; this.passwordHash = passwordHash ?? "";
            listener = new TcpListener(address, port);
        }
        public void Start() { listener.Start(); Listening = true; acceptThread = new Thread(AcceptLoop) { IsBackground = true }; acceptThread.Start(); }
        public void Stop() {
            stopping = true; Listening = false; Publishing = false;
            try { listener.Stop(); } catch { }
            Client[] copy; lock (gate) copy = clients.ToArray(); foreach (var c in copy) c.Close();
            if (acceptThread != null) acceptThread.Join(1000);
        }
        public void Dispose() { Stop(); }
        void AcceptLoop() { while (!stopping) { try { var tcp = listener.AcceptTcpClient(); tcp.NoDelay = true; var c = new Client(this, tcp); lock (gate) clients.Add(c); new Thread(c.Run) { IsBackground = true }.Start(); } catch { if (!stopping) Thread.Sleep(50); } } }
        internal void Remove(Client c) { lock (gate) clients.Remove(c); if (!clients.Any(x => x.IsPublisher)) Publishing = false; }
        internal string AnnouncedSdp { get { lock(gate) return announcedSdp; } set { lock(gate) announcedSdp=value ?? ""; } }
        internal bool Authorize(string header) {
            if (String.IsNullOrEmpty(user) && String.IsNullOrEmpty(passwordHash)) return true;
            if (String.IsNullOrEmpty(header) || !header.StartsWith("Basic ", StringComparison.OrdinalIgnoreCase)) return false;
            try {
                var value = Encoding.UTF8.GetString(Convert.FromBase64String(header.Substring(6).Trim()));
                var split = value.IndexOf(':'); if (split < 0 || !String.Equals(value.Substring(0, split), user, StringComparison.Ordinal)) return false;
                using (var sha = SHA256.Create()) return String.Equals("sha256:" + Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(value.Substring(split + 1)))), passwordHash, StringComparison.Ordinal);
            } catch { return false; }
        }
        internal void PublishAudio(byte[] packet) { Client[] copy; lock (gate) copy = clients.Where(x => x.IsReader && x.AudioChannel >= 0).ToArray(); foreach (var c in copy) c.SendInterleaved(c.AudioChannel, packet); }
        public void SendMetadata(byte[] framedJson) {
            if (framedJson == null || framedJson.Length == 0) return;
            lock (gate) { metadataHistory.Add((byte[])framedJson.Clone()); if(metadataHistory.Count>2048)metadataHistory.RemoveAt(0); }
            Client[] copy; lock (gate) copy = clients.Where(x => x.IsReader && x.MetadataChannel >= 0).ToArray(); foreach (var c in copy) SendMetadataToClient(c,framedJson);
        }
        internal void ReplayMetadata(Client client) { byte[][] copy; lock(gate) copy=metadataHistory.Select(x=>(byte[])x.Clone()).ToArray(); foreach(var item in copy)SendMetadataToClient(client,item); }
        void SendMetadataToClient(Client client, byte[] framedJson) {
            var timestamp = unchecked(metadataTimestamp += 1000); var sequence = metadataRtpSequence; const int maxPayload = 1200; var offset = 0;
            while (offset < framedJson.Length) {
                var count = Math.Min(maxPayload, framedJson.Length - offset); var packet = new byte[12 + count]; packet[0] = 0x80; packet[1] = 97; if (offset + count >= framedJson.Length) packet[1] |= 0x80;
                WriteU16(packet, 2, sequence++); WriteU32(packet, 4, timestamp); WriteU32(packet, 8, 0x4d414d31); Buffer.BlockCopy(framedJson, offset, packet, 12, count); offset += count; client.SendInterleaved(client.MetadataChannel, packet);
            }
            metadataRtpSequence = sequence; Interlocked.Increment(ref metadataSequence);
        }
        static void WriteU16(byte[] b, int at, ushort value) { b[at] = (byte)(value >> 8); b[at + 1] = (byte)value; }
        static void WriteU32(byte[] b, int at, uint value) { b[at] = (byte)(value >> 24); b[at + 1] = (byte)(value >> 16); b[at + 2] = (byte)(value >> 8); b[at + 3] = (byte)value; }

        internal sealed class Client {
            readonly MetadataRtspServer server; readonly TcpClient tcp; readonly NetworkStream stream; readonly object writeGate = new object();
            string session = Guid.NewGuid().ToString("N"); bool closed; bool authorized; bool metadataReplayed;
            public bool IsPublisher; public bool IsReader; public int AudioChannel = -1; public int MetadataChannel = -1;
            public Client(MetadataRtspServer server, TcpClient tcp) { this.server = server; this.tcp = tcp; stream = tcp.GetStream(); }
            public void Close() { if (closed) return; closed = true; try { tcp.Close(); } catch { } server.Remove(this); }
            public void Run() { try { while (!closed) { var first=ReadByte(); if(first<0)break; if (first == '$') { ReadInterleaved(); continue; } var request = ReadRequest(first); if (request == null) break; Handle(request); } } catch { } finally { Close(); } }
            int ReadByte() { return stream.ReadByte(); }
            void ReadInterleaved() { var channel = ReadByte(); var hi = ReadByte(); var lo = ReadByte(); if (channel < 0 || hi < 0 || lo < 0) throw new IOException(); var length = (hi << 8) | lo; var data = ReadExact(length); if (IsPublisher && (channel % 2 == 0)) server.PublishAudio(data); }
            byte[] ReadExact(int count) { var result = new byte[count]; var at = 0; while (at < count) { var n = stream.Read(result, at, count - at); if (n <= 0) throw new IOException(); at += n; } return result; }
            Request ReadRequest(int firstByte) {
                var bytes = new List<byte>(); int state = 0; var initial = firstByte; bytes.Add((byte)initial); while (true) { var b = ReadByte(); if (b < 0) return null; bytes.Add((byte)b); if (state == 0 && b == 13) state = 1; else if (state == 1 && b == 10) state = 2; else if (state == 2 && b == 13) state = 3; else if (state == 3 && b == 10) break; else state = b == 13 ? 1 : 0; if (bytes.Count > 65536) throw new IOException(); }
                var text = Encoding.ASCII.GetString(bytes.ToArray()); var lines = text.Split(new[] { "\r\n" }, StringSplitOptions.None); var first = lines[0].Split(' '); if (first.Length < 2) return null; var headers = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase); foreach (var line in lines.Skip(1)) { var p = line.IndexOf(':'); if (p > 0) headers[line.Substring(0,p).Trim()] = line.Substring(p+1).Trim(); }
                var bodyLength = headers.ContainsKey("Content-Length") ? Int32.Parse(headers["Content-Length"]) : 0; var body = bodyLength > 0 ? Encoding.UTF8.GetString(ReadExact(bodyLength)) : ""; return new Request { Method=first[0], Url=first[1], Headers=headers, Body=body };
            }
            void Handle(Request r) {
                var cseq = r.Headers.ContainsKey("CSeq") ? r.Headers["CSeq"] : "1";
                if (r.Method == "OPTIONS") { Send("RTSP/1.0 200 OK\r\nCSeq: "+cseq+"\r\nPublic: OPTIONS, DESCRIBE, ANNOUNCE, SETUP, RECORD, PLAY, TEARDOWN\r\n\r\n"); return; }
                if (r.Method == "ANNOUNCE") { var remote=((IPEndPoint)tcp.Client.RemoteEndPoint).Address; if(!IPAddress.IsLoopback(remote)){Send("RTSP/1.0 403 Forbidden\r\nCSeq: "+cseq+"\r\n\r\n");return;} IsPublisher=true; server.AnnouncedSdp=r.Body; server.Publishing=true; Send("RTSP/1.0 200 OK\r\nCSeq: "+cseq+"\r\n\r\n"); return; }
                if (r.Method == "DESCRIBE") { if(!server.Authorize(r.Headers.ContainsKey("Authorization")?r.Headers["Authorization"]:null)){SendAuth(cseq);return;} authorized=true; IsReader=true; var sdp=BuildSdp(server.AnnouncedSdp); Send("RTSP/1.0 200 OK\r\nCSeq: "+cseq+"\r\nContent-Base: rtsp://"+server.address+":"+server.port+"/audio/\r\nContent-Type: application/sdp\r\nContent-Length: "+Encoding.UTF8.GetByteCount(sdp)+"\r\n\r\n"+sdp); return; }
                if (r.Method == "SETUP") { if(!IsPublisher && !authorized && !server.Authorize(r.Headers.ContainsKey("Authorization")?r.Headers["Authorization"]:null)){SendAuth(cseq);return;} if(!IsPublisher)authorized=true; var metadata=r.Url.IndexOf("trackID=1",StringComparison.OrdinalIgnoreCase)>=0; if(metadata) MetadataChannel=2; else AudioChannel=0; var channel=metadata?"2-3":"0-1"; Send("RTSP/1.0 200 OK\r\nCSeq: "+cseq+"\r\nSession: "+session+"\r\nTransport: RTP/AVP/TCP;unicast;interleaved="+channel+"\r\n\r\n"); return; }
                if (r.Method == "RECORD") { Send("RTSP/1.0 200 OK\r\nCSeq: "+cseq+"\r\nSession: "+session+"\r\n\r\n"); return; }
                if (r.Method == "PLAY") { if(!server.Authorize(r.Headers.ContainsKey("Authorization")?r.Headers["Authorization"]:null) && !authorized){SendAuth(cseq);return;} authorized=true; Send("RTSP/1.0 200 OK\r\nCSeq: "+cseq+"\r\nSession: "+session+"\r\nRTP-Info: url=trackID=0;seq=0;rtptime=0,url=trackID=1;seq=0;rtptime=0\r\n\r\n"); if(IsReader && MetadataChannel>=0 && !metadataReplayed){metadataReplayed=true; ThreadPool.QueueUserWorkItem(_ => { try { Thread.Sleep(50); server.ReplayMetadata(this); } catch { } });} return; }
                if (r.Method == "TEARDOWN") { Send("RTSP/1.0 200 OK\r\nCSeq: "+cseq+"\r\nSession: "+session+"\r\n\r\n"); Close(); return; }
                Send("RTSP/1.0 200 OK\r\nCSeq: "+cseq+"\r\n\r\n");
            }
            string BuildSdp(string audio) { var config=server.channels==1?"1188":"1190"; var baseSdp="v=0\r\no=- 0 0 IN IP4 "+server.address+"\r\ns=Machining Monitor\r\nt=0 0\r\nm=audio 0 RTP/AVP 96\r\na=control:trackID=0\r\na=rtpmap:96 MPEG4-GENERIC/48000/"+server.channels+"\r\na=fmtp:96 streamtype=5;profile-level-id=1;mode=AAC-hbr;config="+config+";SizeLength=13;IndexLength=3;IndexDeltaLength=3\r\n"; return baseSdp+"m=application 0 RTP/AVP 97\r\na=control:trackID=1\r\na=rtpmap:97 x-machining-metadata/1000\r\na=fmtp:97 framing=MAM1\r\n"; }
            void SendAuth(string cseq) { Send("RTSP/1.0 401 Unauthorized\r\nCSeq: "+cseq+"\r\nWWW-Authenticate: Basic realm=MachiningMonitor\r\n\r\n"); }
            public void SendInterleaved(int channel, byte[] data) { if(closed)return; lock(writeGate){try{stream.WriteByte((byte)'$');stream.WriteByte((byte)channel);stream.WriteByte((byte)(data.Length>>8));stream.WriteByte((byte)data.Length);stream.Write(data,0,data.Length);stream.Flush();}catch{Close();}} }
            void Send(string text) { if(closed)return; lock(writeGate){var b=Encoding.UTF8.GetBytes(text);stream.Write(b,0,b.Length);stream.Flush();} }
        }
        sealed class Request { public string Method,Url,Body; public Dictionary<string,string> Headers; }
    }
}
