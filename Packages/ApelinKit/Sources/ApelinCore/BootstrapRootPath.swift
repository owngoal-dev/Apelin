import Foundation

/// A path recorded under a roothide bootstrap, carried over to the root the
/// bootstrap has now.
///
/// roothide names its root `.jbroot-` and sixteen hex digits under
/// `/var/containers/Bundle/Application`, and a reboot or a new jailbreak can
/// give it another name. A path written down under the old name — a
/// registered toolchain's or SDK's — then names nothing, though every file
/// is still there under the new one. Readers therefore take a recorded path
/// through `rebased(_:onto:)`, with a path of their own that is under the
/// current root (the install root, the data folder), before using it.
///
/// Rootless's `/var/jb` does not move: a path with no roothide root is
/// answered as it is. The name rule is libroothide's `is_jbroot_name`, the
/// same as `Shared/RoothideRoot.swift`'s.
public enum BootstrapRootPath {
    /// `path` with its roothide root's name replaced by the name of the one
    /// `reference` lies under. Only that one component changes, so the path
    /// keeps its own spelling (`/var/…` or `/private/var/…`) and two readers
    /// that rebase the same recorded path get the same string. Unchanged
    /// when either has no roothide root, or both name the same one.
    public static func rebased(_ path: String, onto reference: String) -> String {
        guard let recorded = rootRange(path), let current = rootRange(reference) else { return path }
        let name = current.components[current.index]
        guard recorded.components[recorded.index] != name else { return path }
        var components = recorded.components
        components[recorded.index] = name
        return "/" + components.joined(separator: "/")
    }

    /// The part of `path` below its roothide root (`usr/lib/x`, empty for
    /// the root itself); nil outside one. A name made from this, unlike one
    /// made from the whole path, stays the same when the root is renamed.
    public static func belowRoot(_ path: String) -> String? {
        guard let range = rootRange(path) else { return nil }
        return range.components[(range.index + 1)...].joined(separator: "/")
    }

    private static func rootRange(_ path: String) -> (components: [Substring], index: Int)? {
        let components = CanonicalPath.components(path)
        guard let index = components.firstIndex(where: isRootName) else { return nil }
        return (components, index)
    }

    /// libroothide's `is_jbroot_name`: sixteen hex digits whose last byte is
    /// the xor of the seven before it.
    static func isRootName(_ name: Substring) -> Bool {
        let prefix = ".jbroot-"
        let digits = name.dropFirst(prefix.count)
        guard name.hasPrefix(prefix), digits.count == 16, digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16)
        else { return false }
        let check = (1 ... 7).reduce(UInt8(0)) { $0 ^ UInt8(truncatingIfNeeded: value >> ($1 * 8)) }
        return check == UInt8(truncatingIfNeeded: value)
    }
}
