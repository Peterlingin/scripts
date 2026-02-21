# nparse.sh

A simple Bash script that parses Nmap plain-text output files and produces a clean, easy-to-read report suitable for copying into a document.

## Usage

```bash
./nparse.sh [-v] [-d] <nmap_output_file> [nmap_output_file2 ...]
```

## Options

| Option | Description |
|--------|-------------|
| `-v` | Include the **Version** column in the output |
| `-d` | Include the **resolved domain name** (if any) alongside the IP address |

Options can be combined freely (e.g. `-d -v` or `-dv`).

## Output Format

Each scanned host is presented as a titled block. If multiple files are provided, hosts are separated by a blank line.

**Default output** (no options):

```
Host: 45.33.32.156

PORT/PROTO   STATE      SERVICE
------------ ---------- ---------------
22/tcp       open       ssh
23/tcp       closed     telnet
80/tcp       open       http
443/tcp      closed     https
8043/tcp     closed     fs-server
```

**With `-d`** (domain name):

```
Host: 45.33.32.156 (scanme.nmap.org)

PORT/PROTO   STATE      SERVICE
------------ ---------- ---------------
22/tcp       open       ssh
...
```

**With `-d -v`** (domain name + version):

```
Host: 45.33.32.156 (scanme.nmap.org)

PORT/PROTO   STATE      SERVICE         VERSION
------------ ---------- --------------- -------
22/tcp       open       ssh             OpenSSH 6.6.1p1 Ubuntu 2ubuntu2.13 (Ubuntu Linux; protocol 2.0)
23/tcp       closed     telnet
80/tcp       open       http            Apache httpd 2.4.7 ((Ubuntu))
...
```

## Examples

Parse a single file:
```bash
./nparse.sh scan.nmap
```

Parse multiple files with domain names and version info:
```bash
./nparse.sh -d -v scan1.nmap scan2.nmap
```

Save the output to a text file:
```bash
./nparse.sh -d -v scan.nmap > report.txt
```

## Notes

- The script accepts standard Nmap plain-text output (`.nmap`) generated with `-oN` or `-oA`.
- Both TCP and UDP ports are supported.
- Recognised port states: `open`, `closed`, `filtered`, `open|filtered`, `closed|filtered`.
- If a host was scanned by IP only (no hostname resolution), the `-d` flag has no effect on that entry.
- Windows-style line endings (`\r\n`) are handled automatically.
