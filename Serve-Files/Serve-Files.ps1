# Serve-Files.ps1
# A local HTTP file server with upload, auth, live filter, zip download, and file logging.
# Author: PL (ver. 1 - April 2026)
# Usage: .\Serve-Files.ps1 [-Path "C:\folder"] [-Port 8080] [-Username user] [-Password pass] [-LogFile "server.log"]

param(
    [string]$Path     = (Get-Location).Path,
    [int]   $Port     = 8080,
    [string]$Username = '',
    [string]$Password = '',
    [string]$LogFile  = ''
)

$Path = (Resolve-Path $Path).Path
$url  = "http://+:$Port/"

if ($LogFile -eq '') {
    $LogFile = Join-Path $PSScriptRoot "server-$(Get-Date -Format 'yyyy-MM-dd').log"
}
$script:LogFile = $LogFile

function Write-Log([string]$method, [int]$status, [string]$urlPath, [long]$bytes, [int]$ms, [string]$extra = '') {
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $size = if ($bytes -gt 0) { Format-Size $bytes } else { '-' }
    $line = "$ts  $($method.PadRight(6)) $($status)  $($ms.ToString().PadLeft(5))ms  $($size.PadLeft(9))  $urlPath"
    if ($extra) { $line += "  [$extra]" }
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    $color = if ($status -lt 300) { 'DarkGray' } elseif ($status -lt 400) { 'Cyan' } elseif ($status -lt 500) { 'Yellow' } else { 'Red' }
    Write-Host "  [$status] $method $urlPath$(if ($extra) { " ($extra)" })" -ForegroundColor $color
}

function Get-MimeType([string]$ext) {
    $map = @{
        '.html'= 'text/html'; '.htm'= 'text/html'; '.css'= 'text/css'
        '.js'=   'application/javascript'; '.json'= 'application/json'
        '.xml'=  'application/xml'; '.txt'= 'text/plain'; '.md'= 'text/plain'
        '.csv'=  'text/csv'; '.png'= 'image/png'; '.jpg'= 'image/jpeg'
        '.jpeg'= 'image/jpeg'; '.gif'= 'image/gif'; '.svg'= 'image/svg+xml'
        '.ico'=  'image/x-icon'; '.webp'= 'image/webp'; '.pdf'= 'application/pdf'
        '.zip'=  'application/zip'; '.7z'= 'application/x-7z-compressed'
        '.tar'=  'application/x-tar'; '.gz'= 'application/gzip'
        '.mp3'=  'audio/mpeg'; '.mp4'= 'video/mp4'
        '.mkv'=  'video/x-matroska'; '.webm'= 'video/webm'
    }
    if ($map[$ext]) { return $map[$ext] }
    return 'application/octet-stream'
}

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N1} MB' -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return '{0:N1} KB' -f ($bytes / 1KB) }
    return "$bytes B"
}

function Send-Html([System.Net.HttpListenerResponse]$resp, [string]$html, [int]$status = 200) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $resp.StatusCode      = $status
    $resp.ContentType     = 'text/html; charset=utf-8'
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.Close()
    return $bytes.Length
}

