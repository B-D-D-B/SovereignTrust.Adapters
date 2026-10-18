using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
#pragma warning disable SYSLIB0057

public sealed class CodexCLIFixtureHttps : IDisposable {
  readonly TcpListener listener;
  readonly CancellationTokenSource stop = new();
  readonly RSA rsa;
  readonly X509Certificate2 certificate;
  readonly Task server;
  readonly string mode;
  public int Port { get; }
  public string Thumbprint => certificate.GetCertHashString();
  public string Sni { get; private set; }
  public string Host { get; private set; }
  public string Error { get; private set; }
  public CodexCLIFixtureHttps(string mode) {
    this.mode = mode;
    rsa = RSA.Create(2048);
    var request = new CertificateRequest("CN=allowed.example", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    var san = new SubjectAlternativeNameBuilder(); san.AddDnsName("allowed.example");
    request.CertificateExtensions.Add(san.Build());
    using var created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
    certificate = new X509Certificate2(created.Export(X509ContentType.Pfx, "fixture"), "fixture",
      X509KeyStorageFlags.UserKeySet | X509KeyStorageFlags.Exportable);
    listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
    Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    server = Task.Run(Run);
  }
  async Task Run() {
    try {
      using var client = await listener.AcceptTcpClientAsync(stop.Token);
      using var tls = new SslStream(client.GetStream(), false);
      await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
        ServerCertificateSelectionCallback = (sender, host) => { Sni = host; return certificate; },
        EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13
      }, stop.Token);
      var request = new StringBuilder(); var buffer = new byte[1];
      while (!request.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal)) {
        if (await tls.ReadAsync(buffer, stop.Token) == 0) return;
        request.Append((char)buffer[0]);
        if (request.Length > 16384) throw new InvalidOperationException("Request header limit.");
      }
      foreach (var line in request.ToString().Split("\r\n"))
        if (line.StartsWith("Host:", StringComparison.OrdinalIgnoreCase)) Host = line[5..].Trim();
      if (mode == "stallheaders") { await Task.Delay(10000, stop.Token); return; }
      var png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9O3wAAAABJRU5ErkJggg==");
      string status = mode == "redirect" ? "302 Found" : "200 OK";
      string mime = mode == "missingmime" ? "" : mode == "wrongmime" ? "Content-Type: text/plain\r\n" : "Content-Type: image/png\r\n";
      int length = mode == "oversize" ? 100000 : mode == "stallbody" ? 100 : png.Length;
      string extra = mode == "redirect" ? "Location: https://other.example/image.png\r\n" : "";
      if (mode == "chunkedoversize") {
        var chunkedHeader = $"HTTP/1.1 {status}\r\n{mime}Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
        await tls.WriteAsync(Encoding.ASCII.GetBytes(chunkedHeader), stop.Token);
        await tls.WriteAsync(Encoding.ASCII.GetBytes("258\r\n"), stop.Token);
        await tls.WriteAsync(new byte[600], stop.Token);
        await tls.WriteAsync(Encoding.ASCII.GetBytes("\r\n258\r\n"), stop.Token);
        await tls.WriteAsync(new byte[600], stop.Token);
        await tls.WriteAsync(Encoding.ASCII.GetBytes("\r\n0\r\n\r\n"), stop.Token);
        await tls.FlushAsync(stop.Token);
        return;
      }
      var header = $"HTTP/1.1 {status}\r\n{mime}{extra}Content-Length: {length}\r\nConnection: close\r\n\r\n";
      await tls.WriteAsync(Encoding.ASCII.GetBytes(header), stop.Token); await tls.FlushAsync(stop.Token);
      if (mode == "stallbody") { await Task.Delay(10000, stop.Token); return; }
      if (mode != "oversize") { await tls.WriteAsync(png, stop.Token); await tls.FlushAsync(stop.Token); }
    } catch (OperationCanceledException) {} catch (Exception ex) { Error = ex.ToString(); }
  }
  public void Dispose() { stop.Cancel(); listener.Stop(); try { server.Wait(1000); } catch {} certificate.Dispose(); rsa.Dispose(); stop.Dispose(); }
}
