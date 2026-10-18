$script:CodexCLIHttpTypeReady = $false

function Initialize-CodexCLIHttpType {
    $opSignal = [Signal]::Start('Initialize-CodexCLIHttpType') | Select-Object -Last 1
    try {
    if (-not $script:CodexCLIHttpTypeReady) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
public static class CodexCLIPinnedImageDownload {
  public static string LastTestSelectedAddress;
  public static string LastTestForwardedAddress;
  public static bool IsAllowedAddress(IPAddress ip) {
    var b = ip.GetAddressBytes();
    if (IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.IPv6Any) || ip.Equals(IPAddress.IPv6None) || ip.IsIPv6LinkLocal || ip.IsIPv6SiteLocal || ip.IsIPv6Multicast) return false;
    if (ip.AddressFamily == AddressFamily.InterNetworkV6) return !ip.IsIPv4MappedToIPv6 && (b[0] & 0xfe) != 0xfc;
    if (ip.AddressFamily != AddressFamily.InterNetwork) return false;
    return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 ||
      (b[0] == 169 && b[1] == 254) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
      (b[0] == 192 && b[1] == 0) || (b[0] == 198 && (b[1] == 18 || b[1] == 19)));
  }
  public static byte[] Get(string url, string[] hosts, int maxBytes, int seconds, out string mime) {
    string localMime = null;
    var bytes = Download(url, hosts, maxBytes, seconds,
      (host, token) => Dns.GetHostAddressesAsync(host, token), ConnectSocket, null,
      value => localMime = value).GetAwaiter().GetResult();
    mime = localMime;
    return bytes;
  }
  // Private module fixture entry point. It does not change jacket or plan policy.
  public static byte[] GetForTest(string url, string[] hosts, int maxBytes, int seconds,
      IPAddress[] addresses, int localPort, string fixtureThumbprint, int dnsDelayMs, out string mime) {
    string localMime = null;
    LastTestSelectedAddress = null;
    LastTestForwardedAddress = null;
    var bytes = Download(url, hosts, maxBytes, seconds,
      async (host, token) => { await Task.Delay(dnsDelayMs, token); return addresses; },
      async (selected, token) => {
        LastTestSelectedAddress = selected.ToString();
        var forwarded = new IPEndPoint(IPAddress.Loopback, localPort);
        var stream = await ConnectSocket(forwarded, token);
        LastTestForwardedAddress = forwarded.ToString();
        return stream;
      }, fixtureThumbprint, value => localMime = value).GetAwaiter().GetResult();
    mime = localMime;
    return bytes;
  }
  static async Task<Stream> ConnectSocket(IPEndPoint endpoint, CancellationToken token) {
    var socket = new Socket(endpoint.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
    try { await socket.ConnectAsync(endpoint, token); return new NetworkStream(socket, true); }
    catch { socket.Dispose(); throw; }
  }
  static async Task<byte[]> Download(string url, string[] hosts, int maxBytes, int seconds,
      Func<string,CancellationToken,Task<IPAddress[]>> resolve,
      Func<IPEndPoint,CancellationToken,Task<Stream>> connect,
      string fixtureThumbprint, Action<string> setMime) {
    var uri = new Uri(url, UriKind.Absolute);
    if (uri.Scheme != "https" || uri.UserInfo.Length != 0 || uri.Port != 443 || (Array.IndexOf(hosts, "*") < 0 && Array.IndexOf(hosts, uri.Host) < 0))
      throw new InvalidOperationException("Image URL is not allowed.");
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
    var token = deadline.Token;
    var addresses = await resolve(uri.DnsSafeHost, token).WaitAsync(token);
    if (addresses.Length == 0) throw new InvalidOperationException("Image host has no address.");
    foreach (var ip in addresses) if (!IsAllowedAddress(ip)) throw new InvalidOperationException("Image host resolves to a disallowed address.");
    var selected = addresses[0];
    var handler = new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false };
    if (fixtureThumbprint != null) {
      handler.SslOptions.RemoteCertificateValidationCallback = (sender, cert, chain, errors) =>
        cert != null && (errors & SslPolicyErrors.RemoteCertificateNameMismatch) == 0 &&
        String.Equals(cert.GetCertHashString(), fixtureThumbprint, StringComparison.OrdinalIgnoreCase);
    }
    handler.ConnectCallback = async (context, cancellation) => {
      return await connect(new IPEndPoint(selected, 443), cancellation);
    };
    using (handler) using (var client = new HttpClient(handler)) {
      client.Timeout = Timeout.InfiniteTimeSpan;
      using (var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, token)) {
        if (response.StatusCode != HttpStatusCode.OK || (int)response.StatusCode >= 300) throw new InvalidOperationException("Image download failed or redirected.");
        var mime = response.Content.Headers.ContentType?.MediaType;
        if (String.IsNullOrWhiteSpace(mime)) throw new InvalidOperationException("Image MIME is required.");
        setMime(mime);
        if (response.Content.Headers.ContentLength > maxBytes) throw new InvalidOperationException("Image is too large.");
        using (var source = await response.Content.ReadAsStreamAsync(token)) using (var target = new MemoryStream()) {
          var buffer = new byte[8192]; int count;
          while ((count = await source.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, maxBytes + 1 - (int)target.Length)), token)) > 0) {
            target.Write(buffer, 0, count);
            if (target.Length > maxBytes) throw new InvalidOperationException("Image is too large.");
          }
          return target.ToArray();
        }
      }
    }
  }
}
'@ -ErrorAction Stop
    $script:CodexCLIHttpTypeReady = $true
    }
    $opSignal.SetResult($true) | Out-Null
    }
    catch { $null = $opSignal.LogCritical('CodexCLI HTTPS transport initialization failed.') }
    return $opSignal
}