$script:SVG_FOLDER  = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M1 3.5A1.5 1.5 0 0 1 2.5 2h3.086a1.5 1.5 0 0 1 1.06.44L7.5 3.293 8.354 2.44A1.5 1.5 0 0 1 9.414 2H13.5A1.5 1.5 0 0 1 15 3.5v9A1.5 1.5 0 0 1 13.5 14h-11A1.5 1.5 0 0 1 1 12.5v-9z" fill="#7ec8f5"/></svg>'
$script:SVG_IMAGE   = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="2" width="14" height="12" rx="1.5" stroke="#a89cf7" stroke-width="1.2"/><circle cx="5.5" cy="6" r="1.5" fill="#a89cf7"/><path d="M1 11l4-4 3 3 2-2 5 5" stroke="#a89cf7" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></svg>'
$script:SVG_AUDIO   = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="2" width="10" height="12" rx="1.5" stroke="#a89cf7" stroke-width="1.2"/><circle cx="4" cy="11" r="1.5" fill="#a89cf7"/><circle cx="8" cy="11" r="1.5" fill="#a89cf7"/><path d="M4 9.5V5h4v4.5" stroke="#a89cf7" stroke-width="1.2" stroke-linecap="round"/><path d="M12 4c1.5.8 2.5 2.3 2.5 4s-1 3.2-2.5 4" stroke="#7ec8f5" stroke-width="1.2" stroke-linecap="round"/></svg>'
$script:SVG_VIDEO   = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="3" width="10" height="10" rx="1.5" stroke="#a89cf7" stroke-width="1.2"/><path d="M11 6.5l4-2v7l-4-2V6.5z" fill="#a89cf7"/></svg>'
$script:SVG_ARCHIVE = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="3" width="14" height="2.5" rx="1" fill="#a89cf7"/><rect x="1" y="5.5" width="14" height="8" rx="1" stroke="#a89cf7" stroke-width="1.2"/><path d="M6.5 5.5v8M9.5 5.5v8" stroke="#a89cf7" stroke-width="1.2"/><rect x="5.5" y="8" width="5" height="2" rx=".5" fill="#a89cf7" opacity=".5"/></svg>'
$script:SVG_CODE    = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M5 4L1 8l4 4M11 4l4 4-4 4" stroke="#7ec8f5" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/><path d="M9.5 3l-3 10" stroke="#a89cf7" stroke-width="1.2" stroke-linecap="round"/></svg>'
$script:SVG_DOC     = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M3 1.5A1.5 1.5 0 0 1 4.5 0h6L14 3.5V14.5A1.5 1.5 0 0 1 12.5 16h-8A1.5 1.5 0 0 1 3 14.5v-13z" stroke="#a89cf7" stroke-width="1.2"/><path d="M10.5 0v3.5H14" stroke="#a89cf7" stroke-width="1.2" stroke-linecap="round"/><path d="M5.5 7h5M5.5 9.5h5M5.5 12h3" stroke="#a89cf7" stroke-width="1.1" stroke-linecap="round"/></svg>'
$script:SVG_EXE     = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8 1l2 5h5l-4 3 1.5 5L8 11l-4.5 3L5 9 1 6h5L8 1z" fill="#a89cf7" opacity=".7" stroke="#a89cf7" stroke-width=".8" stroke-linejoin="round"/></svg>'
$script:SVG_FILE    = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M3 1.5A1.5 1.5 0 0 1 4.5 0h6L14 3.5V14.5A1.5 1.5 0 0 1 12.5 16h-8A1.5 1.5 0 0 1 3 14.5v-13z" stroke="#5f5d84" stroke-width="1.2"/><path d="M10.5 0v3.5H14" stroke="#5f5d84" stroke-width="1.2" stroke-linecap="round"/></svg>'
$script:SVG_UP      = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8 13V3M3 8l5-5 5 5" stroke="#5f5d84" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>'
$script:SVG_ZIP_DL  = '<svg width="13" height="13" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8 1v9M4 7l4 4 4-4" stroke="#7ec8f5" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><path d="M2 12h12" stroke="#7ec8f5" stroke-width="1.5" stroke-linecap="round"/></svg>'

function Get-FileIcon([System.IO.FileSystemInfo]$item) {
    if ($item.PSIsContainer) { return $script:SVG_FOLDER }
    switch ($item.Extension.ToLower()) {
        { $_ -in '.png','.jpg','.jpeg','.gif','.svg','.webp','.ico','.bmp','.tiff' } { return $script:SVG_IMAGE }
        { $_ -in '.mp3','.wav','.flac','.aac','.ogg','.m4a' }                        { return $script:SVG_AUDIO }
        { $_ -in '.mp4','.mkv','.mov','.webm','.avi','.wmv' }                        { return $script:SVG_VIDEO }
        { $_ -in '.zip','.7z','.tar','.gz','.rar','.bz2','.xz' }                    { return $script:SVG_ARCHIVE }
        { $_ -in '.html','.htm','.css','.js','.ts','.json','.xml','.py','.ps1','.sh','.c','.cpp','.cs','.go','.rs','.rb','.php' } { return $script:SVG_CODE }
        { $_ -in '.pdf','.txt','.md','.csv','.xls','.xlsx','.doc','.docx','.ppt','.pptx','.odt','.rtf' } { return $script:SVG_DOC }
        { $_ -in '.exe','.msi','.bat','.cmd','.com' }                                { return $script:SVG_EXE }
        default                                                                        { return $script:SVG_FILE }
    }
}

