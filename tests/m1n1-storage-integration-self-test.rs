// SPDX-License-Identifier: MIT
// Actual NVMEStorage implementation; fake fatfs traits and C read boundary.
extern crate alloc;
extern crate self as fatfs;
use core::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

pub enum SeekFrom { Start(u64), End(i64), Current(i64) }
pub trait IoBase { type Error; }
pub trait Read: IoBase { fn read(&mut self, data: &mut [u8]) -> Result<usize, Self::Error>; }
pub trait Write: IoBase {
    fn write(&mut self, data: &[u8]) -> Result<usize, Self::Error>;
    fn flush(&mut self) -> Result<(), Self::Error>;
}
pub trait Seek: IoBase { fn seek(&mut self, from: SeekFrom) -> Result<u64, Self::Error>; }
mod logging {
    #[macro_export]
    macro_rules! println { ($($args:tt)*) => {{ let _ = format!($($args)*); }}; }
}
include!("nvme-source.rs");
static CALLS: AtomicUsize = AtomicUsize::new(0);
static FAIL: AtomicBool = AtomicBool::new(true);
#[no_mangle]
extern "C" fn nvme_read(nsid: u32, lba: u64, pointer: *mut c_void) -> bool {
    assert_eq!(nsid, 1);
    assert!(!pointer.is_null() && pointer as usize % 4096 == 0);
    CALLS.fetch_add(1, Ordering::SeqCst);
    if FAIL.swap(false, Ordering::SeqCst) { return false; }
    unsafe { std::ptr::write_bytes(pointer as *mut u8, lba as u8, 4096); }
    true
}
fn main() {
    let mut disk = nvme::NVMEStorage::new(1, 10);
    let mut data = [0xaa; 64];
    assert!(disk.read(&mut data).is_err());
    assert_eq!(data, [0xaa; 64]);
    assert_eq!(disk.read(&mut data), Ok(64));
    assert_eq!(CALLS.load(Ordering::SeqCst), 2);
    assert_eq!(data, [10; 64]);
    assert_eq!(disk.read(&mut data), Ok(64));
    assert_eq!(CALLS.load(Ordering::SeqCst), 2);
    assert_eq!(disk.seek(SeekFrom::Start(4096)), Ok(4096));
    FAIL.store(true, Ordering::SeqCst);
    assert!(disk.read(&mut data).is_err());
    assert_eq!(disk.read(&mut data), Ok(64));
    assert_eq!(CALLS.load(Ordering::SeqCst), 4);
    assert_eq!(data, [11; 64]);
    std::println!("Rust NVMe cache: PASS (failed reads retried; valid same-sector cache preserved)");
}
