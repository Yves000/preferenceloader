// The two values a PrimarySettingsListToggleState is made of that cannot be assembled from C.
//
// Settings' toggle rows are driven by an @Observable class holding the current value, a closure
// to call when the user flips the switch, and an ObservationRegistrar. Its module's Swift
// symbols are stripped, so there is no initialiser to call and the object is built field by
// field (see PLRootListToggleState in PLRootList.m). Two of those fields have no C
// representation:
//
//   - ObservationRegistrar owns a reference to a context object it allocates. Zero-filling the
//     field leaves a nil reference that SwiftUI dereferences on the first read.
//   - A Swift closure is a function pointer plus a heap-allocated context with its own
//     retain/release. Hand-assembling one means owning the layout of that context.
//
// Both are public API, so Swift builds them properly here and hands the bytes over.

import Observation

/// Writes a fresh ObservationRegistrar into `out`, which must point at uninitialised storage of
/// at least `PLSwiftObservationRegistrarSize()` bytes. Returns false when the OS has no
/// Observation, which is also every OS whose Settings has no SwiftUI root list.
@_cdecl("PLSwiftObservationRegistrarInitialize")
public func PLSwiftObservationRegistrarInitialize(_ out: UnsafeMutableRawPointer) -> Bool {
    guard #available(iOS 17.0, *) else { return false }
    out.assumingMemoryBound(to: ObservationRegistrar.self).initialize(to: ObservationRegistrar())
    return true
}

/// The size the field above occupies. Read at runtime rather than written down: ObservationRegistrar
/// is resilient, so its layout belongs to the OS the tweak is running on, not to the one it was
/// built against.
@_cdecl("PLSwiftObservationRegistrarSize")
public func PLSwiftObservationRegistrarSize() -> Int {
    guard #available(iOS 17.0, *) else { return 0 }
    return MemoryLayout<ObservationRegistrar>.size
}

/// A plain C function and a pointer to hand back to it. The pointer identifies which row was
/// flipped; it is not owned by the closure and has to outlive it.
public typealias PLBoolCallback = @convention(c) (UnsafeRawPointer?, Bool) -> Void

/// The closure in the representation a stored property of that type holds.
///
/// Swift keeps a function value in two shapes. A stored property declared `(Bool) -> Void` -- what
/// `setIsOn` is -- holds the concrete lowering, taking its argument in a register. A function type
/// substituted into a generic parameter holds the abstract lowering, taking it indirectly, and what
/// is written there is a reabstraction thunk rather than the closure.
/// `UnsafeMutablePointer<(Bool) -> Void>` is such a substitution.
///
/// The two differ only in their function pointer, and on arm64e that is fatal: Swift signs it with
/// a discriminator derived from the type it is stored as, so the abstract shape carries the wrong
/// signature for the field. A failed authentication poisons the pointer rather than trapping, and
/// the branch spins until the watchdog kills Settings.
///
/// A struct is not a generic substitution, so its field keeps the concrete lowering.
private struct PLBoolClosureField {
    var invoke: (Bool) -> Void
}

/// Writes a `(Bool) -> Void` closure calling `callback(token:)` into `out`, which must point at
/// uninitialised storage of `PLSwiftBoolClosureSize()` bytes. Ownership passes to the caller, who
/// must let the containing object's value witness destroy it.
@_cdecl("PLSwiftBoolClosureInitialize")
public func PLSwiftBoolClosureInitialize(_ out: UnsafeMutableRawPointer,
                                         _ callback: PLBoolCallback,
                                         _ token: UnsafeRawPointer?) {
    let closure: (Bool) -> Void = { value in callback(token, value) }
    out.assumingMemoryBound(to: PLBoolClosureField.self)
       .initialize(to: PLBoolClosureField(invoke: closure))
}

/// Releases what such a closure holds, without freeing the storage. Only the probe used to check
/// the signing needs this; a closure that reached a row is destroyed with the row.
@_cdecl("PLSwiftBoolClosureDestroy")
public func PLSwiftBoolClosureDestroy(_ pointer: UnsafeMutableRawPointer) {
    pointer.assumingMemoryBound(to: PLBoolClosureField.self).deinitialize(count: 1)
}

/// The size of that closure, for the same reason as above.
@_cdecl("PLSwiftBoolClosureSize")
public func PLSwiftBoolClosureSize() -> Int {
    return MemoryLayout<PLBoolClosureField>.size
}