function Build-DirectoryPage([string]$dirPath, [string]$urlPath) {
    $items   = Get-ChildItem -LiteralPath $dirPath | Sort-Object { -not $_.PSIsContainer }, Name
    $rows    = ''
    $urlPath = $urlPath.TrimEnd('/')
    $title   = if ($urlPath) { $urlPath } else { 'Home' }

    if ($urlPath -ne '') {
        $parent = if ($urlPath -match '/') { $urlPath -replace '/[^/]+$', '' } else { '' }
        $rows  += @"
<tr class="row-parent" data-name="..">
  <td class="col-icon">$($script:SVG_UP)</td>
  <td class="col-name" colspan="3"><a href="/$parent">Parent directory</a></td>
</tr>
"@
    }

    foreach ($item in $items) {
        $name      = $item.Name
        $href      = if ($urlPath) { "/$urlPath/$name" } else { "/$name" }
        $href      = $href -replace '\\', '/'
        $isDir     = $item.PSIsContainer
        $size      = if ($isDir) { '' } else { Format-Size $item.Length }
        $date      = $item.LastWriteTime.ToString('MMM dd, yyyy  HH:mm')
        $icon      = Get-FileIcon $item
        $cls       = if ($isDir) { 'row-dir' } else { 'row-file' }
        $zipBtn    = ''
        if ($isDir) {
            $zipHref = $href.TrimEnd('/') + '?zip=1'
            $zipBtn  = "<a href='$zipHref' class='zip-btn' title='Download folder as zip'>$($script:SVG_ZIP_DL)</a>"
        }
        $safeName  = $name -replace '"', '&quot;'
        $rows += @"
<tr class="$cls" data-name="$safeName">
  <td class="col-icon">$icon</td>
  <td class="col-name"><a href="$href">$name$(if ($isDir){ '/' })</a></td>
  <td class="col-zip">$zipBtn</td>
  <td class="col-size">$size</td>
  <td class="col-date">$date</td>
</tr>
"@
    }

    $count      = ($items | Measure-Object).Count
    $uploadPath = if ($urlPath) { "/$urlPath" } else { '/' }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    min-height: 100vh;
    background: #0f0f13;
    background-image:
      radial-gradient(ellipse 80% 50% at 20% 10%, rgba(99,57,210,0.28) 0%, transparent 60%),
      radial-gradient(ellipse 60% 40% at 80% 80%, rgba(20,130,180,0.18) 0%, transparent 55%);
    color: #e0dff5;
    font-family: 'Segoe UI', system-ui, sans-serif;
    padding: 2.5rem 1rem 4rem;
  }
  .container { max-width: 900px; margin: 0 auto; }
  header { margin-bottom: 1.5rem; }
  .breadcrumb { font-size: .72rem; color: #7a78a8; margin-bottom: .5rem; letter-spacing: .05em; text-transform: uppercase; }
  h1 { font-size: 1.5rem; font-weight: 600; color: #f0eeff; word-break: break-all; letter-spacing: -.01em; }
  .meta { margin-top: .35rem; font-size: .78rem; color: #5f5d84; }
  .toolbar { display: flex; gap: .6rem; margin-bottom: 1rem; align-items: center; }
  #filter {
    flex: 1; background: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.1); border-radius: 8px;
    padding: .45rem .85rem; color: #e0dff5; font-size: .88rem;
    font-family: inherit; outline: none; transition: border-color .15s;
  }
  #filter::placeholder { color: #3e3c60; }
  #filter:focus { border-color: rgba(168,156,247,0.4); }
  .card {
    background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08);
    border-radius: 14px; overflow: hidden;
  }
  table { width: 100%; border-collapse: collapse; }
  thead tr { background: rgba(255,255,255,0.04); border-bottom: 1px solid rgba(255,255,255,0.07); }
  th {
    padding: .6rem 1rem; font-size: .68rem; font-weight: 600;
    letter-spacing: .07em; text-transform: uppercase; color: #6b69a0;
    text-align: left; user-select: none;
  }
  th.col-size, th.col-date { text-align: right; }
  th.col-zip, th.col-icon  { text-align: center; }
  td { padding: .55rem 1rem; font-size: .87rem; border-bottom: 1px solid rgba(255,255,255,0.04); vertical-align: middle; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(255,255,255,0.04); transition: background .1s; }
  .col-icon { width: 2rem; text-align: center; }
  .col-zip  { width: 2rem; text-align: center; }
  .col-size { text-align: right; white-space: nowrap; color: #5f5d84; font-variant-numeric: tabular-nums; font-size: .8rem; }
  .col-date { text-align: right; white-space: nowrap; color: #5f5d84; font-variant-numeric: tabular-nums; font-size: .8rem; min-width: 9rem; }
  a { color: #a89cf7; text-decoration: none; font-weight: 500; }
  a:hover { color: #c8bcff; text-decoration: underline; text-underline-offset: 3px; }
  tr.row-dir .col-icon { color: #7ec8f5; }
  tr.row-dir a         { color: #7ec8f5; }
  tr.row-dir a:hover   { color: #b0e0ff; }
  tr.row-parent td { opacity: .7; }
  tr.row-parent a  { color: #5f5d84; font-weight: 400; font-size: .84rem; }
  tr.row-parent a:hover { color: #a89cf7; opacity: 1; }
  .zip-btn {
    display: inline-flex; align-items: center; justify-content: center;
    opacity: 0; padding: 3px; border-radius: 5px;
    transition: opacity .15s, background .15s;
  }
  tr:hover .zip-btn { opacity: 1; }
  .zip-btn:hover { background: rgba(126,200,245,0.15); text-decoration: none !important; }
  .no-results { text-align: center; padding: 2rem; color: #3e3c60; font-size: .88rem; display: none; }
  /* Upload zone */
  .upload-zone {
    margin-bottom: 1rem; border: 1.5px dashed rgba(168,156,247,0.25);
    border-radius: 12px; padding: 1.1rem 1.5rem; text-align: center;
    cursor: pointer; transition: border-color .2s, background .2s;
    font-size: .84rem; color: #5f5d84;
  }
  .upload-zone.drag-over { border-color: rgba(168,156,247,0.7); background: rgba(168,156,247,0.06); color: #a89cf7; }
  .upload-zone input[type=file] { display: none; }
  .upload-zone strong { color: #a89cf7; }
  .upload-progress { margin-bottom: 1rem; display: none; flex-direction: column; gap: .4rem; }
  .upload-item { display: flex; align-items: center; gap: .7rem; font-size: .82rem; color: #7a78a8; }
  .upload-bar-wrap { flex: 1; height: 4px; background: rgba(255,255,255,0.07); border-radius: 2px; overflow: hidden; }
  .upload-bar { height: 100%; background: #a89cf7; width: 0%; transition: width .2s; border-radius: 2px; }
  .upload-fname { min-width: 8rem; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .upload-status { min-width: 3rem; text-align: right; font-size: .76rem; }
  footer { margin-top: 1.8rem; font-size: .72rem; color: #3a3860; text-align: center; letter-spacing: .03em; }
  @media (max-width: 560px) {
    .col-date, th.col-date, .col-zip, th.col-zip { display: none; }
  }
</style>
</head>
<body>
<div class="container">
  <header>
    <div class="breadcrumb">File Server</div>
    <h1>$(if ($urlPath) { "/$urlPath" } else { '/' })</h1>
    <div class="meta" id="meta">$count item$(if ($count -ne 1) { 's' })</div>
  </header>

  <div class="upload-zone" id="dropzone">
    <input type="file" id="fileInput" multiple>
    Drop files here to upload, or <strong>click to browse</strong>
  </div>
  <div class="upload-progress" id="uploadProgress"></div>

  <div class="toolbar">
    <input type="text" id="filter" placeholder="Filter files..." autocomplete="off" spellcheck="false">
  </div>

  <div class="card">
    <table id="filetable">
      <thead>
        <tr>
          <th class="col-icon"></th>
          <th class="col-name">Name</th>
          <th class="col-zip"></th>
          <th class="col-size">Size</th>
          <th class="col-date">Modified</th>
        </tr>
      </thead>
      <tbody id="tbody">
$rows
      </tbody>
    </table>
    <div class="no-results" id="noResults">No files match your filter.</div>
  </div>

  <footer>PowerShell File Server &bull; port $Port</footer>
</div>
<script>
const uploadPath = '$uploadPath';

// Live filter
const filterInput = document.getElementById('filter');
const tbody       = document.getElementById('tbody');
const noResults   = document.getElementById('noResults');
const metaEl      = document.getElementById('meta');
const allRows     = Array.from(tbody.querySelectorAll('tr[data-name]'));
const totalCount  = allRows.filter(r => !r.classList.contains('row-parent')).length;

filterInput.addEventListener('input', () => {
  const q = filterInput.value.trim().toLowerCase();
  let visible = 0;
  allRows.forEach(row => {
    if (row.classList.contains('row-parent')) { row.style.display = q ? 'none' : ''; return; }
    const show = !q || (row.dataset.name || '').toLowerCase().includes(q);
    row.style.display = show ? '' : 'none';
    if (show) visible++;
  });
  noResults.style.display = (q && visible === 0) ? 'block' : 'none';
  metaEl.textContent = q
    ? visible + ' of ' + totalCount + ' item' + (totalCount !== 1 ? 's' : '') + ' match'
    : totalCount + ' item' + (totalCount !== 1 ? 's' : '');
});

// Upload
const dropzone    = document.getElementById('dropzone');
const fileInput   = document.getElementById('fileInput');
const progressBox = document.getElementById('uploadProgress');

dropzone.addEventListener('click', () => fileInput.click());
dropzone.addEventListener('dragover',  e => { e.preventDefault(); dropzone.classList.add('drag-over'); });
dropzone.addEventListener('dragleave', () => dropzone.classList.remove('drag-over'));
dropzone.addEventListener('drop', e => {
  e.preventDefault(); dropzone.classList.remove('drag-over');
  uploadFiles(Array.from(e.dataTransfer.files));
});
fileInput.addEventListener('change', () => { uploadFiles(Array.from(fileInput.files)); fileInput.value = ''; });

function uploadFiles(files) {
  if (!files.length) return;
  progressBox.style.display = 'flex';
  let completed = 0;
  const total = files.length;

  files.forEach(file => {
    const item  = document.createElement('div'); item.className = 'upload-item';
    const fname = document.createElement('span'); fname.className = 'upload-fname'; fname.textContent = file.name;
    const wrap  = document.createElement('div'); wrap.className = 'upload-bar-wrap';
    const fill  = document.createElement('div'); fill.className = 'upload-bar';
    const stat  = document.createElement('span'); stat.className = 'upload-status'; stat.textContent = '0%';
    wrap.appendChild(fill);
    item.appendChild(fname); item.appendChild(wrap); item.appendChild(stat);
    progressBox.appendChild(item);

    const base = uploadPath.endsWith('/') ? uploadPath : uploadPath + '/';
    const fd = new FormData();
    fd.append('file', file, file.name);
    const xhr = new XMLHttpRequest();
    xhr.open('POST', base + '?upload=1');
    xhr.upload.addEventListener('progress', e => {
      if (e.lengthComputable) {
        const pct = Math.round(e.loaded / e.total * 100);
        fill.style.width = pct + '%'; stat.textContent = pct + '%';
      }
    });
    xhr.addEventListener('load', () => {
      if (xhr.status === 200) {
        stat.textContent = 'done'; fill.style.background = '#6ec97e';
      } else {
        stat.textContent = 'error'; fill.style.background = '#e24b4a';
      }
      // Only reload once every file has finished (success or error)
      completed++;
      if (completed === total) setTimeout(() => location.reload(), 900);
    });
    xhr.addEventListener('error', () => {
      stat.textContent = 'error'; fill.style.background = '#e24b4a';
      completed++;
      if (completed === total) setTimeout(() => location.reload(), 900);
    });
    xhr.send(fd);
  });
}
</script>
</body>
</html>
"@
}

function IndexOf-Bytes([byte[]]$haystack, [byte[]]$needle, [int]$start = 0) {
    $limit = $haystack.Length - $needle.Length
    for ($i = $start; $i -le $limit; $i++) {
        $found = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($haystack[$i + $j] -ne $needle[$j]) { $found = $false; break }
        }
        if ($found) { return $i }
    }
    return -1
}

function Save-UploadedFile([System.Net.HttpListenerRequest]$req, [string]$destDir) {
    $ct = $req.ContentType
    if (-not $ct -or $ct -notmatch 'multipart/form-data') { return $false }
    if ($ct -notmatch 'boundary=([^\s;]+)') { return $false }
    $boundaryStr  = $Matches[1].Trim()

    # Read entire body into bytes
    $ms = [System.IO.MemoryStream]::new()
    $req.InputStream.CopyTo($ms)
    $body = $ms.ToArray()

    $enc          = [System.Text.Encoding]::UTF8
    $boundBytes   = $enc.GetBytes('--' + $boundaryStr)
    $CRLF         = [byte[]]@(13, 10)   # \r\n
    $CRLFx2       = [byte[]]@(13, 10, 13, 10)  # \r\n\r\n
    $saved        = $false

    $pos = IndexOf-Bytes $body $boundBytes 0
    while ($pos -ge 0) {
        # Skip past boundary + CRLF
        $pos += $boundBytes.Length
        if ($pos + 1 -ge $body.Length) { break }
        # Check for final boundary (--)
        if ($body[$pos] -eq 45 -and $body[$pos+1] -eq 45) { break }
        # Skip the CRLF after boundary line
        if ($body[$pos] -eq 13 -and $body[$pos+1] -eq 10) { $pos += 2 }

        # Find end of headers (\r\n\r\n)
        $headerEnd = IndexOf-Bytes $body $CRLFx2 $pos
        if ($headerEnd -lt 0) { break }

        $headerBytes = $body[$pos..($headerEnd - 1)]
        $headerText  = $enc.GetString($headerBytes)

        # Data starts after \r\n\r\n
        $dataStart = $headerEnd + 4

        # Find next boundary
        $nextBound = IndexOf-Bytes $body $boundBytes $dataStart
        if ($nextBound -lt 0) { break }

        # Data ends just before \r\n--boundary
        $dataEnd = $nextBound - 2   # strip the \r\n before the boundary
        if ($dataEnd -le $dataStart) { $pos = $nextBound; continue }

        # Only process parts that have a filename
        if ($headerText -match 'filename="([^"]+)"') {
            $filename = $Matches[1]
            if ($filename) {
                $safeName  = [System.IO.Path]::GetFileName($filename)
                $dest      = Join-Path $destDir $safeName
                $fileBytes = $body[$dataStart..($dataEnd - 1)]
                [System.IO.File]::WriteAllBytes($dest, $fileBytes)
                $saved = $true
            }
        }

        $pos = $nextBound
    }
    return $saved
}

function Stream-DirectoryZip([System.Net.HttpListenerResponse]$resp, [string]$dirPath, [string]$zipName) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # ZipArchive requires a seekable stream for the central directory.
    # Buffer into MemoryStream first, then write to response in one shot.
    $ms      = [System.IO.MemoryStream]::new()
    $archive = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        Get-ChildItem -LiteralPath $dirPath -Recurse -File | ForEach-Object {
            $rel   = $_.FullName.Substring($dirPath.Length).TrimStart('\').TrimStart('/')
            $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Fastest)
            $es    = $entry.Open()
            $fs    = [System.IO.File]::OpenRead($_.FullName)
            $fs.CopyTo($es); $fs.Close(); $es.Close()
        }
    } finally {
        $archive.Dispose()   # flushes central directory into $ms
    }

    $zipBytes = $ms.ToArray()
    $ms.Dispose()

    $resp.ContentType     = 'application/zip'
    $resp.ContentLength64 = $zipBytes.Length
    $resp.AddHeader('Content-Disposition', "attachment; filename=`"${zipName}.zip`"")
    $resp.OutputStream.Write($zipBytes, 0, $zipBytes.Length)
    $resp.Close()
}

function Test-Auth([System.Net.HttpListenerRequest]$req) {
    if (-not $Username -or -not $Password) { return $true }
    $h = $req.Headers['Authorization']
    if (-not $h -or -not $h.StartsWith('Basic ')) { return $false }
    $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($h.Substring(6)))
    return $decoded -eq "${Username}:${Password}"
}

function Send-AuthChallenge([System.Net.HttpListenerResponse]$resp) {
    $resp.StatusCode = 401
    $resp.AddHeader('WWW-Authenticate', 'Basic realm="File Server"')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes('<html><body><h2>401 Unauthorized</h2></body></html>')
    $resp.ContentType = 'text/html'; $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length); $resp.Close()
    return $bytes.Length
}

function Handle-Request($ctx) {
    $req   = $ctx.Request
    $resp  = $ctx.Response
    $sw    = [System.Diagnostics.Stopwatch]::StartNew()
    $sent  = 0

    $rawPath  = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath)
    $relPath  = $rawPath.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $fullPath = Join-Path $Path $relPath
    $query    = $req.Url.Query

    if (-not $fullPath.StartsWith($Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        $resp.StatusCode = 403; $resp.Close()
        Write-Log $req.HttpMethod 403 $rawPath 0 $sw.ElapsedMilliseconds 'path traversal'
        return
    }

    if (-not (Test-Auth $req)) {
        $sent = Send-AuthChallenge $resp
        Write-Log $req.HttpMethod 401 $rawPath $sent $sw.ElapsedMilliseconds
        return
    }

    $method = $req.HttpMethod

    if ($method -eq 'POST' -and $query -match 'upload=1') {
        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            $ok = Save-UploadedFile $req $fullPath
            if ($ok) { $sent = Send-Html $resp '<html><body>OK</body></html>' 200 }
            else     { $sent = Send-Html $resp '<html><body>Upload failed</body></html>' 400 }
            $uploadStatus = if ($ok) { 200 } else { 400 }
            Write-Log $method $uploadStatus $rawPath $sent $sw.ElapsedMilliseconds 'upload'
        } else {
            $sent = Send-Html $resp '<html><body>Not a directory</body></html>' 400
            Write-Log $method 400 $rawPath $sent $sw.ElapsedMilliseconds 'not a dir'
        }
        return
    }

    if ($method -eq 'GET' -and $query -match 'zip=1' -and (Test-Path -LiteralPath $fullPath -PathType Container)) {
        $zipName = Split-Path $fullPath -Leaf
        if (-not $zipName) { $zipName = 'archive' }
        try {
            Stream-DirectoryZip $resp $fullPath $zipName
            Write-Log $method 200 $rawPath 0 $sw.ElapsedMilliseconds "zip:$zipName"
        } catch {
            Write-Log $method 500 $rawPath 0 $sw.ElapsedMilliseconds $_.Exception.Message
        }
        return
    }

    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $html = Build-DirectoryPage $fullPath $rawPath.Trim('/')
        $sent = Send-Html $resp $html 200
        Write-Log $method 200 $rawPath $sent $sw.ElapsedMilliseconds
        return
    }

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        $ext  = [System.IO.Path]::GetExtension($fullPath).ToLower()
        $info = [System.IO.FileInfo]::new($fullPath)
        $resp.ContentType     = Get-MimeType $ext
        $resp.ContentLength64 = $info.Length
        $resp.AddHeader('Content-Disposition', "inline; filename=`"$($info.Name)`"")
        try {
            $fs = [System.IO.File]::OpenRead($fullPath)
            $fs.CopyTo($resp.OutputStream)
            $fs.Close()
        } catch {
            Write-Log $method 500 $rawPath 0 $sw.ElapsedMilliseconds $_.Exception.Message
            $resp.Close(); return
        }
        $resp.Close()
        Write-Log $method 200 $rawPath $info.Length $sw.ElapsedMilliseconds
        return
    }

    $sent = Send-Html $resp "<html><body><h2>404 Not Found</h2><p>$rawPath</p></body></html>" 404
    Write-Log $method 404 $rawPath $sent $sw.ElapsedMilliseconds
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($url)

try {
    $listener.Start()
} catch {
    Write-Host ""
    Write-Host "  ERROR: Could not start listener on port $Port." -ForegroundColor Red
    Write-Host "  Try running as Administrator, or pick a different port with -Port <number>." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

$localIP = (
    Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1' } |
    Select-Object -First 1
).IPAddress

Write-Host ""
Write-Host "  File Server started" -ForegroundColor Green
Write-Host "  Serving : $Path"
Write-Host "  Local   : http://localhost:$Port"
if ($localIP) { Write-Host "  Network : http://${localIP}:$Port" }
if ($Username) { Write-Host "  Auth    : $Username / $('*' * $Password.Length)" } else { Write-Host "  Auth    : none (open)" }
Write-Host "  Log     : $LogFile"
Write-Host ""
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

Add-Content -LiteralPath $LogFile -Value "# Started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  path=$Path  port=$Port" -Encoding UTF8

try {
    while ($listener.IsListening) {
        $async = $listener.BeginGetContext($null, $null)
        while (-not $async.AsyncWaitHandle.WaitOne(200)) {
            if (-not $listener.IsListening) { return }
        }
        if (-not $listener.IsListening) { break }
        try {
            $ctx = $listener.EndGetContext($async)
            Handle-Request $ctx
        } catch {
            if ($listener.IsListening) {
                Write-Host "  [ERR] $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
} finally {
    $listener.Stop()
    Add-Content -LiteralPath $LogFile -Value "# Stopped  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
    Write-Host ""
    Write-Host "  Server stopped." -ForegroundColor DarkGray
}
