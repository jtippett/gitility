use gitility_core::{Budget, ErrorCode, FetchRequest};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new(label: &str) -> Self {
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gitility-fetch-{label}-{}-{id}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path).expect("test directory can be created");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct HttpResponder {
    address: SocketAddr,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl HttpResponder {
    fn start(response: &'static [u8]) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("loopback listener binds");
        listener
            .set_nonblocking(true)
            .expect("listener can be nonblocking");
        let address = listener.local_addr().expect("listener has an address");
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread = std::thread::spawn(move || {
            while !thread_stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut stream, _peer)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_secs(1)))
                            .expect("accepted stream timeout can be set");
                        read_request_headers(&mut stream);
                        if stream.write_all(response).is_ok() {
                            let _ = stream.flush();
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("loopback listener failed: {error}"),
                }
            }
        });
        Self {
            address,
            stop,
            thread: Some(thread),
        }
    }

    fn url(&self) -> String {
        format!("http://{}/repo.git", self.address)
    }
}

impl Drop for HttpResponder {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = TcpStream::connect(self.address);
        if let Some(thread) = self.thread.take() {
            thread.join().expect("responder thread exits cleanly");
        }
    }
}

fn read_request_headers(stream: &mut TcpStream) {
    let mut request = Vec::new();
    let mut chunk = [0_u8; 1024];
    while !request.ends_with(b"\r\n\r\n") {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(count) => {
                request.extend_from_slice(&chunk[..count]);
                assert!(request.len() <= 64 * 1024, "request headers are bounded");
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break;
            }
            Err(error) => panic!("request headers could not be read: {error}"),
        }
    }
}

fn run_fetch(server: &HttpResponder, root: &Path, authorization: Option<&str>) -> ErrorCode {
    let request = FetchRequest {
        dest: root.join("destination.git"),
        url: server.url(),
        refspecs: vec!["+refs/heads/*:refs/remotes/origin/*".to_owned()],
        authorization: authorization.map(ToOwned::to_owned),
        prune: false,
    };
    gitility_core::fetch::fetch(request, &Budget::unlimited())
        .expect_err("fixed-status responder must fail")
        .code
}

#[test]
fn real_401_is_authentication_failed() {
    let server = HttpResponder::start(
        b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"test\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    let root = TestDirectory::new("401");

    assert_eq!(
        run_fetch(&server, root.path(), Some("Basic bad")),
        ErrorCode::AuthenticationFailed
    );
}

#[test]
fn real_301_is_redirect_network_error() {
    let server = HttpResponder::start(
        b"HTTP/1.1 301 Moved Permanently\r\nLocation: http://127.0.0.1:9/moved.git\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    let root = TestDirectory::new("301");
    let request = FetchRequest {
        dest: root.path().join("destination.git"),
        url: server.url(),
        refspecs: vec!["+refs/heads/*:refs/remotes/origin/*".to_owned()],
        authorization: None,
        prune: false,
    };

    let error = gitility_core::fetch::fetch(request, &Budget::unlimited())
        .expect_err("redirect must be refused");
    assert_eq!(error.code, ErrorCode::NetworkError);
    assert!(
        error.message.contains("redirect"),
        "redirect-specific message was lost: {}",
        error.message
    );
}

#[test]
fn real_403_is_network_error() {
    let server = HttpResponder::start(
        b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    let root = TestDirectory::new("403");

    assert_eq!(
        run_fetch(&server, root.path(), None),
        ErrorCode::NetworkError
    );
}
