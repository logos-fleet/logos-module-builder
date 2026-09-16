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
//!
//! AND IT CALLS OUT FROM `on_context_ready`, which is the earliest moment a
//! module has to call anything and the one an author reaches for first —
//! "push my configuration into my dependency at load". That hook fires AT
//! MODULE LOAD (the generated `install`), before any inbound dispatch, so in a
//! wasm image it runs inside the host's `main()`. It used to reach a door the
//! host had not opened yet: `lp_invoke_async` found no connection, refused the
//! call INLINE, still returned LP_OK, and put nothing on the wire
//! (logos-workspace#195). Nothing downstream could see the difference between
//! that and a dependency that never answered, so the hook's call is a fixture
//! method of its own: `boot()` reports what it got, and the harness asserts the
//! frame reached the wire.

// The generated scaffold — the provider glue AND the typed `modules()` clients
// the builder generates from `dependency_overrides`.
include!(concat!(env!("CARGO_MANIFEST_DIR"), "/generated/provider_gen.rs"));

/// What the last outbound call answered. Empty until one lands.
///
/// A `static`, not a field on the impl: the callback the door takes is
/// `FnOnce + Send + 'static` and cannot borrow the module, which is true of
/// every async callback in the SDK and not a property of this fixture.
static LAST: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

/// The same, for the call `on_context_ready` makes. Kept apart from `LAST` so
/// the two cannot be confused for one another in a transcript: one is a call
/// the module made because somebody asked it to, the other is one it made
/// because it was loaded.
static BOOT: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

/// The argument the load-time call carries. Distinct from anything `kick` is
/// driven with, so a harness can tell the two frames apart by their payload.
const BOOT_AMOUNT: i64 = 41;

/// Park an outbound call's verdict where the reporting method can read it:
/// `ok:<value>` or `err:<message>`.
///
/// One spelling for both callers, so a transcript reads the same whichever of
/// them produced it. The slot is taken by reference rather than captured
/// because the door's callback is `FnOnce + Send + 'static`, which the statics
/// are and a field on the impl is not.
fn record_outcome<T: std::fmt::Display, E: std::fmt::Display>(
    slot: &'static std::sync::Mutex<String>,
    result: std::result::Result<T, E>,
) {
    *slot.lock().unwrap() = match result {
        Ok(v) => format!("ok:{}", v),
        Err(e) => format!("err:{}", e),
    };
}

pub trait WebRustCallerModule: Send + 'static {
    /// Fire `stub_target.increment(amount)` and return at once. The answer
    /// arrives later, in `last()`.
    fn kick(&mut self, amount: i64) -> String;

    /// `""` while the call is in flight, then `ok:<value>` or `err:<message>`.
    fn last(&mut self) -> String;

    /// The same report for the call made from `on_context_ready`. `""` means
    /// it is still in flight — or, before logos-workspace#195, that it was
    /// refused inline and never reached the wire at all.
    fn boot(&mut self) -> String;

    fn on_context_ready(&mut self, _ctx: &RustModuleContext) {}
}

#[derive(Default)]
struct WebRustCallerImpl;

impl WebRustCallerModule for WebRustCallerImpl {
    fn kick(&mut self, amount: i64) -> String {
        // The scope is load-bearing: the door may answer INLINE (a refusal it
        // decides without the wire), so the lock has to be gone before the
        // call goes out or the callback would deadlock on it.
        {
            let mut slot = LAST.lock().unwrap();
            slot.clear();
        }
        modules().stub_target.increment_async(amount, |result| record_outcome(&LAST, result));
        "dispatched".to_string()
    }

    fn last(&mut self) -> String {
        LAST.lock().unwrap().clone()
    }

    fn boot(&mut self) -> String {
        BOOT.lock().unwrap().clone()
    }

    /// THE HOOK CALLS ITS DEPENDENCY. Nothing here is conditional on the
    /// target: a module author writes this once and it has to behave the same
    /// on a desktop host and inside a Worker.
    fn on_context_ready(&mut self, _ctx: &RustModuleContext) {
        modules().stub_target.increment_async(BOOT_AMOUNT, |result| record_outcome(&BOOT, result));
    }
}

#[no_mangle]
pub extern "Rust" fn logos_module_install() {
    install::<WebRustCallerImpl>();
}
