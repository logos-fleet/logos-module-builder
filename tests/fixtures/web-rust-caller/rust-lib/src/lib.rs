//! Fixture module — a `codegen.rust` module that CALLS ITS DEPENDENCY, which is
//! the one thing a wasm image could not do before the outbound door.
//!
//! WHY THE ANSWER IS PARKED IN A STATIC AND READ BY A SECOND METHOD. The door
//! is async and only async (ADR 0004: a Worker is one event loop and this image
//! has no ASYNCIFY, so a call that blocked for its reply would deadlock the loop
//! that delivers it). `kick` therefore cannot return the dependency's answer —
//! by the time its own reply goes out, the outbound call has not been answered
//! yet. Two methods is what "async" LOOKS like from the outside, and a fixture
//! that hid that would be testing a shape the platform does not have.
//!
//! IT CALLS `increment_async`, NOT `increment`. The synchronous twin is not
//! compiled on emscripten at all (logos-rust-sdk gates it on
//! `target_os = "emscripten"`, lidl-gen emits it under the same gate), so this
//! file is also the assertion that the surviving half is usable: if the gate
//! took the async twin with it, this fixture would not compile.

// The generated scaffold — the provider glue AND the typed `modules()` clients
// the builder generates from `dependency_overrides`.
include!(concat!(env!("CARGO_MANIFEST_DIR"), "/generated/provider_gen.rs"));

/// What the last outbound call answered. Empty until one lands.
///
/// A `static`, not a field on the impl: the callback the door takes is
/// `FnOnce + Send + 'static` and cannot borrow the module, which is true of
/// every async callback in the SDK and not a property of this fixture.
static LAST: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

pub trait WebRustCallerModule: Send + 'static {
    /// Fire `stub_target.increment(amount)` and return at once. The answer
    /// arrives later, in `last()`.
    fn kick(&mut self, amount: i64) -> String;

    /// `""` while the call is in flight, then `ok:<value>` or `err:<message>`.
    fn last(&mut self) -> String;

    fn on_context_ready(&mut self, _ctx: &RustModuleContext) {}
}

#[derive(Default)]
struct WebRustCallerImpl;

impl WebRustCallerModule for WebRustCallerImpl {
    fn kick(&mut self, amount: i64) -> String {
        {
            let mut slot = LAST.lock().unwrap();
            slot.clear();
        }
        modules().stub_target.increment_async(amount, |result| {
            let mut slot = LAST.lock().unwrap();
            *slot = match result {
                Ok(v) => format!("ok:{}", v),
                Err(e) => format!("err:{}", e),
            };
        });
        "dispatched".to_string()
    }

    fn last(&mut self) -> String {
        LAST.lock().unwrap().clone()
    }
}

#[no_mangle]
pub extern "Rust" fn logos_module_install() {
    install::<WebRustCallerImpl>();
}
