//! Fixture module — a Rust cdylib with NO system dependencies, so the only
//! thing its build exercises is the toolchain: the crate compiled for the
//! target, whole-archived into a Bare module that exports the module-impl C
//! ABI and leaves `lp_*` undefined. Its sibling `rust-native-dep` is the one
//! that adds a system library to the picture.

/// Trivial IPC contract — the build is the test; the method just makes the
/// module loadable. The defaulted on_context_ready is framework plumbing.
pub trait BareRustModule: Send + 'static {
    fn ping(&mut self) -> String;
    fn on_context_ready(&mut self, _ctx: &RustModuleContext) {}
}

// The builder injects the generated scaffold here (no OUT_DIR; CARGO_MANIFEST_DIR).
include!(concat!(env!("CARGO_MANIFEST_DIR"), "/generated/provider_gen.rs"));

#[derive(Default)]
struct BareRustImpl;

impl BareRustModule for BareRustImpl {
    fn ping(&mut self) -> String {
        "ok".to_string()
    }
}

#[no_mangle]
pub extern "Rust" fn logos_module_install() {
    install::<BareRustImpl>();
}
