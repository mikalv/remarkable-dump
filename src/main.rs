use std::fs::{self, File, Metadata};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, Duration};

const DEFAULT_BIND: &str = "0.0.0.0:8080";
const DEFAULT_DIR: &str = "/home/root";
const PATTERN: &str = "rm-debug-";
const SUFFIX: &str = ".tgz";

fn main() {
    // Miljøvariabler for enkel styring
    let bind_addr = std::env::var("RM_HTTP_BIND").unwrap_or_else(|_| DEFAULT_BIND.to_string());
    let base_dir = std::env::var("RM_HTTP_DIR").unwrap_or_else(|_| DEFAULT_DIR.to_string());
    let base = Path::new(&base_dir);

    // Lytt
    let listener = TcpListener::bind(&bind_addr).expect("bind failed");
    eprintln!("rm-support-http listening on http://{bind_addr}/  (dir: {base_dir})");

    listener
        .set_nonblocking(false)
        .ok();

    for stream in listener.incoming() {
        match stream {
            Ok(mut s) => {
                // Sett kort read-timeout så dårlige klienter ikke henger oss
                let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
                handle(&mut s, base);
            }
            Err(e) => {
                eprintln!("accept error: {e}");
            }
        }
    }
}

fn handle(stream: &mut TcpStream, base: &Path) {
    // Minimal HTTP-parser: les første linje (metode, path)
    let mut buf = [0u8; 4096];
    let n = match stream.read(&mut buf) {
        Ok(n) if n > 0 => n,
        _ => return,
    };

    let req = String::from_utf8_lossy(&buf[..n]);
    let mut parts = req.lines().next().unwrap_or("").split_whitespace();
    let method = parts.next().unwrap_or("");
    let path    = parts.next().unwrap_or("/");

    if method != "GET" && method != "HEAD" {
        return http_405(stream);
    }

    match path {
        "/" | "/index.html" => serve_index(stream, base, method == "HEAD"),
        "/download/latest"  => serve_latest(stream, base, method == "HEAD"),
        _ if path.starts_with("/download/") => {
            let name = &path["/download/".len()..];
            if name.contains('/') || name.starts_with('.') {
                return http_400(stream, "bad filename");
            }
            let candidate = base.join(name);
            serve_file(stream, &candidate, method == "HEAD");
        }
        _ => http_404(stream),
    }
}

fn serve_index(mut s: &mut TcpStream, base: &Path, head_only: bool) {
    let latest = newest_bundle(base);
    let mut html = String::new();
    html.push_str("<!doctype html><meta charset=utf-8>");
    html.push_str("<title>reMarkable Support Bundles</title>");
    html.push_str("<style>body{font:14px system-ui, sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem}</style>");
    html.push_str("<h1>reMarkable Support Bundles</h1>");

    if let Some((p, m)) = latest.as_ref() {
        let name = p.file_name().unwrap().to_string_lossy();
        let size = m.len();
        html.push_str(&format!(
            "<p><strong>Siste bundle:</strong> <a href=\"/download/latest\">{}</a> ({} bytes)</p>",
            name, size
        ));
    } else {
        html.push_str("<p><em>Ingen bundles funnet i /home/root.</em></p>");
    }

    html.push_str("<h2>Alle bundles</h2><ul>");
    for (p, meta) in list_bundles(base) {
        let name = p.file_name().unwrap().to_string_lossy();
        html.push_str(&format!(
            "<li><a href=\"/download/{n}\">{n}</a> ({sz} bytes)</li>",
            n = name,
            sz = meta.len()
        ));
    }
    html.push_str("</ul>");

    let body = html.into_bytes();
    http_ok_html(&mut s, body, head_only);
}

fn serve_latest(s: &mut TcpStream, base: &Path, head_only: bool) {
    if let Some((path, _)) = newest_bundle(base) {
        serve_file(s, &path, head_only);
    } else {
        http_404(s);
    }
}

fn serve_file(mut s: &mut TcpStream, path: &Path, head_only: bool) {
    // Sikkerhet: bare rm-debug-*.tgz i base
    if path.extension().and_then(|e| e.to_str()) != Some("tgz") {
        return http_403(&mut s);
    }
    if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
        if !(name.starts_with(PATTERN) && name.ends_with(SUFFIX)) {
            return http_403(&mut s);
        }
    } else {
        return http_403(&mut s);
    }

    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return http_404(&mut s),
    };
    let meta = match file.metadata() {
        Ok(m) => m,
        Err(_) => return http_404(&mut s),
    };

    let fname = path.file_name().unwrap().to_string_lossy();
    let headers = format!(
        "HTTP/1.1 200 OK\r\n\
         Content-Type: application/gzip\r\n\
         Content-Length: {len}\r\n\
         Content-Disposition: attachment; filename=\"{fname}\"\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\r\n",
        len = meta.len(), fname = fname
    );

    let _ = s.write_all(headers.as_bytes());
    if head_only {
        return;
    }

    // Stream i biter for lavt minnebruk
    let mut f = file;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        match f.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if s.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
            Err(_) => break,
        }
    }
}

fn list_bundles(base: &Path) -> Vec<(PathBuf, Metadata)> {
    let mut v = Vec::new();
    if let Ok(rd) = fs::read_dir(base) {
        for e in rd.flatten() {
            let p = e.path();
            if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                if name.starts_with(PATTERN) && name.ends_with(SUFFIX) {
                    if let Ok(m) = e.metadata() {
                        v.push((p, m));
                    }
                }
            }
        }
    }
    // sort nyeste først (modified)
    v.sort_by_key(|(_, m)| m.modified().unwrap_or(SystemTime::UNIX_EPOCH));
    v.reverse();
    v
}

fn newest_bundle(base: &Path) -> Option<(PathBuf, Metadata)> {
    list_bundles(base).into_iter().next()
}

/* --------- små HTTP helpers --------- */
fn http_ok_html(s: &mut TcpStream, body: Vec<u8>, head_only: bool) {
    let headers = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = s.write_all(headers.as_bytes());
    if !head_only {
        let _ = s.write_all(&body);
    }
}

fn http_404(s: &mut TcpStream) {
    let body = b"Not Found".to_vec();
    let _ = s.write_all(
        format!(
            "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .as_bytes(),
    );
    let _ = s.write_all(&body);
}

fn http_403(s: &mut TcpStream) {
    let body = b"Forbidden".to_vec();
    let _ = s.write_all(
        format!(
            "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .as_bytes(),
    );
    let _ = s.write_all(&body);
}

fn http_405(s: &mut TcpStream) {
    let body = b"Method Not Allowed".to_vec();
    let _ = s.write_all(
        format!(
            "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .as_bytes(),
    );
    let _ = s.write_all(&body);
}

fn http_400(s: &mut TcpStream, msg: &str) {
    let body = format!("Bad Request: {msg}");
    let _ = s.write_all(
        format!(
            "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .as_bytes(),
    );
    let _ = s.write_all(body.as_bytes());
}