function Get-CodexCLIImageKind {
    param([byte[]]$Bytes)
    $opSignal = [Signal]::Start('Get-CodexCLIImageKind') | Select-Object -Last 1
    try {
        $kind = $null
        if ($Bytes.Length -ge 8 -and [Convert]::ToHexString($Bytes[0..7]) -ceq '89504E470D0A1A0A') { $kind = 'png' }
        elseif ($Bytes.Length -ge 3 -and [Convert]::ToHexString($Bytes[0..2]) -ceq 'FFD8FF') { $kind = 'jpeg' }
        elseif ($Bytes.Length -ge 6 -and [Text.Encoding]::ASCII.GetString($Bytes,0,6) -cin @('GIF87a','GIF89a')) { $kind = 'gif' }
        elseif ($Bytes.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($Bytes,0,4) -ceq 'RIFF' -and [Text.Encoding]::ASCII.GetString($Bytes,8,4) -ceq 'WEBP') { $kind = 'webp' }
        if ($null -eq $kind) { throw 'Unsupported image signature.' }
        $opSignal.SetResult($kind) | Out-Null
    }
    catch { $null = $opSignal.LogCritical('Unsupported image signature.') }
    return $opSignal
}

function Assert-CodexCLIImageMimeSignature {
    param([byte[]]$Bytes, [string]$Mime)
    $opSignal = [Signal]::Start('Assert-CodexCLIImageMimeSignature') | Select-Object -Last 1
    $kindSignal = Get-CodexCLIImageKind $Bytes | Select-Object -Last 1
    if ($opSignal.MergeSignalAndVerifyFailure($kindSignal)) { return $opSignal }
    $kind = $kindSignal.GetResult()
    $expected = @{ png='image/png'; jpeg='image/jpeg'; gif='image/gif'; webp='image/webp' }[$kind]
    if ($Mime -cne $expected) { $null = $opSignal.LogCritical('Image MIME and signature differ.'); return $opSignal }
    $opSignal.SetResult($kind) | Out-Null
    return $opSignal
}

function Invoke-CodexCLIImageDownload {
    param([string]$Url, [string[]]$AllowedHosts, [int]$MaxBytes, [int]$Seconds, [ref]$Mime)
    $opSignal = [Signal]::Start('Invoke-CodexCLIImageDownload') | Select-Object -Last 1
    try {
        $initSignal = Initialize-CodexCLIHttpType | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($initSignal)) { return $opSignal }
        $bytes = [CodexCLIPinnedImageDownload]::Get($Url, $AllowedHosts, $MaxBytes, $Seconds, $Mime)
        $opSignal.SetResult($bytes) | Out-Null
    }
    catch { $null = $opSignal.LogCritical('CodexCLI HTTPS image download failed.') }
    return $opSignal
}

