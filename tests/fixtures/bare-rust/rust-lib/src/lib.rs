//! Fixture module — a Rust cdylib with NO system dependencies, so the only
//! thing its build exercises is the toolchain: the crate compiled for the
//! target, whole-archived into a Bare module that exports the module-impl C
//! ABI and leaves `lp_*` undefined. Its sibling `rust-native-dep` is the one
//! that adds a system library to the picture.
//!
//! ...and, since the `web` variant learned to carry a Rust core, the same crate
//! compiled for `wasm32-unknown-emscripten` and linked INTO a Wasm host. The
//! two methods below the ping are what make that leg worth testing rather than
//! merely building: they persist through `logos_rust_sdk::storage`, which is
//! the one part of the SDK whose behaviour DIFFERS between the two targets.

use logos_rust_sdk::storage::{FileStorage, Storage};

/// Trivial IPC contract — for the native and mobile legs the build is the test,
/// and `ping` just makes the module loadable. `remember`/`recall` are the pair
/// the `web` leg needs: a write that must outlive its image, and a read from
/// the next one. The defaulted on_context_ready is framework plumbing.
pub trait BareRustModule: Send + 'static {
    fn ping(&mut self) -> String;

    /// Write `text` and COMMIT it. Answers whether the write is durable —
    /// `false` when the host offers no durable store, which is a legitimate
    /// state (a webview with storage disabled) and must be reported rather
    /// than hidden: an emscripten image has a filesystem, so the write itself
    /// succeeded either way.
    fn remember(&mut self, text: String) -> bool;

    /// What a previous image committed, or the empty string.
    fn recall(&mut self) -> String;

    fn on_context_ready(&mut self, _ctx: &RustModuleContext) {}
}

// The builder injects the generated scaffold here (no OUT_DIR; CARGO_MANIFEST_DIR).
include!(concat!(env!("CARGO_MANIFEST_DIR"), "/generated/provider_gen.rs"));

#[derive(Default)]
struct BareRustImpl;

/// The store this module was given, rooted at the persistence path the host
/// stamped onto the context. Opened per call rather than held: the fixture is
/// about the path from a Rust core to a durable medium, and holding it would
/// only add state that the property under test does not need.
fn store() -> Option<FileStorage> {
    let ctx = context()?;
    FileStorage::open(ctx.instance_persistence_path).ok()
}

const NOTE: &str = "note.txt";

impl BareRustModule for BareRustImpl {
    fn ping(&mut self) -> String {
        "ok".to_string()
    }

    fn remember(&mut self, text: String) -> bool {
        let Some(store) = store() else { return false };
        if store.write(NOTE, text.as_bytes()).is_err() {
            return false;
        }
        // THE BARRIER. Without it this returns true in a webview and the note
        // is gone on the next page load, with nothing anywhere saying so.
        store.commit().is_ok()
    }

    fn recall(&mut self) -> String {
        let Some(store) = store() else { return String::new() };
        store
            .read(NOTE)
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
            .unwrap_or_default()
    }
}

#[no_mangle]
pub extern "Rust" fn logos_module_install() {
    install::<BareRustImpl>();
}