function Resolve-CodexCLIMedia {
    param([object[]]$Media, [object]$Runtime, [string]$InvocationDirectory)
    $opSignal = [Signal]::Start('Resolve-CodexCLIMedia') | Select-Object -Last 1
    try {
    $files = @()
    foreach ($entry in $Media) {
        if ($null -eq $entry -or ($entry -isnot [Collections.IDictionary] -and $entry -isnot [pscustomobject])) { throw 'Prompt.Media entry is invalid.' }
        $allowedSignal = Assert-CodexCLIAllowedMembers $entry @('MediaPath','MediaUrl','MediaType','Detail') 'Media' | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($allowedSignal)) { return $opSignal }
        $pathSignal = Resolve-PathFromDictionary -Dictionary $entry -Path 'MediaPath' -SignalLevel 'Information' | Select-Object -Last 1
        $path = $null
        if (-not $pathSignal.Failure() -and $pathSignal.HasResult()) { $path = $pathSignal.GetResult() }
        $urlSignal = Resolve-PathFromDictionary -Dictionary $entry -Path 'MediaUrl' -SignalLevel 'Information' | Select-Object -Last 1
        $url = $null
        if (-not $urlSignal.Failure() -and $urlSignal.HasResult()) { $url = $urlSignal.GetResult() }
        $typeSignal = Resolve-PathFromDictionary -Dictionary $entry -Path 'MediaType' -SignalLevel 'Information' | Select-Object -Last 1
        $type = $null
        if (-not $typeSignal.Failure() -and $typeSignal.HasResult()) { $type = $typeSignal.GetResult() }
        $detailSignal = Resolve-PathFromDictionary -Dictionary $entry -Path 'Detail' -SignalLevel 'Information' | Select-Object -Last 1
        $detail = $null
        if (-not $detailSignal.Failure() -and $detailSignal.HasResult()) { $detail = $detailSignal.GetResult() }
        foreach ($value in @($path,$url,$type,$detail)) { if ($null -ne $value -and $value -isnot [string]) { throw 'Prompt.Media values must be text.' } }
        if ($type -cnotin @($null,'','image') -or -not [string]::IsNullOrWhiteSpace($detail)) { throw 'Unsupported media type or detail.' }
        if ([string]::IsNullOrWhiteSpace($path) -and [string]::IsNullOrWhiteSpace($url)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($path) -and -not [string]::IsNullOrWhiteSpace($url)) { throw 'Media requires one path or URL.' }
        if ($files.Count -ge $Runtime.Limits.MaxImages) { throw 'Too many CodexCLI images.' }
        $mime = $null
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            if (-not [IO.Path]::IsPathFullyQualified($path) -or -not [IO.File]::Exists($path)) { throw 'Local media path is invalid.' }
            $canonical = [IO.Path]::GetFullPath($path)
            $allowed = '*' -cin $Runtime.AllowedLocalImageRoots
            foreach ($root in $Runtime.AllowedLocalImageRoots) {
                if ($root -ceq '*') { continue }
                $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                if ($canonical.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true }
            }
            if (-not $allowed) { throw 'Local media path is outside allowed roots.' }
            $info = [IO.FileInfo]::new($canonical)
            if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Local media links are unsupported.' }
            $directoryCursor = $info.Directory
            while ($null -ne $directoryCursor) {
                if (($directoryCursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Local media links are unsupported.' }
                $directoryCursor = $directoryCursor.Parent
            }
            if ($info.Length -gt $Runtime.Limits.MaxImageBytes) { throw 'Image is too large.' }
            $bytes = [IO.File]::ReadAllBytes($canonical)
        }
        else {
            $downloadSignal = Invoke-CodexCLIImageDownload $url ([string[]]$Runtime.AllowedImageHosts) $Runtime.Limits.MaxImageBytes $Runtime.Limits.MaxDownloadSeconds ([ref]$mime) | Select-Object -Last 1
            if ($opSignal.MergeSignalAndVerifyFailure($downloadSignal)) { return $opSignal }
            $bytes = $downloadSignal.GetResult()
        }
        if ($bytes.Length -gt $Runtime.Limits.MaxImageBytes) { throw 'Image is too large.' }
        $kindSignal = if (-not [string]::IsNullOrWhiteSpace($url)) { Assert-CodexCLIImageMimeSignature $bytes $mime } else { Get-CodexCLIImageKind $bytes }
        $kindSignal = $kindSignal | Select-Object -Last 1
        if ($opSignal.MergeSignalAndVerifyFailure($kindSignal)) { return $opSignal }
        $kind = $kindSignal.GetResult()
        $destination = Join-Path $InvocationDirectory ("image-{0}.{1}" -f $files.Count,$kind)
        [IO.File]::WriteAllBytes($destination, $bytes)
        $files += $destination
    }
    $opSignal.SetResult($files) | Out-Null
    }
    catch {
        $safe = Get-CodexCLISafeFailureMessage $_.Exception.Message @(
            'Prompt.Media entry is invalid.', 'Unsupported Media member.',
            'Prompt.Media values must be text.', 'Unsupported media type or detail.',
            'Media requires one path or URL.', 'Too many CodexCLI images.',
            'Local media path is invalid.', 'Local media path is outside allowed roots.',
            'Local media links are unsupported.', 'Image is too large.',
            'Unsupported image signature.', 'Image MIME and signature differ.'
        ) 'CodexCLI media validation or acquisition failed.'
        $null = $opSignal.LogCritical($safe)
    }
    return $opSignal
}
